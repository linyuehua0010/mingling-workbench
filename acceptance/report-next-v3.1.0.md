# 冥零工作台 V3.1.0 安装自动化验收报告（续轮）

生成时间（Asia/Shanghai）：2026-11-10T07:49:32+08:00

**结论：验收未闭环，整体 blocked-env。** full → recovery → upgrade → final 已按顺序分别实际调用宿主入口，四次都在来宾启动前返回 13。新包断网专项亦返回 13，未切 NAT。SnowLuma 缓存补传未完成。这不是四阶段端到端成功报告；产品全链路完成标准尚未达到。

当前安装包与已有 pre 证据指纹完全相同，因此保留该包已证部分；没有借用旧包 netcut、失败旧构建或静态分析声称新包成功。13 项均有显式结论：整项已证 2 项、部分且未覆盖 1 项、环境阻塞 10 项。

## 产物与源码

- 安装包：`dist/MinglingWorkbench-3.1.0-setup.exe`；88,855,864 B；版本 3.1.0.0 / V3.1.0。
- SHA256：`ff9982cd9c45be477f49471a248b93cb7b8c1f28adeaae7b677716f336d809f8`。
- Authenticode：**NotSigned**，无签名者；本轮由 report-data.py 实际采集。
- Git HEAD：`37adb9fc8772921c24791337378a64c09b124257`；分支 `main`；`git status --porcelain` 85 项（含 untracked 目录折叠计数）。
- 未改产品、未重建、未改版本号；四次 Prepare-Stage 均 5/5 成功。完整脚本哈希与 stage 指纹见 [report-data.json](evidence/report-20261110-074000/report-data.json)，执行入口快照在同目录 `script-snapshots/`。
- pre 的本轮只读复核：根清单 82 个列出文件全部匹配 SHA256/字节，清单自哈希也匹配；stage 中包哈希与当前包相等。详见 [input-manifest-validation.json](evidence/report-20261110-074000/input-manifest-validation.json)。

## 实际运行与环境

同指纹 pre 已覆盖：Windows 11 专业版 10.0.26100.1742（非 Insider），标准用户 MWAcceptance，非管理员令牌，NAT VMnet8，中文空格程序目录与工作区分离。本轮新阶段只执行到了宿主前置门禁；未重新证明来宾 OS/权限/联网状态。VMX 目标始终为 `E:\Windows 11 x64\Windows 11 x64.vmx`。只读窗口清单没有 VMware 窗口，vmrun 也无法列出 VM，故交接中的“运行中”状态本轮无法确认。未启动、关闭或回滚 VM；未改动来宾目录或宿主 NAT。

| 入口 | 独立 run-id | 结果 | 实际范围 |
|---|---|---|---|
| seed | [seed-20261110-074827-1f6c](evidence/seed-20261110-074827-1f6c/run.json) | 13 / blocked-env | vmrun 宿主启动失败；guestStarted=false |
| full | [v310-20261110-073846-90ac](evidence/v310-20261110-073846-90ac/run.json) | 13 / blocked-env | 本地证据 socket WinError 10013；guestStarted=false |
| recovery | [v310-20261110-073855-374e](evidence/v310-20261110-073855-374e/run.json) | 13 / blocked-env | 本地证据 socket WinError 10013；guestStarted=false |
| upgrade | [v310-20261110-073903-b09f](evidence/v310-20261110-073903-b09f/run.json) | 13 / blocked-env | 本地证据 socket WinError 10013；guestStarted=false |
| final | [v310-20261110-073914-6ab5](evidence/v310-20261110-073914-6ab5/run.json) | 13 / blocked-env | 本地证据 socket WinError 10013；guestStarted=false |
| netcut | [netcut-20261110-074839](evidence/netcut-20261110-074839/run.json) | 13 / blocked-env | vmrun 宿主启动失败；guestStarted=false |

每次失败都保存 `run.json`、`phases/<phase>/phase.json`、`results.jsonl`、`commands.jsonl`、宿主 checks、stdout/stderr、manifest.json 及 manifest.json.sha256。`guestExitCode=null`，避免把宿主退出码当成来宾退出码；没有 progress.json 或来宾日志，因为来宾阶段根本未启动。原始错误在各 run 的 `host/`（seed/netcut 位于 run 根目录）。

