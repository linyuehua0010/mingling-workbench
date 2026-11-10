# V3.1.0 原 13 项验收矩阵（权威重建 + 产品预审计）

> 只读分析产物。仓库 `F:\dsh工作区\MinglingWorkbench`，工作树含 ~83 个未提交改动，本次未改动任何产品文件。
> 生成于 2026-11-09。所有结论以 `file:line` 定位；"缺口"指**即使 harness 完全正确也会失败**的产品侧原因。
> 配套机读版：`acceptance/analysis/matrix-13.json`（同 13 项，字段一一对应）。

---

## 0. 方法与可信度（必读）

### 0.1 三层信息，只有第 2 层是"可执行原文"

| 层 | 内容 | 位置 | 可信度 |
|---|---|---|---|
| L1 原始需求 | 13 条中文需求条目 | **未入库**（全仓 grep 无命中） | 不可得 |
| L2 执行口径 | 每个 criterion 的 id、前置、机器断言 | `acceptance/guest-acceptance.ps1:130-393`；旧副本 `acceptance/stage/guest-acceptance.ps1`；分阶段 harness `.workbuddy/acceptance/v3.1.0-before/host/guest-tests.ps1` | 高（可执行） |
| L3 既往判定 | 两轮验收的逐项结果文字 | `.workbuddy/acceptance/v3.1.0-before/report-vm.md:38-50`（改前，16 项口径）；`acceptance/report-fix-v3.1.0.md:41-53`（改后，21 项口径） | 中（叙述，非规范） |

**检索证据（为什么 L1 判"未入库"）**：对 `13 项|13项|十三项|原 13|13 条`、`第 6 项|第13项|criterion-`、`不改动文件|纯人工|21 个` 全仓 grep，只命中两处"原文"字样：
- `.workbuddy/acceptance/v3.1.0-before/report-vm.md:150`：「期望：第 6 项**原文**要求第二次全部跳过且不改动文件」；
- `.workbuddy/acceptance/v3.1.0-before/report-vm.md:43` 引用了 `fixed=0 satisfied=11 manual=1 missing=0 failed=0`。

`docs/ACCEPTANCE.md` 是 V3.0 及更早的历史验收（章节 1-16），**不含** V3.1.0 的 13 项；`docs/CHANGES.md:7` 只有 `## V3.1.0 本地功能构建（2026-11-09，尚未发布）`；`docs/setup-automation.md:63,267` 仅提到"验收脚本用它做隔离"。→ **13 条原始措辞已丢失**，本文的"要求"是从 L2 断言 + L3 叙述反推的**规范式重建**，不是原文。凡原文可能更宽/更严的地方，都在各项"不确定性"里写明，**不静默降标准**。

### 0.2 重建时的六处口径冲突（必须先裁决，否则 13 项无法判定）

| # | 冲突 | 证据 | 后果 |
|---|---|---|---|
| C1 | 组件数 **16（旧）vs 21（现行）** | report-vm 项 1/2 按 16；`tools/components.json` 现为 21；harness 用 `$manifest.components.Count` 自适应 | 项 1/2 的"21/21"只能按当前清单判；旧结论不可直接沿用 |
| C2 | 项 5 断言写成"**装后仍非 0**" | `acceptance/guest-acceptance.ps1:147`：`$beforeCheck.exitCode -ne 0 -and $afterCheck.exitCode -ne 0` | harness 只测"安装器不装组件→Check=2"；**"组件装完 Check=0"没有写成断言**，只存在于 report-vm:42 的叙述 |
| C3 | 项 6「不改动文件」的文件边界未定义 | `guest-acceptance.ps1:187-192`：`Get-FileMap @($Ws,{App}\sidecar)`，比 sha256+bytes+**mtime**，**不排除日志** | 连 `state.json`/`bootstrap-*.log` 的 mtime 变化都算失败；比常见"幂等"严格得多 |
| C4 | 项 12 的"备份完整性"只在自定义目录路径断言 | `:317-323` 仅 `criterion-12-custom-sync` 比对 `backup-manifest.json`；default-sync/old-helper 只看 protected 变化 | 默认目录/独立助手的备份缺失不会被判失败 |
| C5 | 项 12 默认目录路径用 `--wb-update`，而 D-05 走的是 CLI | `:333` `Invoke-Capture 'upgrade-default-sync' $dExe @('--wb-update', ...)`；D-05 是命令行升级 | 原需求若指 CLI，harness 测的是另一条路径 |
| C6 | 项 13 的 SHA 比较是"自证" | `:372` `$hashShown` 由 `$shown` 现算，`:373` 要求 `$shown -eq $appBoot` | 一旦 `$shown == $appBoot`，哈希必然相等；真正有效的是"路径落在程序目录" |

---

## 1. 项 1 — 组件清单结构与来源哈希模型

- **要求（重建）**：`tools/components.json` 是唯一组件图；每个组件的 `source.sha256` 均为 64 位十六进制；纯人工组件 `asset_count=0` 且 `sha256` 为空资产的 SHA256；组件 id 唯一、依赖不悬空、无环、必填字段齐全。
- **出处**：`acceptance/guest-acceptance.ps1:137-140`；字段/重复/悬空/环检查在 `.workbuddy/acceptance/v3.1.0-before/host/guest-tests.ps1`（report-vm:38 记录"缺必填字段 0、重复 ID 0、悬空引用 0、环 0、嵌套字段错误 0"）。
- **前置**：仓库可读；无需安装。
- **步骤**：读取清单 → 遍历 `components[].source.sha256` → 正则 `^[0-9a-fA-F]{64}$` → 统计非法项。
- **断言**：`criterion-1`：`$bad.Count -eq 0`，detail 必须给出 `组件 N 个；source 哈希格式错误 0`（`guest-acceptance.ps1:139`）。补充断言（旧轮）：重复 id=0、悬空 requires=0、依赖环=0。
- **证据**：`evidence/results.jsonl` 的 `criterion-1` 行、`pre.json`、`source-integrity.json`。
- **不确定性**：① 原 13 条措辞未入库，本项只有"哈希格式"是可执行断言，"必填字段/环/悬空"来自旧 harness 文字，当前 `guest-acceptance.ps1` **不再检查**；② 16→21 的扩容是否在原需求范围内无从判断；③ **空串哈希 `e3b0c442…` 也满足 `^[0-9a-fA-F]{64}$`**，所以本项无法区分"真实资产哈希"与"纯人工占位"——这是断言本身的窄口，后文项 2 单独补。
- **产品实现**：`tools/components.json` 21 个组件，起始行 webview2:46、node:141、ffmpeg:217、uv:291、python:364、astrbot:441、snowluma:558、breeze:645、ollama:718、ollama-service:802、bili-whale:859、memory-plugin:980、bili-bridge-plugin:1045、embedding-model:1105、soulx-singer:1164、dsh-pet:1234、edge-tts:1276、bots-launchers:1335、qq-login:1374、bili-login:1444、deepseek-provider:1515。`tools/bootstrap.ps1:806-815` 校验 id 存在/唯一；`:895-924` 拓扑排序并对环抛错；`:882-892` 只对 `kind=download` 强制 64 位 sha。
- **产品缺口**：
  1. `bootstrap.ps1:882-892` 只检查 **download 步**的 sha，`copy_tree`/`uv-lock`/`npm_install` 的 source 哈希格式错误不会被 bootstrap 拒绝，只能靠 harness 静态检查兜住。
  2. 纯人工组件（ollama-service:823、dsh-pet:1250、bots-launchers:1351、qq-login:1405、bili-login:1476、deepseek-provider:1546）的 sha 全是空串哈希，与"真实资产"在格式上不可区分；若把 node 的 sha 误填成 `e3b0c442…`，项 1 仍通过。

## 2. 项 2 — 来源完整性：全资产 SHA256 + 篡改拒绝 + 离线三态

