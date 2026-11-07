# 验收记录

记录时间：2026-11-05（Asia/Shanghai）。所有命令都在 `D:\MinglingWorkbench` 实跑，
输出是原文摘录，不是事后补写。

## 1. 构建

```bat
taskkill /IM MinglingWorkbench.exe /F
build.bat
```

结果：

```
OK: D:\MinglingWorkbench\win32\..\bin\MinglingWorkbench.exe
```

（构建器是 MinGW-w64 g++ 静态链接；工作台运行时不需要 MinGW。）

## 2. 无 DSH 的隔离环境自检

伪造一个没有 `.dsh` 的用户目录，只保留 B 站凭据，然后跑命令行自检：

```powershell
$env:USERPROFILE = "D:\MinglingWorkbench\tmp\fakehome"   # 没有 .dsh
$env:APPDATA     = "D:\MinglingWorkbench\tmp\fakeapp"
MinglingWorkbench.exe --paths
```

`--paths` 关键行：

```
工作区     D:\MinglingWorkbench
机器人根   D:\
状态目录   ...\tmp\fakeapp\MinglingWorkbench
sidecar    D:\MinglingWorkbench\sidecar\bili-whale
node       D:\MinglingWorkbench\sidecar\node\node.exe
ffmpeg     D:\MinglingWorkbench\sidecar\bili-whale\bin\ffmpeg.exe
配置       ...\MinglingWorkbench\bili-whale.config.json
凭据       ...\fakehome\.bili-ai\credentials.json（存在）
日记       ...\bili-state\whale-diary.md
台账       D:\MinglingWorkbench\logs\jobs.jsonl
```

`--feed`：退出码 0，耗时 5.2s，输出包含「（读不到日记，用默认偏好）」、
「候选池: 120 条 → 85 条」以及 6 条选题。没有读取 `~/.dsh`。

`--watch BV1FZ4t6HEy7`：退出码 0，耗时 16.5s。

产物（只在这里）：

```
out\BV1FZ4t6HEy7\cover.jpg
out\BV1FZ4t6HEy7\BV1FZ4t6HEy7-2026-...-3x3.jpg
out\BV1FZ4t6HEy7\BV1FZ4t6HEy7-2026-...-subs.jpg
out\BV1FZ4t6HEy7\BV1FZ4t6HEy7-2026-....mp4
out\BV1FZ4t6HEy7\BV1FZ4t6HEy7-debrief.txt
tmp\    没有 .frames-* 残留
```

台账新增一行：

```json
{"t":1793881457,"bv":"BV1FZ4t6HEy7","title":"...","up":"...","source":"console","chat":"工作台","status":"ok","sink":"D:\\MinglingWorkbench\\logs\\jobs\\BV1FZ4t6HEy7-1793881457.txt","seconds":"16s"}
```

## 3. 界面截图

截图都在 `docs\screens\`，取自一次隔离安装（`tmp\itest3`，用户目录里没有 `.dsh`，
只带 B 站凭据），窗口 1480×1010，`SetProcessDPIAware` 后整窗抓取：

| 文件 | 内容 |
| --- | --- |
| `overview.png` | 总览：三张服务卡（SnowLuma / AstrBot / bili-whale）、今日任务、最近任务、快捷动作、凭证状态 |
| `bili-feed.png` | B 站页：左栏「今晚看什么」8 条选题（标题 / UP / BV / 时长），右栏输入框、「让她看」、底部当前工作区与「换工作区」 |
| `bili-result.png` | 看完一条之后：封面、九宫格入口、「打开文件夹 / 复制全文」、结果正文（元信息、分节） |
| `jobs.png` | 队列：2 条任务（来源「本机」、状态「完成」）+ 任务详情（`console · ok · 29s` 与正文摘录） |
| `maint.png` | 维护：八张卡、四个频率开关、两排一键动作（第二排有「打开工作区」，没有桌宠相关项） |
| `check.png` | 体检·自检：`» bili-whale selftest（退出码 0）`，配置 / 凭据 / 登录态 / 目录 / 依赖全绿，末尾是「B 站能力已经内置在工作台里，不用装 DSH」 |
| `help.png` | 帮助：FAQ（怎么聊、不回话、被踢、花费、开机、游戏模式、掉线提醒、B 站、换电脑、关窗、快捷键、关于） |

> 本机的 `GamePP.exe` 会往 GUI 进程注入 `GPP64.dll`，注入失败时程序会在启动
> 10–30 秒内 `0xC0000005` 退出（换任何页签都一样，不点也崩）。截图是在
> `taskkill /IM GamePP.exe /F` 之后抓的；干净机器没有这个 DLL。

## 4. 安装包

产物：`dist\MinglingWorkbench-2.0.0-setup.exe`（Inno Setup 6.0.5 编译，
`installer\mingling.iss`，`installer\build-installer.bat` 一键重打）。

在一份没有 DSH 的隔离用户目录里（`USERPROFILE=tmp\itest5\home`、
`LOCALAPPDATA=tmp\itest5\localappdata`，`.dsh` 不存在，只复制了 `.bili-ai` 凭据）：

```text
install rc 0
exe True   unins000.exe True
settings.json = {"workspace": "D:/MinglingWorkbench/tmp/itest5/ws", "base": "D:/MinglingWorkbench/tmp/itest5"}
sidecar/node/node.exe 的 SHA256 与源文件一致（ba4e6d11...）
```

装完直接跑（同一隔离环境）：

| 命令 | 退出码 | 关键输出 |
| --- | --- | --- |
| `--paths` | 0 | 工作区 `…\itest5\ws`；sidecar / node / ffmpeg 都在安装目录；台账 `…\ws\logs\jobs.jsonl` |
| `--feed` | 0 | 「（读不到日记，用默认偏好）」「候选池: 120 条 → 85 条」+ 6 条选题（8–13s） |
| `--watch BV1FZ4t6HEy7` | 0 | 17.4s，产物只在 `ws\out\BV1FZ4t6HEy7\`，`tmp` 为空，台账一行 `status:"ok"`、`source:"console"`、`seconds:"18s"` |

开始菜单快捷方式（真实用户目录下另装一遍验证）：

```text
C:\Users\…\Start Menu\Programs\冥零工作台\冥零工作台.lnk
C:\Users\…\Start Menu\Programs\冥零工作台\B 站部署教程.lnk
C:\Users\…\Start Menu\Programs\冥零工作台\QQ 机器人部署教程.lnk
C:\Users\…\Start Menu\Programs\冥零工作台\卸载 冥零工作台.lnk
```

桌面快捷方式随安装器可选任务（`desktopicon`）创建。

卸载（隔离环境实跑）：

```text
uninstall rc 0
after: appdir exists False   exe exists False
after: ws files 6            jobs.jsonl True   out ['BV1FZ4t6HEy7']
start menu after: []          （四个快捷方式都被清掉）
```

卸载只删程序目录，工作区里的 `out\`、`tmp\`、`logs\`（含 `jobs.jsonl`）保留；
`CurUninstallStepChanged` 还会读 `settings.json` 里的工作区路径并弹窗告知。

补充：同一份安装包装到本机默认位置 `C:\Users\…\AppData\Local\Programs\MinglingWorkbench`
时，卸载器在 `taskkill` 之后仍返回 1、程序目录没有被删；装到 `F:\…\tmp\` 下的隔离目录时
卸载器返回 0、目录被清空。两者用的是同一份 `unins000.exe`/`unins000.dat`，判断同样是本机
对那几个路径的进程限制（该目录下 `regtest.exe` 也写不了 HKCU），不是安装包逻辑问题——
干净机器上卸载路径只有一种，按上面的实测结果（rc 0、程序删除、工作区保留）执行。

**卸载项登记（已知限制）**：安装器进程在本机写
`HKCU\…\Uninstall\MinglingWorkbench_is1` 会被系统拒（`RegCreateKeyEx failed; code 5`，
Inno 自己的 `CreateUninstallRegKey`、`[Registry]` 段、`reg import` 全部一样），所以
安装包不写这条键，改由程序首次启动时 `RegisterUninstallEntry()` 自己补。
这一点在普通目录下验证过（把 exe 和 `unins000.exe` 放到 `C:\Temp\mwtest` 启动，
键出现且 `InstallLocation`、`UninstallString` 正确）；只有在本机
`C:\Users\…\Programs\…` 这种目录里启动时，本机的安全策略会同时拒掉该进程的
注册表写入，键就不会出现——此时开始菜单里的「卸载 冥零工作台」和
`unins000.exe` 仍然可用。干净机器上不会遇到这条限制。

## 5. 关键词清理

在仓库根执行（排除 `tmp/`、`out/`、`logs/`、`sidecar/`、`.git/`、`node_modules/`）：

```bash
grep -rn "大肥鱼配置包\|配置包更新\|桌宠\|petbridge\|pet_bridge\|pet-key" \
  --include=*.cpp --include=*.h --include=*.inc --include=*.md --include=*.py \
  --include=*.json --include=*.iss .