首次 full 尝试 `v310-20261110-073706-0cf1` 在原入口的早期返回路径退出 13，只留下外层日志、没有 run 目录；该证据落盘缺口已修，正式 full 用新 run-id 重跑。首条按交接调用的旧缓存 helper 曾写入既有 `_seed` 的六个同名辅助 stdout/stderr；这是本轮的保留缺口，无法还原先前同名内容。此后 helper 已改为独立 seed run-id；未修改任何历史正式验收 run。另 HANDOVER 已记载 `acceptance/local-verify.json` 在上一轮被旧脚本覆盖，不能宣称原件仍完整。

## 分类计数

| 口径 | 产品失败 | 夹具失败 | 环境阻塞 | 人工待办 |
|---|---:|---:|---:|---:|
| 本轮最终 6 个宿主门禁子检查（补缓存+四阶段+断网） | 0 | 0 | 6 | 0 |
| 13 项整项结论 | 0 已运行证实 | 0 未解决夹具失败 | 10 | 另列 4 |

两类环境根因：① 本地 loopback 连接被系统拒绝（实际 Python stderr 为 WinError 10013）；② vmrun 本身无法启动（连不带凭据的 list 也失败）。这两类故障发生在产品运行之前，不归因于产品。计数 0 产品失败表示没有本轮新动态失败，**不表示产品没有缺陷**。已有 pre 为 13 pass / 1 not-run，不与本轮门禁检查混算成 19 项通过。13 项中的来源完整性整体另记 not-run（部分已证），WebView2 另记 not-run。人工待办为 QQ、B站、真实付费 API、SoulX/CUDA 共 4 项，缺失条件见下文。

交付前曾实际发现 **1 项夹具安全失败**：Capture 参数数组未遮蔽 VMware 的 -vp/-gp；命令行文本已遮蔽，但两个新诊断 run 的 commands.jsonl 中仍出现凭据。已就地用内存凭据脱敏这两份文件，未保留含明文副本，redaction-remediation.json 记录变更前后摘要；修复 Capture 后新增 4/4 回归检查，并用新 run-id 重新执行 seed 与 netcut。旧诊断 run 仅保留已脱敏现场，不作为修复后夹具的验证依据。最终表统计复跑后的检查，夹具失败数 0；本轮发现过的该失败数为 1，不能说从未发生泄漏。报告与对话没有输出口令原文。

本轮最小夹具修复：DPAPI 目录在 LOCALAPPDATA 重定向时回退到同一用户既有存储；部署前与证据服务早退生成明确 blocked-env；Capture 同时遮蔽 argv 中的 -vp/-gp 与带引号命令行；缓存补传使用独立 run-id；断网入口使用 VM state.text 并移除不存在的 Start-MwVm -Label 参数；Run-All 在最终汇总后封存；collector 不把来宾未回收文件默认声称为“存在”；report-data 修复 PowerShell 调用及 5.1 PSModulePath 污染导致签名状态空值。所有修改的验收 ps1 均 BOM 且通过真实 PS 5.1 Parser；阻塞分支已实际运行验证。正常来宾执行路径仍待复验，没有通过放宽产品断言消除失败。

## 13 项要求—前置条件—步骤—断言—证据

机器可读矩阵：[criteria.json](evidence/report-20261110-074000/criteria.json)。每个 run 已用 collect-findings.py 聚合，见 `evidence/report-20261110-074000/findings/`。

### 1. 组件结构、依赖图与状态模型 — pass

- 前置条件：当前包与 pre 的 stage 哈希一致；清单可读取。
- 实际步骤：pre 实际解析 21 组件，验证 schema、无悬空/无环、自动及人工状态模型。
- 断言及结论：4 个 c1 检查 pass；21 组件，0 图问题；这只覆盖该项定义的结构行为。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-manifest-schema.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-manifest-schema.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-dependency-dag.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-dependency-dag.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-source-hashes.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-source-hashes.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-state-model.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-state-model.json)

