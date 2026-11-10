# 来宾阶段性执行器静态审查：acceptance/v2/guest/Invoke-Phase.ps1

- 审查对象：`acceptance/v2/guest/Invoke-Phase.ps1`（Windows PowerShell 5.1，宿主 `Run-Acceptance.ps1` 经 `vmrun runProgramInGuest` 以 `-Phase pre|full|recovery|upgrade|final -RunId -LibDir -GuestRoot -StageUrl -EvidenceUrl -Installer31 -Installer30` 启动）
- 审查方式：只读静态审查。审查期间被审文件在变动，故先冻结快照 `acceptance/analysis/_frozen-Invoke-Phase.b0cad635.ps1.txt`（2356 行，内容 md5 `8a8c385cc6da6f5c90fbfc10682c23b0`，文件 md5 `b0cad6351c5a…`）。
- **本文所有行号均指该 2356 行版本。** 若 live 文件后续再改，行号需按同内容（`8a8c385c…`）重新对齐。
- 只读约束遵守：未修改被审文件及任何产品/库/宿主文件；仅写 `acceptance/analysis/` 下本报告与 `.json` 摘要。

## 结论摘要

| 类别 | 数量 | 说明 |
| --- | --- | --- |
| 致命问题（P0） | **6** | 会让"没测到"显示为 pass，或让某阶段必然失败/必然被宿主杀 |
| 需修正（P1/P2） | **25** | 断言弱于文案、覆盖缺口、证据/上传/超时问题 |
| 旧缺陷 (a)–(g) 重现 | **0** | 7 条旧的实现级缺陷均已避开（证据见第三节） |
| 13 条要求有检查 | 13/13 | 每条都有 `Add-PhaseCheck`，但子断言存在 5 处明确缺口（见 1.14） |

一句话结论：**实现骨架比旧脚本强（参数编码、跨阶段对照、每阶段上传、文件图含程序根目录都做对了），但 `Add-PhaseCheck` 这个包装层把 `Check.ps1` 的两道"pass 门"（前置条件、证据存在性）系统性地关掉了；在此之上还有 6 处"断言写了一套、判定判了另一套"的地方。**

---

## 一、13 条要求的检查覆盖

先说共性（对第二节所有行都成立）：

- 55 处 `Add-PhaseCheck` 调用（747/757 是同一个 `c5-webview2-missing-branch` 的两个分支），分布在 pre(20)、full(9)、recovery(13)、upgrade(10)、final(6)、全域(2)。
- 全部检查的证据都自动包含 `checks\<id>.json`（`Add-PhaseCheck` 第 115 行 `$ev = @($cp)`），下表"证据"列只列**额外**证据。
- OSS 事实（库）：`New-MwCheck` 在 `Status=pass` 且（`Preconditions` 空 或 `Evidence` 空 或 `Evidence` 有不存在路径）时降级 `evidence-incomplete`；`Get-MwPhaseExitCode` = fail-fixture(11) > fail-product(10) > blocked-precondition(12) > blocked-env(13) > evidence-incomplete(14) > 0。

### 1.1 项 1：组件清单 / 依赖图 / 状态模型

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c1-manifest-schema | pre | 21 个组件、字段齐全、id 唯一（511-519） | `{App}\tools\components.json` | 有效，但"21"硬编码 |
| c1-dependency-dag | pre | Kahn 拓扑排序无环、依赖不悬空（548-574） | 同上 | 有效 |
| c1-source-hashes | pre | 空串哈希（e3b0c442…）单独列出，不计失败（576-584） | 同上 | **偏弱**：只"列出"，不校验"纯人工组件 asset_count=0 且哈希为空"这一条要求 |
| c1-state-model | pre | state.json schema=1 且 components 数>0（600-606） | `{Ws}\state.json` | 判定可用；606 行两分支同值（死分支） |

### 1.2 项 2：资产完整性 / 篡改拒绝 / 离线三态

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c2-stage-integrity | pre | 5 个固定文件 SHA256 与 checksums.txt 一致（386-404） | `stage-checksums.json` | **偏弱**：不一致只判 `evidence-incomplete`（402），被篡改的安装包不会被判产品失败；checksums.txt 自身不在被校验的 5 项里（386） |
| c2-source-real-chain | pre | requirements/edge 下载哈希、bili 树、npm lock、模型 digest 串一致（674-682） | `source-chain.json`、两个 requirements 文件 | **弱**：模型 digest 只证明"URL 里含同一串"（661），不构成资产校验 |
| c2-tamper-reject | pre | 伪造 uv 缓存 + 离线安装 → exit 2、无 uv.exe、输出含"缓存/校验/SHA256"（696-704） | 伪造 zip、stdout | 有效；缓存文件名 `uv-uv-x86_64-pc-windows-msvc.zip`（688）与 `tools/bootstrap.ps1:489` 的命名规则一致，**已核实无误** |
| c2-download-cache-hashes | full | 安装器下载缓存与 components.json 的 SHA256 比对，`mismatch=0 且 matched>=5`（1180-1186） | `download-cache-hashes.json` | 有效（matched<5 → evidence-incomplete，不误报 pass） |

### 1.3 项 3：普通用户静默安装

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c3-normal-user-install | pre | exit=0 且当前进程非管理员（445） | Inno 日志、stdout/stderr | **断言过弱**：Assertion(441) 说"日志显示非管理安装模式"，但 `$modeLine`（430）只进 Actual/Data，未参与判定 |
| c3-program-exe-version | pre | exe 存在且 FileVersion `^3.1\.`（449-455） | Inno 日志、`{App}\MinglingWorkbench.exe` | 有效（唯一真正证明"装的是 3.1"的地方） |
| c3-program-workspace-separate | pre | Ws 下无 exe、App 下无 bots/secrets、日志 WsPath 相等（459-473） | Inno 日志、`{App}` 目录 | 有效（但把目录当证据文件，见 5.4） |