```

结果只剩 `docs\CHANGES.md` 里的「删除项清单」——那是变更记录本身，用于说明删了
什么，不是入口。`win32\src`、`plugin\`、`installer\`、`README.md` 零命中。

另外 `docs\ui-text-audit.md`（旧界面文案审计）、`.venv`、`.venv312`、`.selftest`、
`.env`、`tools\__pycache__`、`tools\dfy.py` 的残留都已删除；`.gitignore` 里补了
`tools/dl/`、`sidecar/node/`、`sidecar/bili-whale/bin/ffmpeg.exe`、`dist/`、
`win32/setup/`。

## 6. 回归

在 `bin\MinglingWorkbench.exe` 上逐项跑：

| 项 | 做法 | 结果 |
| --- | --- | --- |
| 单实例置前 | 起第一个，再起第二个 | 第二个 rc=0 立刻退出；第一个窗口可见且 `GetForegroundWindow()` 就是它 |
| 页签快捷键 1–9 | `PostMessage(WM_LBUTTONDOWN)` 点侧栏 / 按 1–9 | 九个页签都能切，截图见 `docs\screens\` |
| Enter 开始看 | 输入框里按 Enter | 与点「让她看」同一条路径（`StartWatch`） |
| Esc | 有焦点时按 Esc | 取消输入焦点，不误触发 |
| 日志尾随 | 打开日志页，计时器 2.5s 刷新 | 服务日志按 `TailFile(240 行 / 260KB)` 滚动更新 |
| 台账 | 队列页 + `logs\jobs.jsonl` | 两类来源都在：`console`（工作台/CLI）、`qq`/`tool`（插件）；详情正文读 `sink` |
| 体检 | 体检页五个按钮 | `session` / `deps` / `quota status` / `traffic status` / `selftest` 都有输出，`deps` 见 `check.png` |
| 求助 / 帮助 | 求助页 11 张卡、帮助页 FAQ | 卡片可复制给 Agent；帮助页末尾显示当前工作区、台账、状态目录 |
| F9 / F10 | 全部启动 / 全部关闭 | 走 `StartService` / `StopService`（端口 5099、6199 + `KillPid`），逻辑未改；本机两个服务常驻，未重复起停 |

## 7. 已知限制

见 `docs\CHANGES.md` 的「已知限制」一节：ffmpeg 是 GPL 构建、安装包未签名（会触发
SmartScreen）、按用户安装、凭据仍在 `%USERPROFILE%\.bili-ai`、换工作区不搬
`%APPDATA%` 里的状态、feed 需要联网、AstrBot 启动器只枚举常见位置、暂无自动更新、
只发 x64、代码里保留了 `DSH_*` 环境变量名（给上游 sidecar 用，不读 `~/.dsh`）。

## 8. 首次上手暴露的问题复测（2026-11-05）

修完 `docs\CHANGES.md` 4.2 节那五处后，用**当前最终安装包**重新装到 `tmp\itest9`
（隔离 `USERPROFILE`，没有 `.dsh`），命令与结果：

```
install                                   rc 0
MinglingWorkbench.exe --bili selftest     rc 0
  ✓ 配置文件 …\MinglingWorkbench\bili-whale.config.json
  ✓ 依赖体检（deps）—— 全绿
  ══════════ 全部通过 ✓ 可以用了 ══════════
  （末尾是「B 站能力已经内置在工作台里，不用装 DSH」，不再提会话/未分组/权限）
