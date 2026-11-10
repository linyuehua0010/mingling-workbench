# 冥零工作台 V3.1.0 安装自动化验收续轮报告

生成时间（Asia/Shanghai）：2026-11-10T08:22:38+08:00

**结论：blocked-env，验收未闭环。** 本轮按顺序真实调用了缓存补传、full、recovery、upgrade、final、断网专项。六个入口均在宿主前置门禁停止，机器结果 exitCode=13、guestStarted=false。没有来宾阶段执行或新包端到端通过结论。

既有 `acceptance/report-next-v3.1.0.md` 已存在（07:49 续轮报告），按历史只读约束原样保留；本次报告新增时间戳文件。未修改产品、版本、夹具脚本；未重建，未回滚快照，未操作来宾目录或 NAT。

## 产物与源码

- 当前包：`dist/MinglingWorkbench-3.1.0-setup.exe`；88,855,864 B；文件版本 3.1.0.0；产品版本 V3.1.0；签名 **NotSigned**。
- SHA256：`ff9982cd9c45be477f49471a248b93cb7b8c1f28adeaae7b677716f336d809f8`。四次 Prepare-Stage 均 5/5 成功。
- Git HEAD：`37adb9fc8772921c24791337378a64c09b124257`；分支 `main`；未提交条目 85（porcelain，未跟踪目录折叠）。
- [report-data.json](evidence/report-20261110-082100/report-data.json) 由 report-data.py 实际采集，含产物、stage、Git 与运行脚本 SHA256；脚本只读快照在同目录 `script-snapshots/`。
- 沿用的 pre 包哈希和大小与当前包完全一致；本轮只读校验其根清单 82 个列出文件及清单自身 SHA256 全匹配，见 [input-manifest-validation.json](evidence/report-20261110-082100/input-manifest-validation.json)。未重跑 pre。

## 执行与分类计数

同指纹 pre 已覆盖 Windows 11 专业版 10.0.26100.1742（非 Insider）、MWAcceptance 标准用户（administratorToken=false）、NAT VMnet8、中文空格程序/工作区分离。本轮只覆盖宿主门禁，无法重新确认 VM 当前运行状态、来宾身份或网络。目标 VMX 为 `E:\Windows 11 x64\Windows 11 x64.vmx`。

| 入口 | 本轮独立 run-id | 实际结果 |
|---|---|---|
| seed | [seed-20261110-081840-31b8](evidence/seed-20261110-081840-31b8/run.json) | blocked-env / 13；vmrun 返回 -1：unable to start |
| full | [v310-20261110-081851-bdc2](evidence/v310-20261110-081851-bdc2/run.json) | blocked-env / 13；loopback socket：WinError 10013 |
| recovery | [v310-20261110-081912-be06](evidence/v310-20261110-081912-be06/run.json) | blocked-env / 13；loopback socket：WinError 10013 |
| upgrade | [v310-20261110-081920-39e8](evidence/v310-20261110-081920-39e8/run.json) | blocked-env / 13；loopback socket：WinError 10013 |
| final | [v310-20261110-081928-ba91](evidence/v310-20261110-081928-ba91/run.json) | blocked-env / 13；loopback socket：WinError 10013 |
| netcut | [netcut-20261110-081936](evidence/netcut-20261110-081936/run.json) | blocked-env / 13；vmrun 返回 -1：unable to start |

以上是直接观测到的错误，不据此推断 VMware 安装损坏或 VM 已停止。没有 progress.json、来宾命令或来宾上传回执，因为阶段未启动。各 run 保留宿主 stdout/stderr、脱敏 commands.jsonl（起止时间/超时/退出码/哈希）、results.jsonl、phase.json、run.json、清单及清单 SHA256。四阶段完整宿主日志另存为 `host/runall-complete.log`。

| 统计口径 | 产品失败 | 夹具失败 | 环境阻塞 | 人工待办 |
|---|---:|---:|---:|---:|
| 本轮 6 个宿主门禁结果 | 0 | 0 | 6 | 0 |
| 13 项整项结论 | 0 新动态证实 | 0 新动态证实 | 10 | 另列 4 |

