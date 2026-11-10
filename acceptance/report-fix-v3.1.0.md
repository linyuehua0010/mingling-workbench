# MinglingWorkbench V3.1.0 安装自动化修复与复验报告

日期：2026-11-09。本报告只记录实际执行结果。静态/单元结果不等于端到端通过；未完成的 VM 项明确标为“无法验证”。

## 1. 总结论

- 代码修复已实施，开发机静态与单元检查通过。
- 新安装包已构建：`dist\MinglingWorkbench-3.1.0-setup.exe`，88,869,111 字节，SHA256 `ab8443bb94678115bba720c8fa8012f48de067702a9043055056c0751d172fbf`。
- **原 13 项端到端验收未完成，不能判定通过。** 本次 VM 复验环境只有 1 项完整通过、4 项部分通过、1 项因夹具错误失败、7 项无法验证。主要阻塞是来宾控制台/命令执行不稳定和一次测试夹具 `/DIR` 引号拼接错误；没有把夹具问题改写成产品失败，也没有把静态检查当作安装成功。
- 已把测试 VM 回退到“快照 1”，未保留测试安装。

## 2. 缺陷、根因与修复

| 缺陷 | 根因 | 修复 |
|---|---|---|
| AstrBot `--help` 通过但 `run` 报根目录无效 | 只安装 CLI，未 `astrbot init`；没有验证 `.astrbot` 和真实后台 | 固定 AstrBot 4.29.4 + 全依赖哈希锁；安装后幂等 `init --yes`；启动真实 6185 后台；`verify-astrbot.ps1` 检查 `.astrbot`、固定 Python、监听进程所属根目录和 HTTP 响应 |
| bili-whale 半安装被判完成 | 完成判定只看 `package.json`，且恢复时 `copy_tree` 会覆盖和提前跳过 | 所有自动组件统一用 verify 判定；copy_tree 增加 only-if-missing；bili 验证 `require.resolve('qrcode')`；npm 返回 0 后仍用 Node 实际解析；离线无缓存明确失败 |
| QQ/B 站登录、API Key 被当成安装完成 | 安装状态和人工状态混在一起 | 新增独立 manual 组件 `qq-login`、`bili-login`、`deepseek-provider`；点名安装/检测父组件时自动带上依附的 manual 项；未登录不输出 `##OK` |
| 10 个 source 无 SHA256 | winget/uv/PyPI/Ollama 被当作免哈希例外 | 所有 21 个 source 均有 64 位 SHA256；WebView2/Python 改固定直链；AstrBot、edge-tts 用逐包哈希锁并内置无 wheel 的 aiocqhttp/jieba wheel；npm 用 package-lock；Ollama 模型固定 manifest/layer digest；纯人工项显式 `asset_count=0` + 空资产摘要 |
| V3.0 CLI 升级装到默认目录 | 新安装器没有收到老调用方的 `/DIR` | 安装器从调用进程/旧 updater 命令行恢复原 exe 路径，并从 settings.json 读工作区；V3.1 调用方也显式传 `/DIR` |
| V3.0 默认目录同步升级因自身 exe 被占用失败 | 安装器直接覆盖正在运行的主程序 | 安装器先落 `MinglingWorkbench.new.exe`；旧进程退出后由 `finish-update.ps1` 原子替换；被占用时异步完成，未被占用时同步等待 |
| 覆盖的 unins 无旧备份 | 升级只备份程序子目录和 exe | 安装器在 `ssInstall` 覆盖前备份所有旧程序文件（排除 bots/private/secrets/out/logs/旧版），写 `backup-manifest.json`；C++ 顶层备份也改为含 unins/README |
| 升级重启新增 secrets/README、logs/cache | 首次启动继续执行补目录/更新检查 | 安装器留一次性 `SuppressStartupWrites`；V3.1 首次启动消费标记，跳过 EnsureSecrets、工作区补目录、Skill 铺设和更新缓存写入 |
| 技能指向 `<工作区>\tools\bootstrap.ps1` | 程序目录与工作区分离后路径不存在 | 新增 `resolve-program-root.ps1` 和技能 `bootstrap.ps1` 包装入口；注册表 `ProgramRoot` 由安装器写入；文档改走包装入口 |
| Ollama 首次失败、随后只看 exe | 客户端和服务混在一个组件，detect/verify 不一致 | 拆分 `ollama`（固定客户端版本输出）与 `ollama-service`（`ollama list` 真实服务）；两者分别判定 |
| 重复运行新增日志、改 state.json | Emit 立即建日志，Save-State 无条件写 | 日志先缓冲；无变化且未指定 `-LogFile` 时不创建日志、不写 state；只有实际安装/失败/缺项才落盘 |

## 3. 修改文件

- 安装器/升级：`installer/mingling.iss`、`win32/src/her/her_selfupdate.cpp`、`win32/src/main.cpp`、`win32/src/paths.cpp`、`win32/src/core.h`、`win32/src/her/her_actions.cpp`
- 组件引擎：`tools/bootstrap.ps1`、`tools/components.json`、`tools/source-manifest.ps1`、`tools/start-astrbot.ps1`、`tools/verify-astrbot.ps1`、`tools/verify-manual.ps1`、`tools/backup-install.ps1`、`tools/finish-update.ps1`、`tools/start-ollama.ps1`、`tools/self-setup.ps1`、`tools/fetch-runtime.ps1`（仅 UTF-8 BOM，原有 PS5 解析错误）
- 锁定资产：`tools/astrbot-requirements.txt`、`tools/edge-tts-requirements.txt`、`pack/mingling-vendor/wheels/*`、`sidecar/bili-whale/package-lock.json`
- 来源清单：`tools/source-manifests/bili-whale.json`、`bili-bridge-plugin.json`、`dafeiyu-sing-plugin.json`
- 技能入口：`skill/mingling-install/SKILL.md`、`scripts/probe.ps1`、`scripts/bootstrap.ps1`、`scripts/resolve-program-root.ps1`
- 验收材料：`acceptance/local-verify.ps1`、`guest-acceptance.ps1`、`Store-VmSecrets.ps1`、`host-http.py`、`vm-type.py`、`evidence/local-verify.json`、`evidence/vm-upload/pre.json`

