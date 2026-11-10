# 来宾验收执行器加固记录（acceptance/v2/guest/Invoke-Phase.ps1）

- 范围：`acceptance/v2/guest/Invoke-Phase.ps1` 单文件（另加本说明与 `acceptance/evidence/runner-harden/` 自测证据）。
- 未改动：`installer/`、`tools/`、`win32/`、`sidecar/`、`acceptance/lib/*`、`acceptance/v2/host/*`、`acceptance/analysis/*`；未执行任何 git 操作。
- 目标：修掉静态审查（`acceptance/analysis/guest-runner-review.md`）的致命项 F-01…F-06 与需修正项 M-01…M-25，重点是**证据完整性**——宁可判 blocked / evidence-incomplete，也不让无证据的结论落成 pass。
- 自证手段（本轮**没有**跑 VM 里的 pre/full，按要求只做静态解析 + 纯本机小单测）：
  1. `Parser::ParseInput` 语法解析，`parseErrors=0`；UTF-8 BOM 存在；`Ensure-Utf8Bom.ps1` 0 problems。
  2. 包装层自测 `Invoke-WrapperSelfTest`（`MW_RUNNER_SELFTEST=1` 触发）：证明缺证据的 `Add-PhaseCheck` 落成 `evidence-incomplete`、默认状态是 `not-run`。
  3. 纯本机单测 `unit-selftest.ps1`（AST 取函数 + dot-source，不碰 VM）：工作区信号、保护快照分类、应有检查集合、阶段预算夹紧。
  4. 证据文件：`acceptance/evidence/runner-harden/{parse-check.json,parse-check.txt,ensure-utf8bom.txt,wrapper-selftest.json,wrapper-selftest.stdout.txt,unit-selftest.json,unit-selftest.stdout.txt,summary.json}`。

---

## 1. 致命项

### F-01 `Add-PhaseCheck` 包装层替调用方“补证据/补通过”（最要命）

**原缺陷**：`Preconditions` 默认 `@('来宾脚本已启动；验收库已加载')`、`Status` 默认 `'pass'`，并且证据路径用
`$ev = @($cp)` + `try { if (Test-Path …) { $ev += $s } } catch {}` 静默丢弃不存在的路径；`checks/<id>.json`
先按调用方声称的 `$Status` 落盘。结果：`Check.ps1` 的两道机械防线（pass 必须有前置条件、必须有真实存在的证据）被包装层架空。

**改法**（`Invoke-Phase.ps1` 的 `function Add-PhaseCheck`）：
1. `[string[]]$Preconditions = @()`——不再替调用方编前置条件；空前置会由库降级。
2. `[string]$Status = 'not-run'`（`ValidateSet` 保留 8 个状态，但**默认不是 pass**）；忘记写状态的检查不会被当成通过。
3. 证据逐条 `Test-Path -LiteralPath`（不做通配符解释）：存在才进入 `Evidence`；缺失的路径进 `$problems`（文本 `证据不存在：<path>`）并从 `Evidence` 移除。
4. 空前置 / 空证据同样进 `$problems`；`if ($Status -eq 'pass' -and $problems.Count -gt 0) { $Status = 'evidence-incomplete' }`；`Detail` 追加 problems；`Data` 是 IDictionary 时注入 `data.evidenceMissing`。
5. **先 `New-MwCheck`（拿到库二次降级后的真实状态）再写 `checks/<id>.json`**，并把该文件路径回填到 `checkFile` 字段——落盘状态与库判定一致，不再出现“json 写 pass、results 是 evidence-incomplete”。

**自证**：`Invoke-WrapperSelfTest`（runner 内，`MW_RUNNER_SELFTEST=1` 触发，主调度在 try 之前直接 `exit`）跑 4 个用例：

