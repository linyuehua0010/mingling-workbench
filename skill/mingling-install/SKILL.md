---
name: mingling-install
description: 在 Windows 10/11 上装、修、搬、卸「冥零工作台」（MinglingWorkbench V3，C++ 工作台 + bots 组件 + pack 配置包）：一键自动配置装齐 AstrBot、SnowLuma/NapCat、uv、ffmpeg、Ollama、Breeze，跑八块自设定（模型、平台、聊天、插件、记忆、语音、人设、自检），换人设换声音、让她看视频、搬去云服务器、备份还原、卸干净、看不懂的报错先体检。用户说「装冥零」「冥零工作台起不来」「自设定没成」「她记不住事」「换个声音」「换成我自己的角色」「她看不见视频」「搬到服务器上」「备份/还原/卸载冥零」「工作台日志是空的」「更新页说没找到安装」时使用。
---

# 帮人装、修、搬、卸冥零工作台（skill 0.1.0，2026-11-07）

你在帮一个可能完全不懂电脑的人，在**他自己的 Windows 电脑**上把「冥零工作台」装好、修好，
或者搬去云服务器。整套东西是：

```
<工作区>（= 机器人根，一个文件夹，装哪由他挑）
├─ bin\MinglingWorkbench.exe      工作台本体（C++，一个窗口管全部）
├─ win32\ build.bat 的源码        只有开发机上才有
├─ tools\                         脚本：self-setup.ps1、auto-setup.ps1、diag.ps1、backup.ps1……
├─ pack\mingling-pack\            配置包：pack.json、plugins\、voice\
├─ bots\                          组件都在这（不是散在工作区根！）
│   ├─ uv\bin\astrbot.exe         AstrBot 的 python 运行环境 + 入口
│   ├─ AstrBot\                   大脑；日志 bots\AstrBot\run.log；端口 6199
│   ├─ SnowLuma\node.exe          登 QQ 的程序；日志 bots\SnowLuma\snowluma-run.log；端口 5099
│   ├─ ffmpeg\bin\ffmpeg.exe      看视频、语音用
│   ├─ asr\                       本机语音识别模型
│   ├─ Ollama\ + ollama-models\   本机记忆用的 bge-m3；端口 11434
│   └─ Breeze\                    本机 Breeze 语音；端口 8137
├─ private\                       凭据：backend.txt、deepseek-key.txt、features.txt、voice-mode.txt……
├─ answers.json                   一键自动配置的答卷（base_url、memory、voice、video、路径）
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

安装包在 `https://github.com/linyuehua0010/mingling-workbench/releases`，名字是
`MinglingWorkbench-<版本>-setup.exe`（约 50 MB，已经内含 bots\ 组件和 pack\，不用另外下）。

1. 问他装哪个盘，默认「不是 C 盘、空间够的那个」。工作区就是装完后的那个文件夹。
2. 安装时**不要**把工作区设成安装目录的上一级；工作区本身就是机器人根。
3. 装完先跑第 0 步的 probe 确认「工作台 / 工作区 / 组件」三行都不是「没找到」。

> 只拿到源码的情形：源码树里的 `bin\MinglingWorkbench.exe` 可以直接跑（工作区就是源码目录）；
> 重编译在 `win32\` 下 `cmd /c build.bat`，产物会拷到 `..\bin\`。**关掉窗口再编**，否则
> `COPY FAILED: ... is locked`。exe 是 GUI 子系统，命令行里要用
> `Start-Process .\bin\MinglingWorkbench.exe -ArgumentList @("--her-op","<动作>") -Wait`，
> 结果写在 `<工作区>\logs\her-op.txt`。

## 第 2 步：一键自动配置（装齐 bots）

工作台「维护页 → 一键自动配置」做的事，命令行等价：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<工作区>\tools\auto-setup.ps1" -Workspace "<工作区>" -Bots "<工作区>\bots" -Base "<工作区>"
```

它按 `answers.json` 装/补 uv、AstrBot、SnowLuma（或 NapCat）、ffmpeg、asr、Ollama、Breeze。
可以重复跑，已经有的会跳过。慢的是下模型和 python 包装，先说清「在下什么、多大」。

## 第 3 步：自设定（八块）

工作台功能页那些开关、维护页「自设定」按钮，背后都是同一个脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<工作区>\tools\self-setup.ps1" -Base "<工作区>" -Only <块>
```

八块顺序：`provider`（DeepSeek/模型）→ `platform`（QQ 平台、白名单）→ `chat`（回复方式等 13 项）
→ `plugins`（10 个插件开关）→ `memory`（记忆接哪）→ `voice`（语音路线）→ `persona`（人设写入并切换）
→ `verify`（自检）。`-DryRun` 只说不做；`-Only` 只跑一块。

输出协议：`##STEP` / `##OK` / `##FAIL` / `##RESULT ok= done= fail= why= next=`。
日志落在 `<工作区>\logs\self-setup.log`，失败时**先读最后几行**，`why=` 就是给人看的原因。