13 项中：2 项整项已证（同指纹 pre）、1 项来源完整性部分已证/整体未覆盖、10 项环境阻塞。WebView2 缺失分支另计 not-run=1；QQ、B站、付费 API、SoulX/CUDA 人工待办=4。0 产品失败不代表产品无缺陷；宿主门禁也不能与 pre 的 13 pass / 1 not-run 混算为通过数。

每个 run 已用 collect-findings.py 聚合（[findings](evidence/report-20261110-082100/findings/)）。[summary.json](evidence/report-20261110-082100/summary.json) 给出机器计数；[criteria.json](evidence/report-20261110-082100/criteria.json) 给出 13 项要求—前置—步骤—断言—证据矩阵。

## 13 项结论

### 1. 组件结构、依赖图与状态模型 — pass

- 前置条件：当前包与 pre 的 stage 哈希一致；清单可读取。
- 实际步骤：pre 实际解析 21 组件，验证 schema、无悬空/无环、自动及人工状态模型。
- 断言与结论：4 个 c1 检查 pass；21 组件，0 图问题；这只覆盖该项定义的结构行为。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-manifest-schema.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-manifest-schema.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-dependency-dag.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-dependency-dag.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-source-hashes.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-source-hashes.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-state-model.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c1-state-model.json)

### 2. 来源完整性与篡改拒绝 — not-run

- 前置条件：下载/锁/树摘要的实际消费链；可运行安装通道。
- 实际步骤：已执行 pre 的 stage 5/5 校验与 uv 缓存篡改拒绝；本轮 full/recovery 被宿主门禁阻断。
- 断言与结论：部分已证：篡改缓存 exit 2 且拒绝安装；不能据此推定所有资产均强制校验。AstrBot package_sha256 未消费、npm integrity 未单独篡改、embedding 层未真实拉取/负向复验、SoulX 无闭环。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-stage-integrity.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-stage-integrity.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-source-real-chain.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-source-real-chain.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-tamper-reject.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c2-tamper-reject.json)；[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)；[analysis/integrity.md](analysis/integrity.md)；[analysis/soulx.md](analysis/soulx.md)

### 3. 干净普通用户安装 — pass

- 前置条件：pre 使用标准用户 MWAcceptance，清除专用测试安装基线。
- 实际步骤：真实安装器安装，检查身份令牌、Inno 模式、最终主程序版本。
- 断言与结论：administratorToken=false；Administrative install mode: No；最终 exe=3.1.0.0；不只依赖安装器 exit 0。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-normal-user-install.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-normal-user-install.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-exe-version.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-exe-version.json)

### 4. 中文空格路径、程序/工作区分离、启动与配置读取 — blocked-env

- 前置条件：分离程序/工作区；可真实启动并读取配置。
- 实际步骤：pre 已真实安装至中文空格目录并核对 WsPath；本轮 full/final 未进入来宾。
- 断言与结论：目录/分离部分 pass；同一当前实例的实际启动、配置读取全链尚未证明，整项不算通过。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-workspace-separate.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c3-program-workspace-separate.json)；[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c4-chinese-space-paths.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c4-chinese-space-paths.json)；[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)；[evidence/v310-20261110-081928-ba91/phases/final/](evidence/v310-20261110-081928-ba91/phases/final/)

### 5. 同一安装实例 Check 前后状态变化 — blocked-env

- 前置条件：同一实例在组件安装前后均可 Check；full 完成。
- 实际步骤：pre 真实记录安装前 exit=2、missing=11；full 未启动。
- 断言与结论：缺少安装后的有效状态；不能用两次相同 Check 替代状态翻转。HANDOVER 表中“已证”按原始 check 收紧为部分。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c5-check-before-components.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c5-check-before-components.json)；[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)

### 6. 第二次默认执行严格幂等 — blocked-env

- 前置条件：首次默认安装真正完成；后台自然写入可区分。
- 实际步骤：full 入口实际执行，宿主证据 socket 连接失败即停止。
- 断言与结论：未取文件集合/内容 SHA256/mtime 的前后对照，未排除 logs/state 绕过断言；未覆盖。
- 证据：[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)

### 7. 真实中断与合成半安装恢复 — blocked-env