| 用例 | 期望 | 实际（`wrapper-selftest.json`） |
| --- | --- | --- |
| `missing-evidence-pass`：传 pass + 一个真实证据 + 一个不存在路径 | evidence-incomplete 且 Detail 含 `selftest-missing-evidence.txt` | evidence-incomplete ✔（detailOk=true） |
| `default-status`：不传 -Status | not-run | not-run ✔ |
| `pass-control`：pass + 前置条件 + 真实证据 | pass | pass ✔ |
| `no-precondition`：pass + 证据但无前置条件 | evidence-incomplete 且 Detail 含“前置条件” | evidence-incomplete ✔ |

每个用例都回读 `checks/<id>.json` 的 `status`，与内存对象比对（`checkFileStatus` 全一致）。结论 `ok:true`。

### F-02 升级起点版本（复核项）

live 文件已修（升级路径先装 3.0 再 `--wb-update` 到 3.1，并用 `Wait-FileVersion '^3\.0\.'` 断言起点）。本轮复核保留，未回退。

### F-03 升级保护快照把安装器自有日志当成“内容被覆盖”

**原缺陷**：`Get-ProtectedSnapshot` 对 `bots/private/secrets/out/logs` 全量哈希；产品每次安装都会写
`{Workspace}\logs\setup\installer-check.log`，于是“内容不被升级覆盖”必然出现一条 `added:` 变更，检查要么恒失败、要么被迫放宽。

**改法**：
1. 保护面**不缩水**：仍对 `bots/private/secrets/out/logs` 全量快照与比对。
2. 新增 `Split-ProtectedChanges -Changes`：把变更按前缀（`added:/content:/removed:`）拆开，只有
   `added:` 且归一化后为 `logs/setup/installer-check.log` 的条目归入 `Known`（安装器自有日志新增），其余归入 `Real`。
3. 三个 `c12-*-protected` 的判定改为 `$Real.Count -eq 0`；`Data` 同时保留 `realChanges`、`knownInstallerLogAdds`、`rawChanges`、计数——**已知噪音可见，但没有被忽略**。
4. `Requirement` 改写为“旧版程序备份完整性（由 c12-*-backup 逐文件 sha 覆盖）+ bots/private/secrets/out/logs 内容不被升级覆盖”。
5. 连带修（同一根因）：`c5-check-before-components` 与三条升级路径原先靠
   `{Workspace}\logs\setup\installer-check.log` 是否存在来证明 `/WORKSPACE` 生效。现在改用
   `Get-MwWorkspaceUseSignals -WorkspaceRoot -AppRoot`：观察 `ws-installer-log`、`ws-bootstrap-state`、`ws-bots-dir`、
   `app-installer-log`、`app-bootstrap-state` 五个信号，工作区内任一命中即 `Used=true`；每个阶段各自落
   `workspace-use-custom.json` / `workspace-use-default.json` / `workspace-use-old-helper.json` 并进入 Evidence。产品把日志迁出工作区后不会误判。

**依赖产品修复**：`installer/mingling.iss:126` 的 `[Run]` 目前仍把 `-LogFile "{code:WorkspacePath}\logs\setup\installer-check.log"`
写在工作区内。产品把该日志迁出工作区后，`Known` 列表自然为空，断言等价于“任何受保护内容变更都失败”（更严格）。在迁出前，本条只剥离这一条已知新增，且必须在 Data/Detail 里可见，不算放宽。

### F-04 真实中断检测的“无条件 45 秒 fallbackKill”与 observed 误计

**原缺陷**：轮询 45s 后只要 `$observed` 非空（任何 `##STEP`，包括“准备目录”）就 `$fallbackKill=$true` 并杀树；`c7-interrupt-observed`
只判 `$observed -and $killed`，fallback 触发的终止也被算作“观察到安装阶段”。