- **要求（重建）**：每个需要下载的真实资产在清单里有 64 位 SHA256，安装时**逐个校验**；缓存/已存在文件同样校验；被篡改的缓存必须拒绝且不留产物；`-Offline` 只接受已校验缓存。
- **出处**：`guest-acceptance.ps1:150-161`（uv 三态）；report-vm:39（10/16 空 sha 的失败面）；report-fix:42（21/21 有 64 位，未逐一篡改）。
- **前置**：联网可下 uv（0.13.7）；可写缓存目录。
- **步骤**：① `-Component uv` 在线装（900s）→ 取 `logs\setup\dl\uv-*` 缓存；② 复制到 validBase/badBase/emptyBase；③ badBase 只翻缓存**首字节**（长度不变）；④ 三次 `-Offline`。
- **断言**：`criterion-2-tamper-offline` pass = `online==0 && valid==0 && bad==2 && empty==2 && !(Test-Path $badBase\uv\bin\uv.exe)`（`:161`）。`criterion-2-sources`（`:140`）另要求所有真实 source 与纯人工空资产都有 SHA256 模型。
- **证据**：`uv-online.*`、`uv-offline-valid|bad|empty.*`、`evidence\logs`、`results.jsonl`。
- **不确定性**：① **原需求是否要求"逐个篡改 8 个下载资产"无法确认**；现行 harness 只测 uv 一个，report-fix 也自认"未逐一篡改"——这是**判据缺口，不是产品通过**；② astrbot/edge-tts 的 `source.sha256` 实际是"依赖锁文件哈希"，不是 wheel 哈希（见 §14.2），原需求若指"资产本体哈希"则本项在口径上就被放宽了；③ 缓存位置 `{Base}\logs\setup\dl` 由 bootstrap 自定，harness 用 `uv-*` 通配，跨版本可能失效。
- **产品实现**：`tools/common.ps1:12-105` `Get-File`：按 Urls 顺序、断点续传 `curl -C -`（:64）、退出码 33 重试一次（:82-86）、成功条件 `code==0 && size>=MinBytes && size==ExpectedBytes` 再比 SHA256（:87-92）、不符删除换源、全失败 throw（:100）。`bootstrap.ps1:474-506` 下载前要求 64 位 sha、缓存也校验（:491-496）、下载后复算（:504-506）。离线时只接受已校验缓存。
- **产品缺口（关键）**：**21 个组件里只有 8 个 download 资产是"安装时哈希校验"**：webview2、node、ffmpeg、uv、python、snowluma、breeze、ollama。其余：
  - `astrbot`/`edge-tts`：`source.sha256` = requirements 锁文件哈希（`components.json:473`/`:489` 同值 `53d20a66…`，实测等于 `sha256sum tools\astrbot-requirements.txt`；edge 同 `:1301`/`:1317`=`889c13b3…`）；真正的 wheel 由 `uv --require-hashes` 间接校验。astrbot 另有 `package_sha256: 189e9b07…`（`components.json:470` 附近）**bootstrap 从不读取**。
  - `bili-whale`：唯一用 `source-manifest.ps1` 树摘要校验的组件（`components.json:898,922-923` → `tools\source-manifests\bili-whale.json`）。
  - `memory-plugin`、`bili-bridge-plugin`、`soulx-singer`：有 sha，但 install 是 `manual`，**永不校验**；`bili-bridge-plugin` 的 manifest（`components.json:1074-1075`）从未被读取。
  - `embedding-model`：sha 与 `ollama pull bge-m3@sha256:0c4c9c2a…` 的 digest 同值，校验交给 ollama，bootstrap 不比。
  - 6 个零资产组件：sha 为空串哈希。
  → 若原需求是"21/21 资产在安装时被哈希校验"，产品**不满足**；harness 的项 1/2 只查格式，掩盖了这一点。

## 3. 项 3 — 普通用户静默安装

- **要求（重建）**：非管理员账户用 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CURRENTUSER` 安装，退出码 0，程序目录出现主程序；不请求 UAC；日志应显示非管理安装模式。
- **出处**：`guest-acceptance.ps1:142,145`；report-vm:40（`Administrative install mode: No`）。
- **前置**：来宾为普通账户（`administratorToken=false`）、WebView2 已预装或可装、无旧版本残留（pre 阶段清 `$App`/`$Ws`）。
- **步骤**：`Invoke-Capture $Installer @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER',('/DIR='+$App),('/WORKSPACE='+$Ws),('/LOG='+…))`（600s）。
- **断言**：`criterion-3-install` = `exitCode==0 && Test-Path {App}\MinglingWorkbench.exe`；detail 记录 `IsInRole(Administrator)`（`:145`）。
- **证据**：`install-3.1.inno.log`、`install-3.1.*`、`pre.json`。
- **不确定性**：① 原需求可能要求"安装后能启动并显示窗口"，harness 只查 exe 存在；② "WebView2 缺失时安装仍成功"是另一分支（原需求疑含），现行 harness **未覆盖**（来宾预装 WebView2）。
- **产品实现**：`installer/mingling.iss:46` `PrivilegesRequired=lowest`；`:60` `CreateUninstallRegKey=no`；`:75` 主程序先落 `MinglingWorkbench.exe.new.exe`；`:120-121` `CanWriteMainExe` 为真→`waituntilterminated`，否则→`nowait`；`:189-209`：**目标 exe 不存在时 `CanWriteMainExe` 直接返回 True**（:196-200），所以首装是同步等待，exe 在安装器退出前已就位；`:126` 收尾 `bootstrap -Check`（退出码被 Inno 忽略）。
- **产品缺口**：
  1. `finish-update.ps1` 的退出码被 `[Run]` 默认忽略（`installer/mingling.iss:120-121` 无 `check` 也不捕获），**替换失败时安装器仍返回 0**，项 3 的 `exitCode==0` 不能证明 exe 是 3.1 版本（只证明"有个 exe"）。
  2. 卸载项依赖 app 首次运行才写（`win32/src/paths.cpp:476-499` 需 `unins000.exe` 存在），与 `:60` 的 `CreateUninstallRegKey=no`、`:130` 的 `reg delete` 形成三段矛盾；项 3 不查，但项 12 的默认目录检测会受此影响（见项 12）。
  3. `suppressStartupWrites` 只在 `HadExistingApp` 时写（`:338-339`），首装不写，属设计内。

## 4. 项 4 — 中文/空格路径（/DIR 与 /WORKSPACE）