MinglingWorkbench.exe --bili deps         rc 0   ✓ 全部可用（生物钟：工作台按需开看…跳过 ✓）
unins000.exe /VERYSILENT                  rc 0   程序目录删除、工作区保留
```

维护页那条「没找到掉线自救工具（tools\relogin.cmd）」也一起没了：现在缺脚本会先保证
SnowLuma/NapCat 起来，再打开它的后台网页让用户扫码，不再给一句死路提示。

## 9. 第二次上手暴露的问题复测（安装包 2.0.0 最终版）

隔离环境 `tmp\itest19` / `tmp\itest20`：`USERPROFILE`、`APPDATA`、`LOCALAPPDATA`、`TEMP` 全在临时目录，`%USERPROFILE%\.dsh` 不存在。

| 项 | 结果 |
| --- | --- |
| 安装（`/WORKSPACE=D:\MinglingWorkbench`） | rc=0；`settings.json` 每次都写成 `{"workspace": "D:/MinglingWorkbench", "base": "D:/"}`（旧版会因已存在而跳过） |
| 安装向导语言 / 许可协议 | `[Languages]` 解析到 `ChineseSimplified.isl`（编译日志可见）；`docs\THIRD-PARTY.md` 带 UTF-8 BOM，不再按 ANSI 读成乱码 |
| 维护页八卡 | 大脑 / 登 QQ / DeepSeek / 记忆 / 语音 / 看图看视频 / 表情包 全部「正常」，开机自启「留意」；顶部版本行 `AstrBot 4.29.4 · SnowLuma 2.3.4 · Breeze 0.1.3 · Ollama 0.40.11`；掉线提醒「开着 · 后台在跑」。见 `screens/maint.png` |
| AstrBot 后台连接 | 登录成功（DeepSeek 余额 78.05 CNY、今天 74 条消息读到，都是后台接口数据） |
| 更新页 | AstrBot 4.29.4「最新」、SnowLuma 2.3.4 → 2.4.0「有新版」、安装 Skill 0.5.0「最新」、冥零工作台 2.0「本机」。见 `screens/update.png` |
| 卸载 | rc=0，程序目录删除，`ws\logs\jobs.jsonl` 与 `out\` 保留 |

工作台自更新：`settings.json` 里没写 `repo` 时显示「本机」，不发起网络请求；写了 `repo` 才去 GitHub Releases 比对，有新版给「去 GitHub 下载」。


## 10. v2.1 五项修复验收（2026-11-06）

分支 `feat/v2.1-fixes`，从 `65cf9cd`（v2 基线）起：`9845315` `ea6c965` `0bef6c8`（密钥目录 + 安装器）、`b27bb58`（后端判定）、`eec6bab`（界面）、`08eec2d` `545f807`（AutoSetup 实跑修复 + 命令行入口）。

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 构建 | `taskkill /IM MinglingWorkbench.exe /F` 后 `win32\build.bat` | `OK: …\bin\MinglingWorkbench.exe` `size: 1203200 bytes`，warning 只有基线既有的 6 条 |
| 每条提交单独可编 | `git worktree add --detach tmp/wt-A b27bb58` 后在该树里 `build.bat` | `size: 1180160 bytes` OK（界面层另加约 15KB） |
| 状态误判 | `MinglingWorkbench.exe --her-status` 后读 `F:\logs\her-status.txt` | `ITEM memory ok 记忆 · Ollama 在跑 …` 尾列 `记忆未开`；`ITEM voice ok 语音 · Breeze 在跑 …` 尾列 `语音未开`；两行动作列空（不再挂 fixAct）；「选了要记忆但插件关着」仍是 `bad` |
| 密钥目录 | `--paths` | 新增末行 `密钥目录 : F:\secrets`，原有 10 行不变 |
| 密钥优先级 | 临时 `base` 下三种布置各跑一次 `--her-status` | 只在 `secrets` → 读到 key（401）；只在 `private` → 读到（回退生效）；两处都有且 `secrets` 里是注释行 → `nokey`（若 private 优先会报「密钥不对」，故 secrets 优先成立） |
| settings 白名单 | 手写 `secrets` / `notify_every` / `mirror_node` / `mirror_ffmpeg` 后跑一次 `--paths`（触发整文件重写）再读 | 四个键都存活（`paths.cpp:74` 现 7 键） |
| 安装包 | `installer\build-installer.bat` | `Successful compile`，`dist\MinglingWorkbench-2.0.0-setup.exe` 50,852,862 字节；`[Dirs]`/`[Files]` 落 `{code:GetSecretsDir}`，`onlyifdoesntexist uninsneveruninstall`，secrets 不在 `[UninstallDelete]` |
| 一键自动配置（真跑） | 隔离环境 `MINGLING_SIDECAR=tmp\autotest\sidecar`、`base=tmp/autotest`，跑 `--autosetup` | exit 0 全绿：`tmp\autotest\sidecar\node\node.exe` 83,344,536 字节、`…\ffmpeg\bin\ffmpeg.exe` 170,163,200 字节；summary「环境齐了：Node、ffmpeg、工作区、密钥目录都在位，可以开始用了。」 |
| AutoSetup 幂等 | 同一环境再跑一次 `--autosetup` | 立即 exit 0，同样全绿，`bin` 的 mtime 未变，`%APPDATA%\MinglingWorkbench\tmp` 为空 |
| 自动配置暴露的缺陷 | 首轮真跑 | ①`MoveTree` 的 `MoveFileExW` 缺 `MOVEFILE_COPY_ALLOWED`，状态目录在 C:、sidecar 在安装盘时跨盘 `ERROR_NOT_SAME_DEVICE`，下载解压都成功却报「没搞到」；②每跑一次往 `StateDir\tmp` 留 236MB（node 34MB + ffmpeg 202MB 的 zip 与解压目录）；③失败不给阶段。三处已修（`08eec2d`） |

未在本轮实跑的两项，理由写在这里而不是含糊过去：

- **打游戏模式的 `GameOn/GameOff` 破坏性验证**：它会真停 Ollama / Breeze / SnowLuma，而验收机上这些服务正在跑，跑一次会打断她说话。改为代码逐支核对（`local_voice`/`local_mem` 写入时机、`GameOff` 的回退判定），界面三态另靠审阅。要实跑需要先约一个可以停服务的时间窗。
- **托盘与气泡、总览页按钮的交互**：需要真人点窗口，脚本够不着；已核对 `WM_APP_TRAY` / `WM_APP_TOAST` / `WM_APP_AUTOCFG` 三个 case 与 `TrayAdd/Remove/Balloon` 的挂载点。

开发机上演练下载路径的注意事项：必须设 `MINGLING_SIDECAR` 并把 `base`/`workspace` 指向临时目录并预建，否则 `SidecarDir()` 会命中仓库里已装的 sidecar、`WorkspaceDir()` 会回落并覆盖 `settings.json`。

## 11. 安装包「无法安装」修复验收（2026-11-06）

用户报障原文：「安装包无法安装」。以下为实跑记录。

### 11.1 复现（修复前，`dist\MinglingWorkbench-2.0.0-setup.exe`）

```
MSYS2_ARG_CONV_EXCL='*' ./dist/MinglingWorkbench-2.0.0-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS \
  '/DIR=D:\MinglingWorkbench\tmp\itest' '/LOG=D:\MinglingWorkbench\tmp\install.log'
```

日志原文（节选）：

```
Creating directory: D:\MinglingWorkbench\tmp\itest
文件夹名不能包含下列任何字符: / : * ? " < > |
Failed to proceed to next wizard page; aborting.
安装程序未完成安装。
```

instrument 探针（`[Code]` 里把中间值写进日志）实测：

```
afterexist=[:]  final=[:]  userdocs=[C:\Users\<user>\Documents]  wizard=[:]
```

即 `ExistingWorkspace` 从 `{"workspace": "F:/MinglingWorkbench", "base": "F:/"}` 里解析出的是 `:`。

### 11.2 修复后

| 场景 | rc | 关键日志 | 附加检查 |
| --- | --- | --- | --- |
| settings.json 已存在（用户场景） | 0 | `Installation process succeeded.` | settings.json 仍为 `{"workspace": "F:/MinglingWorkbench", "base": "F:/"}`；`tmp\final1\MinglingWorkbench.exe` 1203200 B |
| 删掉 settings.json（全新用户） | 0 | `Installation process succeeded.` | `C:\Users\<user>\Documents\secrets` 生成 |
| `/WORKSPACE=D:\MinglingWorkbench\tmp\wsx` | 0 | `Installation process succeeded.` | `tmp\secrets\README.txt` 生成 |
| 带图标重装（不带 /NOICONS） | 0 | 无 `0x80070005` | 开始菜单 4 个 .lnk 全部生成 |

修复后日志里不再出现 `文件夹名不能包含`、`aborting`。

### 11.3 曾被误判为「测试环境限制」的现象：其实是 Low 完整性标签

> 2026-11-06 更正：本节原先的结论（「本会话对子进程的写限制，真实用户不存在」）**是错的**。真正原因是仓库目录树带 Low 完整性标签，从树里启动的 exe 以 Low IL 跑；用户双击 `dist` 里的安装包时同样中招（`安装程序不能创建目录 "…\Temp\is-1QRB2.tmp"。错误 5: 拒绝访问。`）。详见 `docs/CHANGES.md` 8.1。下面是当初的对照实验原始记录，保留作证据。

`[Code]` 里的 `SaveStringToFile(cfg, js, False)` 在安装时返回 False，settings.json 始终不会由安装器写出。对照实验：

```
# 8 行 Win32 程序，由本会话的 bash 启动
DENY C:\Users\<user>\AppData\Roaming\c1.txt err=5
DENY C:\Users\<user>\AppData\Local\c2.txt     err=5
DENY C:\Users\<user>\AppData\Local\Temp\c3.txt err=5
DENY C:\Users\<user>\Documents\c4.txt          err=5
DENY C:\Users\<user>\c5.txt                     err=5
DENY F:\c6.txt                                      err=5
OK   D:\MinglingWorkbench\tmp\c7.txt
OK   D:\MinglingWorkbench\c8.txt
```

同一路径 bash 自己 `echo hi > file` 成功。安装器（含用 WMI `Win32_Process.Create` 拉起、脱离本会话 job 的那一次）也只是工作区内可写；`%APPDATA%`、`%USERPROFILE%`、`F:\` 根目录一律拒绝。

结论（已作废）：曾判为「本会话对子进程的写限制」。真正原因是完整性标签：

```
dist\MinglingWorkbench-2.0.0-setup.exe   label=0x1000 mask=0x1   ← Low + NO_WRITE_UP（改之前）
dist\MinglingWorkbench-2.0.0-setup.exe   label=0x2000 mask=0x1   ← Medium（icacls /setintegritylevel Medium 之后）
```

一个 Low IL 进程当然写不了 Medium 的 `%TEMP%`/`%APPDATA%`，上面那串 `err=5` 全部由此而来，与 Inno 的代码无关。

### 11.4 Low 标签修正后的复验

```
MSYS2_ARG_CONV_EXCL='*' icacls 'D:\MinglingWorkbench\dist\MinglingWorkbench-2.0.0-setup.exe' /setintegritylevel Medium
tmp/lab3.exe 'D:\MinglingWorkbench\dist\MinglingWorkbench-2.0.0-setup.exe'
  → label=0x2000 mask=0x1