**改法**：
1. 删除 45s 无条件 fallback 分支。
2. 只有 `##STEP` 文本命中 `npm|node_modules|qrcode`（真实安装动作）才置 `$installPhaseSeen = $true` 并 break。
3. 只有 `$installPhaseSeen` 为真时才 `Stop-MwProcessTree` 且 `$killed = $true`。
4. 循环结束仍未见到安装阶段、但进程还活着：只做**清理性终止**，置 `$fallbackKill = $true`，**不计 killed、不计 observed**。
5. `c7-interrupt-observed` 的 Status 改为 `if ($intEnc.Bad) {'fail-fixture'} elseif ($installPhaseSeen -and $killed -and -not $fallbackKill) {'pass'} else {'fail-fixture'}`；`interrupt.json` 增 `installPhaseSeen` / `elapsedSeconds` / `launchEncodedFailure` / `launchHits`；Detail 明确“清理性终止不算 observed”。

**自证**：代码路径 + `interrupt.json` 字段结构（静态）。**本轮未跑 VM**，因此“扫描到 npm 阶段再杀”只有逻辑自证，需在恢复（recovery）阶段的真实运行里最终确认。

### F-05 真实断网只测 `-Offline`，且普通用户自己禁用网卡

**改法**（c8-real-network-cut 重写）：
1. **断网由宿主执行**：若 `$GuestRoot\network-cut-by-host.flag` 存在（宿主停止 VMware NAT 后写入），来宾**不再调用 `Disable-NetAdapter`**，只做取证。
2. 无 flag 且非管理员 → `blocked-precondition`（普通用户做管理员操作必然失败，不允许把失败当产品问题）；无 flag 且是管理员 → 才走自切（禁用另一默认路由网卡，`finally` 恢复 + 二次兜底）。
3. **外网不可达至少两个独立目标**：`Test-MwTcpTarget` 用 `TcpClient.BeginConnect` 计时，目标 `1.1.1.1:443` 与 `223.5.5.5:53`，逐条记 `{target,kind,ok,elapsedMs,error}`。
4. **DNS** 双证：先证明 DNS 客户端可用（解析 `localhost`），再证明 `example.com` 解析失败，并交叉 `Resolve-DnsName`；`dnsFailed = ($apiOk -and -not $dnsOk)`。
5. **控制/证据回传通道**：`$StageUrl/ping.txt` 仍须可达（`hostChannelOk`），证明“断网没把验收通道一起断掉”。
6. **正常模式必须失败**：空缓存下不带 `-Offline` 跑 `-Component uv`，必须非零退出，且解析输出**不得出现 `ok=1`**（`normalExit` / `normalOkOne` / `normalSatisfied`）；同时 `-Offline` 空缓存必须 exit 2。
7. `network-cut.json` 记录 `mode/hostCutFlag/isAdmin/tcpTargets/dnsAttempts/hostChannelOk/emptyOfflineExit/normalExit/normalOkOne/normalSatisfied/elapsedSeconds`；`host-cut` 模式下外网仍可达 → `fail-fixture`（说明宿主没真断网，不是产品问题）。

**依赖环境**：需要宿主真实停 NAT 并写 flag；本机无法验证，普通用户来宾在无 flag 时按设计落 `blocked-precondition`。

### F-06 full 阶段超时 14400s > 宿主上限 10800s

**改法**：
1. `c9-full-install` 的单步超时 `9000`（`$fullBudgetSeconds`），Detail 记录单步/阶段预算与被夹紧次数。
2. 新增阶段预算表 `pre=5100 / full=10200 / recovery=6900 / upgrade=6900 / final=2400`，全部低于宿主上限（5400/10800/7200/7200/2700）。
3. `Get-MwRemainingBudget`（下限 30s）+ `Resolve-MwStepTimeout`：`Invoke-Cap` / `Invoke-Long` 的每个子步骤超时都被夹到“阶段剩余预算”内；被夹紧的记录进 `$script:BudgetClamped`（label/requested/used/at），避免整段被宿主判 fail-fixture。

**自证**：`unit-selftest.ps1` 的 `phase-budget` 用例：`Resolve-MwStepTimeout -Requested 9000` → 9000 原样通过；`-Requested 999999` → 夹到 10200（< 10800）；5 个阶段预算均 < 宿主上限。

---

