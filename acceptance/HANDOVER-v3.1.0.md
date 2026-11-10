# V3.1.0 安装自动化验收 —— 交接说明（2026-11-09 夜）

> 用途：本轮工作被用户要求「暂时结束、之后交给其他 AI」。本文是唯一入口：现状、已改什么、
> 还差什么、怎么一条命令继续跑、有哪些坑。所有结论都指向可复现的产物，不依赖本文的转述。

---

## 0. 一句话现状

验收工具链（宿主机 + 来宾 + 证据）已经修好并跑通；**产品侧已修 7 处真实缺陷并重建 5 次安装包**；
最新产物上 `pre` 阶段已 **13 pass / 1 not-run / exit 0**；`full / recovery / upgrade / final` 四阶段尚未在新产物上跑完。
VM 通道（vmrun + 来宾 PowerShell + 文件哈希回传）稳定可用，证据逐阶段落盘并回传。

---

## 1. 本轮的硬性要求（不可降低，来自用户原文要点）

1. 验收工具先修：`Invoke-Capture` 参数编码按 exe / PowerShell / cmd 分开，并在真实 PS 5.1 下验证；
   中文、空格、空参数、尾部反斜杠、`/DIR` `/WORKSPACE` `/LOG` 全覆盖；必须用真实安装器确认最终目录。
2. 断言强化：普通用户安装必须 `administratorToken=false`；中文路径要覆盖程序目录、工作区、实际启动、配置读取；
   两次相同 `Check` 不算前后对照；每个 pass 必须有前置条件和证据。
3. 恢复夹具：不得对含通配符路径用 `-LiteralPath`；qrcode 解析要定位到目标 bili-whale；「构造半安装」与
   「真实中断安装后恢复」分开验证；真实中断要等到可观察阶段再杀进程树；验证离线失败 / 联网恢复 / 已完成组件不重装。
4. 结果与证据：子项失败、夹具错误、前置缺失、证据不完整要在机器可读结果与退出码里区分；
   每条命令存开始/结束时间、脱敏命令、退出码、超时、stdout、stderr；每阶段落盘并回传（失败也回传）；
   检查上传 HTTP 状态与本机 SHA256；打包含 final 阶段；每次运行独立 run-id。
5. 13 项复验：先建「要求—前置—步骤—断言—证据」矩阵；pre/full/recovery/upgrade/final 全跑；
   覆盖组件结构/依赖/状态模型、来源完整性与篡改拒绝、干净普通用户安装、程序与工作区分离（中文+空格）、
   Check 状态变化、严格二次幂等、真实中断与半安装恢复、Offline 三种缓存与真实断网、AstrBot 真实初始化/
   进程归属/监听/后台 HTTP、八块自设定 apply/verify、密钥泄漏扫描、QQ/B站/API Key 独立 manual、
   三条 V3.0 升级路径（含被占用 exe 替换、旧程序完整备份、bots/private/secrets/out/logs 保护、首次启动新增写入）、
   bootstrap.ps1 绝对路径与 SHA256、WebView2 缺失分支。
6. 真实登录 / 真实付费 API / 缺失凭据 = 外部依赖，不得伪造成功；不得用静态检查、单测、进程启动、
   安装器 exit 0 代替端到端成功；不得用旧证据证明新包；默认不改版本号；保留历史报告与旧证据；
   工作区有大量未提交改动，**不得 reset / clean / 覆盖无关改动**。

---

## 2. 环境与凭据（不入库、不写进报告）