功能页那六个开关的另一半在 `private\`：写 `features.txt`（`astrbot_plugin_dafeiyu_sing=1` 这种）、
`memory-mode.txt`（0 关 / 1 本机 / 2 硅基流动）、`voice-mode.txt`（0 关 / 1 Edge / 3 豆包 / 4 本机 Breeze / 5 在线 Breeze），
再跑 `-Only plugins`（记忆改 `memory`，语音改 `plugins,voice`）。

## 第 4 步：按症状修

先把「哪一块」对齐现实，再动手。以下都是踩过的：

- **自设定说「后台没连上」，但后台明明在跑**：九成是**机器人根算错了**。工作台把 `-Base` 传的是
  settings 里的 `base`；它如果在「工作区的上一级」，脚本就会去上一级的 `private\backend.txt` 找登录信息，
  找不到就报这一句。去 `<工作区>` 里确认有 `private\backend.txt`，然后核对
  `%APPDATA%\MinglingWorkbench\settings.json` 或 `...\snapshot\settings.json` 的 `base` 必须 == `workspace` == 机器人根。
- **从桌面「冥零工作台（快照）」快捷方式启动，自设定永远找不到脚本**：那个快捷方式指向
  `%LOCALAPPDATA%\Programs\MinglingWorkbench-snapshot\`，那里没有 `tools\`、也没有 `pack\`。
  让他用指向工作区 `bin\MinglingWorkbench.exe` 的那个快捷方式。
- **日志页说「日志是空的：服务可能还没启动过」，但服务在跑**：日志要看
  `bots\AstrBot\run.log`、`bots\SnowLuma\snowluma-run.log`（老布局才在 `AstrBot\`、`SnowLuma\` 下）。
- **她记不住事**：先看 `bots\AstrBot\data\plugins\astrbot_plugin_livingmemory\` 在不在，再看
  `bots\AstrBot\data\config\astrbot_plugin_livingmemory_config.json` 有没有写出来；
  `memory-mode.txt` 是 1 就要有 Ollama + bge-m3（`ollama list` 里有 `bge-m3`）。
- **她不说话/答得慢**：`private\deepseek-key.txt` 的 key 还有没有钱；AstrBot 6185 通不通。
- **她听不见语音、也看不懂视频里说什么**：`bots\asr\` 有没有模型，`bots\ffmpeg\bin\ffmpeg.exe` 在不在。
- **换个角色**：改 `plugin\mingling_skill\persona\mingling.md` 里 `{user_persona}` / `{user_tone}` 两段，
  再跑 `powershell -File "<工作区>\tools\import-mingling.ps1" -Base "<工作区>"`（维护页「导入冥零人设」是同一件事）。
- **换个声音**：本机 Breeze 用 `pack\mingling-pack\voice\` 里那几条参考音；在线 Breeze 要密钥和音色 ID，
  按字扣积分，先跟他讲清楚再开。
- **让她看视频**：`video-mode.txt=1`，再 `-Only plugins`；单个视频能不能看，去「队列」页看任务。

## 第 5 步：搬、备份、还原、卸

- 备份：`powershell -File "<工作区>\tools\backup.ps1"`（维护页「备份到桌面」同一个）。
- 体检/求助信息：`tools\diag.ps1`，报告存桌面，能直接发给人看。
- 搬云服务器：Windows 云主机（不支持 macOS），先把工作区整个搬过去，再跑第 2 步和第 3 步；
  账号类（QQ 登录）要在新机器上重新扫码。
- 卸载：**先问要不要备份**，再删安装目录 + 工作区；开机自启项用 `tools\autostart.ps1 -Remove`。
  用户回「确认」才删。

## 收尾：让工作台认这份 skill

工作台的更新页/维护页靠两个文件认识这份 skill：

- `<工作区>\tools\skill-home.txt` —— 这个 skill 装在哪（一行绝对路径）
- `<工作区>\tools\skill-version.json` —— 装的是哪一版（`version.json` 的拷贝）

跑一次就行（更新 skill 之后也要重跑）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<这个 skill>\scripts\finish.ps1" -Dir "<工作区>"
```

## 规矩

- 只读不改的活（体检、看日志、报错定位）先做完再问要不要修。
- 动 `private\`、`bots\AstrBot\data\` 之前，先把要动的文件复制到 `<工作区>\旧版\MMdd-HHmm-<名字>\`。
- 不要 `cat bots\AstrBot\data\plugins.json`——那是插件市场目录缓存，几十万 token。
- 装完、修完，都跑一遍第 0 步 probe，把 `##结论` 念给他听。