## 2. 需修正项 M-01…M-25

| 编号 | 改法 | 自证 | 残余风险 |
| --- | --- | --- | --- |
| M-01 | c3 用 Inno 日志 `Administrative install mode:` 行参与判定：pass 需 `exit=0` 且非管理员会话且 `modeNo`（`: No`）；否则 evidence-incomplete 并写明日志缺行 | 代码 + Detail 文案 | 需真实安装日志（VM） |
| M-02 | c4 Expected 改为 `exe=<AppExe>; WsPath=<规范路径>`，Actual 改为 `exeExists=…; loggedWs=…`，两者不再相同 | 静态 | 需 VM 安装 |
| M-03 | c1-state-model 改单一判定 `pass` / `fail-product`，并给 `$stateReason`（不存在 / 解析失败 / schema≠1 / components=0） | 静态 | 无 |
| M-04 | c2-stage-integrity 全量解析 `checksums.txt`：行格式、重复、必需 5 项在清单、所有列名文件逐个 sha256 比对、记录未列名文件、用 `checksums.txt.sha256` 做自校锚点（match/mismatch/none）；不一致从 `evidence-incomplete` 改为 **fail-product** | 静态 | 需 stage 实包 |
| M-05 | embedding digest 判据：digest 必须 64hex 且 URL **精确**匹配 `/manifests/sha256:<digest>$`，`source.layers` 每条 `sha256:<64hex>` 且 size>0；`verifiedRemotely=false` 明确写出“远端层哈希未在本机复核” | 静态 | 远端层内容无法本机验证 |
| M-06 | c7-half-install-online-fix 断言含 `resolve=0`（live 已有，复核保留） | 静态 | 需 VM |
| M-07 | c7-online-recovers 增：node.exe 哈希前后一致（未被重装）+ qrcode 由缺到有 + resolve 退出 0；失败归 fail-product，Detail 说明违反“只补缺失” | 静态 | 需 VM |
| M-08 | c10：>64MB 文件不再整块跳过，改为首尾各读 8MB 部分扫描并标 `partial-large`；扫描根补 `%LOCALAPPDATA%\Programs\MinglingWorkbench`、`%APPDATA%\MinglingWorkbench`、`%ProgramData%\MinglingWorkbench`；不可读文件数参与判定 | 静态 | 大文件中间窗口未扫（已标注） |
| M-09 | c9-model-stub-protocol 增真实请求 `http://127.0.0.1:18080/v1/models`：桩 2xx 才算“桩在监听”；`configHits=0` 或出现 `api.deepseek.com` → fail-product；`model-stub-probe.json` 落证据 | 静态 | 需 VM |
| M-10 | c9-astrbot-process 只把 **2xx** 当 HTTP 通过；探测 `/`、`/api/stat`、`/login` 三路径并逐条记录 `astrbot-http.json`；4xx/5xx 不再算通过 | 静态 | 需 VM |
| M-11 | c11-pre-snowluma-manual 改为**不传 `-Base`** 走产品默认解析，并解析输出里的 `Base=` 核实；再直接跑 `$App\tools\verify-manual.ps1 -Kind qq` 取真实退出码；无 verify-manual → blocked-precondition；detect 退出 0 → fail-product | 静态 + 产品脚本已核实存在 | 需 VM |
| M-12 | c13-autosetup-trace：`Get-BootstrapChildTrace` 为每条记录生成 `ancestry`（沿 ParentProcessId 最多 8 跳，遇 EntryPid 停）；`$chainOk` 要求链回工作台入口 PID，否则 fail-product | 静态 | 需 VM 启动工作台 |
| M-13 | c13-skill-wrapper：记录 run 前/后工作台 exe 哈希稳定性（`appStable`）、封装脚本是否调用 `resolve-program-root.ps1`（`wrapCallsResolve`）、是否错误地出现在工作区（`shownInWs` 必须为 false）；Detail 自认“两处哈希现算不构成独立证据” | 静态 | 需 VM |
| M-14 | c13-evidence-inventory：逐行校验 sha256 为 64hex 或 `skipped-large`（`badRows=0`）+ `totalBytes>0` + `files>0` 才 pass；统计 skipped-large 数量 | 静态 | 无 |
| M-15 | 上传不再 `Select-Object -First 40`，改为全量 `Sort-Object Name` 上传所有 checks | 静态 | 数量大时靠 M-25 预算兜底 |
| M-16 | 兜底上传含 `manifest.json.sha256`（正确文件名；live 已有，复核） | 静态 | 无 |
| M-17 | 默认目录升级改为**不传 `/DIR`**（`Install-MwVersion -NoDir`），由产品 `DefaultInstallDir` 推断；用安装日志 `Dest filename: …\MinglingWorkbench.exe` 反证落点，`default-dir-inference.json` + `logMatchesDefault` 进证据；c12-default-upgrade 的 Expected/Actual/Detail 同步改写 | 静态 | 需 VM 真装 |
| M-18 | 三条升级路径都有 `c12-*-backup` 逐文件 sha 比对（live 已有 default/old-helper，复核保留） | 静态 | 需 VM |
| M-19 | old-helper 保护检查补 before 快照证据文件 `upgrade-old-helper-before.json`，Evidence 同时含 before/after，Data 给两侧计数 | 静态 | 需 VM |
| M-20 | c6 幂等归因：第二次运行前记 `secondStartUtc`，mtime ≥ 该时刻的变更直接归 installer（`afterSecondStart`），命中自然基线的归 ambiguous，其余归 installer——不再让 ambiguous 吞掉真实写入 | 静态 | 需 VM |
| M-21 | `Get-StageAsset` 失败包 try/catch，`c2-stage-assets` 判 blocked-env 而不是 fail-fixture（live 已有，复核） | 静态 | 需 stage 服务 |
| M-22 | `Save-MwPhase` 失败时写 `save-error.txt` + `save-phase-error.json`，`$status='failed'` 且 `$exitCode=11`；成功后把 `phase.json/manifest.json/manifest.json.sha256/results.jsonl/commands.jsonl` 复制回 `$script:EvidenceDir`，避免 `phases\<Phase>` 不在宿主回收范围时证据丢失 | 静态 | 宿主侧回收范围仍需确认 |
| M-23 | 新增 `Get-ExpectedCheckIds -ForPhase`（pre 15 / full 12 / recovery 10 / upgrade 9 / final 6）与 `Add-PhaseCoverageCheck`，在 finally 最前面执行：缺检查 → evidence-incomplete（若本阶段已被 `c0-*-precondition` 阻塞则 not-run），多出的只记录不失败 | `unit-selftest` expected-ids 用例 | 新增检查需同步维护清单 |
| M-24 | 两处等升级完成 `Wait-FileVersion` 240s → 900s（覆盖产品 600s 自更新窗口） | 静态 | 需 VM |
| M-25 | 上传加总预算：`Send-PhaseEvidence -TimeoutSeconds 20 -MaxTotalSeconds 900`，用 Stopwatch 计总时长，超预算条目记 `skipped='budget'`，不再串行 55×180s 撑爆 final 45min | 静态 | 证据极多时仍可能截断上传（但会显式记录） |