- 前置条件：可观察真实安装阶段、可控进程树、有效联网与缓存基线。
- 实际步骤：recovery 入口实际执行，宿主门禁阻断。
- 断言与结论：未杀来宾进程；离线失败/联网恢复/不重装已完成组件、两条恢复路径均未覆盖。
- 证据：[evidence/v310-20261110-081912-be06/phases/recovery/](evidence/v310-20261110-081912-be06/phases/recovery/)

### 8. Offline 有效/空/坏缓存与真实断网 — blocked-env

- 前置条件：可访问来宾与 NAT；断网前真实可达；控制和取证通道可保留。
- 实际步骤：recovery 与 netcut 各自独立运行；后者 vmrun list 失败。
- 断言与结论：没有停 NAT；没有来宾不可达证明；三种缓存与当前包真实断网均未覆盖。旧 netcut-7127 不作为本包通过依据。
- 证据：[evidence/v310-20261110-081912-be06/phases/recovery/](evidence/v310-20261110-081912-be06/phases/recovery/)；[evidence/netcut-20261110-081936/phases/netcut/](evidence/netcut-20261110-081936/phases/netcut/)

### 9. AstrBot 真实初始化/进程/HTTP、八块 apply/verify — blocked-env

- 前置条件：默认组件安装成功；可连接真实 AstrBot 后台。
- 实际步骤：full 入口被宿主证据端口门禁阻断。
- 断言与结论：初始化标记、监听进程归属、HTTP、8 块配置落盘与回读均无本轮新结论；本地模型桩即使可用也仅证明协议，不能代表真实付费服务。
- 证据：[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)

### 10. 成功配置后的密钥泄漏扫描 — blocked-env

- 前置条件：成功配置的真实或明确标记测试凭据；程序/工作区/缓存/临时/验收全范围可读。
- 实际步骤：full/final 未启动；仅另做本轮宿主交付物敏感字符串检查。
- 断言与结论：产品扫描未覆盖；宿主交付物检查不能替代 c10。应记录 skip/unreadable，不能将无法读取视为无泄漏。
- 证据：[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)；[evidence/v310-20261110-081928-ba91/phases/final/](evidence/v310-20261110-081928-ba91/phases/final/)；[evidence/report-20261110-082100/host-delivery-secret-scan.json](evidence/report-20261110-082100/host-delivery-secret-scan.json)

### 11. QQ/B站/API Key 独立 manual — blocked-env

- 前置条件：无真实外部凭据仍须独立 manual；默认执行及点名父组件均需验证。
- 实际步骤：pre 仅验证 SnowLuma manual=1、detect exit=3；full 未启动。
- 断言与结论：该 pre 子项不能替代 QQ/B站/API Key 三项默认及父组件路径；真实登录与付费调用另列人工待办。
- 证据：[evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c11-pre-snowluma-manual.json](evidence/v310-20261110-000750-71cb/phases/pre/guest/checks/c11-pre-snowluma-manual.json)；[evidence/v310-20261110-081851-bdc2/phases/full/](evidence/v310-20261110-081851-bdc2/phases/full/)

### 12. 已发布 V3.0 三条升级路径 — blocked-env

- 前置条件：真实 V3.0 安装包；每条独立基线；可运行被占用旧 exe 及安装器。
- 实际步骤：upgrade 入口实际执行，未进入来宾。
- 断言与结论：自定义目录/默认目录/独立助手均未覆盖；原路径、完整备份含 unins、保护目录、最终替换及升级首次启动新增写入均无结论。
- 证据：[evidence/v310-20261110-081920-39e8/phases/upgrade/](evidence/v310-20261110-081920-39e8/phases/upgrade/)

### 13. 工作台/技能 bootstrap 绝对路径与 SHA256 一致 — blocked-env

- 前置条件：程序已安装；工作台子进程与技能包装均可实际运行。
- 实际步骤：final 入口实际执行，未启动来宾。
- 断言与结论：未抓实际子进程或技能输出；源码哈希记录不等于运行路径证明；未覆盖。
- 证据：[evidence/v310-20261110-081928-ba91/phases/final/](evidence/v310-20261110-081928-ba91/phases/final/)

## 外部依赖、剩余问题与人工入口