```

清空 settings.json 后用 WMI 拉起安装（脱离本会话）：

```
2026-11-06 07:12:44.954   Installation process succeeded.
-rw-r--r-- 1 Mingling 197609 94 Nov  6 07:12  %APPDATA%\MinglingWorkbench\settings.json
{"workspace": "C:/Users/Mingling/Documents/冥零工作台", "base": "C:/Users/Mingling/Documents"}
```

→ 安装成功，并且 `SaveStringToFile` 这次真的写出了 settings.json（走 userdocs 回退，因为测试前删过文件）。11.3 那条「安装器不写 settings.json」的结论就此推翻。用户真实配置已还原为 `{"workspace": "F:/MinglingWorkbench", "base": "F:/"}`。

注意：**每次重建安装包都要重做一次 `icacls /setintegritylevel Medium`**，新文件会继承 dist 目录的 Low 标签；或把包拷到桌面再双击。

## 12. 自设定验收（2026-11-06）

「一键自动配置」原本只装组件，装完停在「能启动、不会说话」。这一节验收的是第三段：按 `pack\mingling-pack\pack.json` 把 DeepSeek、QQ 平台、聊天设置、插件、长期记忆、语音、人设配成冥零。

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 构建 | `win32\build.bat` | `OK: …\bin\MinglingWorkbench.exe` `size: 1273344 bytes`，exit 0 |
| PS 语法 | `[Parser]::ParseFile` 过 `tools\self-setup.ps1`、`tools\diag-config.ps1` | 两份都 `syntax OK`；必须是 **UTF-8 with BOM**（无 BOM 时 PS 5.1 按 GBK 读，中文引号断成几十个 Parser 错） |
| 干跑（脚本层） | `powershell -File tools\self-setup.ps1 -Base F:\dafeiyu -DryRun` | `##RESULT ok=0 done=7 fail=1`：provider/platform/chat/plugins/memory/persona/verify 七块 `##OK`，voice 因 Breeze 里没有 `mingling` 音色 `##FAIL`；把临时 answers 的 `breeze_voice=dafeiyu` 后 voice 也绿 |
| 干跑（CLI） | `MinglingWorkbench.exe --selfsetup --dry`（隔离 `APPDATA` 指向临时 state 目录，`settings.json` 写 `base=F:/dafeiyu`） | 七条 `[ok]` + voice 一条 `[!!]`（同上，缺冥零音色）+ `[!!] 自设定脚本`；八块顺序 provider/platform/chat/plugins/memory/voice/persona/verify；`verify` 干跑时直接 `[ok] 干跑：不动现场，跳过核对`；输出写 `MINGLING_CLI_OUT` 指定的文件（GUI 子系统进程不占父控制台） |
| 动作入口 | `MinglingWorkbench.exe --her-op selfsetup dry` | exit 0；`F:\dafeiyu\logs\her-op.txt` 写 `OK 自设定完成：…` |
| 真跑 | `MinglingWorkbench.exe --her-op selfsetup`（base=`F:\dafeiyu`，live AstrBot 6185） | exit 0；快照 `F:\dafeiyu\private\snapshots\before-selfsetup-20261106-194005.json` 47,138 字节 |
| 写入生效 | 真跑后读 `/config-profiles/default` | `compression.max_turns=30`、`computer_use_runtime=none`、`segmented_reply.enable=true`、`split_mode=regex`、`safety_mode=true`、`default_image_caption_provider_id=deepseek/deepseek-flash`、人设「冥零」len 1664→1571；`agent_runner.config.model.provider_id` 仍是 `mirarouter/deepseek-v4.1-flash`（非空不覆盖，符合设计） |
| 插件真跑 | `powershell -File tools\self-setup.ps1 -Base F:\dafeiyu -Only plugins` | exit 0；快照 `before-selfsetup-20261106-194825.json`；`##OK plugins|插件 10 个：在位 10 个，开了 6 个、关了 4 个（这次新装 3 个）` |
| 插件配置写盘 | 读 `F:\dafeiyu\astrbot\data\config\astrbot_plugin_dafeiyu_signature_config.json` 等 | `owner_session = "冥零:FriendMessage:2957389852"`；video 的 `ffmpeg_path`/`asr_dir` 与 `answers.json` 一致；sing `backend=doubao`。API 返回中文乱码是 AstrBot 没带 charset，不是写错 |
| 记忆真跑 | `powershell -File tools\self-setup.ps1 -Base F:\dafeiyu -Only memory`（`answers.json` 的 `memory=1`） | exit 0；快照 `before-selfsetup-20261106-195840.json`；`##OK memory|记忆开了：本机 Ollama 的 bge-m3…`；新 provider `冥零记忆-本机`（`type=openai_embedding`、`model=bge-m3`、`enable=true`）；livingmemory 的 `provider_settings.embedding_provider_id=冥零记忆-本机`、`agent_tools.enable_memorize_tool=true`、`filtering_settings.memory_scope_mode=global` |
| 语音真跑 | `powershell -File tools\self-setup.ps1 -Base F:\dafeiyu -Only voice -Answers <临时 answers，breeze_voice=dafeiyu>` | exit 0；快照 `before-selfsetup-20261106-195944.json`；`##OK voice|语音开了：本机 Breeze（dafeiyu）；三条回复里大约一条发语音`；`provider_tts_settings.provider_id=冥零语音-Breeze`、`enable=true`、`trigger_probability=0.33`；provider `type=openai_tts_api`、`openai-tts-voice=dafeiyu`、`api_base=http://127.0.0.1:8137/v1` |
| 语音诚实失败 | 默认 answers（`voice=4`，Breeze 里只有 `dafeiyu` 一个音色） | `##FAIL voice|Breeze 里还没有叫 mingling 的声音（现有：dafeiyu）：先双击「做声音.bat」…现有语音设置没动`，exit 1；同一轮 `##OK memory` 仍是绿的（一块失败不影响别的） |
| 验收脚本 | `powershell -File tools\diag-config.ps1 -Base F:\dafeiyu -Quick` | 十项 `CHECK … ok`（含「插件 10 个都在位，开了 6 个」「记忆开着，用 冥零记忆-本机」「语音开着，用「冥零语音-Breeze」」），`RESULT ok=1 bad=0 why=配置都验过了，能聊` |
| 验收脚本（未应用时） | 同上，现场退回后 | 八项 ok；`CHECK 记忆 bad 记忆插件开着，记忆模型指向「大肥鱼记忆-本机」，要「冥零记忆-本机」`、`CHECK 语音 bad 全局语音指向「大肥鱼语音-Breeze」，不是配置包里那几路`，`RESULT ok=0 bad=2` |
| 回退 | `powershell -File tools\self-setup.ps1 -Base F:\dafeiyu -Restore <上面那份快照>` | `##RESULT ok=1 done=1 fail=0 why=退回好了`；之后人设 len 回到 1664、`computer_use_runtime` 回到 `local` |
| 路径引号 | base 为盘符根（`F:/`）时跑 `--selfsetup` | 脚本收到 `F:\`，干净报「后台没连上」+ exit 2；修前会把 `F:\` 削成 `F:`，`Test-Path F:` 变相对路径 |

本轮**没有**实跑的两处，理由照规矩写清楚：

- **维护页按钮与进度条**：`StartAutoSetup` 第三段（`her::Configure`，75+pct/4，「自设定：」前缀）只是接线，真点按钮要人手，脚本层和 CLI 两条路都已实跑。
- **多平台歧义分支**：live 后台恰好有同名「冥零」平台，走的是精确匹配；「多个平台且没有同名 → 报错不猜」只做了代码核对。
- **快照回退的边界**：快照只收 config、personas、bots。插件自己的配置文件（如 astrbot_plugin_livingmemory_config.json）与「把新增 provider 从列表里去掉」都不在回退范围内——PUT 配置是合并语义，DELETE /providers/{id} 这条路没打通（401）。实测退回后 livingmemory 仍指向 冥零记忆-本机，最后是用 PUT /plugins/config 手工指回 大肥鱼记忆-本机 才干净。

## 13. 自设定踩到的六个坑（复现要点）

1. **命令行收尾反斜杠吃掉引号**：`-Base "F:\x\"` 传进脚本变成 `F:\x"`，`Test-Path` 报「路径中具有非法字符」。`ArgPath` 削尾、盘符根补 `\`、最后再补一个 `\`（命令行里 `\\"` 才是字面反斜杠 + 收尾引号）。
2. **协议行必须带 `##`**：`Done()` 原来写 `RESULT ok=…`，而 `Configure`/`BotsSetup` 只认 `##RESULT `，结果脚本全成功、UI 却报「脚本没给出结果」。统一成 `##RESULT`。
3. **`$pid` 是只读自动变量**：`$pid = "deepseek/deepseek-flash"` 直接炸；两个脚本里的同名变量都改成 `$itemId`。
4. **PS 5.1 没有 `Select-Object -SkipLast`**：快照保留 20 份的裁剪改成「取全部、Count>20 时 `Select-Object -First (n-20)` 删旧的」。
5. **编辑工具会把 `.ps1` 的 UTF-8 BOM 弄丢**：改完必须用 `[IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p,[Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))` 重存，再用 `[Parser]::ParseFile` 过一遍；否则 PS 5.1 按 GBK 读，报一堆 `Missing closing ')'`。
6. **PowerShell 截图会被 DPI 虚拟化**：工作台是 DPI-aware（`SetProcessDpiAwarenessContext`），150% 下真实客户区 2100x1350；不设 `SetThreadDpiAwarenessContext(-4)` 时 `GetClientRect` 只报 1400x900，`CopyFromScreen` 截出来的图右边和下边的控件全被裁掉（一度误判「功能页的开关 chip 没画」）。正确姿势：DPI-aware 线程 + `PrintWindow(hwnd, memDC, 1)`。