---

## 3. 失败分类与阶段收尾

- 分类口径（全阶段一致）：子项断言不成立 = `fail-product`；夹具自身错误（启动编码失败、前置证据缺失、无法证明执行过）= `fail-fixture`；环境/前置缺失（缺 bootstrap、缺 stage 包、普通用户无法断网、无 verify-manual）= `blocked-precondition`（或 `blocked-env`，视是否属于环境而非产品）；pass 但缺前置/缺证据 = `evidence-incomplete`。
- 退出码统一由 `lib/Check.ps1` 的 `Get-MwPhaseExitCode` 计算（fail-fixture 11 > fail-product 10 > blocked-precondition 12 > blocked-env 13 > evidence-incomplete 14 > 0），runner 不自行决定退出码；`c0-harness-fatal` 强制 11。
- 每个阶段无论成败，finally 都会：`Get-MwCounts` → `Get-MwPhaseExitCode` → `Complete-MwProgress` → `Save-MwPhase`（写 `phases/<Phase>` 的 results/commands/phase.json/manifest）→ 写 `done.json` → 兜底 `Send-PhaseEvidence` 上传（含 `manifest.json.sha256`）。M-22/M-23/M-25 已保证保存失败、检查缺失、上传超预算这三种情况都会显式留痕而不是静默吞掉。