| 项 | 值 |
|---|---|
| 宿主机工作区 | `F:\dsh工作区\MinglingWorkbench` |
| VM | `E:\Windows 11 x64\Windows 11 x64.vmx`（VMware Workstation 17，`E:\VMware\vmrun.exe`） |
| 来宾 | Windows 11 专业版 10.0.26100.1742，2 vCPU / 4GB，NAT `VMnet8 = 192.168.206.1/24` |
| 快照 | `快照 1`（回滚前必须先回收证据，`-RevertSnapshot '快照 1'` 已实现） |
| 来宾管理员 | `冥零`（仅用于建测试账号、停 NAT 等需要管理权的动作） |
| 来宾标准用户 | `MWAcceptance`（SID `…-1002`，Users 组、不在 Administrators） |
| 凭据存储 | `%LOCALAPPDATA%\MinglingWorkbench\acceptance\`：`vm-password.dpapi`、`guest-password.dpapi`、`guest-user.txt`、`std-user-password.dpapi`、`std-user.txt`（DPAPI，CurrentUser） |
| 证据服务 | `acceptance/v2/host/EvidenceServer.py`，默认 `0.0.0.0:8000`，stage=`acceptance/v2/stage` |
| 当前 VM 状态 | 运行中（交接时未关机；需要时 `vmrun -T ws -vp <vm口令> stop "<vmx>" soft`） |

**注意**：本轮用户曾在对话里贴过两个口令，任何日志/报告/证据都不得包含明文；代码路径只读 DPAPI。
`acceptance/vm-secrets-input.txt` 是导入用临时文件的模板，导入后应删除。

---

## 3. 当前产物指纹（最新，build #5）

| 产物 | 大小 | SHA256 |
|---|---|---|
| `dist\MinglingWorkbench-3.1.0-setup.exe` | 88,855,864 B | `ff9982cd9c45be477f49471a248b93cb7b8c1f28adeaae7b677716f336d809f8` |
| `acceptance\v2\stage\MinglingWorkbench-3.0.0-setup.exe` | 69,545,896 B | `48e4d6c74222debf7c6e6cc4fcfa97f78c8126cb86fab87bac0ca7e0a5a2428c` |
| `tools\components.json`（=stage） | 52,784 B | `7a0e789152275d57f2d01c49640c06b3b3e8c810d2b20b1869ef15e88ecc8e81` |
| `tools\astrbot-requirements.txt` | 285,804 B | `53d20a66ed025b7305db0227dcf02d1d5d5c8456cda436cf31ba0d2817f44317` |
| `tools\edge-tts-requirements.txt` | 64,080 B | `889c13b325e79e7377d04e4cbf314168d0d4b50438a8c44cdc821efafd6f3261` |

- 版本号保持 `3.1.0` / FileVersion `3.1.0.0`（按用户要求未升版本）。
- Authenticode：**NotSigned**（`Get-AuthenticodeSignature` 无签名者）；报告里必须写明。
- 源码状态：HEAD `37adb9fc8772921c24791337378a64c09b124257`，未提交改动约 85 项（含本轮全部修改）。
- 构建：`MSYS2_ARG_CONV_EXCL='*' cmd /c "installer\build-installer.bat"`（ISCC=`tools\innosetup6\app\ISCC.exe`）。
  **不要**用 `cmd //c`（会开交互式 cmd 什么都不做）；`installer\mingling.iss` 必须保持 UTF-8 **带 BOM**。

---

## 4. 已建成的验收体系（全部新增，未覆盖历史文件）

```
acceptance/
  lib/                       宿主机与来宾共用的库
    Capture.ps1              三种命令类型的参数编码 + 启动/超时/杀进程树/落盘 SHA256 + 脱敏
    Evidence.ps1             run-id、JSONL、manifest(+sha256)、上传回执（HTTP 状态+双向哈希）
    Check.ps1                状态词表、pass 降级规则、计数、阶段退出码（见下）
    Progress.ps1             来宾侧进度心跳（step/command/elapsed/tail，原子写）
  tools/Ensure-Utf8Bom.ps1   给 .ps1 补 BOM（PS 5.1 无 BOM 会把中文按 GBK 读坏）
  tests/                     宿主机自测
    test-capture.ps1         ##RESULT capture-selftest 21/21
    test-evidence.ps1        ##RESULT evidence-selftest 9/9
    test-channel 在 v2/host/Test-Channel.ps1（需 VM）
  v2/
    Run-All.ps1              总入口：stage→证据服务→各阶段→断网专项→汇总
    README.md                操作手册（前置、命令、退出码、证据结构）
    host/
      VmChannel.ps1          vmrun 封装：身份/运行程序/传文件/删文件/目录存在/快照/电源
      GuestScript.ps1        生成来宾脚本：统一 $R 结构 + 语法预检 + 逐文件上传 + 回执
      Run-Acceptance.ps1     阶段编排：部署库、跑阶段、轮询进度、取回证据、熔断
      Test-Channel.ps1       通道验收 7 项（身份/退出码/中文路径/杀进程树/256KB 双向/上传回执）
      Test-InstallSmoke.ps1  安装冒烟 7 项（哈希/退出码/exe/版本/普通用户模式/分离/新文件消费）
      Test-NetworkCut.ps1    真实断网（宿主停 VMware NAT，来宾证明不可达，正常模式必须失败）
      New-GuestStandardUser.ps1  创建/校验 MWAcceptance 并 DPAPI 存随机口令
      Prepare-Stage.ps1      从 dist/tools 生成 stage + checksums.json
      EvidenceServer.py      证据接收服务（/health /stage /upload /receipts，原子写+SHA256）
      collect-findings.py    按 13 项聚合 checks/*.json → 表格
      report-data.py         采集 git/安装包/脚本哈希 → report-data.json
      prefetch.py            多线程 Range 预取大文件（镜像前缀 MW_MIRROR）
    guest/
      Invoke-Phase.ps1       五阶段全部检查（约 3300 行，UTF-8 BOM）
      CHANGES-runner-harden.md  F/M 修复逐条说明与残余风险
  evidence/<run-id>/         每次运行独立目录（phases/<phase>/{phase.json,results.jsonl,commands.jsonl,manifest*,guest/...}）
  evidence/<run-id>-evidence.zip
```