### 1.4 项 4：中文 + 空格路径

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c4-chinese-space-paths | pre | exe 落在请求目录 且 日志 WsPath 与请求完全一致（483） | Inno 日志、exe | **偏弱/语义错位**：`-Expected $App` vs `-Actual $AppExe`（481，目录 vs 文件）；判定内容与 c3-program-workspace-separate 重复，没有额外证明"中文未被截断"（只靠 WsPath 一行） |

### 1.5 项 5：同一实例 Check 三态

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c5-check-before-components | pre | 未装时 exit=2 且 missing>0（706-721） | `installer-check.log`、stdout | 有效（同一实例、装前） |
| c5-webview2-missing-branch | pre | WebView2 存在则 not-run，缺失则独立分支（723-765） | 注册表探测结果 json | 结构性正确 |
| c5-check-after-components | full | 装后 exit=0、missing=0、failed=0（1131-1153） | 装后 `installer-check.log` | 有效；before 值从 pre 阶段 json 跨阶段读（1140-1144），**不是**两次相同调用 |

### 1.6 项 6：幂等

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c6-idempotent-exit | full | 第二次 exit=0、ok=1、fixed=0（1237-1245） | 第二次 stdout | 有效 |
| c6-idempotent-files | full | 工作区 + 程序目录文件图零变化（`installerChanges==0`，1247-1253） | `filemap-before/after.json` | 边界正确（含程序根目录，见 (f)）；**但**：90s 自然写入窗口内的路径被记 ambiguous 后忽略（1196、1254 自认），真实重复写入可能被吞 |

### 1.7 项 7：真实中断与恢复

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c0-recovery-precondition | recovery | 前置二进制存在（1356-1362，blocked） | 无额外 | 占位式前置 |
| c7-interrupt-observed | recovery | 观察到 ##STEP 且杀树成功（1395-1403） | 被杀进程 stdout | **判据过宽**：`'npm|bili|node_modules'`（1378）对 bili-whale 组件几乎恒真 + 45s fallback（1379-1385），见第四节 |
| c7-offline-fails-after-interrupt | recovery | killed 且离线 exit≠0 且无 qrcode（1438-1446） | 离线 stdout | 依赖上一条 |
| c7-online-recovers | recovery | killed 且联网 exit=0、qrcode 存在、resolve=0（1448-1457） | 联网 stdout、resolve stdout | 有效；但未断言"只补缺失"（未比对其他包） |
| c7-completed-not-reinstalled | recovery | killed 且 nodeExe 存在且 node 目录零变化（1459-1467） | 前后快照 json | 有效（sha/size/mtime） |
| c7-half-install-synthetic | recovery | 构造半装 → 离线 exit=2、无 qrcode、resolve≠0（1517-1528） | 构造目录 | 有效（构造态，非真实中断） |
| c7-half-install-online-fix | recovery | 联网 exit=0、qrcode 存在、node 侧零变化（1553） | 联网 stdout | **断言与文案不符**：Assertion(1549) 写 resolve=0，判定未含 |

### 1.8 项 8：离线三态 / 真实断网

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c8-offline-valid-cache | recovery | 有效缓存 + `-Offline` → exit=0 且 uv.exe 存在（1606-1614） | stdout | 有效 |
| c8-offline-empty-cache | recovery | 空缓存 + `-Offline` → exit=2 且无 uv.exe（1616-1624） | stdout | 有效 |
| c8-offline-bad-cache | recovery | 翻坏首字节 → exit=2 且无 uv.exe（1626-1634） | 坏缓存 + stdout | 有效 |
| c8-real-network-cut | recovery | 断网后 example.com 必败、宿主通道必通、空缓存 `-Offline`=2（1703-1713） | 网卡/请求记录 json | **缺口**：只测 `-Offline`，没测"断网 + 普通模式必须失败且不留产物"（1685-1687 参数含 `-Offline`） |

### 1.9 项 9：全量安装 + AstrBot 真后台 + 八块自设定

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c0-full-precondition | full | bootstrap.ps1 存在（936-942，blocked） | 无额外 | 占位式前置 |
| c9-full-install | full | exit=0、ok=1、failed=0（954-966） | 全量 stdout | 有效，但超时与宿主上限冲突（第六节） |
| c9-astrbot-init | full | `.astrbot` + `bin\astrbot.exe` + Python `^3\.12\.16`（972-990） | 目录探测 json | 有效 |
| c9-astrbot-process | full | 6185 监听 + 归属程序目录 + HTTP 有响应（992-1022） | 监听/HTTP 记录 | **偏弱**：4xx 算通过（999），异常但带响应时 5xx 也算通过（1003） |
| c9-selfsetup-apply | full | apply exit=0 且 stdout 匹配 `RESULT\s+ok=1\s+done=8\s+fail=0`（1086-1095） | apply stdout | 有效 |
| c9-selfsetup-verify | full | verify 同上（1097-1105） | verify stdout | 有效 |
| c9-model-stub-protocol | full | AstrBot 配置含 `127.0.0.1:18080` 且不含 `api.deepseek.com`（1120-1129） | 配置扫描 json | **偏弱**：不要求模型桩真的在监听（788-837 只等 20s 置标志，Detail 1128 自认只是配置协议证据） |

### 1.10 项 10：合成密钥扫描

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c10-key-scan | full | `Scanned>0 且 bad==0`（1284） | 扫描结果 json | **偏弱**：Assertion(1281) 写"不可读=0"，`unreadable` 未参与判定；范围限 GuestRoot + `%APPDATA%\MinglingWorkbench` + `%TEMP%` 名字过滤（1259-1268），不含 `%LOCALAPPDATA%\Programs`（升级目标）；>64MB 跳过（1275） |

