# 在一台新电脑上部署 QQ 机器人

目标：Windows 10/11 x64 上，**AstrBot 当大脑**、QQ 那边接进来，让工作台能一键起停，
让群里的 @ 有回应。全程不需要预装 Python/Node，也不用自己下载解压任何组件。

从 V3.1.0 起，装组件只有一套实现（V3.2.0 沿用，没改）：

- 清单：`tools/components.json` —— 每个组件都写清了怎么检测、从哪下、怎么校验、怎么装、怎么验证。
- 引擎：`tools/bootstrap.ps1` —— 按依赖拓扑排序，逐个「检测 → 安装 → 验证」，可重复跑。
- 所有组件统一装到 `<工作区>\bots\<名字>\`，不再平铺在机器人根下面。老的平铺布局仍然认（工作台
  按「`<组件根>\<名字>` → 老位置」的顺序找），但新装一律走 bots。

---

## 1. 一键装

### 1.1 图形入口

工作台 → 照顾她页 →「组件与操作」分区 →「一键自动配置」。它跑三段，进度显示在页面顶部那行小字里：

1. **补环境**：`-Component webview2,node,ffmpeg,python`（都在 `bootstrap.ps1` 里跑，幂等）；
2. **装组件**：`-Component uv,astrbot,breeze,ollama,bili-whale,bots-launchers`，外加清单里跟 QQ 对接有关的几项（id 见 `tools/components.json`）；
3. **自设定**：拿 `pack\mingling-pack\pack.json` 把 DeepSeek、QQ 平台、聊天、插件、记忆、语音、人设配成冥零。

前两段是同一个 `bootstrap.ps1`，第三段是 `tools/self-setup.ps1`。命令行的等价入口：

```bat
MinglingWorkbench.exe --autosetup      :: 只补环境
MinglingWorkbench.exe --bots-setup     :: 只装组件 + 启动脚本
```

### 1.2 直接跑脚本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 `
  -Base "D:\冥零工作区" -Workspace "D:\冥零工作区" -Bots "D:\冥零工作区\bots"
```

常用开关：

| 想干什么 | 加什么 |
| --- | --- |
| 只补某几个组件 | `-Component astrbot,breeze`（依赖会自动带上） |
| 只检测、什么都不改 | `-Check`（不下载、不解压、不建 `dl`/`tmp`） |
| 只用本地缓存、不联网 | `-Offline`（只吃 `logs\setup\dl` 里 sha256 对得上的那份） |
| 连可选组件一起装 | `-IncludeOptional`（本机嵌入模型、SoulX、桌宠、Edge 语音等） |
| 已满足也重装 | `-Force` |
| 走代理 | `-Proxy http://127.0.0.1:7890` |
| 换个日志落点 | `-LogFile "D:\...\my.log"` |

完整参数表见 [setup-automation.md](setup-automation.md)。出口约定：退出码 0 = 齐，2 = 有缺项，
1 = 脚本自身出错；stdout 里有 `##STEP` / `##OK` / `##FAIL <id>|<原因>` / `##RESULT ok=<0|1> ...`
四类协议行，工作台就是照 `##RESULT ok=1` 且没有 `##FAIL` 判断成没成。

每次跑完的状态在 `<Base>\logs\setup\state.json`（哪个组件到位、哪个缺、为什么），同目录还有
`bootstrap-<时间>.log`。日志、协议行、state.json 都过一层脱敏：`sk-…`、`token=`、`password=`、
`QQ号/UIN` 都会打成 `***`，不会把密钥写进日志。

### 1.3 关于「安装包要不要联网」

默认**要联网**：组件是在装的时候按 `tools/components.json` 从上游发布页下的（走清单里配的镜像，
`gh.dpik.top` / `gh-proxy` 那几个，逐个试，最后才直连）。