## 14. 功能页验收（2026-11-06，V2.3.0）

「配置包里默认关着的几样」做成侧栏第 8 页「功能」：四个插件开关（桌宠 / 唱歌 / 豆包语音 / 在线 Breeze）+ 长期记忆三选一 + 语音路线五选一。点一下写 `<base>\private\features.txt`、`memory-mode.txt`、`voice-mode.txt`，再自动跑对应的自设定块。

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 构建 | `win32\build.bat` | `OK: …\bin\MinglingWorkbench.exe` `size: 1289728 bytes` |
| 版本 | `tools\check-version.ps1` | `[版本] OK V2.3.0 (2.3.0.0)` |
| 切页 | `SendMessage WM_KEYDOWN 0x38`（`8`） | `g_tab=7`，功能页渲染；`0` 键新增到帮助页 |
| 截图 | DPI-aware 线程 + `PrintWindow` | `tmp\ui-full.png` 2100x1350：六行齐全，桌宠/唱歌/豆包/在线 Breeze 的「开/关」、记忆「本机 bge-m3」、语音「本机 Breeze」选中态正确 |
| 点「桌宠 开」 | 客户区 (1814,242) → 屏幕 (2044,364) 点击 | `private\features.txt` 写入 `astrbot_plugin_dafeiyu_petlink=1`；自设定跑 `plugins` 块，快照 `before-selfsetup-20261106-210052.json`，`##OK plugins|插件 10 个：在位 10 个，开了 7 个、关了 3 个`；页面刷新后「开」变蓝、状态行「自设定完成：自设定跑完了，都成了」 |
| 还原 | 删 `features.txt` + `self-setup.ps1 -Only plugins` | `##OK plugins|插件 10 个：在位 10 个，开了 6 个、关了 4 个`，现场回到默认 |
| 引擎覆盖 | `features.txt` 写 `…petlink=1` 后 `-DryRun -Only plugins` | `（dry-run，astrbot_plugin_dafeiyu_petlink → 开）`、`开了 7 个、关了 3 个` |
| 命令行等价 | `--her-op feature voice/4` | `logs\her-op.txt` 写「OK 语音路线改成 4 了（跑完自设定就生效）」，生成 `private\voice-mode.txt` |
| 安装包 | `installer\build-installer.bat` | `dist\MinglingWorkbench-2.3.0-setup.exe`，51,553,244 字节，sha256 `18970FFC411F4327D8DD3EFD9F8756538EFCBF1E08445DE31C3607F2B19C0E15`，ProductVersion `2.3.0` |

没跑的：安装包覆盖安装（沿用 2.2.1 的注意：重建后要 `icacls /setintegritylevel Medium`）；「豆包语音」「在线 Breeze」两条路只验到写覆盖文件 + 跑块，没填真 key。
## 15. V3.0.0-snapshot 验收（2026-11-07）

V3.0.0 是**预奏快照版**，走独立通道：界面与文件版本都是 `V3.0.0-snapshot` / `3.0.0.0-snapshot`，状态目录、卸载项、窗口类、AUMID、安装目录和正式版分开，工作区与 `<Base>\secrets` 共用。下面按六项需求逐条对。

### 15.1 构建与版本（五处一致）

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 构建 | `win32\build.bat` | `OK: …\bin\MinglingWorkbench.exe`，1441280 字节，exit 0（只剩既有 warning：`#pragma comment`、`0x1F525` 超范围 case、几处 unused） |
| 版本号出处 | `tools\check-version.ps1` | `[版本] OK V3.0.0-snapshot (3.0.0.0-snapshot)`，exit 0；脚本顺带校验「`APP_VERSION_SUFFIX` 非空 ⇔ `APP_SNAPSHOT=1`」 |
| 命令行 | `MinglingWorkbench.exe --version` | `冥零工作台 V3.0.0-snapshot` / `  文件版本 3.0.0.0-snapshot` |
| 命令行 | `--paths` 第一行 | `版本     : V3.0.0-snapshot（3.0.0.0-snapshot）` |
| exe 属性 | 资源管理器 / `FileVersionInfo` | FileVersion `3.0.0.0-snapshot`、ProductVersion `V3.0.0-snapshot` |
| 侧边栏 | 截图 `tmp\v2_maint.png` | `工作台 · V3.0.0-snapshot`（放不下时先降字号、再只留版本串，不用省略号切掉后缀） |
| 维护页 | 同上 | 头部版本行「工作台 V3.0.0-snapshot　组件版本还没取到」——工作台版本与组件版本分开画，组件版本单独可辨 |
| 帮助页 | 截图 `tmp\v3_help2.png` | 「关于」段：`冥零工作台 V3.0.0-snapshot · 单个 exe，Win32 + GDI+ 自绘，不挂浏览器内核。` |
| 卸载列表 | 跑一遍安装后的 exe 后读注册表 | `HKCU\…\Uninstall\MinglingWorkbench_snapshot_is1`：DisplayName `冥零工作台 V3.0.0-snapshot`、DisplayVersion `V3.0.0-snapshot` |

### 15.2 快照通道（不与正式版共通）