## 4. Start-Process / -ArgumentList 参数编码（lead m00360，单列）

### 4.1 审计结论

`acceptance/v2/guest/Invoke-Phase.ps1` 内**没有真实的 `Start-Process` 或 `-ArgumentList` 调用**（全文 3 处 `Start-Process` 与 2 处 `-ArgumentList` 都是注释/Steps 描述文本）。所有子进程都经
`Invoke-Cap` / `Invoke-Long` → `acceptance/lib/Capture.ps1`：powershell 分支用 `ConvertTo-PsFileArg`、cmd 分支用 `ConvertTo-CmdArg`、exe 分支用 `ConvertTo-MsvcrtArg`，再以 `ProcessStartInfo.FileName/Arguments` 启动。**只要不绕过这两个包装，含空格/中文路径不会被空格切断。**

但“库层已经正确”不等于“结论可信”：一旦某次启动仍然没跑起来（-196608 / 0xFFFD0000），外层很容易把它误读成产品失败，甚至让“期待失败”的检查蒙混过关。因此本轮加了三道守卫。

### 4.2 新增守卫

1. `Test-MwLaunchEncodedFailure -Record / -Stdout / -Stderr`：识别
   `exit=-196608`（0xFFFD0000）、`exit=-1073741510`（0xC000013A，被终止）、stderr 里的
   `-File 参数…不存在` / `is not recognized as the name of a script file` / `无法将…识别为…脚本文件` / `Cannot find path|drive`，返回 `{Bad; Hits}`。
2. `Invoke-Cap` / `Invoke-Long` 新增 `-CheckId`：每次命令结束后检测，命中就把 `<label> → <hits>` 记入
   `$script:LaunchAnomaliesAll` 与 `$script:LaunchAnomaliesByCheck[$CheckId]`，同时 `Add-MwProgressTail` 告警。
3. `Add-PhaseCheck` 末尾守卫：若该 `-Id` 有关联的启动异常，把“子进程未真正执行：…”写进 `problems`/`Detail`，并把
   `pass / fail-product / evidence-incomplete / blocked-precondition / blocked-env / manual-pending` **一律改判 `fail-fixture`**，`Data.launchAnomalies` 留证。c7 中断检查另行首判。
4. `Get-MwLaunchPrecondition -Paths -Label`：对“期待失败/期待成功”的检查先证明被执行的程序真的存在（`Test-Path -LiteralPath` + `bytes` + `sha256`），落成 `launch-pre-*.json`；前置不成立 → `fail-fixture`。
5. stdout/stderr 重定向：由 `Capture.ps1` 保证落到 `<EvidenceDir>\<runId>-<label>.stdout.txt` / `.stderr.txt`，runner 把这些路径与 `launch-pre-*.json` 一并写进各检查的 `Evidence`。

### 4.3 已接 `-CheckId` 的调用点清单（20 处 + 3 条安装器调用）