只有一种情况不下载：程序目录里已经有对得上的文件。出包时显式加了
`installer\build-installer.bat -BundleLogin` 的那一版 `setup.exe` 会把组件包一起带进来，
装到 `{程序目录}\pack\<组件id>\`（内置版的产物名带后缀 `-login`，比默认那份大，两种产物
分两个文件、不会互相覆盖）；`bootstrap.ps1` 会先算它的 sha256，对得上就直接用、不联网，
对不上照样回退去下载。

这套「装包自带优先」的机制对所有组件都成立，不只某一份。装好的程序目录里
只要有对应文件、sha256 和 `components.json` 对得上，`bootstrap.ps1` 就直接用，不下载也不联网，
`-Offline` 下同样有效。哈希按清单判定，不看文件名。

---

## 2. 组件清单

清单在 `tools/components.json`。`default_install=false` 的是「可选且默认不装」，
要 `-IncludeOptional` 才会选进来。

| id | 是什么 | 版本 | 默认装 |
| --- | --- | --- | --- |
| `webview2` | WebView2 运行时（界面靠它） | 156.0.4314.58 | 是 |
| `node` | Node.js 运行时 | 22.14.0 | 是 |
| `ffmpeg` | ffmpeg（视频/音频） | autobuild-2026-11-08-12-35 | 是 |
| `uv` | uv（装 AstrBot 用） | 0.13.7 | 是 |
| `python` | Python 3.12（AstrBot 的固定解释器） | 3.12.16+20261026 | 是 |
| `astrbot` | AstrBot（大脑） | 4.29.4 | 是 |
| `bots-launchers` | `bots\start-all.cmd` 一键全起 | bundled | 是 |
| `qq-login` | QQ 人工登录态 | manual | 是（人工） |
| `deepseek-provider` | 模型 API Key | manual | 是（人工） |
| `memory-plugin` | 长期记忆插件 LivingMemory | 固定 commit | 是（人工确认） |
| `breeze` | Breeze 本地语音 | 0.1.7 | 是（可选） |
| `ollama` | Ollama 客户端 | 0.40.15 | 是（可选） |
| `ollama-service` | Ollama 本机服务 | 0.40.15 | 是（可选） |
| `bili-whale` | B 站侧车 | 0.4.6 | 是（可选） |
| `bili-login` | B 站人工登录态 | manual | 是（可选/人工） |
| `bili-bridge-plugin` | bili_bridge 插件 | bundled | 否（可选） |
| `embedding-model` | 本机嵌入模型 bge-m3 | bge-m3 | 否（可选） |
| `soulx-singer` | SoulX 本地唱歌服务 | manual | 否（可选/人工） |
| `dsh-pet` | DSH 桌宠联动 | manual | 否（可选/人工） |
| `edge-tts` | Edge 语音依赖 | edge-tts 7.3.1 / pyffmpeg 2.5.2.3.2 | 否（可选） |

装完 `<工作区>\bots\` 长这样：

```
bots\
  AstrBot\      bin\astrbot.exe / env.cmd / start.cmd / data\ / tools\ / python\
  Breeze\       start.cmd / models\ / voices\
  Ollama\       ollama.exe / models\
  bili-whale\   package.json / bin\
  start-all.cmd 一键全起（Ollama → Breeze → AstrBot，每个间隔 6 秒）
```

两个例外，默认不装在 bots 里：`uv` 落 `<Base>\uv\bin\uv.exe`，`node` 和 `ffmpeg` 落
`<Base>\sidecar\`（`MINGLING_SIDECAR` 可以改 sidecar 的位置）。AstrBot 用的 Python 在
`<组件根>\AstrBot\python`，是固定解释器，不用系统那个。

AstrBot 的启动器是 `<组件根>\AstrBot\bin\astrbot.exe`（uv 工具目录 + 固定 Python 都在它旁边）。
别再手工 `uv tool install astrbot`：那会装到 `%USERPROFILE%\.local` 去，工作台的检测和日志都跟
不到它。

---

## 3. 端口

| 端口 | 谁在听 | 用途 |
| --- | --- | --- |
| `6199` | AstrBot | aiocqhttp 反向 WS（QQ 侧连进来） |
| `6185` | AstrBot | Dashboard / Web 后台 |
| `8137` | Breeze | 本机语音 |
| `11434` | Ollama | 本机模型服务 |

工作台判断「服务在不在」就是探上面几个里该听的；F10 停止时也是按端口找进程。
AstrBot 那两个端口写在 `data\cmd_config.json` 的 `platform` 段里，改过就按改过的算。

---

## 4. 接到 AstrBot

这一步**不用手工点**。自设定第 2 块（`tools\self-setup.ps1 -Only platform`）会按 `pack.json` 的
`platform` 段建平台：

| 字段 | 值 |
| --- | --- |
| id | `冥零` |
| type | `aiocqhttp` |
| 反向 WS Host | `127.0.0.1` |
| 反向 WS 端口 | `6199` |
| Token | `private\napcat-ws-token.txt` 的内容（没有就现生成 16 位写进去） |

后台里已经有一个 `aiocqhttp` 平台就沿用它（不重建、不改名）；有多个又没有叫「冥零」的，它不猜，
直接报错让你先删干净的。

QQ 那边要开一个 OneBot 11 反向 WS 客户端，把地址指向 `ws://127.0.0.1:6199/ws`，Token 与
`private\napcat-ws-token.txt` 一致，消息格式 `array`，重连间隔 5000 毫秒。它连上以后 AstrBot 日志里
有 `aiocqhttp` 连接成功。