- **要求（重建）**：`/DIR` 与 `/WORKSPACE` 都能接受含中文与空格的绝对路径；安装退出 0；主程序落在指定程序目录；收尾体检"看得见"这两个路径（不因编码/引号被截断）。
- **出处**：`guest-acceptance.ps1:142,146`；report-vm:41（该轮通过）。
- **前置**：同项 3；路径形如 `C:\Users\Public\Documents\冥零 验收\程序 3.1`。
- **步骤**：同上，`/DIR=`、`/WORKSPACE=` 拼中文路径；`/LOG=` 也指向同一中文根。
- **断言**：`criterion-4-paths` = `exitCode==0 && Test-Path -LiteralPath {App}\MinglingWorkbench.exe`（`:146`）。
- **证据**：`install-3.1.inno.log` 中 `WsPath=[…]`、`{app}` 展开值；`pre.json`。
- **不确定性**：① 原需求很可能还要求"工作区也真的建在中文路径下且 Check 收到它"，harness 只查 exe 存在——**比原文窄**；② 上一轮该失败是夹具引号错误（report-fix:44），不是产品缺陷，但 harness 至今仍靠 `Invoke-Capture` 的 `/X=含空格 → /X="…"` 重写（`:35-65`）来兜，**这条重写规则本身没有单元验证**。
- **产品实现**：Inno 原生 `/DIR` 覆盖 `DefaultDirName`；`installer/mingling.iss:231-248` `PathUsable`（长度≥3、`s[2]==':'`、`s[3]` 为分隔符、不含 `" * ? < > |`）与 `CleanPath`（遇第一个 `"` 截断、`\\`→`\`、`/`→`\`）；`:257-268` 工作区优先级 `/WORKSPACE` → 旧 settings → `{userdocs}\冥零工作台`，并 `Log('WsPath=[…]')`。
- **产品缺口**：`CleanPath` 遇到**未闭合引号**会静默截断路径（`:239-248`），安装器不会报错，只会装到一个"看起来对"的目录；harness 若只查 exe 存在（`Test-Path` 的 `$App` 路径），可能把"装到别处"误判为通过。另：`/WORKSPACE` 的路径只用于写 settings.json 与 `[Run]` 参数，**安装器不校验该目录是否真的可写**，只在 `NextButtonClick`（`:284-312`）里 ForceDirectories。

## 5. 项 5 — `-Check` 的前后对比（未装=2 / 装后=0 / 恢复后仍 0）

- **要求（重建）**：同一安装实例上，组件未装时 `bootstrap -Check` 返回 2（可诊断）；默认组件装完后 `-Check` 返回 0；恢复/重跑后仍为 0。退出 0 只证明"该引擎判定无缺项"，不等于功能全好。
- **出处**：`guest-acceptance.ps1:143-147`（before/after 两次均在装包后、未装组件时）；`:176-180`（full 后 check=0）；report-vm:42（记录 2→0→0 实机序列）。
- **前置**：安装包已装（无组件）；默认组件集 16 个；astrbot/ollama-service 的 detect 要求后台在跑。
- **步骤**：① 装包后立即 `-Check`（300s）；② 再跑一次（300s）；③ 全量安装后 `-Check`（900s）。
- **断言**：`criterion-5-check-before` = `before!=0 && after!=0`（`:147`）；`criterion-9-full-backend` 的 check 部分 = 全量后 `check==0`（`:180`）。
- **证据**：`check-before-installer.*`、`check-before-components.*`、`check-after-full.*`、`results.jsonl`。
- **不确定性**：**C2**——harness 只断言"两次都非 0"，"装后 0"只存在于叙述；原需求若明确要求"装后 0"，当前 harness **没有把它写成断言**，判定会漏。
- **产品实现**：`tools/bootstrap.ps1:1045-1049` blocking = 非 manual 且 (missing|failed)（optional 仅显式选中才阻塞）；`:1063-1067` **Check 与安装同一条退出规则**：blocking==0 → 0，否则 2；`:969`/`:45-50`/`:185-194`/`:1075` 的 1 只表示内部或参数错误。manual 分支 `:984-1001`：不阻塞、`manual++`、打 `[人工] …未完成`、**绝不打 `##OK`**。`check-before` 会 `Dirty=true` 并写日志/state（`:1011-1012`）。
- **产品缺口（会合法翻转状态，导致断言不稳）**：
  1. `astrbot` 的 detect 是 `verify-astrbot.ps1 -RequireRunning`（`components.json:451-465`），要求 6185 正在监听、监听进程根目录=R、能回 HTTP；**AstrBot 没起时已装组件仍判 missing → Check=2**。安装器 `[Run]:126` 的体检在 app 启动后立刻跑，后台通常还没起，所以"装完 Check=0"实际取决于 self-setup/用户是否拉起后台。
  2. `ollama-service` detect 是 `ollama list`（`components.json:833-846`），服务未起同样判 missing。
  3. `bili-whale` detect 要 `require.resolve('qrcode')` 成功（`:953-975`），npm 半装会判 missing（这是设计要的）。
  4. manual 组件一旦被登录（QQ/B 站/Key），`manual` 计数下降、`##OK` 出现——**状态会向"通过"翻转**；反之 session 过期会翻回 manual。项 5 只比退出码，不锁状态快照。
  5. 显式 `-Component X` 会带上 X 的 manual 依赖项（`bootstrap.ps1:849-864`），因此同一台机器不同命令行会给出不同 `manual` 计数。

## 6. 项 6 — 严格幂等：第二次全部跳过且"不改动文件"

- **要求（重建，含原文转述）**：首装完成后，用**同样的默认参数**再跑一次 bootstrap：退出 0；所有组件"已满足/已跳过"（`fixed=0`）；**工作区与程序 sidecar 的文件集合零变化**（内容、大小、mtime 均不变，含新增/缺失）。
- **原文代理**：`.workbuddy/acceptance/v3.1.0-before/report-vm.md:150`「期望：第 6 项**原文**要求第二次全部跳过且不改动文件」；report-vm:43 记录 `fixed=0 satisfied=11 manual=1 missing=0 failed=0`。
- **出处**：`guest-acceptance.ps1:187-192`。
- **前置**：项 9 的全量首装已完成；无并发写；`state.json` 已存在。
- **步骤**：`Get-FileMap`（`$Ws` + `{App}\sidecar`，递归、sha256+bytes+mtime）→ 默认参数第二次运行（7200s）→ 再取映射 → `Compare-Maps`。
- **断言**：`criterion-6-idempotent` = `second.exitCode==0 && changes.Count==0`；detail `第二次退出 X，文件变化 N 处`。注释（`:187`）明确"不排除日志"。
- **证据**：`bootstrap-full-second.stdout.txt`、`idempotent-before.json`/`after.json`、`results.jsonl`。
- **不确定性**：**C3**——原文只说"不改动文件"，未定义是否包含 `state.json`/日志/时间戳；harness 把 mtime 也算变化，且不排除日志，**比多数"幂等"定义更严**。旧轮 D-11 的失败正是"新增 1 个日志 + state.json 变化"，而组件文件其实没变。这一条不能靠"解释"绕过，只能让产品真的不写，或由裁决方明确豁免。
- **产品实现（写入点清单，见 §14.7）**：`bootstrap.ps1:61` `Dirty=[bool]$LogFile`；`:101-112` 未 Dirty 时日志只进内存；`:165` **无条件** `New-Item {Base}\logs\setup`（目录，不计入文件映射）；`:936` `if (-not Dirty -and (Test-Path StatePath)) { return }`；`:1011-1012` Check 缺项 → Dirty；`:1020-1021` 进入安装分支即 Dirty；`:1068-1070` 仅"未改动且未显式指定 -LogFile"才打"没有改动：未创建日志，state.json 保持原样"。
- **产品缺口**：
  1. **`state.json` 不存在时必写**（`:936` 的条件是"未 Dirty **且** 已存在才跳过"）。只要首装没留下 state（例如首装全部 satisfied、无安装动作），第二次就会新建 → 项 6 直接失败。
  2. **显式 `-LogFile` 会让 `Dirty` 永真**（`:61`），日志必写；安装器 `[Run]:126` 恰恰带 `-LogFile`，若 harness 的第二次运行沿用同一命令行（或带 -LogFile），项 6 必失败。harness 的 `full-second` 用的是默认参数（不带 -LogFile），这一点上口径是自洽的。
  3. `-Check` 命中缺项会 Dirty 并写 state（`:1011-1012`）——**Check 不是只读操作**；若第二次运行前有任一组件掉线（如 AstrBot 停了），会走安装分支 → 写日志/state → 失败。
  4. `npm install` 若被触发会重写 `package-lock.json`（npm 默认行为），`{bots}` 不在映射内（映射只含 `$Ws`+`{App}\sidecar`），所以不影响本项，但会影响"工作区文件"叙事。
  5. `write_file` 步是否"内容相同就不写"未在本次审计中逐行确认（`bootstrap.ps1:699-781` 的 write_file 分支）——若每次强制写，`bots\start-all.cmd` 等文件的 mtime 会变；它们在 `$Ws\bots` 下，**在映射内**。

## 7. 项 7 — 半安装恢复（Node 完成、bili 缺 qrcode）