| label | check id |
| --- | --- |
| `install-31` | c3-normal-user-install |
| `bootstrap-full` | c9-full-install |
| `self-setup-apply` / `self-setup-verify` | c9-selfsetup-apply / c9-selfsetup-verify |
| `astrbot-restart` | c9-astrbot-process |
| `tamper-uv-offline` | c2-tamper-reject |
| `check-before-components` | c5-check-before-components |
| `bili-offline-after-interrupt` / `bili-online-after-interrupt` | c7-offline-fails-after-interrupt / c7-online-recovers |
| `half-bili-offline` / `half-bili-online` | c7-half-install-synthetic / c7-half-install-online-fix |
| `uv-online` / `uv-offline-valid` | c8-offline-valid-cache |
| `uv-offline-empty` | c8-offline-empty-cache |
| `uv-offline-bad` | c8-offline-bad-cache |
| `uv-offline-netcut` / `uv-normal-netcut` | c8-real-network-cut |
| `update-custom` / `update-default` / `update-old-helper` | c12-custom-upgrade / c12-default-upgrade / c12-old-helper-upgrade |

安装器三处（`Install-MwVersion` 透传 `-CheckId`）：`install-3.0-custom` → c12-custom-upgrade、`install-3.0-default` → c12-default-upgrade、`install-3.0-helper-base` → c12-old-helper-upgrade。

### 4.4 前置条件证据（`launch-pre-*.json`）

`c2-tamper-reject`（bootstrap + 伪造缓存包）、`c5-check-before-components`（bootstrap）、recovery 中断后的离线/联网（bootstrap + bili 源目录）、c8 离线三态（bootstrap + 三个测例 base）、`c8-real-network-cut`（bootstrap）。
上述检查的 Status 首判均为 `if (-not $pre.ok) { 'fail-fixture' }`——**前置不成立绝不允许 pass**。

---

## 5. 残余依赖与未闭环项

1. **F-03 依赖产品修复**：`installer/mingling.iss:126` 仍把 `installer-check.log` 写在工作区；产品迁出后 `Known` 列表自然为空、断言更严格。迁出前该条噪音只在 Data/Detail 中可见，不影响“内容不被覆盖”的判定。
2. **F-05 需要真实断网**：来宾普通用户不能自行禁用网卡；无 `network-cut-by-host.flag` 时按设计落 `blocked-precondition`，需宿主真实停 NAT 才能取得 pass。
3. **M-05 远端层哈希不可复核**：只校验 URL 与 digest 结构一致、layers 格式合法，`verifiedRemotely=false` 已写入证据。
4. **M-22 宿主回收范围**：`phases\<Phase>` 目录不在宿主现有回收清单内；runner 已把关键文件复制回 `$script:EvidenceDir` 兜底，但宿主侧的收集逻辑仍建议补上 `phases`。
5. **未跑 VM**：F-04（真实中断时机）、F-05（断网）、M-01/M-02/M-07/M-09/M-10/M-11/M-12/M-13/M-17/M-18/M-19/M-20/M-24 的真实行为需要 VM 里 pre/full/recovery/upgrade/final 各跑一次才能最终确认；本轮只做静态解析与纯本机单测。
6. **bili-login verify 未登录时可能记 failed 而非 manual**（产品依赖，未闭环）。
7. `Copy-TreeIfExists` 仍用 `-Path (Join-Path $From '*')` 通配符是刻意行为（需要展开目录内容），不属于“对含通配符路径误用 `-LiteralPath`”。

---

## 6. 自测证据索引（`acceptance/evidence/runner-harden/`）

| 文件 | 内容 |
| --- | --- |
| `parse-check.json` / `parse-check.txt` | `parseErrors=0`、`bytes`、`lines`、`hasUtf8Bom=true`、PS 版本 |
| `ensure-utf8bom.txt` | `Ensure-Utf8Bom.ps1 -Path acceptance/v2`：`ok=16 files, fixed=0, problems=0` |
| `wrapper-selftest.json` / `wrapper-selftest.stdout.txt` | 包装层 4 用例（缺证据/默认状态/对照/无前置）+ checks/<id>.json 回读比对，`ok:true` |
| `unit-selftest.ps1` / `unit-selftest.json` / `unit-selftest.stdout.txt` | 6 个纯本机用例：工作区信号×3、保护变更分类、应有检查集合、阶段预算夹紧 |
| `summary.json` | 上述结果的汇总与结论 |