想确认到底通没通，别靠眼睛看：组件清单里的 `qq-login` 就是这么判的——AstrBot 的 OneBot 端口上
有没有**已建立**的 TCP 连接，且连接那一端的进程路径落在 `<工作区>\bots\` 下的 QQ 组件目录里。
两个条件都满足才算「登录完成」。软件装好不等于登录完成。

---

## 5. 白名单与 @ 触发

自设定第 2 块顺带把白名单补齐（并集，原有条目一条不删）：

- `enable_id_white_list` 打开；
- `id_whitelist` 里加 `<平台id>:FriendMessage:<主人QQ>` 和每一条 `<平台id>:GroupMessage:<群号>`；
- 主人 QQ 写 `<base>\private\owner-qq.txt`，群号写 `<base>\private\group.txt`（一行一个）；
- `wl_ignore_admin_on_group` / `wl_ignore_admin_on_friend` 默认都是 false；
- 主人 QQ 同时被加进 `admins_id`。

@ 触发这块没有额外配置：群里要 **@机器人** 才会回，私聊默认不用唤醒词。嫌它抢话就打开
`ignore_at_all`（@全体成员 不响应）。

---

## 6. 启动顺序

1. 先起 AstrBot（它要先在 6199 上听）；
2. 再起 QQ 侧（它是 WS 客户端，连不上会每 5 秒重连）；
3. 桌面 QQ 什么时候登都行。

工作台 F9「全起」**不跑** `start-all.cmd`：它按顺序起 QQ 侧和 AstrBot
（`bots\AstrBot\bin\astrbot.exe run`），脚本日志在 `<工作区>\logs\`。
`start-all.cmd` 是留给手工/开机自启用的，顺序是 Ollama → Breeze → AstrBot，每个间隔
6 秒，和 F9 不完全一样，但都是自动重连，最终状态一样。F10「全停」按端口收进程。

日常最省事：

```
打开工作台 → 桌面 QQ 登录 → F9 → 等灯都变绿 → 群里 @ 试一句
```

开机自启在照顾她页「组件与操作」分区里的「修开机自启」，掉线提醒在「相处的习惯」分区。

---

## 7. 常见问题

| 症状 | 查什么 |
| --- | --- |
| 一键自动配置卡在下载 | `logs\setup\bootstrap-*.log` 里那条 URL；GitHub 慢就换镜像或加 `-Offline` 用缓存 |
| AstrBot 起不来、日志空白 | `<组件根>\AstrBot\run.log` 和 `data\run.log`；<br>`bin\astrbot.exe` 是否在，`env.cmd` 里的 UV 目录是否指对 |
| QQ 那边一直没会话 | 桌面 QQ 登了没；QQ 侧本身有没有起来（看它自己的日志） |
| 桌面 QQ 升级以后接不上 | 升级会让一部分接入方式失效。先把 `<base>\private\protocol.txt` 改成 `napcat` 换成另一条路；不换也行，等上游跟进 |
| QQ 侧连不上 AstrBot | 6199 在不在听；两边 Token 是否一致；OneBot 11 那条客户端是否 enabled |
| 群里 @ 没反应 | 白名单格式（`<平台id>:GroupMessage:<群号>`）；平台 id 是否写对；`ignore_at_all` |
| 私聊有反应、群里没有 | 群号没进 `id_whitelist`，或群里没 @ |
| 服务都在线但机器人不回 | 日志页看 AstrBot；多半是模型 Key 或余额（照顾她页「DeepSeek · 她的饭」那张卡） |
| 掉了不提醒 | 照顾她页「相处的习惯」里的「掉线提醒」开着没 |
| 换 QQ 号 | QQ 侧退出重登；AstrBot 不用动，平台 id 和 Token 不变 |

排错先看三样：**端口、Token、白名单**。三样都对还不行，再去看
`bots\AstrBot\data\cmd_config.json` 的 `platform` 段是不是真的写进去了，以及
`logs\setup\state.json` 里那个组件为什么标着没到位。