- **要求（重建）**：安装中途中断后重跑：离线时不得伪装成功（退出 2），缺失的 qrcode 不得凭空出现；联网重跑只补缺失部分，**已完成的 Node 不被重装**（sha256 与 mtime 不变）。
- **出处**：`guest-acceptance.ps1:250-268`；harness-notes.md（真实 taskkill/停滞代理的用例只采纳 `recovery-node-bili.*`）。
- **前置**：node 缓存可用；`{App}\sidecar\bili-whale` 源码可复制；离线需真空 npm 缓存。
- **步骤**：① 复制 node 缓存到 `$R\Half`，`-Component node -Offline`（600s）必须 0；② 复制 bili-whale 源（排除 node_modules）；③ `-Component bili-whale -Offline`（300s）；④ `require.resolve('qrcode')`；⑤ 联网 `-Component bili-whale`（1800s）；⑥ 再 resolve + 比 Node 的 sha256/mtime。
- **断言**：`criterion-7-offline-half` = `node==0 && bili==2 && resolve!=0 && !qrcode package.json`（`:263`）；`criterion-7-recovery` = `online==0 && resolve==0 && nodeHash 不变 && nodeTime 不变`（`:267`）。
- **证据**：`half-node-offline.*`、`half-bili-offline.*`、`half-bili-online.*`、`half-qrcode-*`。
- **不确定性**：① 原需求可能指**真实安装中断**（taskkill/断网），现行 harness 用"复制源码的合成半装"，harness-notes 承认真实中断只存在于旧轮（report-vm 项 7）；② "只补 qrcode"的断言实际只验证"Node 没被重装 + qrcode 可解析"，**没有验证"没有重下别的组件"**。
- **产品实现**：`components.json:953-975` bili-whale 的 verify = `package.json` + `node_modules\qrcode\package.json` + `node -e require.resolve('qrcode')`（expect 0）→ 缺 qrcode 必判 missing；`:935-943` npm 步骤 `needs_network`；`bootstrap.ps1:630-678` npm 前置检查（`node_modules\<pkg>\package.json` 存在就 return，:647-653）、`--offline` 时加 `--offline` 并只试一个源（:660,675）、成功后强制 `require.resolve`（:667-668）；`:659` 参数为 `install --omit=dev --no-audit --no-fund --ignore-scripts`，**非 `npm ci`**。
- **产品缺口**：
  1. npm 缓存固定 `{base}\logs\setup\npm-cache`（`:656`），**harness 无法从产品侧强制"空缓存"**；来宾若已有该缓存，`--offline` 可能成功 → 项 7 的"离线必须失败"变成假阴性/假阳性（取决于机器历史）。
  2. 恢复后 `package-lock.json` 可能被 npm 改写（mtime/内容），`{bots}\bili-whale` 不在项 7 的哈希断言内，但会影响项 12 的"protected 变化=0"（`bots` 是 protected 快照目录，`Snapshot-Protected` 会算 `bots\bili-whale\package-lock.json`）。
  3. 无网络时 `Invoke-NpmStep` 直接跑 npm 等它超时（1800s），harness 只给 300s → **可能被 harness 超时误判**，而不是产品快速失败。

## 8. 项 8 — 真断网行为（普通模式失败、Offline 空缓存失败、有效缓存成功）

- **要求（重建）**：真实断网时，普通模式不得静默成功，应返回非 0 且无伪造产物；`-Offline` 空缓存返回 2；预先放好的有效缓存可由 `-Offline` 成功使用。
- **出处**：report-vm:45（真断 ethernet0，uv 普通模式 32.24s 返回 2；Offline 空缓存 2、有效缓存 0）；`guest-acceptance.ps1:150-161` 只覆盖同机缓存三态。
- **前置**：可断开网卡（来宾 `ethernet0`）；或至少能阻断外网。
- **步骤**：断网 → `-Component uv` 普通模式 → `-Offline` 空缓存 → 放有效缓存 → `-Offline`。
- **断言**：普通模式 `exit!=0` 且 `{base}\uv\bin\uv.exe` 不存在；空缓存 `-Offline`=2；有效缓存 `-Offline`=0。现行 `guest-acceptance.ps1` **没有真实断网用例**，只有 `criterion-2-tamper-offline` 的缓存三态。
- **证据**：`offline-real-*`、`uv-offline-*`、`Get-NetAdapter` 状态记录。
- **不确定性**：**原需求明确有"真断网"，现行 harness 缺**（harness-notes 与 report-fix:48 均承认）。因此项 8 目前只有旧轮证据，重建口径只能引用 report-vm:45 的叙述，机器断言需另写。
- **产品实现**：`common.ps1:64-100` curl 失败链 → 全失败 throw；`bootstrap.ps1:65` `OfflineMode`；download 步离线只认已校验缓存（`:491-496`）；`uv` 步离线跳过镜像切换（`:605`）；npm 离线 `--offline` 只试一个源（`:660,675`）。
- **产品缺口**：
  1. 普通模式**在有缓存时会静默成功**（合法，但"断网必失败"的断言必须限定"无缓存"）；report-vm 的 32s 返回 2 是恰好无缓存。
  2. `common.ps1:56-60` 对"已存在且大小够但 hash 不符"的文件先删再下；断网时这会**删掉用户缓存**再失败——恢复在线后需重下，属可接受但应记录。
  3. uv 离线时不再尝试镜像（`:605`），只用一个源；若该源在缓存里是坏的，没有第二机会（预期行为，但要在断言里写清）。

## 9. 项 9 — 全量安装 + 真实 AstrBot 后台 + self-setup 八块

- **要求（重建）**：默认组件全量安装退出 0；安装后 `-Check` 退出 0；AstrBot 真实后台在 6185 上可服务（HTTP 200 + 固定 Python 3.12.16 + `.astrbot`）；`self-setup.ps1 -Apply` 与 `-Verify` 都退出 0，verify 输出 `##RESULT ok=1 done=8 fail=0`。
- **出处**：`guest-acceptance.ps1:176-180`（full→check）；`:213-231`（model stub + conf + answers + apply/verify）。
- **前置**：全量安装完成（含 1.6 GB Ollama）；本地 OpenAI 兼容桩 `127.0.0.1:18080`；`answers.json`（memory/voice/video=0）；后台密码已设。
- **步骤**：默认参数全量（14400s）→ Check（900s）→ 起 stub → 写 `private\backend.txt` 与 `answers.json` → `start-astrbot.ps1 -Restart`（300s）→ `self-setup.ps1 -Base Ws -Answers …`（1200s）→ 加 `-Verify` 再跑（1200s）。
- **断言**：`criterion-9-full-backend` = `full==0 && check==0`；`criterion-9-selfsetup` = `apply==0 && verify==0 && verifyText 匹配 '##RESULT ok=1 done=8 fail=0'`（`:231`）。
- **证据**：`full-first.*`、`check-after-full.*`、`astr-restart.*`、`self-setup-apply.*`、`self-setup-verify.*`、`results.jsonl`。
- **不确定性**：① 原需求是否要求"插件真的回消息"（端到端对话）无法确认；harness 只到"后台 HTTP + 八块 apply/verify"；② `done=8` 是块数，若产品把八块拆成九块，断言会失配；③ stub 只实现 `/models` 与 `chat/completions`，不覆盖 embedding/语音。
- **产品实现**：`tools/self-setup.ps1:21` param；`:47-51` `Done()` 输出 `##RESULT ok= done= fail= [mode=verify] why= next=`；`:1448` 八块 `provider/platform/chat/plugins/memory/voice/persona/verify`；`:1451` verify 模式换成 `Verify-*` 八函数；`:1480-1481` 全成功 `Done 1 $done $fail`。`verify-astrbot.ps1` 见 §14.5。`tools/start-astrbot.ps1` 幂等启动、`-Restart` 只杀属于 Root 的监听进程。
- **产品缺口**：
  1. **`self-setup.ps1` 要求的产品侧前置比 harness 假设多**：`private\backend.txt` 的 `username/password` 由 harness 写（`:223`），但 `answers.json` 里 `deepseek_key_file` 指向 `secrets/deepseek-key.txt`；若 self-setup 在读 key 时要求文件存在且非空，合成 Key 必须已写（harness 在 `:195-197` 写）。顺序在 harness 里是对的，但产品侧若改成"从环境变量读"，该断言会失败。
  2. `done=8` 依赖八块全跑；`-Only` 或块内提前 `Done 1 1 0`（如 restore 分支 `:316`）会改变 `done` 计数 → 断言脆弱。
  3. 全量安装含 `ollama`（1.6 GB，`components.json:718`）与 `snowluma`(43 MB)/`breeze`(73 MB)，14400s 在慢网/镜像慢时可能不够，**失败会被记为产品失败**（旧轮就是 Ollama 下载失败）。
  4. `ollama-service` 与 `ollama` 拆成两个组件后，默认 Check 需要服务真起（`:833-846`），而 `start-ollama.ps1` 只在安装步里调；若服务未起，`check-after-full` 必 2 → 项 9 失败。

