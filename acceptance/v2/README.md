# 冥零工作台 V3.1.0 验收通道 v2（可重复执行）

本目录是一套**可重复运行**的端到端验收通道：宿主侧调度 + 来宾侧阶段执行 + 证据回收。
它取代旧的 `acceptance/guest-acceptance.ps1`（旧文件保留为历史，不再用于新证据）。

## 前置条件

1. 宿主 Windows 10/11，PowerShell 5.1，Python 3（`python` 在 PATH）。
2. VMware Workstation 已安装：`E:\VMware\vmrun.exe`（可用 `-VmExe` 覆盖）。
3. 专用测试 VM：`E:\Windows 11 x64\Windows 11 x64.vmx`（可用 `-VmxPath` 覆盖），
   来宾 Windows 11 专业版 26100，VMware Tools 已装。
4. DPAPI 口令已导入（只读一次，值不落盘）：

   ```bat
   acceptance\Import-VmSecrets.ps1  :: 读取 acceptance\vm-secrets-input.txt 后删除明文
   acceptance\New-GuestStandardUser.ps1  :: 创建/校验非管理员 MWAcceptance，并把它存进 DPAPI
   ```

   存到 `%LOCALAPPDATA%\MinglingWorkbench\acceptance\`：
   `vm-password.dpapi`（VMX 加密口令）、`guest-password.dpapi`（管理员 冥零）、
   `std-user-password.dpapi`（MWAcceptance）、`guest-user.txt`、`std-user.txt`。

## 一条命令跑完整轮

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 `
  -Phases pre,full,recovery,upgrade,final -Tier standard -RevertSnapshot '快照 1'
```

- `-Tier standard`：用非管理员 `MWAcceptance` 安装（条件 3/4 必须这样跑）；`-Tier admin` 用 冥零。
- 默认从 `dist/` 与 `tools/` 重建 `acceptance/v2/stage` 并写 `checksums.json`；`-SkipPrepareStage` 才跳过。
- `-RevertSnapshot`：开跑前回到 `快照 1`（先回收证据，再回滚——见 `Run-Acceptance.ps1`）。
- `-SkipNetCut`：跳过真断网专项（默认会在主阶段之后单独跑一次）。
- 退出码：0 全通过；10 产品失败；11 夹具失败；12 前置条件缺失；13 环境阻塞；14 证据不完整。
  一次运行里有多类时取最严重者。

每次运行使用独立 run-id（`v310-<时间戳>-<4hex>`），证据写入
`acceptance/evidence/<run-id>/`，绝不复用或覆盖旧 run。

## 产物结构

```
acceptance/evidence/<run-id>/
  run.json                  运行总账（退出码、缺失项、阶段汇总）
  run-summary.json          Run-All 汇总（各阶段 counts、netcut、worstExit）
  phases/<phase>/
    phase.json              阶段结论 + counts + 每条 check 的 id/status/actual/detail
    results.jsonl           逐条结果（机器可读）
    commands.jsonl           逐条命令（开始/结束、脱敏命令、退出码、超时、stdout/stderr 路径与 SHA256）
    timeline.json           阶段时间线
    receipts.json           上传回执（HTTP 状态 + 对方 SHA256 + 字节数）
    done.json               来宾侧完成标记（阶段结束时一定写）
    guest/                  来宾落盘的证据文件（按文件逐个回收并校验 SHA256/字节）
    manifest.json           本阶段证据清单（每项 SHA256 + 字节）
    manifest.sha256         清单自身的 SHA256
  channel/channel.json      通道验收（T0–T6）
  netcut/netcut.json        真断网专项（宿主停 VMware NAT）
  evidence.zip              整轮证据打包（含 manifest）
```

## 分阶段单独跑

```powershell
# 只跑 pre（装 + 条件 1–5/11 的静态与安装面）
powershell -File acceptance\v2\Run-All.ps1 -Phases pre -Tier standard

# 只跑 recovery（真实中断恢复 + 半安装）
powershell -File acceptance\v2\Run-All.ps1 -Phases recovery -Tier standard -SkipNetCut

# 只跑 upgrade（V3.0 三条升级路径）
powershell -File acceptance\v2\Run-All.ps1 -Phases upgrade -Tier standard -SkipNetCut

# 只跑 final（bootstrap 绝对路径 + SHA256、技能包装入口、证据清单）
powershell -File acceptance\v2\Run-All.ps1 -Phases final -Tier standard -SkipNetCut
```

## 通道自检（不装产品）

```powershell
powershell -File acceptance\v2\host\Test-Channel.ps1 -Tier standard
```

T0 VMware Tools、T1 身份/令牌、T2 退出码、T3 中文空格路径读写、T4 超时与进程树清理、
T5 上传下载哈希、T6 来宾回传证据 HTTP 状态与 SHA256。

## 单项小实验

```powershell
# 安装冒烟（7 项：哈希、退出码、exe 存在/版本、非管理安装、程序/工作区分离、.new 被消费）
powershell -File acceptance\v2\host\Test-InstallSmoke.ps1 -Tier standard

# 真断网（宿主停 VMware NAT 服务，来宾证明外网不可达，正常模式必须失败）
powershell -File acceptance\v2\host\Test-NetworkCut.ps1 -RunId netcut-manual
```

## 说明

- 宿主用 `vmrun runProgramInGuest` 执行来宾 PowerShell；控制台键盘注入仅作兜底，不在链路里。
- 所有子进程参数按 exe / PowerShell / cmd 三类分别编码（`acceptance/lib/Capture.ps1`），
  空参数、中文、空格、尾部反斜杠都有自测（`acceptance/tests/test-capture.ps1`）。
- 所有生成的 `.ps1` 必须 **UTF-8 带 BOM**（PowerShell 5.1 否则按 ANSI 读中文），
  用 `acceptance/tools/Ensure-Utf8Bom.ps1` 修复。
- 长任务在 `phases/<phase>/progress.json` 暴露 `step` / `command` / `elapsedSeconds` / `tail`，
  宿主每 20 秒拉一次并写 `host/run.log`；来宾电源断开会被每 5 次轮询检测到并判 `fail-fixture`。

## 宿主环境门禁与缓存续跑（2026-11-10）

- 如果 `LOCALAPPDATA` 被重定向且其中没有凭据目录，通道会读取同一用户
  `%USERPROFILE%\AppData\Local\MinglingWorkbench\acceptance` 内既有 DPAPI 文件；不复制解密后的口令。
- `vmrun list` 不可用，或本地证据服务连接被系统拒绝时，记为 `blocked-env` / exit 13。
  `phases/<phase>/checks/` 是宿主门禁证据，`guestStarted=false`，不得当成来宾测试已执行。
  此时没有来宾 `progress.json`，因为阶段还没启动；看 `host/` 原始 stdout/stderr。
- 缓存补传仍可按 HANDOVER §8.2 调用 `host/_seed-cache.ps1`。该入口现使用独立 `seed-*`
  run-id，不再覆写旧 `_seed`；VMware 通道不可用时保留证据并退出 13。
- `collect-findings.py` 同时聚合宿主与来宾 checks；没有回收副本的来宾路径不声称宿主已核实。
  `report-data.py --run <run-id> --out <新路径>` 采集指纹及验收脚本哈希。
- 当前执行环境若报 `WinError 10013`，需要在可访问本地证据端口和 VMware 的既有宿主会话续跑。
  不通过放宽断言、跳过门禁、改变系统安全设置或申请提权绕过。