### 1.11 项 11：manual 门禁

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c11-pre-snowluma-manual | pre | 点名 snowluma 后 manual≥1 且 ##OK 不含 qq-login（776-784） | Check stdout | **伪测**：`-Base $Ws`（769-772）让 qq-login 的 detect（`{base}\tools\verify-manual.ps1`）必然不存在 ⇒ manual 恒真；Detail(783) 自认"不等于登录状态检测有效" |
| c11-default-manual | full | 默认 manual≥3 且三个登录类组件不在 ##OK（1298-1307） | 全量 Check stdout | 有效，但依赖 bili-login 的 verify 真的把"未登录"记成 manual 而非 failed（产品侧风险，见第七节） |

### 1.12 项 12：三条升级路径

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c0-upgrade-precondition | upgrade | 两个安装包存在（1798-1805，blocked） | 无额外 | 占位式前置 |
| c12-custom-upgrade | upgrade | upd1 exit=0 且版本 `^3.1\.`（1906-1913） | 升级器日志、版本探测 | **起点未断言**：3.0 版本只记录（1846） |
| c12-custom-protected | upgrade | 受保护快照零变化（1917-1922） | 前后快照 json | **确定性冲突**：快照含 `logs`（1725-1744），产品 [Run] 必写 `logs\setup\installer-check.log`（`installer/mingling.iss:126`）⇒ 大概率必然 fail-product |
| c12-custom-backup | upgrade | backup-manifest 存在、含 unins000.exe/.dat、逐文件 sha 与升级前一致（1897-1933） | manifest、快照 | 有效（唯一测备份的地方） |
| c12-default-upgrade | upgrade | upd2 exit=0 且 `^3.1\.`（1967-1975） | 同上 | **没测默认目录**：1939-1945 显式 `-Dir $def`；1974 的 Detail 与实现相反 |
| c12-default-protected | upgrade | changes2==0（1977-1982） | 快照 | 同上 logs 冲突 |
| c12-old-helper-upgrade | upgrade | upd3 exit=0 且 `^3.1\.`（2015-2021） | helper 日志 | 起点 3.0 未断言（1992） |
| c12-old-helper-protected | upgrade | changes3==0（2025-2029） | **只有 after 快照**（2028） | 缺少 before 证据，无法证明"零变化"从何而来 |

### 1.13 项 13：bootstrap 绝对路径 + SHA256

| 检查 id | 阶段 | 断言（行号） | 证据 | 判定 |
| --- | --- | --- | --- | --- |
| c13-installer-metadata | final | 存在 + sha256 + 签名状态有值（2120） | `installer-metadata.json` | 有效（NotSigned 也算"有值"，符合"只记录"） |
| c13-entry-static | final | resolve-program-root 输出 == `{App}`（2140-2145） | resolve stdout | 有效 |
| c13-autosetup-trace | final | 90s 内抓到命令行含 `{App}\tools\bootstrap.ps1` 的进程（2174-2180） | `autosetup-trace.json` | **偏弱**：`Get-BootstrapChildTrace` 从不校验 `ParentProcessId`（2039-2051、2056），同窗口其他 bootstrap 进程也能满足 |
| c13-skill-wrapper | final | 包装 `##BOOTSTRAP` 路径 == appBoot 且哈希相等（2203-2209） | `skill-wrapper.json` | **哈希自证**：两哈希都现场算（2195-2198），真正有效的只有路径相等 |
| c13-evidence-inventory | final | 证据清单非空（2232） | `evidence-inventory.json` | 偏弱（排除 stage、>64MB 跳过） |
| c0-evidence-upload | final | 上传全部 2xx 且 rows>0（2258-2263） | 上传回执 json | 有效；但只传前 40 个 check json（2248） |
| c0-harness-fatal | 全域 | 异常兜底（2285-2293） | 异常文本 | 有效，但会把环境类失败也记成 fail-fixture |

### 1.14 覆盖缺口小结（项级）

1. **项 8 缺一半**：真实断网只跑 `-Offline`（1685-1687），"普通模式断网不得静默成功"没有检查。
2. **项 12 缺四项子断言**：3.0 起点版本（1846/1949/1992）、默认目录真实推断（1939-1945）、默认/助手路径的备份（仅 1926-1935）、助手路径的 before 快照（2028）。
3. **项 1 缺一条**：`asset_count=0 / 空哈希` 只列出（576-584），未与 manual 组件集合交叉断言。
4. **项 10 缺一条**：`unreadable=0`（1281 写了、1284 没判）。
5. **项 7 缺一条**："联网只补缺失"未在 bili 包层面断言（1448-1457 只判 qrcode + resolve）。
6. **无"应有检查集合"断言**：任何阶段只要正常返回，缺少的检查不会出现在 results.jsonl 里，也没有 missing-check 记录（对照 2270-2314）。

---

## 二、每条 Add-PhaseCheck 是否真带 preconditions 与 evidence

### 2.1 致命：包装层把库的两道门关掉了

```
 93|    [string[]]$Preconditions = @('来宾脚本已启动；验收库已加载'),
100|    [string]$Status = 'pass',
114|  # 证据只收真实存在的路径；缺失路径不塞给库（否则 Test-Path 抛错或把 pass 降级）
115|  $ev = @($cp)
116|  foreach ($e in @($Evidence)) {
117|    if (-not $e) { continue }
120|    try { if (Test-Path -LiteralPath $s) { $ev += $s } } catch { }
121|  }
```

后果有三层：