| 项 | 观察点 | 结果 |
| --- | --- | --- |
| 状态目录 | `--paths` 的「状态」行 | `C:\Users\Mingling\AppData\Roaming\MinglingWorkbench\snapshot`（正式版在这层的上一级） |
| 隔离排障 | 环境变量 `MINGLING_STATE_DIR` | `StateDir()` 优先认它，验收时用它把状态目录指到 `tmp\dshstate` 之类 |
| 窗口类 / AUMID | `#if APP_SNAPSHOT` | `MinglingWorkbench.snapshot` / `Mingling.Workbench.snapshot`，两份可以同时开，不会互相顶掉 |
| 安装目录 | 安装后 | `%LOCALAPPDATA%\Programs\MinglingWorkbench-snapshot`，正式版旁边并存 |
| 共用部分 | 工作区 `out/tmp/logs`、`<Base>\secrets` | 不变，换渠道不用搬看片产物 |

### 15.3 更新页（GitHub Releases）

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 未配通道 | `settings.json` 里没有 `repo_snapshot` | 「冥零工作台」行 Chip 显示`本机 / 没查到`，右侧 `V3.0.0-snapshot`，描述「快照通道还没配：在 settings.json 里写 repo_snapshot（owner/name），更新页就会去查那个仓库的 snapshot release。现在显示的是本机版本，不影响任何功能。」（`tmp\v2_upd2.png`） |
| 配了但没 release | `repo_snapshot = linyuehua0010/mingling-workbench`，点「再查一遍」 | 该仓库 `releases/latest` 返回 404 → 仍显示`本机 / 没查到`，描述里写出正在查哪个仓库（`tmp\v2_upd3.png`）；页脚「有几项没查到最新版（多半是网络不通），过会儿再点「再查一遍」。」；进程存活、界面不卡 |
| 只看快照 | 代码 | 只读 `repo_snapshot`；tag 里没有 `snapshot` 的 release 一律不认，正式版 exe 的下载按钮永远不会出现在这一行 |
| 私有仓库（无凭据） | 仓库是 private，不带 token 查 `releases/latest` | 只有 404 → 页面仍显示`本机 / 没查到`，描述里点出正在查哪个仓库（`tmp\v3_upd_private.png`）；进程存活、不卡 |
| 私有仓库（带凭据） | `<Base>\secrets\github-token.txt` 放一个无效 token 再点「再查一遍」 | 401 同样按「没查到」处理，不报错不崩（`tmp\v3_upd_faketoken.png`）；`EnsureSecrets()` 顺手在 `secrets\README.txt` 里补上 `github-token.txt` 那一行 |
| 预发布不在 latest | `repo_snapshot` 已配、token 已放，release 发成 prerelease | `/releases/latest` 只回正式版 V2.3.1 → 旧逻辑判成「没查到」；改成问 `/releases?per_page=100` 挑 tag 带 `snapshot` 的第一条后，同一台机器上显示 Chip「最新」+「已经是最新（linyuehua0010/mingling-workbench）。换机器时从 Releases 页面下载安装包覆盖安装就行。」，页脚「都查到了。」（`tmp\v5_upd_ok.png`） |
| 不自动更新 | 代码 | 没有任何下载/替换逻辑；有新版时按钮是「去 GitHub 下载」，点了只开浏览器 |

### 15.4 B 站页统合 + bili-whale 配置界面

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 入口统合 | B 站页截图 `tmp\v2_bcfg2.png` | 一条工具带：`bili-whale 配置` / `登录` / `配额` / `风控` / `自检` / `产物` / `问一句`；看片、结果、产物都还在这一页 |
| 维护页收敛 | 截图 `tmp\v2_maint.png` | 头部只留一个「B 站页」按钮（把 B 站相关操作交给 B 站页），八张卡与状态摘要原样 |
| 配置读写 | 浮层标题下 | 路径 `C:\Users\Mingling\AppData\Roaming\MinglingWorkbench\snapshot\bili-whale.config.json`，就是 `BILI_WHALE_CONFIG` 指的那一份 |
| 保存前备份 | 点「保存」 | 生成 `bili-whale.config.json.bak-20261107-001602`（1520 字节）；同一秒连存两次会依次 `-2`、`-3`，不互相覆盖 |
| JSON 校验 + 回滚 | 无头自检 `tmp\cfgtest` | 写入后重新 `her::J::Parse` 校验；故意写坏时用备份 `CopyFileW` 回滚（原本没有文件则删掉） |
| 未知键保留 | 无头自检：模板里塞 `futureUnknown.block.deeper = "keep-me"`，改 `risk.readDaily`/`preferences.like`/`diary.enabled` 后存盘 | 15 个原有顶层键全在、`futureUnknown.block.deeper` 原样留着；`risk.minGapMs=1500`、`night.windows[0]`、`persona`、`listen.comment/scope` 都没被碰 |
| 工作台侧参数 | 存盘后的 `settings.json` | `bili_grid` 存字符串（`"4x4"`）、`bili_timeout_sec` 存数字（`600`），看片命令用 `--grid <bili_grid>`、超时用 `bili_timeout_sec` |
| 测试连接（没填 Base） | 点「测试连接」 | 左下提示「先填 Base URL，再测」，不崩、不卡（`tmp\v2_bcfg_test.png`） |

### 15.5 DSH 对话 API（OpenAI 兼容 /chat/completions）

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 配置项 | 配置浮层「对话 API（可选）」区 | 启用开关 / Base URL / 路径（默认 `/chat/completions`）/ 模型名（默认 `deepseek-chat`）/ 超时（5–300）/ API Key；提示写明「关掉的话只是 B 站页不调它，别的功能照旧」 |
| Key 不进 settings | 无头自检 `tmp\dshtest` | `sk-test-123` 在 `secrets\dsh-api-key.txt`；`settings.json` 里搜不到；清空 Key 后密钥文件被删 |
| 配置校验 | 同上，18 项 | 启用但空 Base 被拒、非 http(s) Base 被拒、超时越界收敛、存取往返一致、`DshApiUrl` 拼成 `https://127.0.0.1:1/v1/chat/completions` → 全过（`failures: 0`） |
| 断网只影响这一路 | 同上：Base 指到 `127.0.0.1:1` 再调 | 返回失败且错误里是「连不上」；关掉开关后直接拒绝、不发请求；本地 bili-whale CLI 完全不受影响（B 站看片链路不经过它） |
| 用在哪 | 「问一句」浮层 | 拿当前结果（标题/UP/前 8 节要点，上限 1500 字）去问，回答显示在浮层里，可复制；失败给「没问到：…」，不挡看片 |

### 15.6 输入框复制粘贴

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| Ctrl+V | 剪贴板放完整 B 站 URL + 分享尾巴，点输入框按 Ctrl+V | 整串粘进去，`Trim` 后保留「快来看」这类尾巴（`tmp\shot_paste.png`） |
| 输入时不吃快捷键 | 输入框有焦点按 `3` | 只打字符、不切页（`tmp\shot_key3.png`） |
| Ctrl+A / Ctrl+X | 同上 | 全选有高亮（`tmp\shot_selall.png`）；剪切后输入框清空、剪贴板内容与原文一致（`Get-Clipboard` 长度 70） |
| 右键菜单 | 输入框右键 | 六项：粘贴 Ctrl+V / 粘贴（Shift+Insert）/ 复制 Ctrl+C / 剪切 Ctrl+X / 全选 Ctrl+A / 清空；无内容时复制剪切置灰（`tmp\shot_rclick.png`）；选「粘贴」把含换行的 QQ 分享文本粘进去（`tmp\shot_menu_paste.png`） |
| 上限 | 代码 | 输入框上限 200 → 600 字，超了截断并提示「太长了，只取了前面一段」 |