## 10. 项 10 — 密钥不外泄

- **要求（重建）**：写入 `secrets\deepseek-key.txt` 的合成 Key 只能出现在 secrets 目录内；工作区/程序目录/夹具目录中任何其他文件（含日志、stdout/stderr、config）不得出现该字符串；扫描不得有不可读文件。
- **出处**：`guest-acceptance.ps1:195-197,233-245`（apply 后）；`:375-386`（最终，成功配置后）。
- **前置**：合成 Key `sk-mwfix-<guid>` 已写入；self-setup provider 块已成功；无残留进程持有打开的文件。
- **步骤**：递归读 `@($App,$Ws,$R)` 全部文件，按 ASCII/UTF-16LE/UTF-16BE 三种编码 `Contains($testKey)`；命中分类 `insideSecrets`（前缀 `{Ws}\secrets\`）与 `log`（路径含 `\logs\` 或 `.log/.stdout/.stderr`）。
- **断言**：`criterion-10-key-scan` / `criterion-10-final-key-scan` = `scanned>0 && badHits==0 && unreadable==0`；`badHits = hits where (-not insideSecrets) or log`。
- **证据**：`key-scan.json`（hits/badHits/unreadable）、`results.jsonl`。
- **不确定性**：① 原需求可能只要求"日志不出现"，harness 扩大到"secrets 外任何文件"；② 扫描根含 `$R`（夹具），会把 harness 自己写的 `answers.json`/stub 也算进去——若 stub 打印 Key 就会自伤；③ 不区分"明文 Key"与"被转义的 Key"（`sk-…` 原样才命中）。
- **产品实现**：`bootstrap.ps1:88-99` `Redact-Text` 覆盖 `sk-[A-Za-z0-9_-]{8,}`、`Bearer …`、`api_key/token/secret/password`、URL userinfo、QQ 号；`:115-119` 所有 `##` 协议行都过 Redact 再 `Write-Host`/落盘。`start-astrbot.ps1:16-21` 把 Key 注入**进程环境变量** `$env:MINGLING_DEEPSEEK_KEY`，不落盘。`verify-manual.ps1:68-86` 只检查 `cmd_config.json` 里出现字面量 `'$MINGLING_DEEPSEEK_KEY'`。
- **产品缺口**：
  1. **`verify-manual.ps1` 只校验占位符，不校验 Key 真伪**：任何 ≥8 字符假 Key 都让 `deepseek-provider` 判满足——项 10 的"成功配置"可以在没有真实 Key 的情况下达成，扫描就变成"扫一个假 Key"。
  2. AstrBot 自身日志可能打印 `Authorization: Bearer <key>`（第三方代码），产品只 Redact 自己的输出，**管不到 AstrBot 的 run.log**；一旦命中 `logs\`，`badHits` 必非 0。
  3. `answers.json` 由 harness 写（`:224`），其中只有 `deepseek_key_file` 路径，不含 Key；但 self-setup 若把 Key 明文写进 `data\config\cmd_config.json`（而非占位符），会立即命中 `bots\…`。
  4. 扫描 `@($App,$Ws,$R)` 不含 `%APPDATA%\MinglingWorkbench`（settings.json/state），产品若把 Key 写进那里，本项**扫不到**（覆盖缺口，不是通过）。

## 11. 项 11 — manual 门禁（未登录不得 ##OK）

- **要求（重建）**：QQ 登录、B 站登录、DeepSeek Key 是独立的 manual 组件；未完成时必须计入 `manual` 且**不输出 `##OK`**；默认 Check 的 `manual>=3`；点名 `-Component snowluma -Check` 也必须把依附的 `qq-login` 报为 manual，防止"软件装好了、登录没做"被误报完成。
- **出处**：`guest-acceptance.ps1:168-171`（snowluma 单组件）、`:182-185`（默认 manual>=3）；report-vm:47（旧轮 manual=false 的失败面）。
- **前置**：SnowLuma 已装（未登录）；B 站凭据缺失；`secrets\deepseek-key.txt` 不存在或 <8 字符；AstrBot 配置里无 `$MINGLING_DEEPSEEK_KEY` 引用。
- **步骤**：① `-Base $App -Workspace $Ws -Bots $Ws\bots -Component snowluma -Check`（180s）；② 默认 `-Check`（900s）。
- **断言**：① `counts.manual>=1 && manualText 不含 '##OK qq-login'`；② `manual>=3 && manualText 不匹配 '##OK (qq-login|bili-login|deepseek-provider)'`。
- **证据**：`check-manual-model.*`、`check-default-manual.*`、`results.jsonl`。
- **不确定性**：① 原需求说"没登录不输出 `##OK`"，harness 用"`manual>=N` + 正则不含 `##OK <id>`"，**不验证 manual 行的文案/可操作性**；② `manual>=3` 假定三个 manual 项都缺；若来宾恰好已登录 B 站（复用 profile），会变 2 → 失败（夹具污染风险）。
- **产品实现**：`components.json` 中 `qq-login:1374`（manual、requires snowluma、source 零资产、sha=空串哈希）、`bili-login:1444`（manual、requires bili-whale+node）、`deepseek-provider:1515`（manual、requires astrbot）；三者 verify 都是 `tools\verify-manual.ps1`。`bootstrap.ps1:849-864`：**点名任一组件时，把所有 `manual=true` 且其 `requires` 已被选中的组件一并加入**——这正是 `-Component snowluma` 能报出 qq-login 的机制；`:984-1001` manual 分支永不 `##OK`；`:1045-1049` manual 不计 blocking。
- **产品缺口**：
  1. `verify-manual.ps1:68-86`（deepseek-provider）**不验证 Key 真伪、不发请求**，只查"长度≥8 + 配置里有占位符"→ 假 Key 也算"已完成"，manual 门禁形同虚设。
  2. `verify-manual.ps1:18-42`（qq）读 `cmd_config.json` 的 `ws_reverse_port`，配置缺键时 `[int]` 转换在 `$ErrorActionPreference='Stop'` 下抛错 → **退出码 1 而非 3**，bootstrap 会把它当 failed 而不是 manual（`components.json:1420` 附近 expect_exit 0 未区分 1/3）。
  3. `verify-manual.ps1:44-66`（bili）发**真实网络请求** `api.bilibili.com/x/web-interface/nav`；断网/被墙时返回 5，bootstrap 记 failed 而非 manual → 默认 Check 的 `manual>=3` 可能只有 2，**项 11 失败**。
  4. `qq-login` 依赖 SnowLuma 真在跑且 OneBot 已连；若 SnowLuma 未启动，`Get-NetTCPConnection` 找不到 → 3（manual）没问题，但同一台机器上 `snowluma` 组件的 detect 是文件检查（`components.json:558` 附近），二者状态可能不一致（软件 OK、登录 manual）。

## 12. 项 12 — 三条 V3.0 升级路径 + 保护数据 + 备份 + 原子替换