1. **前置条件门永久失效**：默认值非空（93）⇒ `New-MwCheck` 永远不会因"无前置条件"降级。55 处调用没有任何一处传入检查专属前置条件；`c0-*-precondition` 这几条"前置检查"本身也带同一句泛化前置（938/1358/1801）。
2. **证据存在性门永久失效**：`$ev` 首先塞入自己的 `checks\<id>.json`（115），它由 112 行刚写出来，永远存在；不存在的证据路径被 120 行静默丢弃。注释 114 明说这是为了避免"把 pass 降级"。于是 `Check.ps1` 唯一的机械防线被主动绕过——**任何检查只要不传 `-Status`（默认 `pass`，100）就一定 pass**。
3. **状态双写不一致**：107-112 行先用**未降级**的 `$Status` 落 `checks\<id>.json`，130 行 `New-MwCheck` 返回的 `$c` 才进 `results.jsonl`。若库降级，磁盘上的单条证据仍写 `pass`（本夹具里因为前两点不会发生降级，但结构上仍是自相矛盾的风险点）。

### 2.2 逐条结论

- 全部 55 处调用的 `Preconditions` 都是同一句泛化文本（未覆盖 93 的默认值），**没有一条**写"安装器已成功""AstrBot 已启动""缓存目录已构造"之类真正的前置条件。
- `Evidence` 参数层面：绝大多数传了 2-4 个路径，但都被 120 行过滤；真正到达 `New-MwCheck` 的只有 115 行的 `checks\<id>.json`。**因此"证据缺失"这一失效模式在本夹具里不可观测。**
- 明确"实际没测却可能判 pass / 判据与文案不符"的位置：

| # | 位置 | 问题 |
| --- | --- | --- |
| 1 | 441 vs 445 | 断言写"日志显示非管理安装模式"，判定只看 `-not $isAdmin` |
| 2 | 661、681 | 模型 digest 只做"URL 含同串"的字符串比对，Detail 自认 bootstrap 不复核 |
| 3 | 783 | 夹具自己选了 `-Base $Ws` 使 manual 恒真，等于没测产品的 manual 门禁 |
| 4 | 999、1003 | HTTP 4xx、异常带响应的 5xx 都算"有响应" |
| 5 | 1127 | 模型桩未监听也能 pass（只扫配置文本） |
| 6 | 1254 | 幂等的 ambiguous 归因可吞掉真实重复写入 |
| 7 | 1284 | `unreadable` 未参与判定 |
| 8 | 1553 | resolve=0 未参与判定 |
| 9 | 2039-2051、2172 | 子进程追踪不验父子关系 |
| 10 | 2195-2209 | 包装哈希自证 |
| 11 | 2232 | 清单只判非空 |
| 12 | 1846/1949/1992 | 升级起点版本只记录不判定 |

---

## 三、旧缺陷 (a)–(g) 是否真的避开

| 旧缺陷 | 结论 | 行号证据 |
| --- | --- | --- |
| (a) 连续 `-match` 覆盖 `$Matches` 吞 `/DIR=C:\中文 目录` | **已避开** | 379-380 单次 `-match` 后立即取 `$Matches[1]/[2]`；431-433 单次 `-match 'WsPath=\[(.*)\]'`；安装参数 418-419 只拼数组元素，引号/编码全交 Capture.ps1（355 行同样无手拼）；484 行 Detail 自述 |
| (b) 两次相同 `-Check` 当装前/装后对照 | **已避开** | 706-721 装前同实例 exit=2 + missing>0；1131-1153 装后 exit=0 + missing=0 + failed=0；before 从 `$RunDir\pre\checks\c5-check-before-components.json` 跨阶段读（1140-1144） |
| (c) `Copy-Item -LiteralPath` 配通配符 | **已避开** | 唯一通配符复制是 1320 行 `Copy-Item -Path (Join-Path $From '*') -Recurse`（1319 注释明写旧缺陷）；其余全 `-LiteralPath` + 具体文件（1481、1577、1578、1814、1822、1997） |
| (d) qrcode 探测没有 cwd | **已避开** | 1341-1354 `Resolve-Qrcode`：`Push-Location -LiteralPath $ProjectDir` + `Invoke-Cap -WorkDir $ProjectDir`，Cwd 写进 Detail/Data |
| (e) 硬编码 nodeExe 半安装路径 | **已避开** | 1324-1339 `Get-NodeExeFromLayout`（sidecar\node\node.exe → sidecar\* → 递归）；1408-1410 先 Ws 后 App，无硬编码 |
| (f) 幂等文件图漏程序根目录 | **已避开** | 1193/1195 `Get-FileMap -Roots @($Ws, $App)`；1253 判 `installerChanges==0` |
| (g) 证据只在 final 才上传 | **已避开（有一处错名）** | 2338-2352 finally 每阶段都 `Send-PhaseEvidence`；final 另有 2239-2251。**但** 2341 行写的 `manifest.sha256` 与 `Evidence.ps1:104` 实际产物 `manifest.json.sha256` 不符（2244 行写对了），该文件被静默跳过 |

---

## 四、参数解析与引号