## 4. 13 项结果

| 项 | 结果 | 实际证据 |
|---|---|---|
| 1 | 通过（结构） | VM 原始 `pre.json`：21 组件、source 哈希格式错误 0；开发机独立结构/依赖图 0 错误。命令：`acceptance/local-verify.ps1`，证据 `acceptance/evidence/local-verify.json` |
| 2 | 部分通过 | 21/21 source 有 64 位 SHA256；真实 uv 在线下载退出 0，有效缓存 Offline 退出 0，首字节篡改/空缓存 Offline 均退出 2 且无 uv.exe。未逐一篡改所有下载包。证据 `pre.json` 的 `criterion-2-sources`、`criterion-2-tamper-offline` |
| 3 | 无法验证 | 安装器在来宾以 `administratorToken=false` 启动且退出 0，但测试夹具 `/DIR` 引号拼接错误，装到默认目录；不能证明“指定干净普通用户安装”完整通过。证据 `pre.json` 的 `criterion-3-install`、`diag.txt` |
| 4 | 失败（夹具） | 同一夹具错误使中文/空格 `/DIR` 未生效，程序目录不存在；这是验收代码问题，不据此判产品路径实现失败，也未改写成通过 |
| 5 | 无法验证 | 有 Check=2 的输出，但安装目录已被夹具错误和清理动作干扰，无法证明针对同一有效安装实例的前后对比。原始 `pre.json` 不足以作为该项通过证据 |
| 6 | 无法验证 | 完整组件首装未完成，没有可比较的第二次全跳过文件快照 |
| 7 | 无法验证 | 半安装恢复脚本已写，但 VM 阶段未执行；无真实 kill、离线失败、联网补 qrcode 的完整证据 |
| 8 | 部分通过 | 真实 uv 空缓存/有效缓存/坏缓存 Offline 行为符合设计；没有做真实断网，也没有完成全量组件的 Offline 分支。证据 `pre.json` |
| 9 | 无法验证 | 本次没有完成全量组件安装、真实 AstrBot 后台八块 apply/verify |
| 10 | 无法验证 | 未执行成功 provider 配置后的完整密钥扫描。代码已改为配置只存 `$MINGLING_DEEPSEEK_KEY`，Key 仅来自 secrets/进程环境 |
| 11 | 部分通过 | 实机 `-Component snowluma -Check` 显示独立 `manual=1`，未出现 `##OK qq-login`；安装后的默认 manual 数量和 B 站/API Key 未复验。证据 `pre.json` |
| 12 | 无法验证 | 三条 V3.0 升级路径未在本次 VM 执行；只完成升级备份/替换脚本的临时目录单元测试（通过，保护目录未备份、unins 已备份、主程序替换成功） |
| 13 | 部分通过 | 安装后技能包装入口解析到程序目录，`<工作区>\tools\bootstrap.ps1` 不存在；未观察到工作台真实子进程与技能脚本哈希一致。证据 `pre.json` 的 `criterion-13-entry-static` |

## 5. 剩余缺陷与未覆盖

1. **本次端到端验收未完成**：来宾控制台执行不稳定，后续全量安装、恢复、升级、八块、密钥扫描均未实际跑完；不得视为已修复验证。
2. **验收夹具缺陷**：`Invoke-Capture` 最初把 `/DIR=<含空格路径>` 整段加引号，Inno 安装到默认目录。已改为 `/DIR="路径"` 并重打包，但未完成修正后的整套 VM 复验。
3. **SoulX 唱歌仍有人工外部下载**：`setup_windows.ps1` 可下载模型/CUDA 依赖，上游未提供完整固定哈希；bootstrap 默认不自动装，但这是剩余未闭环项。
4. **真实断网**、WebView2 缺失分支、真实 QQ/B 站登录、真实模型 Key、旧版三条升级路径、真实后台八块成功路径均未覆盖。
5. **验收证据目录为空**：来宾脚本的部分 stdout/stderr 未回传；仅有阶段 JSON、安装器退出码和 uv 子用例。原始证据不足以补齐 13 项。
6. 安装包未做代码签名检查；VM 为 Windows 11 Insider 构建 `10.0.26300.9711`，与上轮 `26100` 不同。

## 6. 复现

```powershell
# 开发机静态/单元（不安装）
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\local-verify.ps1

# 重新生成安装包
cmd /c win32\build.bat
cmd /c installer\build-installer.bat
Get-FileHash dist\MinglingWorkbench-3.1.0-setup.exe -Algorithm SHA256
```

VM 脚本为 `acceptance\guest-acceptance.ps1`，阶段 `pre/full/recovery/upgrade/final`；本轮只有 `pre` 产生部分证据。若不修正来宾命令执行与夹具引号，重复运行不会得到可信的 13 项结论。

新安装包：`F:\dsh工作区\MinglingWorkbench\dist\MinglingWorkbench-3.1.0-setup.exe`
版本：V3.1.0（3.1.0.0）
SHA256：`ab8443bb94678115bba720c8fa8012f48de067702a9043055056c0751d172fbf`