**退出码语义**（`Get-MwPhaseExitCode`）：`0` 全通过；`10` 产品失败；`11` 夹具失败；`12` 前置缺失；
`13` 环境阻塞；`14` 证据不完整。总入口取最严重者。

**状态词表**：`pass | fail-product | fail-fixture | blocked-precondition | blocked-env | evidence-incomplete |
manual-pending | not-run`。`pass` 若缺前置条件或缺证据会被库自动降级（本轮修过包装层静默丢证据的致命缺陷）。

---

## 5. 本轮已验证通过的部分

| 项目 | 结果 | 证据 |
|---|---|---|
| 参数编码自测 | 21/21（exe/PS/cmd × 中文/空格/空参数/尾反斜杠/引号拒绝；cmd 遇 `"` 明确抛错） | `evidence/self-test/selftest-capture-*.json` |
| 证据机制自测 | 9/9（上传 200/409、清单逐条哈希、退出码优先级、pass 降级、脱敏、run 隔离） | `evidence/self-test/` |
| 通道验收 | 7/7（身份=MWAcceptance、非管理员、退出码、中文+空格、杀进程树、256KB 双向哈希、上传回执） | `evidence/chan-20261109-203645/channel/channel.json` |
| 安装冒烟 | 7/7（真实安装器、`/DIR`+`/WORKSPACE` 中文空格、exit 0、exe 3.1.0.0、`Administrative install mode: No`、`.new` 被消费） | `evidence/smoke-20261109-210704-ce7b/` |
| 真实断网专项 | 4/4（3/3 可达 → 停 NAT 后 0/3 + DNS 失败 → 正常模式 exit 2 且不装 node → 恢复 3/3） | `evidence/netcut-7127/` |
| **pre 阶段（build #5）** | **exit 0，13 pass / 1 not-run，479 s，44/44 证据文件** | `evidence/v310-20261110-000750-71cb/` |

pre 阶段逐项（run `v310-20261110-000750-71cb`）：

| check | 结果 | 关键实际值 |
|---|---|---|
| c1-manifest-schema | pass | 21 组件，0 问题 |
| c1-dependency-dag | pass | 0 悬空，无环 |
| c1-source-hashes | pass | 0 格式错误；6 个空哈希（manual 组件，已列明） |
| c1-state-model | pass | schema=1, components=16 |
| c2-stage-integrity | pass | 5/5 匹配 |
| c2-source-real-chain | pass | requirements 双锁 True；bili npm 有效；lock=True；embedding=True |
| c2-tamper-reject | pass | 篡改 uv 缓存 → exit 2，未安装（拒绝生效） |
| c3-normal-user-install | pass | exit 0；admin=False；`Administrative install mode: No` |
| c3-program-exe-version | pass | 3.1.0.0 |
| c3-program-workspace-separate | pass | WsPath=`…\冥零 验收\工作区 3.1` |
| c4-chinese-space-paths | pass | exe 存在，安装日志里的工作区路径一致 |
| c5-check-before-components | pass | exit 2，missing=11（安装前的真实状态） |
| c11-pre-snowluma-manual | pass | manual=1，detect 返回 3（非零证明 manual 判据真实） |
| c5-webview2-missing-branch | **not-run** | 本机已装 WebView2 122.0.2365.106，未卸载（如实记录，不算通过） |