- 参数面（13-22）：`-Phase` 校验集合、`-RunId` 必填；`-Installer31/-Installer30` 是**文件名**而非绝对路径（20-21），由 `Resolve-StagePath`（343-347）拼到 `$RunDir\stage`；宿主实际只传前 6 个（宿主 184-186），来宾走默认值——两边一致。
- 路径常量（46-53）：`{GuestRoot}\冥零 验收\程序 3.1` 与 `工作区 3.1` 含中文 + 空格，是刻意的验收条件。
- **引号不由脚本拼**：418-419 只构造 `('/DIR=' + $App)` 这类数组元素；420 行 `Invoke-Long` → `Start-MwCommand` 按扩展名判定 kind（`.exe` → MSVCRT 编码），由 `Capture.ps1` 的 `ConvertTo-MsvcrtArg` 决定加引号与双写尾部反斜杠。1773-1793 的 `Install-MwVersion` 同形（另加 `-Dir/-WsDir` 必填）。符合"不能自己拼引号"的要求。
- 中文/空格：整段 `"/DIR=C:\...\程序 3.1"` 被整体加引号，Inno 去掉外层引号后值完整；日志 `WsPath=[...]`（431-433）是唯一可观测的证据，c3/c4 都依赖它。
- 空参数：`$App/$Ws` 由 `Join-Path $GuestRoot` 生成（47-48），若 `$GuestRoot` 为空则路径退化但不会为空串；`/LOG=` 指向 `$EvidenceDir`（417），目录由 42-44 创建。
- 尾部反斜杠：`$GuestRoot` 在 34 行被 `TrimEnd('\','/')`；`$App/$Ws` 用 `Join-Path` 不会以反斜杠结尾；若调用方显式传 `-Dir "D:\x\"`，MSVCRT 双写规则会把它变成 `"D:\x\\"` 并被 Inno 正确还原——**这一点是库行为，我没有在真机验证**（不确定）。
- 残留风险：`$ErrorActionPreference='Stop'`（24）使任何非终止错误变成异常；安装器超时后 `Invoke-Long` 会杀树（216-258），但 `/LOG` 文件可能只写一半——c3/c4 读到半截日志时 `WsPath` 缺失会判 fail-product，而不是"证据不完整"（见第五节分类）。

---

## 五、失败路径

### 5.1 状态词的实际分布

| 状态 | 出现位置（行号） | 备注 |
| --- | --- | --- |
| fail-product | 445、455、473、483、696-702、1186、1253、1612/1622/1632、1710、1913、1922、1933、1975、1982、2021、2028、2145、2180、2209 | 主力失败态 |
| fail-fixture | 1398-1401（未观察到中断）、2285-2293（兜底）、410 抛异常路径 | 中断未触发也记夹具失败，合理但会掩盖"产品装太快" |
| blocked-precondition | 938、1358、1526、1801、1913、2021、2120、2145、2180、2209 | 多为"文件不存在" |
| blocked-env | 445（管理员令牌）、1710（无法断网） | 正确 |
| evidence-incomplete | 402、1186-1188、2120、2263 | 仅 4 处显式使用；**库的自动降级从未触发**（见 2.1） |
| not-run | 747/757（WebView2 已存在时的分支） | 唯一使用 not-run 的地方 |
| manual-pending | 未使用 | 词表里有，脚本不用 |

### 5.2 落盘与退出码（正确）

- finally 2316 `Save-MwPhase` → `$RunDir\phases\<Phase>\{results.jsonl,commands.jsonl,phase.json,manifest.json(+.sha256)}`；`Save-MwPhase` 异常被 try/catch 吞掉只写 `save-error.txt`（2316-2318）。
- 2320-2333 写 `done.json`（含 counts/status/exitCode/checks）；2338-2352 兜底上传；2354 `exit $exitCode`；2298-2300 用 `Get-MwPhaseExitCode` 并对 fatal 强制 11。
- 异常不会吞掉后续**落盘**：catch 只加一条 `c0-harness-fatal`，finally 仍执行。**但会吞掉后续检查**：例如 410 行 3.1 缺失直接 throw，pre 阶段 c1/c2/c4/c5/c11 全部不产生记录，且没有 not-run 占位，结果只剩 1 条 fail-fixture。

### 5.3 三个语义问题

1. **status 与 exitCode 可矛盾**（2303-2304）：只有 fatal 或 fail-product/fail-fixture>0 才 `status='failed'`；blocked-precondition(12)/blocked-env(13)/evidence-incomplete(14) 时 `status` 仍是 `completed`。宿主 `Run-Acceptance.ps1:282` 只用 counts 求和，**不读 status**，所以不会误报通过；但 `done.json.status` 对任何读它的人（或宿主超时伪造值的对照）都是误导。
2. **阶段产物只走 HTTP**：宿主的目录回收只覆盖 `$RunDir\<Phase>`（宿主 232-234），而 `Save-MwPhase` 写在 `$RunDir\phases\<Phase>`（`Evidence.ps1:157-180`）。上传失败（`c0-evidence-upload` 只判 evidence-incomplete）时，phases 目录的 results/manifest 不会随目录树回传，只剩逐条 `checks\*.json` 与 `done.json`。
3. **证据路径可以是目录**：c3c4 的 `-Evidence @(..., $App)`（472、482）传的是目录，`Test-Path` 通过即算"证据存在"，没有哈希/清单约束。

### 5.4 分类错误

- `Get-StageAsset`（349-358）下载失败（无重试，`-TimeoutSec 900`）会抛异常 → 2281 catch → `c0-harness-fatal` = **fail-fixture(11)**。网络/宿主服务不可达本应是 **blocked-env(13)**，这会把"环境问题"记成"夹具坏了"。

---

## 六、半安装（构造）与真实中断