### 2. 来源完整性与篡改拒绝 — not-run

- 前置条件：下载/锁/树摘要的实际消费链；可运行安装通道。
- 实际步骤：已执行 pre 的 stage 5/5 校验与 uv 缓存篡改拒绝；本轮 full/recovery 被宿主门禁阻断。
- 断言及结论：部分已证：篡改缓存 exit 2 且拒绝安装；不能据此推定所有资产均强制校验。AstrBot package_sha256 未消费、npm integrity 未单独篡改、embedding 层未真实拉取/负向复验、SoulX 无闭环。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-stage-integrity.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-stage-integrity.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-source-real-chain.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-source-real-chain.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-tamper-reject.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-tamper-reject.json)；[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)；[analysis/integrity.md](analysis/integrity.md)；[analysis/soulx.md](analysis/soulx.md)

### 3. 干净普通用户安装 — pass

- 前置条件：pre 使用标准用户 MWAcceptance，清除专用测试安装基线。
- 实际步骤：真实安装器安装，检查身份令牌、Inno 模式、最终主程序版本。
- 断言及结论：administratorToken=false；Administrative install mode: No；最终 exe=3.1.0.0；不只依赖安装器 exit 0。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-normal-user-install.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-normal-user-install.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-exe-version.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-exe-version.json)

### 4. 中文空格路径、程序/工作区分离、启动与配置读取 — blocked-env

- 前置条件：分离程序/工作区；可真实启动并读取配置。
- 实际步骤：pre 已真实安装至中文空格目录并核对 WsPath；本轮 full/final 未进入来宾。
- 断言及结论：目录/分离部分 pass；同一当前实例的实际启动、配置读取全链尚未证明，整项不算通过。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-workspace-separate.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-workspace-separate.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c4-chinese-space-paths.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c4-chinese-space-paths.json)；[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)；[evidence/v310-20261110-073914-6ab5/phases/final/](evidence/v310-20261110-073914-6ab5/phases/final/)

### 5. 同一安装实例 Check 前后状态变化 — blocked-env

- 前置条件：同一实例在组件安装前后均可 Check；full 完成。
- 实际步骤：pre 真实记录安装前 exit=2、missing=11；full 未启动。
- 断言及结论：缺少安装后的有效状态；不能用两次相同 Check 替代状态翻转。HANDOVER 表中“已证”按原始 check 收紧为部分。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c5-check-before-components.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c5-check-before-components.json)；[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)

### 6. 第二次默认执行严格幂等 — blocked-env

- 前置条件：首次默认安装真正完成；后台自然写入可区分。
- 实际步骤：full 入口实际执行，宿主证据 socket 连接失败即停止。
- 断言及结论：未取文件集合/内容 SHA256/mtime 的前后对照，未排除 logs/state 绕过断言；未覆盖。
- 证据：[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)

### 7. 真实中断与合成半安装恢复 — blocked-env

- 前置条件：可观察真实安装阶段、可控进程树、有效联网与缓存基线。
- 实际步骤：recovery 入口实际执行，宿主门禁阻断。
- 断言及结论：未杀来宾进程；离线失败/联网恢复/不重装已完成组件、两条恢复路径均未覆盖。
- 证据：[evidence/v310-20261110-073855-374e/phases/recovery/](evidence/v310-20261110-073855-374e/phases/recovery/)

### 8. Offline 有效/空/坏缓存与真实断网 — blocked-env

- 前置条件：可访问来宾与 NAT；断网前真实可达；控制和取证通道可保留。
- 实际步骤：recovery 与 netcut 各自独立运行；后者 vmrun list 失败。
- 断言及结论：没有停 NAT；没有来宾不可达证明；三种缓存与当前包真实断网均未覆盖。旧 netcut-7127 不作为本包通过依据。
- 证据：[evidence/v310-20261110-073855-374e/phases/recovery/](evidence/v310-20261110-073855-374e/phases/recovery/)；[evidence/netcut-20261110-074839/phases/netcut/](evidence/netcut-20261110-074839/phases/netcut/)

### 9. AstrBot 真实初始化/进程/HTTP、八块 apply/verify — blocked-env