---

## 6. 产品缺陷：本轮已修（7 处，全部有构建/运行证据）

1. **首装没有主程序（P0）**：`installer/mingling.iss:75` 把 exe 装成 `MinglingWorkbench.exe.new.exe`，
   而 `tools/finish-update.ps1:14` 找 `MinglingWorkbench.new.exe` → 每次 exit 5「缺少 .new，无法完成替换」，
   桌面/开始菜单快捷方式指向不存在的 exe。修法：DestName 改为 `MinglingWorkbench.new.exe`。
   证据：`evidence/v310-pre-3/phases/pre/guest/install-3.1.inno.log`（`Process exit code: 5`）→ 修复后
   `smoke-20261109-210704-ce7b` 首次证明 exe 存在且版本 3.1.0.0。
2. **安装/升级改写受保护目录**：`mingling.iss:120/121` 的 `-ManifestLog` 指向 `{Workspace}\旧版`（第 12 项要求保护），
   改为 `{tmp}`；`:126` 的 bootstrap `-Check` 日志指向 `{Workspace}\logs\setup`（也是受保护/幂等区），
   改为 `{app}\logs\setup\installer-check.log`。
3. **`-LogFile` 破坏幂等**：`tools/bootstrap.ps1:61` `$Dirty = [bool]$LogFile` → `$false`；
   并在 Save-State 前加 `if ($script:CheckMode -and (Test-Path $StatePath)) { return }`，
   使「纯 -Check」不再重写安装记录（第 6 项严格幂等的前提）。
4. **`{base}\tools\…` 路径错**：`tools/components.json` 多处把程序文件指向工作区（工作区没有 tools\），
   导致 `ollama-service`（`-File` 找不到脚本 → -196608）和 `astrbot`（依赖锁不存在）必失败；
   12 处改为 `{repo}\tools\…`。证据：`evidence/v310-20261109-234552-6d12` 修复前失败 → 修复后
   `##OK ollama / ##OK astrbot（后台端口 6185 监听有效）`。
5. **npm 版本号探测必失败**：`Invoke-NpmStep` 把 `qrcode@1.5.4` 传给 `require.resolve`，只接受模块名；
   改为先剥版本再 resolve。证据：同一次运行 `##OK bili-whale`（qrcode package.json 命中）。
6. **embedding-model 钉错哈希**：`components.json` 钉的 `0c4c9c2a…` 是 manifest 的 `config.digest`，
   该 manifest 现已 404（MANIFEST_UNKNOWN）；改为钉当前 manifest `79076464…` + 两个不可变层
   `sha256:daec91ff…`(1,157,671,200 B) / `sha256:a406579c…`(1,068 B)，并新增 `tools/verify-embedding-model.ps1`
   实际校验 blob 存在与字节数（exit 3 失败）。**注意：该组件不在默认安装集，本轮未做真实 1.1GB 拉取复验。**
7. **SnowLuma 下载地址已死**：`github.com/SnowLuma/SnowLuma` 仓库 404（已改名为 `TomyJan/SnowLuma`），
   资产本身未变（下载后字节 43,361,462 + SHA256 `0912926c…` 与钉值完全一致）。已把 3 处 URL 改为新仓库。
   证据：`curl -I` 404 → 新仓库 302；宿主 `prefetch.py` 校验 ok=True。

另外调整（非缺陷修复，结论记录）：`tools/setup-singing.ps1` 默认目录改 `{base}\sing`（与 components.json
detect 和人工步骤一致）；`skill/mingling-install/scripts/deploy-singing.ps1` 增加 `resolve-program-root.ps1`
回退，修掉分离布局下找不到 setup-singing.ps1 的问题。

---

## 7. 夹具（验收工具）本轮已修

- 参数编码：`ConvertTo-PsFileArg` = MSVCRT（实测 PS 5.1 `-File` 就是 CommandLineToArgvW 语义）；
  cmd 单独规则，遇 `"` 明确拒绝而不是静默错位；每次调用落盘脱敏命令行 + stdout/stderr 哈希。