- **两者是分开的**：真实中断在 1364-1467（操作真实安装目录 `$App`），构造半装在 1469-1528（新目录 `半装 <RunId>`，复制 node 缓存、`Copy-TreeIfExists` 复制 bili 源、删掉自带 `node_modules\qrcode`）。互不污染，顺序也合理（先真实后构造）。
- **真实中断没有等到可观察阶段**（致命）：
  - 1366-1386 轮询被杀进程 stdout 的最后一条 `##STEP`；1378 行 `if ($observed -match 'npm|bili|node_modules') { break }`。被装组件 id 就叫 `bili-whale`，`##STEP` 文案几乎必然含 "bili" ⇒ 第一次轮询（400ms）就可能 break 并杀树。
  - 1379 行的 45s fallback 是"无论是否到 npm 都杀"。
  - 因此 1395-1403 的 Assertion（"等进程进入可观察安装阶段后再结束进程树"）与实现不符；被杀时可能连 bili 源都没开始复制，"中断后离线必须失败"测到的是"根本没装"，不是"半装"。
  - 没有"杀之前确认 node_modules 已出现/部分出现"的断言。
- **真实状态对照是有的**：1405-1413 取 node 目录 sha/size/mtime 快照 → 1416-1418 离线跑（必须失败）→ 1421-1423 联网跑（必须修好）→ 1431 重新取快照 → 1459-1467 判零变化。这是本脚本最扎实的一段。
- **"只补缺失"没测**：1448-1457 只要求 `qrcode` 存在 + resolve=0，没有比对联网重装前后 bili 的其他包是否被重下（`nodeHalfChanges` 只在构造半装那条里用于 node 侧，1553）。
- **构造半装的"离线必败"判据也有点宽**：1517-1518 只要 exit=2 + qrcode 不存在 + resolve≠0，不校验 stderr 是否真的是"缺 qrcode"（可能是缓存缺失、网络缺失等其它原因）。

---

## 七、误报通过 / 长安装卡死与超时

### 7.1 误报通过的通道

1. 2.1 的包装层（93/100/115-121）——结构性、全局。
2. c2-stage-integrity 的篡改只到 `evidence-incomplete`（402）——安装包被换仍是"证据不完整"，不是"产品失败"。
3. c9 HTTP 4xx/5xx 算通过（999/1003）。
4. c9 模型桩未监听也 pass（1127）。
5. c11-pre 的选择偏差（783）。
6. c12 起点版本未断言（1846/1949/1992）：如果 3.0 安装静默失败但目录里残留 3.1，`--wb-update` 可能空跑，三条 `^3.1` 断言照样通过。
7. c13 autosetup 不验父子关系（2043-2059）——同窗口任何 bootstrap 进程都能满足。
8. 上传只取前 40 个 check（2248），被截断的检查在证据服务器上不存在，但 `c0-evidence-upload` 只看 rows>0 与 HTTP 2xx（2258-2263）。

### 7.2 超时与等待（与宿主上限对照）

宿主上限（`Run-Acceptance.ps1:39` 附近）：pre 90min、full 180min、recovery 120min、upgrade 120min、final 45min；轮询 20s，超时直接杀来宾并伪造 `fail-fixture`。

| 阶段 | 来宾内超时（行号） | 与宿主上限的关系 |
| --- | --- | --- |
| pre | 6 个资产各 900s 下载（355）+ 安装 900s（420） | 下载累计最坏 5400s，加上安装，逼近 90min |
| full | 全量安装 **14400s**（951-952）；第二次 7200s（1211）；astrbot 启动 600s（1060）；apply 1800s（1073）；verify 900s | **14400s > 10800s**：慢机必被宿主杀成 fail-fixture(11)。这是确定性冲突，不是概率问题 |
| recovery | 中断轮询 45s + 离线 900s（1417）+ 联网 1800s（1422）+ node 600s（1485）+ 半装离线 300s（1493）+ uv 900s+3×300s + 断网 ≤ 300s | 合计约 6000-7000s，与 7200s 上限只差几百秒，无余量 |
| upgrade | 3 次安装/升级各 1200s + 3 次等版本 240s（1862/1961/2007） | 最坏约 8000s+，**超过 7200s** 上限 |
| final | autosetup 90s + 包装 `-Check` 900s（2189）+ 串行上传 10+5+40 个文件 × 180s（2080-2081） | 上传最坏 9900s，远超 2700s（45min） |

### 7.3 其它卡死/失败处理

- `Invoke-Long`（216-258）每 10s 轮询，超时杀树后 `Complete-MwCommand -TimeoutSeconds 120`，可控。
- 断网段 1641-1666 先 `Find-NetRoute` 找与宿主通道不同的默认路由，找不到则 `blocked-env`（1710），不会断掉宿主通道；`finally` 里 `Enable-NetAdapter`（1692-1695）。风险：example.com 失败可能是 DNS/代理造成（判据未区分），**不确定**；若来宾只有一块网卡，该检查永远 blocked-env。
- `Invoke-WebRequest` 全部带 `-UseBasicParsing`（355、997、2080），PS 5.1 下不依赖 IE 引擎，这点没问题。
- 库里的 `Send-MwEvidence`（curl.exe）**没有被使用**；来宾自写 `Send-PhaseEvidence`（2068-2094），失败只记录不抛出，不会中途中止阶段。
- `$ErrorActionPreference='Stop'`（24）：任何未包 try 的非终止错误都会把整阶段推进 catch，变成 fail-fixture。`Get-NetTCPConnection`/`Get-CimInstance`/注册表读取处大多有 try，但 `Get-Item`、`Get-FileHash` 在多处直接调用（389、436、2103），文件被并发占用时会整阶段失败。

---

## 八、不确定项（明确标注，未推测为结论）