- 前置条件：默认组件安装成功；可连接真实 AstrBot 后台。
- 实际步骤：full 入口被宿主证据端口门禁阻断。
- 断言及结论：初始化标记、监听进程归属、HTTP、8 块配置落盘与回读均无本轮新结论；本地模型桩即使可用也仅证明协议，不能代表真实付费服务。
- 证据：[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)

### 10. 成功配置后的密钥泄漏扫描 — blocked-env

- 前置条件：成功配置的真实或明确标记测试凭据；程序/工作区/缓存/临时/验收全范围可读。
- 实际步骤：full/final 未启动；仅另做本轮宿主交付物敏感字符串检查。
- 断言及结论：产品扫描未覆盖；宿主交付物检查不能替代 c10。应记录 skip/unreadable，不能将无法读取视为无泄漏。
- 证据：[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)；[evidence/v310-20261110-073914-6ab5/phases/final/](evidence/v310-20261110-073914-6ab5/phases/final/)；[evidence/report-20261110-074000/host-delivery-secret-scan.json](evidence/report-20261110-074000/host-delivery-secret-scan.json)

### 11. QQ/B站/API Key 独立 manual — blocked-env

- 前置条件：无真实外部凭据仍须独立 manual；默认执行及点名父组件均需验证。
- 实际步骤：pre 仅验证 SnowLuma manual=1、detect exit=3；full 未启动。
- 断言及结论：该 pre 子项不能替代 QQ/B站/API Key 三项默认及父组件路径；真实登录与付费调用另列人工待办。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c11-pre-snowluma-manual.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c11-pre-snowluma-manual.json)；[evidence/v310-20261110-073846-90ac/phases/full/](evidence/v310-20261110-073846-90ac/phases/full/)

### 12. 已发布 V3.0 三条升级路径 — blocked-env

- 前置条件：真实 V3.0 安装包；每条独立基线；可运行被占用旧 exe 及安装器。
- 实际步骤：upgrade 入口实际执行，未进入来宾。
- 断言及结论：自定义目录/默认目录/独立助手均未覆盖；原路径、完整备份含 unins、保护目录、最终替换及升级首次启动新增写入均无结论。
- 证据：[evidence/v310-20261110-073903-b09f/phases/upgrade/](evidence/v310-20261110-073903-b09f/phases/upgrade/)

### 13. 工作台/技能 bootstrap 绝对路径与 SHA256 一致 — blocked-env

- 前置条件：程序已安装；工作台子进程与技能包装均可实际运行。
- 实际步骤：final 入口实际执行，未启动来宾。
- 断言及结论：未抓实际子进程或技能输出；源码哈希记录不等于运行路径证明；未覆盖。
- 证据：[evidence/v310-20261110-073914-6ab5/phases/final/](evidence/v310-20261110-073914-6ab5/phases/final/)

## 外部依赖与未覆盖资产

- **webview2-missing / not-run**：来宾已装 WebView2 122.0.2365.106；需要快照副本中的缺失基线。人工入口：在独立快照副本准备无 WebView2 基线后重跑 pre；本轮不卸载原基线。
- **qq-login / manual-pending**：真实 QQ 测试账号与本人扫码。人工入口：工作台 QQ 平台入口；由账号持有人完成登录。
- **bili-login / manual-pending**：真实 B站账号与本人扫码。人工入口：工作台 B站登录入口；由账号持有人操作。
- **paid-api / manual-pending**：有效、获授权且可计费的 API Key。人工入口：工作台模型配置入口；本机填写，不发进对话或验收日志。
- **soulx-cuda / manual-pending**：可用 NVIDIA GPU/驱动、CUDA torch 依赖锁、模型可信哈希及足够磁盘/网络。人工入口：powershell -NoProfile -ExecutionPolicy Bypass -File "<程序目录>\tools\setup-singing.ps1" -Base "<测试工作区>" -Root "<测试工作区>\sing" -Action check；实际部署通过工作台“部署本地唱歌”人工选择。