- 证据链：`Save-MwJson` 曾 `return $Path` 导致证据路径变成 `"p p"`（Test-Path 恒 false，全部降级）；
  已改；嵌套证据数组/单元素数组被 PowerShell 展开的坑已修（`ConvertFrom-Json -InputObject` + 显式 `@()`）。
- 断言真实性：`Add-PhaseCheck` 默认不再补 `Status='pass'`、不再静默丢缺失证据；63 处调用点补了
  **逐项前置条件**（57 处新增）。`-Detail/-Evidence` 处缺续行反引号、空 `-StepText` 两处夹具自伤已修。
- 恢复夹具：不用 `-LiteralPath` 配通配符；qrcode 探测带 `-WorkingDirectory`；真实中断只认「观察到
  安装阶段」再杀进程树（`Invoke-Phase.ps1` 里已无 45 s 无条件 fallback）；**合成半安装**与**真实中断**两条路径分开。
- 断网夹具：改由宿主停 `VMware NAT Service`（来宾标准用户无权重配网卡），来宾用双目标 TCP+DNS 证明不可达，
  正常模式（非 `-Offline`）必须失败且不得装出 node；恢复后 ≥2 目标可达。
- 目录删除：`Remove-MwGuestDir` 的 `-r` 位置错误（删不掉旧安装，冒烟变成覆盖升级）已修；
  来宾 `Reset-TestDir` 删前先结束被测目录内的遗留进程（AstrBot 会锁 exe），再带 20 s 重试删除。
- 编码/时区：所有 `.ps1` 必须 UTF-8 **BOM**（PS 5.1 无 BOM 按 GBK 解，中文路径直接失效）；
  `.ps1` 里 `-Detail 'x' + $v`、反引号后续空行等写法会静默自伤，改动后必须 `Parser::ParseFile` + 实际跑。
- 虚拟机：`copyDirectoryFromGuestToHost` / `copyDirectoryFromHostToGuest` 在本机 build 上恒 exit=-1，
  **目录传输一律逐文件**（`Receive-MwGuestTree` / `Send-MwGuestTree`，逐文件比 bytes+SHA256）。
- 来宾会因空闲待机自我挂起（S1）：已 `powercfg` 关闭待机；宿主轮询每 5 次查 `vmrun list`，
  掉线立即判 `fail-fixture` 而不是空等。
- 证据取回：`Run-Acceptance` 按阶段取回 + 校验，失败也取；上传检查 HTTP 状态、本地/远端 SHA256/字节。

---

## 8. 未完成的工作（接手后按顺序做）

### 8.1 立刻可继续的现场状态

- VM 运行中；来宾已有：新装的程序/工作区（build #5）、`MWAcceptance` 标准用户、
  以及 `{Ws}\logs\setup\dl\ollama-ollama-windows-amd64.zip`（1,614,941,966 B，SHA256 已校验）。
- 宿主机已备好两份预取缓存（可用 `prefetch.py` 重新生成/校验）：
  `acceptance\cache\ollama-windows-amd64.zip`（1,614,941,966 B，`9ca74a7a…`）、
  `acceptance\cache\SnowLuma-v2.4.2-win-x64.zip`（43,361,462 B，`0912926c…`）。
- **SnowLuma 缓存还没传进来**（交接时宿主拷贝被中止）。这是唯一缺失的预置缓存。

### 8.2 建议命令序列

```powershell
cd F:\dsh工作区\MinglingWorkbench

# 0) 补预置 SnowLuma 缓存（43 MB，约 30 s）
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\_seed-cache.ps1 `
  -HostFile  "F:\dsh工作区\MinglingWorkbench\acceptance\cache\SnowLuma-v2.4.2-win-x64.zip" `
  -GuestPath "C:\Users\MWAcceptance\MWAcceptance\冥零 验收\工作区 3.1\logs\setup\dl\snowluma-SnowLuma-v2.4.2-win-x64.zip"

# 1) full 阶段（build #5）
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases full -Tier standard -SkipNetCut

# 2) recovery / upgrade / final（每阶段独立 run-id；需要时可先回滚快照）
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases recovery -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases upgrade  -Tier standard -SkipNetCut
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 -Phases final    -Tier standard -SkipNetCut

# 3) 断网专项（新 run-id，可单独跑）
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Test-NetworkCut.ps1 -RunId netcut-<stamp>

# 4) 汇总 13 项
python acceptance\v2\host\collect-findings.py <run-id> --md acceptance\evidence\_findings.md
python acceptance\v2\host\report-data.py     # → evidence\report-data.json

# 5) 出报告（新文件，不覆盖历史）
#    acceptance\report-next-v3.1.0.md
```