- **webview2-missing / not-run**：来宾已装 WebView2 122.0.2365.106；需要快照副本中的缺失基线。入口：在独立快照副本准备无 WebView2 基线后重跑 pre；本轮不卸载原基线。
- **qq-login / manual-pending**：真实 QQ 测试账号与本人扫码。入口：工作台 QQ 平台入口；由账号持有人完成登录。
- **bili-login / manual-pending**：真实 B站账号与本人扫码。入口：工作台 B站登录入口；由账号持有人操作。
- **paid-api / manual-pending**：有效、获授权且可计费的 API Key。入口：工作台模型配置入口；本机填写，不发进对话或验收日志。
- **soulx-cuda / manual-pending**：可用 NVIDIA GPU/驱动、CUDA torch 依赖锁、模型可信哈希及足够磁盘/网络。入口：powershell -NoProfile -ExecutionPolicy Bypass -File "<程序目录>\tools\setup-singing.ps1" -Base "<测试工作区>" -Root "<测试工作区>\sing" -Action check；实际部署通过工作台“部署本地唱歌”人工选择。

来源完整性限制沿用交接并按当前脚本复核：AstrBot package_sha256 尚未被 bootstrap 强制消费；npm integrity 未单独动态篡改验证；embedding-model 不在默认集，真实约 1.1GB 拉取、缺 blob/尺寸不符负向场景未执行；手工组件摘要不等于安装链实际强制校验。

SoulX：setup-singing.ps1 实际仍 git clone 默认分支；清单已有固定提交归档哈希未被该脚本消费；torch/torchaudio 2.7.1 cu128 未做逐包哈希锁；其他 pip 依赖未完全锁定；模型 resolve/main/model.pt 仅检查 2,818,092,278 B 门槛（清单探针为 2,800,000,000 B）。没有本轮联网安装、GPU/CUDA 或模型运行验证，不能把默认跳过记作全自动成功；现有可信锁未被扩展为虚构哈希。

技能自更新只按 >10000 字节检查后运行 finish.ps1，可信内容校验风险仍未修复。交接及既有 07:49 报告还记载历史 local-verify.json/临时 _seed 证据覆盖和已修 Capture 脱敏缺陷；本轮没有重现或修改那些历史文件。

本轮宿主交付物凭据扫描见 [host-delivery-secret-scan.json](evidence/report-20261110-082100/host-delivery-secret-scan.json)。它只检查新增交付文件是否包含 DPAPI 中三个口令，不替代成功配置后的来宾产品 c10 全范围扫描。

## 复现与续跑

需要可正常运行 vmrun、访问本地证据端口且读取当前用户 DPAPI 的既有宿主执行会话。当前会话尚不具备这两个通道条件。不请求提权、不改变系统安全设置、不绕过门禁。按 HANDOVER §8.2 原命令顺序执行；以下均自动生成新 run-id：

```powershell
cd F:\dsh工作区\MinglingWorkbench
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\_seed-cache.ps1 `
  -HostFile "F:\dsh工作区\MinglingWorkbench\acceptance\cache\SnowLuma-v2.4.2-win-x64.zip" `
  -GuestPath "C:\Users\MWAcceptance\MWAcceptance\冥零 验收\工作区 3.1\logs\setup\dl\snowluma-SnowLuma-v2.4.2-win-x64.zip"
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases full -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases recovery -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases upgrade -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases final -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Test-NetworkCut.ps1 -RunId ("netcut-" + (Get-Date -Format yyyyMMdd-HHmmss))
```

阶段启动后用新 run 的 `phases/<phase>/progress.json` 与宿主 `host/run.log` 看 step/command/elapsed/tail。产品失败保留现场后最小修复并重建：`$env:MSYS2_ARG_CONV_EXCL="*"; cmd /c "installer\build-installer.bat"`，再 Prepare-Stage；新包必须全新 run-id。快照回滚前先回收并校验证据。

```powershell
python acceptance\v2\host\collect-findings.py <run-id> --json <新文件.json> --md <新文件.md>
python acceptance\v2\host\report-data.py --run <run-id> --out <新report-data.json>
```

本轮封存校验：[delivery-validation.json](evidence/report-20261110-082100/delivery-validation.json)；各运行 ZIP 指纹：[archives.json](evidence/report-20261110-082100/archives.json)。聚合 ZIP SHA256 位于包外同名 `.sha256`，避免自引用。