来源完整性已有机制与代表性运行证据：固定下载资产 SHA256、requirements 锁及逐 wheel 哈希、bili 源码树清单、npm lock integrity、Ollama manifest/layer 元数据。pre 证明 stage 完整与 uv 缓存篡改拒绝；对其余未执行资产不得扩大结论。AstrBot package_sha256 字段未被 bootstrap 消费；npm install 不是 npm ci，未单独动态证明损坏 npm 包会被拒绝；node/ffmpeg 已存在探针有旁路风险；手工组件的清单摘要不等于实际安装链已校验。

embedding-model：当前 manifest pin 已修，但不属于默认集；真实 1.1 GB 拉取及缺 blob/尺寸不符 exit 3 的负向场景均未运行。bili-bridge-plugin、memory-plugin 等人工/独立脚本链与所有 manual 零资产不宣称纳入同一 bootstrap 强校验。

SoulX 当前代码复核：默认 Root 已按上一轮修为 `<base>\sing`，不沿用旧审计里已过时的目录缺陷；源码仍 git clone 默认分支，已有归档固定哈希没有被该脚本使用；Python 3.10 具体 build 未固定；torch/torchaudio 2.7.1 cu128 无逐包哈希锁；其他 pip 依赖未完全锁定；model.pt 只有 2,818,092,278 B 门槛，清单探针为 2,800,000,000 B；对齐模型 revision 未固定。这均未新增可信锁或运行验证，属于剩余工作，GPU/驱动和外部大模型下载缺失，不把默认跳过写成全自动安装。本轮未触发 SoulX 联网、安装、付费 API 或真实登录。

另外保留 HANDOVER 指出的技能自更新风险：只按 >10000 字节检验后以 ExecutionPolicy Bypass 运行 finish.ps1，缺可信内容校验；本轮无可执行的产品端到端环境，未改产品并重建，不能将此风险标为已修。旧 analysis 文件包含更早包指纹和已修问题，只作风险出处，当前事实以本报告和 report-data.json 为准。

## 直接复现与续跑

在能够访问 VMware、CurrentUser DPAPI、本地证据端口及所需服务控制的既有宿主执行会话中运行。当前沙箱会话的 vmrun/loopback 拒绝尚未解除；不申请提权，不更改系统安全设置，也不绕过门禁。先用以下命令确认通道；若仍失败，保持环境阻塞结论。

```powershell
cd F:\dsh工作区\MinglingWorkbench
& "E:\VMware\vmrun.exe" -T ws list
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Test-Channel.ps1 -Tier standard
```

按照 HANDOVER §8.2 的顺序，缓存成功后每条阶段命令会生成新 run-id：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\_seed-cache.ps1 `
  -HostFile "F:\dsh工作区\MinglingWorkbench\acceptance\cache\SnowLuma-v2.4.2-win-x64.zip" `
  -GuestPath "C:\Users\MWAcceptance\MWAcceptance\冥零 验收\工作区 3.1\logs\setup\dl\snowluma-SnowLuma-v2.4.2-win-x64.zip"
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases full -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases recovery -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases upgrade -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases final -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Test-NetworkCut.ps1 -RunId ("netcut-" + (Get-Date -Format yyyyMMdd-HHmmss))
```

阶段启动后看新 run 的 `phases/<phase>/progress.json` 与 `host/run.log` 的 step/command/elapsed/tail。失败仍先回收并验证证据；快照回滚前必须确认所有已有来宾证据已落盘。产品变更若需要重建，用 `$env:MSYS2_ARG_CONV_EXCL="*"; cmd /c "installer\build-installer.bat"`，再 Prepare-Stage，并对新指纹使用全新 run-id，不能复用本报告的 pass。

```powershell
python acceptance\v2\host\collect-findings.py <新run-id> --json <新路径.json> --md <新路径.md>
python acceptance\v2\host\report-data.py --run <新run-id> --out <新report-data路径.json>
python acceptance\evidence\report-20261110-074000\assemble-report.py --report <不存在的新报告路径.md>
```

报告聚合根：`acceptance/evidence/report-20261110-074000/`；机器结果、输入证据校验、源码/脚本快照及交付物扫描均在此。报告和新增 run 的最终封存与 zip SHA256 见聚合根 `delivery-validation.json` / `archives.json`。