### 15.7 其他链接 / 分享文本读取（MVP）

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 通用读取 | 粘 `https://example.com/` 回车 | 结果区：「读到的链接 / 标题: Example Domain / 地址 / 状态: HTTP 200 · 读到 577 B / 正文摘要」（`tmp\shot_link_rel.png`） |
| 台账 | `logs\jobs.jsonl` 新增行 | `{"t":…,"bv":"https://example.com/","title":"Example Domain","up":"example.com",…,"sink":"…\\logs\\jobs\\link-1793979934.txt","seconds":"0s","type":"link"}` |
| 分类器 | 无头自检 `tmp\wftest`，15 项 | 空→空；`BV1GJ411x7h7` 与小写 `bv…`→B 站；B 站 URL / `b23.tv` 短链 / B 站分享文本→B 站；普通 `https://…`（连句末「。」也算）→链接；`【分享】看看这个 https://… 挺好`→分享文本；`C:\Windows\notepad.exe`→本地路径；无链接中文→看不出；中文右括号能截断 |
| 网络失败文案 | 同上，5 项 | 404 →「对方拒绝了（HTTP 404）」；`127.0.0.1:1` →「连不上这个站点」；不是 URL →「这不是一个完整链接」；超时/编码/非 HTML 各有自己的话，不崩 |
| 分享文本 | 代码 | 先提首个 URL 再走读取；B 站分享文本走原看片链路 |
| 本地路径 | 代码 | `.lnk/.exe` 只 `ShellExecute` 打开，不做进程注入、不读进程内容、不抓应用界面 |
| B 站回归 | BV18P486KECi | 18s、`status":"ok"`、`sink ...\jobs\BV18P486KECi-1793980125.txt`，**没有 `type` 键**（老台账解析不受影响） |

### 15.8 顺手修掉的老崩溃（0xc0000005）

| 项 | 观察点 | 结果 |
| --- | --- | --- |
| 症状 | 自动化按 `6`/`7` 来回切页，1~2 轮必崩 | 事件日志 `0xc0000005`，同一次构建内偏移恒定 |
| 定位 | 与 bin 同参数、只多 `-g` 的 `MinglingWorkbench_sym.exe` + `addr2line` | 落到 `her::WhitelistOn()` / `her_config.cpp:349` |
| 真因 | `const J* v = CmdConfig().Path(…)` | `CmdConfig()` 按值返回临时 `J`，语句结束即析构，`v` 悬垂 → use-after-free |
| 历史性 | 应用日志里 22:51:40 的 2.3.1 崩溃 | 同一个函数（`0x60f51`），不是本次快照引入的 |
| 修法 | 先 `J cfg = CmdConfig();` 再取地址 | 顺带给 `Net()`/`ImagePath()` 的静态缓存补锁；`Net()` 由返回引用改成返回值 |
| 验证 | 3 轮 × 每轮 16 次快速切 6/7 | run1/2/3 全存活，Windows 应用日志 `crashes=0`（此前同样脚本 1~2 轮必崩） |

### 15.9 安装包

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 打包 | `installer\build-installer.bat` | `dist\MinglingWorkbench-3.0.0-snapshot-setup.exe`，51,615,396 字节，Inno 约 29s，exit 0 |
| 静默升级安装 | 既有（UTF-8、中文工作区、带 `repo_snapshot`）settings 存在时 `/VERYSILENT` | exit 0、`Installation process succeeded.`，且 `settings_unchanged=True`——安装器**不碰**已有配置 |
| 静默全新安装 | 先删 settings，`/WORKSPACE=F:\dsh工作区\tmp去装测试\MinglingWorkbench` | exit 0；写出 `{"workspace": "F:/dsh工作区/tmp去装测试/MinglingWorkbench", "base": "F:/dsh工作区/tmp去装测试"}`（ANSI/GBK 字节，工作台 `DecodeAuto()` 按 UTF-8→系统编码的顺序读，照样认识）；建好 `out`、`tmp`、`logs\jobs` |
| secrets 不猜路径 | 安装后 | 安装器不再建 secrets 目录、也不放 README（工作台 `EnsureSecrets()` 首次启动自己建，含 `dsh-api-key.txt` 那一行），不会在「文档」下面凭空多一个 `secrets` |
| 卸载项 | 跑一遍装好的 exe | DisplayName `冥零工作台 V3.0.0-snapshot`、DisplayVersion `V3.0.0-snapshot`、DisplayIcon 指安装目录的 exe |
| 安装器踩坑 | 记在 `installer\mingling.iss` 注释里 | 别在安装器里解析工作台的 UTF-8 settings（Inno 6.0 没有可用的 UTF-8 解码，中文路径会被拆错字，静默安装直接报「文件夹名不能包含下列任何字符」）；也别塞 UTF-8 BOM 冒充 UTF-8，BOM 后面跟 GBK 字节会让工作台解错 |

### 15.10 没跑的项

- **真实 DSH 端点的「测试连接」**：手头没有可用的 API Key，只验到「没填 Base 就提示」与「断网报连不上、不影响别的功能」。填真 Key 的通路属于同一条代码，风险在服务端而不在这边。
- **`repo_snapshot` 指向一个真有 snapshot release 的仓库**：「有新」分支只做了代码核对（`LatestGithub` 两个分支都回填原始 tag、`VerCmp` 比较 `APP_VERSION_PLAIN_W`），没等到真发版。
- **release 构建下的完整看片链路**：修完崩溃后做的是切页压测（3×16）；完整 debrief 是在带符号构建下跑的，产物与台账字段都正常。
- **GUI 里逐字改 bili-whale 配置再保存**：浮层打开/滚动/测试连接/保存/`Esc` 都点了；逐字编辑 + 保存的语义由无头自检 `tmp\cfgtest` 覆盖（同一套 `BiliCfgApply`/`BiliCfgSave`）。
- **本地 `.lnk` / `.exe` 打开**：代码路径是 `ShellExecuteW`，与「打开工作区」同一条，没单独造快捷方式试。

## 16. V3-snapshot-2 验收（2026-11-07）