- **要求（重建）**：从 V3.0 升级到 3.1 的三条路径（自定义目录 CLI、默认目录 CLI、已发布 V3.0 独立助手）都必须：退出 0、版本从 `^3.0` 变 `^3.1`、`bots/private/secrets/out/logs` 的保护数据零变化；覆盖前把旧程序文件完整备份（含 `unins000.exe/.dat`）并留 `backup-manifest.json`。
- **出处**：`guest-acceptance.ps1:271-357`；report-vm:48（311 文件/308 匹配、unins 无旧备份）；D-05/D-06。
- **前置**：V3.0 安装包；可写自定义/默认目录；旧 exe 可 `--wb-update`；植入 6 个保护文件（`:282-291`）。
- **步骤**：① 自定义目录：装 3.0 → 植入 → 旧 exe `--wb-update <新包> 3.1.0-acceptance`（600s）→ 90s 轮询版本；② 默认目录：装 3.0 到 `%LOCALAPPDATA%\Programs\MinglingWorkbench` → 同样升级；③ 独立助手：降回 3.0 → 复制 exe 到 `%TEMP%\mingling-updater-acceptance.exe` → `--wb-update-run <backup> <setup> <log> 0 <exe>`。
- **断言**：`criterion-12-custom-sync` = `exit==0 && before^3.0 && after^3.1 && protectedChanges==0 && backupMissing==0`（`:324`）；`criterion-12-default-sync` = 同上但**不查备份**（`:340`）；`criterion-12-old-helper` = 同上（`:357`）。
- **证据**：`install-3.0-*.inno.log`、`upgrade-*.inno.log`、`custom|default|helper-protected-before/after.json`、`backup-manifest.json`。
- **不确定性**：**C4/C5**——备份完整性只在自定义目录断言；默认目录路径用 `--wb-update` 而非 D-05 的 CLI；原需求若指"CLI 升级"，harness 测的是另一条入口。
- **产品实现**：`win32/src/her/her_selfupdate.cpp:570-599` 起安装器：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS` + `/WORKSPACE="…"`（:578）+ **`/DIR="…"`（:581，ProgramRoot 非空才加）** + `/LOG="…"`（:582），等 10 分钟；`:601-619` 非 0 → 回滚旧程序；`:549-556` 备份到 `{Workspace}\旧版\workbench-<tag>-<ts>`；`:621-639` 独立助手 `--wb-update-run`。
  `installer/mingling.iss:320-332` ssInstall 先跑 `backup-install.ps1`，失败即 `RaiseException` 中止且不动旧程序；`:333-368` ssPostInstall 写 `ProgramRoot`/`WorkspaceRoot` 注册表、旧版写 `SuppressStartupWrites=1`、`settings.json` 已存在则跳过；`:161-187` `DetectLegacyLayout` 从父进程/`--wb-update-run` 命令行恢复 `InstallLocation`。
  `tools/backup-install.ps1:24` 排除 `bots/private/secrets/out/logs/旧版`，`:27-31` 递归备份其余（含 `unins000.*`），`:44-55` 写 `backup-manifest.json` + `last-install-backup.txt`。
- **产品缺口**：
  1. **`CreateUninstallRegKey=no`（`mingling.iss:60`）让 `DefaultInstallDir` 的注册表自查（`:150-152`）永远落空**；CLI 升级（V3.0 的 `--wb-update` 不带 `/DIR`）只能靠 `DetectLegacyLayout` 从父进程/命令行猜。独立助手场景下父进程是 `%TEMP%\mingling-updater-*.exe`、命令行匹配依赖 `"…MinglingWorkbench.exe"` 带引号（`:174`）；猜不到就装到默认目录（D-05 的根因未被结构性消除）。
  2. **`.new.exe` 的替换失败被 `[Run]` 忽略**（`installer/mingling.iss:120-121`；`tools/finish-update.ps1:24,41,42-43` 的 5/6 退出码无人消费）→ "升级成功"可能只是"安装器返回 0"。
  3. **`finish-update.ps1` 不校验 `.new` 与安装包内 bin 的期望哈希**（只要求"目标==.new"，`:25,42-43`）→ 中间被替换的 exe 不会被发现。
  4. **`backup-install.ps1` 只在 `ssInstall` 且 AppDir 已有 `MinglingWorkbench.exe/unins000.exe/unins000.dat/.new.exe` 时才工作**（`:16-19`）；若旧目录缺 unins（例如绿色副本），静默不备份。
  5. **`unins000.dat/exe` 被备份后仍会被 Inno 重写** → "备份存在"与"卸载项一致"是两回事（D-07 的期望是"有旧备份"，不是"卸载项哈希不变"）。
  6. **默认目录升级时旧 exe 在跑**：`CanWriteMainExe` 返回 false → `[Run]` 变 `nowait` → 安装器退出时 exe 可能还没替换完，`Test-Path` 竞态（项 3 首装不受影响，因为目标不存在时返回 True）。
  7. `Snapshot-Protected` **不含 `旧版`**（`:274`），所以"备份目录被写"不会被判成 protected 变化；但 `logs` 在 protected 内，升级期间写入的日志会让 `protectedChanges!=0`（除非安装器不写 workspace 日志——`[Run]:126` 恰恰写 `{Workspace}\logs\setup\installer-check.log`）。**这条足以让三条升级断言全灭**，是当前最危险的口径/产品交叉点。

## 13. 项 13 — 入口一致性（工作台子进程与技能包装 → 同一个 bootstrap.ps1）

- **要求（重建）**：工作台 `--autosetup` 真正拉起的 bootstrap 子进程，与技能包装 `skill\mingling-install\scripts\bootstrap.ps1` 解析出的脚本，必须是**同一个** `{程序目录}\tools\bootstrap.ps1`，路径与 SHA256 一致；不能落到 `<工作区>\tools\bootstrap.ps1`（D-09 的旧缺陷）。
- **出处**：`guest-acceptance.ps1:164-167`（静态）、`:361-373`（动态）。
- **前置**：程序已装；注册表 `ProgramRoot` 已写（或回落 `%LOCALAPPDATA%`）；工作台能启动。
- **步骤**：① `resolve-program-root.ps1` 输出 == `$App` 且技能包装存在（静态）；② 启动 `{app}\MinglingWorkbench.exe --autosetup`，45s 内抓 `ParentProcessId==entry.Id && CommandLine 含 bootstrap\.ps1` 的子进程；③ 跑技能包装 `-Check`，从 stdout 抓 `##BOOTSTRAP <path>`；④ 比 path 与 SHA256。
- **断言**：`criterion-13-entry-static` = `resolved==$App && skill 存在`；`criterion-13-entry` = `trace.Count>0 && shown=={App}\tools\bootstrap.ps1 && hashShown==hashApp`。
- **证据**：`entrypoints.json`、`entry-skill-check.stdout/stderr.txt`、`entry-workbench.stdout/stderr.txt`、`results.jsonl`。
- **不确定性**：**C6**——`$hashShown` 由 `$shown` 现算，只要路径相同哈希必等；真正的有效断言是"路径落在程序目录"。原需求若要求"技能脚本自身哈希 == 安装包内脚本哈希"则是另一回事（两者本不该相同：一个是包装、一个是被调脚本）。
- **产品实现**：
  - 工作台：`win32/src/her/her_setup.cpp:92` `script = Root()\tools\bootstrap.ps1`；`:105-108` 参数 `-NoProfile -ExecutionPolicy Bypass -File "<script>" -Base <Base()> -Workspace <WorkspaceDir()> -Bots <BotRoot()>` + extra；`win32/src/main.cpp:404-415` `--autosetup`；`:436` 启动时 `ConsumeUpdateRestart()`。
  - `Root()` 回落链：ExeDir 有 tools → 用；否则父目录 leaf 为 bin/build；否则 **WorkspaceDir()/Base() 有 tools 就用它们**（`win32/src/her/her_config.cpp:48-59`）——最后这条正是 D-09 的"静默改用工作区脚本"。
  - 技能包装：`skill/mingling-install/scripts/bootstrap.ps1:6,8,13-15`：`resolve-program-root.ps1` → `{program}\tools\bootstrap.ps1` → 打 `##BOOTSTRAP <path>` → `& @args` → `exit $LASTEXITCODE`。
  - 解析：`skill/mingling-install/scripts/resolve-program-root.ps1:8` 校验 `<root>\tools\bootstrap.ps1` 存在；候选 `HKCU\Software\MinglingWorkbench\ProgramRoot` → `…\Uninstall\MinglingWorkbench_is1` → `%LOCALAPPDATA%\Programs\MinglingWorkbench`；打印完整路径、exit 0，否则 stderr `找不到冥零工作台程序目录…` + exit 2。
  - 文档已纠正：`skill/mingling-install/SKILL.md:86-87` 明确"不要用 `<工作区>\tools\bootstrap.ps1`"，`:101` 用 `resolve-program-root.ps1`。