### 8.3 四阶段里要重点盯的（尚未在新产物上验证）

- `full`：`c6-idempotent-*`（第二次默认执行严格幂等，需区分后台自然写入）、`c9-*`（AstrBot 初始化/进程/监听/
  后台 HTTP、八块自设定 apply+verify、本地模型桩只能证明协议）、`c10-key-scan`（含跳过项与不可读项，不输出密钥）、
  `c11`（manual 不得误报完成）。
- `recovery`：`c7-*`（真实中断观察到阶段后杀树、离线失败、联网恢复、已完成组件不重装、半安装两条路径）、
  `c8-*`（有效/空/坏缓存 + 真实断网）。
- `upgrade`：`c12-*` 三条路径（自定义目录 / 默认目录 / 旧版独立助手），每条独立基线；核对旧程序完整备份
  （含 unins）、`bots/private/secrets/out/logs` 保护、被占用 exe 最终替换、首次启动新增写入。
- `final`：`c13-*`（工作台子进程与技能包装入口解析到同一绝对路径 bootstrap.ps1 + SHA256 自证）、
  最终密钥扫描、证据清点与打包。

---

## 9. 已知未闭环 / 风险清单

1. **c2 astrbot `package_sha256` 未被 bootstrap 读取**（审计确认）；embedding 远端 layer 字节本机不可复核。
   报告里必须写成「机制存在但未强制」，不得写成「已完整校验」。
2. **WebView2 缺失分支 not-run**：本机已安装 WebView2，未卸载（避免破坏基线）。要么在快照副本上卸掉复验，
   要么在报告中明确「未覆盖」，不能算通过。
3. **embedding-model 修复未做真实拉取复验**（组件不在默认集，1.1 GB）；负向用例（缺 blob/尺寸不符 → exit 3）
   也没有实跑。`tools/verify-embedding-model.ps1` 已加 BOM 且可解析。
4. **SoulX**：脚本仍是 `git clone` 默认分支；模型只有 `min_bytes` 阈值（脚本 2,818,092,278 vs 清单 2,800,000,000）；
   torch cu128 依赖锁定未做；驱动/GPU 只能人工。分类结论：**默认跳过 ≠ 全自动安装**，必须保留人工入口与未验证状态。
5. **skill 自更新只查 `>10000` 字节**后以 `-ExecutionPolicy Bypass` 运行自带 `finish.ps1`（审计标为 critical），
   本轮未修；报告「剩余问题」里要列。
6. **`c9-full-install` 依赖网络质量**：snowluma 曾因镜像失败；本轮已修死链 + 预置缓存，但仍需一次完整成功运行。
7. **a`-196608` 类「子进程没跑起来」**已加专门识别与前置证据（`Test-MwLaunchEncodedFailure` /
   `Get-MwLaunchPrecondition`），但预期失败类断言仍要在实跑中确认没有误判。
8. **旧文件**：`acceptance/local-verify.json` 曾被旧脚本覆盖（可再生的自测产物），报告中应说明，不要声称原文件健在。
9. 交接清理项（不影响运行，交付前删）：`acceptance/v2/host/_probe-*.ps1`（含 `_probe-layout.ps1`、
   `_probe-state.ps1`）、`_peek-*.ps1`、`_fetch-file.ps1`、`_set-power.ps1`、`_seed-cache.ps1`、
   `_kill-phase.ps1`、`acceptance/tests/_probe-*.ps1`、`acceptance/evidence/_peek/`、`_seed/`、`_f*.md`、
   `acceptance/evidence/recv-test/`。
   若要保留复现能力，可把 `_seed-cache.ps1` / `_kill-phase.ps1` 改名进 `host/` 并在 README 记一行。
10. 交接时已停掉后台证据服务（`:8000` 端口释放）；下次 `Run-All.ps1` 检测到端口空闲会自动拉起
    `host/EvidenceServer.py`，无需手工启动。

