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