1. 尾部反斜杠在 MSVCRT/Inno 组合下的实际还原效果：我依据 `Capture.ps1` 的双写规则推断可还原，**未在真机验证**。
2. 若 `bili-login` 的 `verify` 在断网/未登录时返回非 0（产品侧记 failed 而非 manual），`c11-default-manual` 的 `manual>=3` 可能变成 2 → fail-product。这是产品行为依赖，**未核 verify-manual.ps1 实现**。
3. `installer/mingling.iss:126` 的 `[Run]` 是否在 `/VERYSILENT` 下也执行（Inno 的 `[Run]` 默认在静默安装时执行，`runhidden` 不影响）：我按"会执行"判断，**未实跑安装器**。
4. c7 中断杀树时 `taskkill /T /F` 对 npm 子进程的实际覆盖范围：取决于进程树，**未实跑**。
5. 宿主 `Run-Acceptance.ps1` 的 phase 超时值我只读了常量声明（39 行附近），未逐行核对是否被覆盖。

---

## 九、问题编号清单（F=致命 6 条，M=需修正 25 条）

### 致命（6）

| 编号 | 位置 | 问题 |
| --- | --- | --- |
| F-01 | 93、100、114-121、107-112 vs 130 | 包装层默认前置条件 + 默认 pass + 静默丢弃缺失证据，`Check.ps1` 的两道 pass 门全部失效；`checks\<id>.json` 写未降级状态，与 results.jsonl 可能不一致 |
| F-02 | 1846、1949、1992（判定 1913/1967/2015） | 三条升级路径都不断言起点是 `^3\.0\.`，3.0 安装静默失败但残留 3.1 时空跑也能 pass |
| F-03 | 1725-1744、1917-1922、1977-1982、2025-2029；`installer/mingling.iss:126` | 受保护快照含 `logs` 且不白名单 `installer-check.log`，产品 `[Run]` 必写该文件 ⇒ 三条 protected 断言大概率必然 fail-product |
| F-04 | 1378-1379、1383-1385、1398 | 中断判据 `'npm\|bili\|node_modules'` 对 bili-whale 几乎恒真 + 45s 无条件 fallback，"等可观察阶段"不成立 |
| F-05 | 1685-1687 | 真实断网只测 `-Offline`，缺"普通模式必须失败且无产物"（项 8 明文要求） |
| F-06 | 951-952 vs 宿主 `Run-Acceptance.ps1:39` | 全量安装允许 14400s，宿主 full 上限 10800s ⇒ 慢机必然被宿主杀成 fail-fixture(11) |

### 需修正（25）

| 编号 | 位置 | 问题 |
| --- | --- | --- |
| M-01 | 441 vs 445 | c3 断言写"日志非管理安装模式"，判定只看 `-not $isAdmin` |
| M-02 | 481（判定 483） | c4 `Expected $App` / `Actual $AppExe` 语义错位，且与 c3-program-workspace-separate 重复 |
| M-03 | 606 | c1-state-model 两个分支同值（死分支） |
| M-04 | 386、402 | c2-stage-integrity 只校验 5 个固定文件（checksums.txt 自身未自校），不一致只降 evidence-incomplete 不判产品失败 |
| M-05 | 661、681 | c2-source-real-chain 模型 digest 只做"URL 含同串"字符串比对，不是资产校验 |
| M-06 | 1549 vs 1553 | c7-half-install-online-fix 断言里的 resolve=0 未参与判定 |
| M-07 | 1448-1457 | c7-online-recovers 未断言"只补缺失"（其他包是否被重下） |
| M-08 | 1281 vs 1284；1259-1268、1275 | c10 `unreadable` 未参与判定；范围不含 `%LOCALAPPDATA%\Programs`；>64MB 文件跳过 |
| M-09 | 1127；788-837 | c9 模型桩未监听也能 pass（只扫配置文本，不校验 stub 状态） |
| M-10 | 999、1003 | c9 AstrBot HTTP 4xx 算通过；异常但带响应的 5xx 也算通过 |
| M-11 | 769-772、783 | c11-pre 用 `-Base $Ws` 使 qq-login detect 必然失败 ⇒ manual 恒真，不能证明产品 manual 门禁 |
| M-12 | 2039-2051、2056、2172 | c13 autosetup 记录 parentPid 但从不校验 `ParentProcessId` 链到 entryPid |
| M-13 | 2195-2198、2209 | c13-skill-wrapper 两个哈希都现场算，哈希相等恒真，只剩路径相等有效 |
| M-14 | 2218、2219、2232 | c13-evidence-inventory 只判"非空"，排除 stage、跳过 >64MB |
| M-15 | 2248 | 上传 `Select-Object -First 40` 静默截断检查 json，无截断标记 |
| M-16 | 2341 vs `Evidence.ps1:104` | 兜底上传写 `manifest.sha256`，实际产物是 `manifest.json.sha256`，该文件被静默跳过 |
| M-17 | 1939-1945、1974 | 默认目录路径显式传 `-Dir $def`，未验证 DefaultInstallDir 推断；1974 的 Detail 与实现相反 |
| M-18 | 1926-1935 | 备份（backup-manifest + unins）只在自定义路径断言，默认/助手路径未查 |
| M-19 | 2028 | c12-old-helper-protected 的 Evidence 只有 after 快照，缺 before 证据 |
| M-20 | 1196、1254 | c6 幂等的 ambiguous 归因可吞掉真实重复写入（Detail 自认） |
| M-21 | 349-358、410、2281 | `Get-StageAsset` 无重试（900s 单发），失败被归为 fail-fixture(11) 而非 blocked-env(13) |
| M-22 | 2316-2318；宿主 232-234 | `phases\<Phase>` 不在宿主目录回收范围，只靠 HTTP 回传；`Save-MwPhase` 异常被吞 |
| M-23 | 2270-2314 | 无"应有检查集合"断言：阶段正常返回时缺少的检查不留 not-run 痕迹 |
| M-24 | 1862、1961、2007 | 等升级完成窗口 240s，短于产品自更新窗口（约 600s），慢机假失败 |
| M-25 | 2080-2081、2239-2251 | final 串行上传最多 55 个文件 × 180s，可能超过宿主 45min 上限 |