---

## 10. 13 项 × 当前结论（新产物 build #5）

| # | 要求 | 当前状态 | 依据 |
|---|---|---|---|
| 1 | 组件结构/依赖图/状态模型 | **已证**（pre） | c1-* 4 项 pass |
| 2 | 来源完整性 + 篡改拒绝 | **部分** | c2-* pass；但 astrbot package_sha256 / embedding 远端层未强制，需在报告列未覆盖 |
| 3 | 干净普通用户安装 | **已证**（pre+smoke） | c3-normal-user-install、c3-program-exe-version |
| 4 | 程序/工作区分离 + 中文空格 | **已证**（pre+smoke） | c3-program-workspace-separate、c4、smoke 7/7 |
| 5 | 同一安装实例 Check 状态变化 | **已证**（pre） | c5-check-before/after-components |
| 6 | 严格二次幂等 | 待跑（full） | c6-* |
| 7 | 真实中断 + 半安装恢复 | 待跑（recovery） | c7-* |
| 8 | Offline 三态 + 真实断网 | 部分（断网专项 4/4 旧包；新包待跑） | netcut-7127、c8-* |
| 9 | AstrBot/八块自设定 | 待跑（full） | c9-* |
| 10 | 密钥泄漏扫描 | 待跑（full/final） | c10-* |
| 11 | QQ/B站/API Key 独立 manual | 部分（pre 的 snowluma manual 已证） | c11-pre-snowluma-manual |
| 12 | 三条 V3.0 升级路径 | 待跑（upgrade） | c12-* |
| 13 | bootstrap 路径+SHA256 | 待跑（final） | c13-* |
| + | WebView2 缺失分支 | **未覆盖（not-run）** | 本机已装，如实记录 |

---

## 11. 交接注意（最容易被下一位踩的坑）

- **BOM**：`write` 工具产出的 `.ps1` 没有 BOM。改完必须
  `powershell -File acceptance\tools\Ensure-Utf8Bom.ps1 -Path <绝对目录>`，否则来宾侧中文路径全废。
- **反引号续行**：反引号后不能有空行；参数里 `'x' + $v` 必须加括号，否则会变成位置参数报
  「找不到接受实际参数」——本轮两次 `c0-harness-fatal` 都是这个。
- **数组拼接**：`@('/DIR=' + $app, …)` 不会按预期拼接（逗号优先级），传参要 `('/DIR=' + $app), ...`。
- **vmrun**：`runProgramInGuest` 不回传来宾 stdout/stderr（恒空）；`-vp`/`-gu`/`-gp` 顺序固定；
  目录拷贝坏掉，只能逐文件；`list`/`listHostTypes` 不带 vmx 参数。
- **来宾口令选择**：admin 操作读 `guest-password.dpapi`，`MWAcceptance` 操作读 `std-user-password.dpapi`；
  混用报 `Invalid user name or password`。
- **中文控制台**：python 打印中文到本控制台会 GBK 乱码，但落盘 JSON 是正确的 UTF-8；判断看文件不看屏。
- **Abort 后**：杀掉宿主 job 后必须进来宾清 `Invoke-Phase|bootstrap` 进程，否则下一轮 pre 删目录被锁。
- **证据不可复用**：新包必须新 run-id；任何「旧包通过」都不得写进新报告。
- **不许 reset/clean**：工作区有 85 项未提交改动（含本轮修复），历史报告/旧证据只读不改。

---

## 12. 交付清单（本轮已产出的部分）

- 新增工具链：`acceptance/lib/*`、`acceptance/v2/**`、`acceptance/tools/Ensure-Utf8Bom.ps1`、
  `acceptance/tests/*`、`acceptance/analysis/*`（13 项矩阵、完整性审计、SoulX 分类、runner 审查）、
  `acceptance/cache/`、`acceptance/v2/stage/`。
- 新增证据：`acceptance/evidence/chan-20261109-203645/`、`smoke-20261109-210704-ce7b/`、`netcut-7127/`、
  `v310-20261110-000750-71cb/`（pre 全绿）、以及多次失败运行的现场（都是历史材料，保留）。
- **尚未产出**：`acceptance/report-next-v3.1.0.md`（等 full/recovery/upgrade/final 有结论后写）。