- **产品缺口**：
  1. **工作台子进程的父进程链**：harness 要求子进程 `ParentProcessId==entry.Id`。若 `her_setup.cpp` 经 `cmd.exe`/`powershell -Command` 中转，父进程不是工作台 → `trace` 为空 → 项 13 失败（与产品好坏无关，是调用链形状）。
  2. **`Root()` 的回落顺序仍会落到工作区**：程序目录缺 `tools`（例如只复制了 exe）时静默使用 `WorkspaceDir()\tools\bootstrap.ps1`；技能包装走注册表却会解析到程序目录 → **两条入口分叉**，正是本项要防的。
  3. **`--autosetup` 的 45s 窗口**：AutoSetup 先做 EnsureWorkspaceLayout/EnsureSecrets、写 `answers`、复制 `qq_watch.py`（`her_setup.cpp:142-208`）才跑脚本；冷启动 + 杀软扫描可能 >45s，`trace` 抓不到 → 假失败。
  4. `--autosetup` 结束会被 harness `taskkill /T /F`（`:366`），此时 bootstrap 可能正在写 → 项 6/13 的时间窗互相干扰。
  5. 注册表 `ProgramRoot` 只在安装时写（`mingling.iss:336`）；**免安装/绿色目录**下 `resolve-program-root.ps1` 只能回落 `%LOCALAPPDATA%`，可能指向另一个（旧的）实例。

---

## 14. 横切事实（13 项共用，写断言时必须引用）

### 14.1 bootstrap 状态机与 `-Check` 语义

| 概念 | 事实 | 出处 |
|---|---|---|
| 输出协议 | `##STEP n|text`、`##OK id|detail`、`##FAIL id|why`、`##RESULT ok=<0\|1> fixed= satisfied= manual= missing= failed=` | `tools/bootstrap.ps1:14-21` |
| 退出码 | **只有 0/2/1**：0=无阻塞缺项；2=有阻塞缺项（安装模式同样）；1=内部/参数错误 | `:1063-1067`、`:969`、`:45-50`、`:185-194`、`:1075` |
| Check 是否只读 | **否**：缺项会 `Dirty=true` → 写日志 + state.json | `:1011-1012`、`:933-965` |
| manual | 不阻塞；`manual++`；打 `[人工] id：未完成。<steps>`；绝不 `##OK` | `:984-1001`、`:1045-1049` |
| 依赖闭包 | 显式 `-Component X` 会递归拉 `requires`，**并追加所有 manual 且依赖已选中的组件** | `:832-865`（关键 `:849-864`） |
| optional | 默认不选；显式选中才阻塞 | `:866-872`、`:1045-1049` |
| 离线 | 只认已校验缓存；镜像只试一个 | `:65`、`:491-496`、`:605`、`:660,675` |

**"已装机器上 Check 合法翻转"的完整原因表**：AstrBot 后台没起（`verify-astrbot.ps1:24-46`）；Ollama 服务没起（`components.json:833-846`）；bili npm 半装（`:953-975`）；登录态丢失/获得（`verify-manual.ps1`）；session Cookie 过期（bili 走真实 API，断网=5）；`state.json` 缺失导致重写；旧布局（`python\cpython-*\python.exe` vs flatten 后的 `python\python.exe`）。

### 14.2 21 组件 × 资产完整性覆盖

| 组件 | 资产类型 | 安装时哈希校验？ | 依据 |
|---|---|---|---|
| webview2 / node / ffmpeg / uv / python / snowluma / breeze / ollama | download | **是**（下载+缓存双检） | `common.ps1:87-92`；`bootstrap.ps1:474-506` |
| astrbot / edge-tts | uv-lock | **间接**（锁文件哈希 + `--require-hashes`） | `components.json:473/489`、`:1301/1317`；`bootstrap.ps1:577-607` |
| bili-whale | copy_tree | **是**（唯一树摘要） | `components.json:898,922-923`；`tools/source-manifest.ps1:42-73` |
| memory-plugin / bili-bridge-plugin / soulx-singer | 源码包 | **否**（install=manual，sha 仅记录） | `components.json:980,1045,1164` |
| embedding-model | ollama pull | 交由 ollama（`@sha256:`） | `components.json:1126` 附近 |
| ollama-service / dsh-pet / bots-launchers / qq-login / bili-login / deepseek-provider | 零资产 | 不适用（空串哈希） | `components.json:823,1250,1351,1405,1476,1546` |

npm 完整性：`npm install … qrcode@1.5.4`（`bootstrap.ps1:659-663`）**不是 `npm ci`**，无 `--package-lock-only`/`ci`；唯一钉住的是随包 `sidecar\bili-whale\package-lock.json:195-199` 的 `integrity: sha512-1ca71Z…`，由 `copy_file only_if_missing` 放入 —— 若目标已存在旧 lock，不会被更新。

### 14.3 安装器开关与目录来源

- 接受的开关：Inno 标准集 `/DIR`、`/WORKSPACE`（自定义）、`/LOG`、`/VERYSILENT`、`/SILENT`、`/SUPPRESSMSGBOXES`、`/NORESTART`、`/SP-`、`/CURRENTUSER`、`/CLOSEAPPLICATIONS`、`/FORCECLOSEAPPLICATIONS`。
- 程序目录：`DetectedDir`（父进程/命令行/同名进程，`mingling.iss:161-187`）→ 注册表 `Uninstall\MinglingWorkbench_is1`（`:150`，因 `:60` 永不命中）→ `{localappdata}\Programs\MinglingWorkbench`。
- 工作区：`/WORKSPACE` → 旧 `settings.json`（`%APPDATA%` 或 `\snapshot`）→ `{userdocs}\冥零工作台`（`:257-268`）。
- **没有任何入口在装完后自动跑全量 bootstrap 或 self-setup**：`[Run]` 只有 finish-update、启动 app、`-Check`（`:120-126`）。组件安装只能由工作台 `--autosetup`/`--bots-setup`（`her_setup.cpp:142-229`）、技能包装或用户手动触发。

### 14.4 三个入口各自"应产出的绝对路径 + SHA256"

| 入口 | 应执行 | 当前实测 SHA256（工作树，非包内值） |
|---|---|---|
| 工作台 `--autosetup` | `{程序目录}\tools\bootstrap.ps1`（`her_setup.cpp:92`） | `tools/bootstrap.ps1` = `b4926acb9879e7a2cc45584b4512ffca69d64fef768654cb4a6e710b5be03fb8` |
| 技能包装 | `{program}\tools\bootstrap.ps1`（`skill/.../bootstrap.ps1:8`） | 同上；包装自身 `8d7b8be33fa39b37bc9571eee10d3648e7baa7853af67634dafc8564702e7747` |
| 解析器 | 打印程序根（`resolve-program-root.ps1`） | 解析器 `3b9d25b0a7fa8c4763bef9efd3786c0fe01e1ee636db93c38616d94831217f64`；`components.json` `f9ac5a7890ff3ee3a6c4f250021bef0138281df5720b2260573c55780eb0b02c` |

> 断言的正确形式：技能包装**实际执行的路径** == `{app}\tools\bootstrap.ps1`，且该文件的 SHA256 == 安装包内同名文件的 SHA256（可用 `checksums.txt`/包内解压值）。不要拿包装脚本自己的哈希去比被调脚本。

### 14.5 AstrBot / verify-astrbot / self-setup

