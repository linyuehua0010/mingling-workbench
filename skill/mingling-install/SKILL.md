---
name: mingling-install
description: 在 Windows 10/11 上装、修、搬、卸「冥零工作台」（MinglingWorkbench V3，C++ 工作台 + bots 组件 + pack 配置包）：一键自动配置装齐 AstrBot、SnowLuma/NapCat、uv、ffmpeg、Ollama、Breeze，跑八块自设定（模型、平台、聊天、插件、记忆、语音、人设、自检），换人设换声音、让她看视频、搬去云服务器、备份还原、卸干净、看不懂的报错先体检。用户说「装冥零」「冥零工作台起不来」「自设定没成」「她记不住事」「换个声音」「换成我自己的角色」「她看不见视频」「搬到服务器上」「备份/还原/卸载冥零」「工作台日志是空的」「更新页说没找到安装」「部署本地唱歌」「SoulX 唱歌」「切换豆包唱歌」「用冥零声音唱歌」「用已有 Breeze 音色制作唱歌参考」时使用。
---

# 帮人装、修、搬、卸冥零工作台（skill 0.6.0，2026-11-10）

你在帮一个可能完全不懂电脑的人，在**他自己的 Windows 电脑**上把「冥零工作台」装好、修好，
或者搬去云服务器。整套东西是：

```
<工作区>（= 机器人根，一个文件夹，装哪由他挑）
├─ bin\MinglingWorkbench.exe      工作台本体（C++，一个窗口管全部）
├─ win32\ build.bat 的源码        只有开发机上才有
├─ tools\                         脚本：self-setup.ps1、bootstrap.ps1（装组件主入口）、diag.ps1、backup.ps1……
├─ pack\mingling-pack\            配置包：pack.json、plugins\、voice\
├─ bots\                          组件都在这（不是散在工作区根！）
│   ├─ AstrBot\                   大脑；入口 bots\AstrBot\bin\astrbot.exe；日志 bots\AstrBot\run.log；端口 6199
│   ├─ SnowLuma\node.exe          登 QQ 的程序；日志 bots\SnowLuma\snowluma-run.log；端口 5099
│   ├─ Ollama\ + ollama-models\   本机记忆用的 bge-m3；端口 11434
│   ├─ asr\                       本机语音识别模型（手工装的，不在组件清单里）
│   └─ Breeze\                    本机 Breeze 语音；端口 8137
├─ uv\bin\uv.exe                  装 Python 包用的 uv（装包外，不在 bots\）
├─ sidecar\                       node\、bili-whale\（装包自带）；ffmpeg 也装这里：sidecar\ffmpeg\bin\
├─ private\                       凭据：backend.txt、deepseek-key.txt、features.txt、voice-mode.txt……
├─ answers.json                   自设定的答卷（base_url、memory、voice、video、路径）
└─ logs\                          自设定日志 self-setup.log、缓存 cache.json、her-op.txt
```

AstrBot 后台登录：`POST http://127.0.0.1:6185/api/v1/auth/login`，账号密码在
`private\backend.txt`（`url` / `username` / `password`，或直接给 `token`）。
`/api/v1/plugin/get` 是 404，别拿它查插件——插件目录看 `bots\AstrBot\data\plugins\`。

## 先说话方式

- 短句、人话。一次只让他做一件事，做完让他回「好了」。
- 不甩术语；非说不可的词第一次出现带半句白话。
- 出错了先自己查，查清了再说「卡在哪、我准备怎么修」，别把整段报错甩给他。
- 影响结果的事都要问（装哪个盘、要不要本机记忆、要不要语音），选项的利弊摆出来，再说「拿不准就选哪个」。

## 第 0 步：他现在是哪一种情况

先跑体检，别猜：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<这个 skill>\scripts\probe.ps1"
```

它会打印 `##结论 <一句话>`、`##工作台`、`##工作区`、`##组件`、`##服务`、`##技能`。
按结论走：