工作副本：`F:\dsh工作区\MinglingWorkbench`，构建 `win32\build.bat`（MinGW-w64，静态链接），
exe 1,637,888 字节。截图见 `docs\screens\`，全部是 `PrintWindow` 抓的 2122×1406 物理像素（DPI 150%）。
截图的实例跑在开发目录（`bin\MinglingWorkbench.exe`），状态目录是真实的 `%APPDATA%\MinglingWorkbench\snapshot`；队列里那几条是自己跑出来的验收记录，没有 PS 过。

### 16.1 版本：四处一致

| 项 | 命令 / 观察点 | 结果 |
| --- | --- | --- |
| 自检脚本 | `tools\check-version.ps1` | `[版本] OK V3-snapshot-2 (3.0.0.2)`，exit 0 |
| 命令行 | `MinglingWorkbench.exe --version` | `冥零工作台 V3-snapshot-2` / `  文件版本 3.0.0.2` |
| exe 属性 | `(Get-Item …).VersionInfo` | FileVersion `3.0.0.2`、ProductVersion `V3-snapshot-2`、ProductName `冥零工作台` |
| 安装包名 | `installer\build-installer.bat` 的 `OutputBaseFilename` | `MinglingWorkbench-{#AppVerShort}-setup` → `MinglingWorkbench-3-snapshot-2-setup.exe` |
| 应用和功能 | 把新 exe 连同占位 `unins000.exe` 放到 `tmp\regtest\` 跑一次，读 `HKCU\…\Uninstall\MinglingWorkbench_snapshot_is1` | DisplayName `冥零工作台 V3-snapshot-2`、DisplayVersion `V3-snapshot-2`、InstallLocation 指向该目录；**测完把这几个值按测试前的快照还原**（本机真实安装项仍指向 `%LOCALAPPDATA%\Programs\MinglingWorkbench-snapshot`） |

版本规则：`version.h` 里 `APP_SNAPSHOT_N=2`、`BUILD=2`、`APP_VERSION_SHORT="3-snapshot-2"`；
`check-version.ps1` 在快照态强制 `suffix=="-snapshot"`、`BUILD==APP_SNAPSHOT_N`，并校验 8 个派生宏。

### 16.2 读链接 + 问一句 + 测试连接

静态夹具在 `tmp\linktest\`（`utf8.html` 292 B / `gbk.html` 264 B CP936 / `big.html` 2,165,713 B），
用 `python -m http.server 8799` 起本机服务；CLI 用 `--link`，GUI 用自绘输入框 + Enter。

| 用例 | 结果 |
| --- | --- |
| UTF-8 页 | 分类=链接，exit 0，标题「冥零测试页 · UTF-8」，正文正确 |
| GBK 页 | Content-Type `charset=gbk` → 按 CP_ACP 解，正文正确（不是乱码） |
| 分享文本 `【冥零】顺手看看这个 http://…/utf8.html 挺有意思的` | 分类=分享文本，抽出链接读成功，exit 0 |
| 非法输入 `not a url` | exit 4「这里面没有链接」 |
| `ftp://example.com/file.txt` | exit 4「只认 http:// 和 https:// 的链接（别的协议读不了）」 |
| 404 | exit 3「对方拒绝了（HTTP 404）」 |
| 超大页（2 MB） | HTTP 200、读到 524,288 B、`注意: 页面太大，只读了前 512 KB`，末尾半个汉字回退后不串码 |
| 真实站点 | `bilibili.com/video/BV1GJ411x7h7` → 242,887 B，标题「【官方 MV】Never Gonna Give You Up - Rick Astley_哔哩哔哩_bilibili」；`example.com` 也通过（gzip 由 WinHTTP 解） |
| 台账 | `logs\jobs.jsonl` 新增行带 `"type":"link"`、`sink` 指 `logs\jobs\link-<t>.txt`；看片老行仍然没有 `type` 键 |
| 「问一句」 | 临时把 `dsh_api_enabled=1`、Base 指到本机夹具服务，结果区右侧出现面板（标题/副标题/错误行「没问到：服务端说不行（HTTP 501）」/复制·再问一次·收起）；测完用 `.bak-test` 还原 settings |
| 「测试连接」 | 同一次配置下点 `lc:test` → 底部「没连上：服务端说不行（HTTP 501）」+ toast「对话 API 没连上（不影响看片）」 |
| Key 不泄漏 | 全程 `settings.json` 只有 `workspace/base/repo_snapshot`（+ 测试期临时键），`secrets\` 下没有 `dsh-api-key.txt`；Key 只在「链接与应用」填了才会写 `secrets\dsh-api-key.txt`，日志与 `--her-op diag` 的 txt 都不含它（`diag` 打码逻辑未改） |

### 16.3 覆盖更新演练（只覆盖工作台自己）

假安装器 `tmp\fake_ok.exe` / `tmp\fake_fail.exe`（`g++ -O2 -municode`，读 `MINGLING_FAKE_TARGET` / `MINGLING_FAKE_MODE`），
用 `bin\MinglingWorkbench.exe --wb-update <fake> v3-snapshot-2-test` 跑。

| 项 | 结果 |
| --- | --- |
| 哨兵 | 先在 `bots\`、`secrets\`、`out\`、`logs\`、`private\` 写哨兵文件，SHA-256 存 `tmp\sentinel-before.json`；成功/失败两次演练后 `changed=0` |
| 备份 | `<工作区>\旧版\workbench-<tag>-<时间>\` 含 `art bin docs pack plugin sidecar skill tools _self`；`_self\MinglingWorkbench.exe` 是主程序自身 |
| 成功路径 | 退出码 0，`[更新] 备份到 …` / `[更新] 好了（安装器退出码 0）`，`bin\FAKE-UPDATED.txt` 出现 |
| 失败路径 | 退出码 4，日志「[更新] 失败：安装器退出码 1，已经回滚到备份」，被改的 `docs\ACCEPTANCE.md` 哈希还原、`<!-- FAKE-INSTALLER-JUNK -->` 不残留 |
| 备份落在哪 | 早先误用 `BotRoot()` 会写进 `bots\旧版\`；改成「工作区优先、空则安装根」，误建目录已删 |
| 安装器审计 | `installer\mingling.iss` 的 `[Files]` 只有 bin/README/art/docs/plugin/sidecar/skill/tools/pack；**没有 `[InstallDelete]`**；`[UninstallDelete]` 只有 `Type: dirifempty; Name: "{app}"`；bots 只出现在 `[Code]` 猜 base 的逻辑里 |
| 运行中检测 | `her::PidsNamed(L"minglingworkbench.exe").size() > 1` 时先弹「先关掉别的工作台」，不进下载 |

### 16.4 教程与帮助（离线）

- 三篇（`使用说明.md` / `deploy-bili.md` / `deploy-qq.md`）随包进 `{app}\docs`（`Source: "..\docs\*"; recursesubdirs`，截图一起进去）。
- 帮助中心 → 帮助 → 教程胶囊 → 自写 Markdown 渲染：标题分三级、列表、代码块（底色先画再写字，修过一次盖字）、表格、引用；
  打开时右上出现「用系统打开」`docopen` /「回 FAQ」`docback`。
- 文档里的版本号 / 页签数 / 快捷键来自 `{{VERSION}} {{FILEVERSION}} {{TABS}} {{TABLIST}} {{HOTKEYS}}`，
  正文里不再出现写死的「10 个页签」「1–9」。
- `docs\*.md` 里没有任何 `![…](http…)` 远程图片（grep 结果为空）。

### 16.5 七页签与动作可达

| 项 | 结果 |
| --- | --- |
| 侧栏 | 总览 / B站 / 队列 / 日志 / 体检 / 维护 / 帮助中心（`TABS[]` 7 项，`docs\screens\overview.png` 可见） |
| 快捷键 | `1`–`7` 切页、`0` 跳帮助中心、F5 按当前页/分段刷新、F9/F10 全起全停、Enter 提交、Esc 失焦（配置分区退回看片） |
| 维护 + 功能 | 维护页滚到底：功能六行（桌宠/唱歌/豆包语音/在线 Breeze/长期记忆/语音路线）都在；点「桌宠 开」→ `private\features.txt` 变化 + 自设定跑完 toast，随后点「关」还原 |
| 帮助中心三段 | 更新（四项 + 工作台一键更新）/ 求助（11 卡，改字与复制）/ 帮助（FAQ、路径、组件目录、教程），三颗胶囊 `hsec:0/1/2` 都点得动 |
| 配置分区不劫持导航 | 修前在「配置」里点侧栏无反应；修后 `tab:` / `hsec:` 先于配置捕获处理，实拍可切走 |
| `--her-op` 回归 | `--her-op meme mid` exit 0，`logs\her-op.txt` 写「OK 改好了：她挑中表情，六成会发图。」 |
| 自设定干跑 | `tools\self-setup.ps1 -Base <机器人根> -DryRun` → 八块 `##OK`，`##RESULT ok=1 done=8 fail=0`；`--selfsetup --dry` 同样八块 `[ok]` |

### 16.6 没跑的项（如实写）

- **真打安装包 / 真装一遍**：本机没有 Inno Setup（`ISCC.exe` 不存在），这一轮只做 `version_auto.iss` 生成逻辑与
  `mingling.iss` 的静态审计；覆盖更新用假安装器验证了备份/回滚/重启链路，真安装包上的 `/VERYSILENT` 参数与这条路径一致。
- **真 DSH 端点的「问一句」成功返回**：没有可用 Key，只验到「配置→请求→错误人话化→不影响看片」。
- **从 GitHub 真下一版安装包**：`FindSetupAsset` / `DownloadFile` / `Sha256File` 的代码路径与错误文案做了静态核对，
  没等到真实 release 资产（`repo_snapshot` 目前最新是 V2.4.0，本机版本更高，UI 显示「最新」）。