- `tools/verify-astrbot.ps1:18` `.astrbot` 必须是**文件**（`-PathType Leaf`）；`:19` `bin\astrbot.exe`；`:20` `python\python.exe`；`:21-22` `--version` 必须 `^Python 3\.12\.16`；`:25` 6185 Listen；`:27-34` 监听进程 ExecutablePath 前缀==Root 或 CommandLine 含 Root；`:36-46` 真发 `GET / HTTP/1.0` 且首行 `^HTTP/\d\.\d\s+\d{3}`；失败一律 exit 2。
- 组件 `astrbot` 的 detect/verify 都带 `-RequireRunning`（`components.json:451-465`）→ **Check 依赖后台真在跑**。
- `tools/start-astrbot.ps1`：读 Key 注入环境变量；已运行直接 0（幂等）；`-Restart` 只杀属于 Root 的监听进程；无 `.astrbot` 才 `init --yes`；Hidden 起 `start.cmd`；800ms×180s 轮询 verify。
- `tools/self-setup.ps1`：八块 `provider/platform/chat/plugins/memory/voice/persona/verify`（`:1448`），verify 模式换 `Verify-*`（`:1451`）；`Done()` 输出 `##RESULT ok= done= fail= [mode=verify] why= next=`（`:47-51`）；全成功 `Done 1 8 0`（`:1480`）。
- manual 门禁：qq/bili/key 三组件全部走 `verify-manual.ps1`；**key 只查占位符，qq 走端口+进程，bili 走真实 HTTP**（见项 11）。

### 14.6 SoulX / 唱歌

- 组件 `soulx-singer`（`components.json:1164-1232`）：`manual=true`、`optional=true`、**`default_install=false`**、`asset_count=0` 之外还有 source（codeload `SoulX-Singer/…81aeb3ae…tar.gz`，sha `b1a1e961…`）；install 只有 `kind=manual`，文字是 `powershell -File "{repo}\pack\mingling-pack\plugins\astrbot_plugin_dafeiyu_sing\sing_server\setup_windows.ps1" -Root "{base}\sing"`；detect 要求 `{base}\sing\SoulX-Singer` 目录 + `{base}\sing\models\SoulX-Singer\model.pt` ≥ 2,800,000,000 B。**默认 Check 不处理它**（未选中）。
- 真实下载发生在 `setup_windows.ps1`（上游，2.8 GB 模型 + CUDA PyTorch），**上游无固定 sha256**；bootstrap 只检测、不盲下（report-fix:57）。
- **两套目录冲突**：`tools/setup-singing.ps1:24` 默认 `Root={Base}\bots\SoulXSinger`（模型在 `{Root}\models\…`），而组件检测 `{base}\sing\…`；`skill/.../deploy-singing.ps1:8` 又去 `{Base}\tools\setup-singing.ps1`（分离布局下 tools 在程序目录）→ **产品自己的"部署本地唱歌"永远无法让该组件变 satisfied，且技能入口在合法分离布局下必失败**。

### 14.7 第二次运行可能写入的东西（幂等判定表）

| 写入点 | 触发条件 | 是否合法 | 依据 |
|---|---|---|---|
| `{Base}\logs\setup` 目录 | **每次**（含 Check） | 目录，不计入文件映射 | `bootstrap.ps1:165` |
| `bootstrap-<stamp>.log` | `Dirty` 为真（装了东西 / Check 缺项 / 显式 `-LogFile`） | 若首装已写，第二次不该写 | `:61,101-112` |
| `state.json` | `Dirty` 或**文件不存在** | 第二次若已存在且无变化 → 不写 | `:933-965`（`:936`） |
| `state.json.tmp` | 写 state 时 | 临时文件，同轮消失 | `:959-961` |
| `{Base}\logs\setup\npm-cache\*` | 触发 npm 安装 | 第二次不该触发 | `:656` |
| `{Base}\logs\setup\dl\*` | 触发下载 | 第二次不该触发 | `:175-178` |
| `{bots}\bili-whale\package-lock.json` | npm 运行 | 第二次不该触发 | npm 默认行为 |
| `{Ws}\bots\start-all.cmd` 等 | `write_file` 步（若内容相同仍写则 mtime 变） | **未逐行确认** | `bootstrap.ps1:699-781` |
| `{App}\sidecar\*` | 安装器覆盖（升级） | 不属于 bootstrap 第二次运行 | `mingling.iss:82` |

**判定**：真正的"重装"信号 = `fixed>0`、组件目录 mtime 变化、`dl/npm-cache` 新增、`##OK …装好了`；合法变化 = 无（项 6 的口径是零变化）。`manual` 行的出现不算写文件。

---

## 15. Top 产品缺口（即使 harness 完美也会失败）

1. **升级期间写 `{Workspace}\logs\setup\installer-check.log`**（`installer/mingling.iss:126`）落在项 12 的 protected 快照目录 `logs` 内（`guest-acceptance.ps1:274`）→ `protectedChanges!=0`，三条升级断言全灭。这是"产品行为"与"验收口径"的直接冲突，必须二选一裁决。
2. **`CreateUninstallRegKey=no` + CLI 不带 `/DIR`**：`DefaultInstallDir` 的注册表自查永不命中（`mingling.iss:60` vs `:150`），只能靠 `DetectLegacyLayout` 猜父进程/命令行；猜不到就装到 `%LOCALAPPDATA%`（D-05 未结构性修复）。
3. **`state.json` 在不存在时必写**（`bootstrap.ps1:936`）且 **`-LogFile` 让 `Dirty` 永真**（`:61`）：任何"第二次运行"若 state 缺失或带 `-LogFile`，项 6 必失败；`-Check` 本身也会 Dirty（`:1011-1012`）。
4. **SoulX 目录双轨**：`tools/setup-singing.ps1:24`（`{Base}\bots\SoulXSinger`）与 `components.json:1177-1183`（`{base}\sing`）不一致；技能 `deploy-singing.ps1:8` 在分离布局下必失败 → 即使手动跑通唱歌，组件检测仍 `manual`，项 11/13 的"人工项状态"叙事与产品实际能力脱节。
5. **来源完整性只有 8/21 真校验**：memory-plugin、bili-bridge-plugin、soulx-singer 的 sha 只记录不校验；astrbot/edge-tts 的 `source.sha256` 是锁文件哈希而非资产哈希，`package_sha256` 字段从未被读；npm 不是 `npm ci`。项 2 若按原文"每个 source 安装时校验"判，产品不满足。
6. （并列）**`verify-manual.ps1` 的 deepseek-provider 只查占位符**：假 Key 也算完成，项 10 的"成功配置后扫描"实际上扫的是一个未被验证的 Key；bili 走真实网络，断网时 5 被记 failed 而非 manual，默认 `manual>=3` 会掉到 2。

## 16. harness 自身必须修的点（否则 13 项无法判定）

1. 项 5 缺"装后 Check=0"的断言（`:147` 只比两次非 0）；需补 `after-full check==0` 并显式记录三态序列。
2. 项 2 只测 uv，未逐资产篡改；至少补 astrbot 锁文件篡改、bili 树摘要篡改、npm 包篡改。
3. 项 8 无真实断网用例（只在旧 harness 有）；需回到 `guest-tests.ps1` 的断网阶段或新增。
4. 项 12 的备份完整性只覆盖自定义目录；default/helper 需同样比对 `backup-manifest.json`。
5. 项 10 扫描根不含 `%APPDATA%\MinglingWorkbench`；且 `$R` 夹具自污染风险未排除。
6. 项 13 的 45s 抓子进程窗口过短，且依赖 `ParentProcessId==entry.Id`（若产品经中转进程则恒失败——需先确认调用链形状）。
7. 项 6 的"文件"边界（是否含 logs/state/mtime）需由裁决方明文，否则与产品 `:1068-1069` 的"没有改动"承诺无法对齐。

---

### 附：本次审计未覆盖（诚实边界）

- `bootstrap.ps1:699-781` 各步实现的逐行语义（write_file 是否幂等、copy_file 是否比哈希、command 步超时/accept_exit）只做了行号级定位，未逐分支确认。
- `pack/mingling-pack` 配置包内容、`plugin/mingling_skill` 的 skill 铺设逻辑未读。
- 未启动安装器/VM（任务约束），所有"产品缺口"均来自静态代码，**未经运行验证**；与 report-vm 的实机结论冲突处以代码为准并标注。