| 结论 | 他去哪儿 |
|---|---|
| 没装过 | 第 1 步装 |
| 装了但组件缺 | 第 2 步一键自动配置 |
| 装齐了但自设定没成 | 第 3 步按块补 |
| 能聊但某一样不对（记忆/语音/看视频/认不出他说什么） | 第 4 步按症状修 |
| 要换角色、换声音 | 第 4 步 |
| 要搬服务器、备份、卸载 | 第 5 步 |

## 第 1 步：装

安装包在 `https://github.com/linyuehua0010/mingling-workbench/releases`，当前正式版是
**V3.2.0**，名字是 `MinglingWorkbench-3.2.0-setup.exe`（约 85 MB，88,892,091 字节）。
它自带 sidecar\（node、bili-whale）、pack\、skill\、tools\（含 components.json + bootstrap.ps1），
**bots\ 里的组件不预装**，装完要跑一次「一键自动配置」联网装（这台没网就用 `-Offline` 走缓存）。
同一版还有一份 `MinglingWorkbench-3.2.0-setup-snowluma.exe`（约 126 MB / 131,675,213 字节），
多带一份 SnowLuma 2.4.2，装完省掉那 41 MB 下载；这是出包时显式开 `-BundleSnowLuma` 才有的产物，
默认不内置，涉及上游 EULA 授权（见 `docs\snowluma.md` 第 14 节），用户没特别要求就给默认那份。
以后换了版本，文件名里的版本号跟着 `version.h` 走。

1. 问他装哪个盘，默认「不是 C 盘、空间够的那个」。工作区就是装完后的那个文件夹。
2. 安装时**不要**把工作区设成安装目录的上一级；工作区本身就是机器人根。
3. 装完先跑第 0 步的 probe 确认「工作台 / 工作区 / 组件」三行都不是「没找到」。

> 只拿到源码的情形：源码树里的 `bin\MinglingWorkbench.exe` 可以直接跑（工作区就是源码目录）；
> 重编译在 `win32\` 下 `cmd /c build.bat`，产物会拷到 `..\bin\`。**关掉窗口再编**，否则
> `COPY FAILED: ... is locked`。exe 是 GUI 子系统，命令行里要用
> `Start-Process .\bin\MinglingWorkbench.exe -ArgumentList @("--her-op","<动作>") -Wait`，
> 结果写在 `<工作区>\logs\her-op.txt`。

## 第 2 步：一键自动配置（装齐 bots）

工作台「照顾她 → 组件与操作 → 一键自动配置」做的事，命令行等价：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<这个 skill>\scripts\bootstrap.ps1" -Base "<工作区>" -Workspace "<工作区>" -Bots "<工作区>\bots"
```

这个入口会从 `HKCU\Software\MinglingWorkbench\ProgramRoot`（或安装器登记的位置）解析程序目录，
再执行**程序目录里的同一个** `tools\bootstrap.ps1`。程序目录和工作区分离时，不要把脚本路径写成
`<工作区>\tools\bootstrap.ps1`；只有源码树里两者才恰好相同。

只想体检、不下载任何东西，就在后面加 `-Check`：退出码 0 = 全都齐了，2 = 有缺项；
输出仍是 `##STEP` / `##OK` / `##FAIL` / `##RESULT`，`-LogFile <路径>` 可以留一份日志。
`auto-setup.ps1` 仍可用，它内部转发到 `bootstrap.ps1`——老教程里的命令不用改，但新写的命令一律用 `bootstrap.ps1`。

它读 `tools\components.json` 那份 21 项清单，按依赖顺序装/补：环境（WebView2、node、ffmpeg、uv、Python）
加上 AstrBot、SnowLuma（或 NapCat）、Breeze、Ollama、bili-whale、启动脚本。默认装 16 项；
`embedding-model`、`bili-bridge-plugin`、`soulx-singer`、`dsh-pet`、`edge-tts` 这几项要显式加
`-IncludeOptional` 才装。可以重复跑，已经有的会跳过。慢的是下模型和 python 包装，先说清「在下什么、多大」。
`answers.json` 不是装组件用的——那是第 3 步自设定的答卷。