## 十、版本漂移记录（审查期间 live 文件仍在改动）

审查期间 `acceptance/v2/guest/Invoke-Phase.ps1` 至少变动 5 次：2337 行（20:38）→ 2356 行（20:39，`8a8c385c…`，**本报告基准**）→ 2482 行（20:48）→ 2506 行（20:49 初）→ 2527 行（20:49:14，`12f0da33…`）。因此上面所有结论与行号**只对 2356 行冻结版成立**；对 live 版不可直接复用行号。

作为给使用者的补充，我在 20:49:14 的 live 版（2527 行，md5 `12f0da3327f2d6832dc585195251acc4`）上对本报告的关键点做了一次抽查（只核关键行，不是完整复审）：

| 编号 | live 状态（20:49:14） | live 行号 |
| --- | --- | --- |
| F-01 包装层两道门 | **仍在**（默认 Preconditions、丢弃缺失证据的注释与实现都保留） | 93、114-121 |
| F-02 升级起点版本 | **已修**：三条路径都断言 `v30 ^3\.0\.`（自定义/默认/旧助手） | 2027、2096、2169 |
| F-03 protected 含 logs | **仍在**：快照仍含 `logs`，且 Detail 明写"不豁免 installer-check.log" | 1787、2037 |
| F-04 中断判据 | **部分修**：break 词已从 `'npm\|bili\|node_modules'` 改为 `'npm\|node_modules\|qrcode'`；但 45s `fallbackKill` 仍无条件成立，且 `c7-interrupt-observed` 的状态不看 fallbackKill | 1431-1432、1452-1455 |
| F-05 断网只测 -Offline | **仍在** | 1738 |
| F-06 full 14400s > 宿主 10800s | **仍在** | 971 |
| M-01 c3 模式行 | 已修（新增 `$modeNo` 并进入判定） | 461-467 |
| M-08 c10 unreadable | 已修（`unreadable=0` 进入判定） | 1319-1322 |
| M-09 模型桩 Listening | 仍在（仍只扫配置文本） | 1146-1155 |
| M-10 HTTP 4xx/5xx | 仍在 | 1029 |
| M-11 c11-pre `-Base $Ws` | 仍在 | 788-789 |
| M-12 父子关系 | 仍在（parentPid 只记录不比较） | 2204 |
| M-13 包装哈希自证 | 仍在 | 2366-2379 |
| M-15 上传截断 40 | 仍在 | 2419 |
| M-16 manifest sha 文件名 | 抽查中**未再发现** `manifest.sha256` 错名（疑似已修） | — |
| M-18 备份只测自定义路径 | 已修（默认与旧助手路径都有 `Find-BackupManifest`） | 2109、2181 |
| M-19 old-helper 缺 before | 已修（新增 `$protBefore3`） | 2138 |
| M-21 stage 下载失败分类 | 已修（try/catch + `c2-stage-assets` = blocked-env + 提前 return） | 368-395 区间（diff 显示） |
| M-17 默认目录 | 仍在（仍显式传 `-Dir $def`，Detail 仍称"默认目录"） | 2064、2097 |

补充：20:50:39 复核时 live 仍是 2527 行但内容已再次变化（md5 `4e4b0619e0a9738063e50aaba5cdd4ce`，`Add-PhaseCheck` 调用增至 59 处），说明下表只是时点快照。

结论：**live 版已经修掉了本报告 6 条致命里的 1 条（F-02）并大幅削弱 F-04，但 F-01（包装层）、F-03（logs 冲突）、F-05（断网普通模式）、F-06（超时预算）四条仍然成立**；25 条需修正中至少 6 条已被 live 改掉。由于 live 仍在变动，建议以本报告的"编号 + 断言文本"为准做定点复核，而不是按行号 diff。



## 十一、建议的最小修正集（按优先级）

1. `Add-PhaseCheck`：删掉默认 `Preconditions`、默认 `Status` 改必填；不要在 120 行丢弃缺失证据，改为把"缺失路径"作为 Detail 传给库让其降级；`checks\<id>.json` 写库返回后的 `$c`（107-112 移到 130 之后）。
2. c12：三条路径都断言起点 `^3\.0\.`（1846/1949/1992）；默认目录路径去掉显式 `-Dir`（1945）或显式记录"这是 /DIR 覆盖，不是默认推断"，并修正 1974 的 Detail；备份检查覆盖三条路径；助手路径补 before 快照；`Get-ProtectedSnapshot` 对 `logs\setup\installer-check.log` 做白名单（1740 附近）。
3. c7 中断：判据改为"bili-whale\node_modules 出现且不完整"或"##STEP 进度 ≥ 某值"，并断言杀之前已产生 `node_modules`；去掉 45s 无条件 fallback；半装联网补 resolve=0 与"其他包未重下"。
4. c8：断网时增加"普通模式（不带 `-Offline`）"分支，断言非 0 且无 uv.exe。
5. 超时：full 的 14400s 与宿主 10800s 对齐（取小者或调宿主）；upgrade 三次 240s 提到 600s；final 上传改并发或分批并断言"文件数==预期"。
6. 分类：`Get-StageAsset` 失败、stage 不可达 → blocked-env；`c2-stage-integrity` 哈希不一致 → fail-product。
7. c9：HTTP 只接受 2xx/3xx；`c9-model-stub-protocol` 增加 `stub.Listening`；`c10` 把 `unreadable` 纳入判定；`c3` 把 `$modeLine` 纳入判定；`c13` 用 `ParentProcessId` 链回溯到 `entryPid`，并用"由 appBoot 现算的哈希"与"由包装输出路径读到的文件字节"比较（而不是两个现场计算值）。