## 第 3 步：自设定（八块）

工作台「照顾她」页那些开关和「自设定」按钮，背后都是同一个脚本：

```powershell
$program = powershell -NoProfile -ExecutionPolicy Bypass -File "<这个 skill>\scripts\resolve-program-root.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$program\tools\self-setup.ps1" -Base "<工作区>" -Only <块>
```

八块顺序：`provider`（DeepSeek/模型）→ `platform`（QQ 平台、白名单）→ `chat`（回复方式等 13 项）
→ `plugins`（10 个插件开关）→ `memory`（记忆接哪）→ `voice`（语音路线）→ `persona`（人设写入并切换）
→ `verify`（自检）。`-DryRun` 只说不做；`-Only` 只跑一块。

输出协议：`##STEP` / `##OK` / `##FAIL` / `##RESULT ok= done= fail= why= next=`。
日志落在 `<工作区>\logs\self-setup.log`，失败时**先读最后几行**，`why=` 就是给人看的原因。

「照顾她 → 她会做的事」那一栏开关的另一半在 `private\`：写 `features.txt`（`astrbot_plugin_dafeiyu_sing=1` 这种）、
`memory-mode.txt`（0 关 / 1 本机 / 2 硅基流动）、`voice-mode.txt`（0 关 / 1 Edge / 3 豆包 / 4 本机 Breeze / 5 在线 Breeze），
再跑 `-Only plugins`（记忆改 `memory`，语音改 `plugins,voice`）。

## 第 4 步：按症状修

需要部署本地唱歌、切换豆包云端与 SoulX、处理唱歌服务启动或显卡兼容问题时，读
[references/本地唱歌.md](references/本地唱歌.md)。工作台「照顾她 → 她会做的事」里每个功能后面都有「配置」，
唱歌（豆包云端 / SoulX 本地）、桌宠、豆包语音、在线 Breeze 各一页，可保存唱歌方式、服务目录、语音凭据和桌宠互通设置。
密钥保存在本机，不要要求用户把它们发进聊天。

先把「哪一块」对齐现实，再动手。以下都是踩过的：

- **自设定说「后台没连上」，但后台明明在跑**：九成是**机器人根算错了**。工作台把 `-Base` 传的是
  settings 里的 `base`；它如果在「工作区的上一级」，脚本就会去上一级的 `private\backend.txt` 找登录信息，
  找不到就报这一句。去 `<工作区>` 里确认有 `private\backend.txt`，然后核对
  `%APPDATA%\MinglingWorkbench\settings.json` 或 `...\snapshot\settings.json` 的 `base` 必须 == `workspace` == 机器人根。
- **桌面快捷方式叫「冥零工作台（快照）」，自设定永远找不到脚本**：那是以前的快照通道
  （`%LOCALAPPDATA%\Programs\MinglingWorkbench-snapshot\`，里面只有 exe，没有 `tools\`、也没有
  `pack\`）。V3 起正式版只走正式通道 `%LOCALAPPDATA%\Programs\MinglingWorkbench\`，让他装正式版
  安装包；从快照版转正式版要重装一次，配置不自动迁移。临时要用，就让他用指向工作区
  `bin\MinglingWorkbench.exe` 的快捷方式。
- **日志页说「日志是空的：服务可能还没启动过」，但服务在跑**：日志要看
  `bots\AstrBot\data\run.log`（组件生成的 `start.cmd` 就是往这写）和 `bots\SnowLuma\snowluma-run.log`。
  工作台日志页读的是 `bots\AstrBot\run.log` —— 老布局（`AstrBot\run.log`、`SnowLuma\` 直接在工作区根）
  才和它重合，所以新装的机器上日志页可能看不到东西，直接开这两个文件看更准。
- **她记不住事**：先看 `bots\AstrBot\data\plugins\astrbot_plugin_livingmemory\` 在不在，再看
  `bots\AstrBot\data\config\astrbot_plugin_livingmemory_config.json` 有没有写出来；
  `memory-mode.txt` 是 1 就要有 Ollama + bge-m3（`ollama list` 里有 `bge-m3`）。
- **她不说话/答得慢**：`private\deepseek-key.txt` 的 key 还有没有钱；AstrBot 6185 通不通。
- **她听不见语音、也看不懂视频里说什么**：`bots\asr\` 有没有模型，`sidecar\ffmpeg\bin\ffmpeg.exe` 在不在
  （老机器上 ffmpeg 也可能在 `bots\ffmpeg\bin\`、`bots\bili-whale\bin\`）。
- **换个角色**：直接编辑 `plugin\mingling_skill\persona\mingling.md` 的完整正文（默认是公孙冥零，与主人是死党），
  再跑 `powershell -File "$program\tools\import-mingling.ps1" -Base "<工作区>"`（「照顾她」→「导入冥零人设」是同一件事）。
- **换个声音**：本机 Breeze 用 `pack\mingling-pack\voice\` 里那几条参考音；在线 Breeze 要密钥和音色 ID，
  按字扣积分，先跟他讲清楚再开。
- **让她看视频**：看视频的插件（`astrbot_plugin_dafeiyu_video`）在配置包里默认就是开的，
  只要 `bots\AstrBot\data\plugins\` 里有它、AstrBot 后台里它是启用状态，就能看。
  如果是想**关掉**（省钱），在 `private\features.txt` 里加一行 `astrbot_plugin_dafeiyu_video=0`，
  再跑一次 `-Only plugins`；这文件里写的开关会盖过配置包的默认值。
  单个视频能不能看，去「做过的事」页看任务。

## 第 5 步：搬、备份、还原、卸

- 备份：`powershell -File "$program\tools\backup.ps1"`（「照顾她」→「备份到桌面」同一个）。
- 体检/求助信息：`tools\diag.ps1`，报告存桌面，能直接发给人看。
- 搬云服务器：Windows 云主机（不支持 macOS），先把工作区整个搬过去，再跑第 2 步和第 3 步；
  账号类（QQ 登录）要在新机器上重新扫码。
- 卸载：**先问要不要备份**，再删安装目录 + 工作区。开机自启不是脚本能一键摘掉的——
  `tools\autostart.ps1` 是给 `common.ps1` 用的函数库，没有 `-Remove` 开关，也没有命令行入口。
  真正要清的是 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` 下这几个快捷方式：
  `大肥鱼-AstrBot.lnk`、`大肥鱼-SnowLuma.lnk`（或 `大肥鱼-NapCat.lnk`）、`大肥鱼-掉线提醒.lnk`、
  `启动Breeze语音.lnk`、`Ollama.lnk`。让他自己删，或者你代删前先问一句。
  用户回「确认」才删。

## 收尾：让工作台认这份 skill

工作台的「检查更新」和「照顾她」靠两个文件认识这份 skill：

- `<程序目录>\tools\skill-home.txt` —— 这个 skill 装在哪（一行绝对路径）
- `<程序目录>\tools\skill-version.json` —— 装的是哪一版（`version.json` 的拷贝）

跑一次就行（更新 skill 之后也要重跑）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<这个 skill>\scripts\finish.ps1" -Dir "<工作区>"
```

## 规矩

- 只读不改的活（体检、看日志、报错定位）先做完再问要不要修。
- 动 `private\`、`bots\AstrBot\data\` 之前，先把要动的文件复制到 `<工作区>\旧版\MMdd-HHmm-<名字>\`。
- 不要 `cat bots\AstrBot\data\plugins.json`——那是插件市场目录缓存，几十万 token。
- 装完、修完，都跑一遍第 0 步 probe，把 `##结论` 念给他听。
