# SnowLuma 是怎么工作的

这份文档讲的是 SnowLuma 的运作原理，以及它为什么和你见过的那些「QQ 协议库」不一样。
装、接、排错的步骤在 [deploy-qq.md](deploy-qq.md)，这里只讲机制和配置细节。

本文所有结论都对着本机 `bots/SnowLuma/` 的实体文件和真实运行日志核过，不是照抄上游介绍。

---

## 1. 一句话

**SnowLuma 不实现 QQ 协议，也不模拟一个 QQ 客户端。**
它让本机真正的桌面 QQ 正常登录，然后往那个已经登录的 QQ 进程**里**装一段自己的代码，
从进程内部把会话拿过来，再在外面用 **OneBot 11** 讲给 AstrBot 听。

这个路线决定了它的全部性格，包括它的优点和它的死穴：

| | Hook 路线（SnowLuma） | 协议路线（常见的协议库 / NapCat 的自实现部分） |
| --- | --- | --- |
| 登录方式 | 桌面 QQ 自己登，SnowLuma 只搭便车 | 自己发包，模拟一次登录 |
| 需要的凭据 | 你没有凭据要保管，登录态在 QQ 进程里 | 要自己处理登录票据、设备指纹、风控 |
| QQ 一升级 | **可能挂不上**，要等 SnowLuma 跟上 | 通常不受影响，但风控变了要自己跟 |
| 账号安全面 | 用的是官方客户端的真实会话 | 全看实现方怎么伪装 |
| 硬前提 | **本机必须装着桌面 QQ，且那个号已经登录** | 只需要能上网 |

第二条和第五行是排错时最要紧的：QQ 没开、没登、或者刚自动升级过，SnowLuma 起来的再正常也没会话。

---

## 2. 启动时到底发生了什么

对着 `bots/SnowLuma/logs/snowluma-<日期>.log` 看，一次成功的启动是这样一串（本机 11-10 那份日志的原文顺序）：

```
[App] SnowLuma starting
[App] Node integrity: pid=32960, process=High (RID=12288); EXE=unlabeled
[App] hook auto-load enabled: every discovered QQ process will be injected
[WebUI] login rate-limit keyed by: socket peer (default)
[WebUI] EULA/PRIVACY consent supplied by SNOWLUMA_ACCEPT_EULA and SNOWLUMA_ACCEPT_PRIVACY (agreements version=dcb31a7b03a0b64d)
[WebUI] listening http://127.0.0.1:5099
[Hook] initial connection started: PID=7624 timeoutMs=60000
[Bridge] session started: UIN=3259570870
OK [Hook] login detected: PID=7624 UIN=3259570870
[Hook] pipe connected: PID=7624
[QQHook.Runtime] Client private-message reporting is available: PID=7624
[SysFace] system face catalog restored: entries=403 uniqueFaces=367 overlaps=36 packs=11
[Bridge] friends loaded: UIN=3259570870 count=9
[Bridge] self info: UIN=3259570870 nickname=小零不熬夜
[Bridge] groups loaded: UIN=3259570870 count=3
[Bridge.Contacts] loaded robot UIN ranges uin=3259570870 version=206 count=5
[Bridge] member warmup completed: groups=3/3 members=34 failed=0
[OneBot] session started: UIN=3259570870
[OneBot] network startup applied: UIN=3259570870 adapters=1
[OneBot.WS-Client] [astrbot] connected ws://127.0.0.1:6199/ws
[OneBot] rkeys loaded: UIN=3259570870 count=2
[OneBot.HistorySync] login history sync selected: UIN=3259570870 scanned=3/8 selected=0/1
```

按段拆开：

1. **`[App]` 前两行** —— 起 Node 自己，然后自检。
   `process=High (RID=12288)` 说的是当前进程的完整性级别是「高」，`EXE=unlabeled` 说的是这个 exe 没有 AppLocker 之类的标签。
   这一行不是炫耀，是它自己判定「我有没有权限往别人的进程里装 DLL」的依据；降级了会变成 `WARN`。
2. **`[App] hook auto-load enabled`** —— 自动挂载开着（`SNOWLUMA_HOOK_AUTOLOAD=1`）。
   意思是**之后发现的每一个** QQ 进程都会被挂上，不只是启动那一刻已经开着的那个。你启动 SnowLuma 之后再开 QQ 也能挂上。
3. **`[WebUI]` 四行** —— 网页后台就绪。
   同意记录从环境变量来、还是在等你点、限流按什么维度算，这三件事都在这里交代清楚。
   `listening http://127.0.0.1:5099` 是最后一行，**到这一步 WebUI 就能开了，但一个号都还没挂上**。
4. **`[Hook] initial connection started: PID=7624 timeoutMs=60000`** —— 它认出了一个 QQ 主进程（PID 7624），
   开始建立内部连接，给 60 秒。
5. **`[Bridge] session started` → `OK [Hook] login detected`** —— 连接通了，并且从进程里读到了登录态和 UIN。
   这一行的时间点**就是**桌面 QQ 登录的时刻；如果 QQ 是早就登好的，那它出现在 SnowLuma 启动后一两秒内。
6. **`[Hook] pipe connected`** —— 管道打通，从此双向说话。
7. **`[SysFace]` / `[Bridge] friends loaded` / `groups loaded` / `[Bridge.Contacts]` / `member warmup`** ——
   灌数据：表情目录、好友、群、成员。`member warmup completed: groups=3/3 members=34 failed=0` 是预热全部群成员，
   群多的时候这段会明显变长。
8. **`[OneBot] session started` → `network startup applied: adapters=1`** —— 开始按 OneBot 配置拉起网络端点。
9. **`[OneBot.WS-Client] [astrbot] connected ws://127.0.0.1:6199/ws`** —— **这一行才是 AstrBot 收到连接**。
   前面全绿但卡在这里，说明 AstrBot 没起或 Token 不对。
10. **`[OneBot.HistorySync]`** —— 登录历史补齐（下面 §7 单独讲）。

反过来的正常噪音，看到了别慌：

| 日志 | 意思 |
| --- | --- |
| `WARN [Hook] process enumeration timed out after 4000ms; keeping prior process set` | 枚举 QQ 进程超时，沿用上一次的结果。不是致命错误，重新开一次 QQ 通常就好 |
| `[Hook] PID=N already has SnowLuma pipe; will reconnect` | 那个 QQ 进程本来就挂着它的管道，直接重连，不是重复注入 |
| `[Hook] awaiting login: PID=N` | 进程找到了，但那个 QQ 还没登录 |
| `[OneBot.WS-Client] [astrbot] error … connect ECONNREFUSED 127.0.0.1:6199` | AstrBot 还没起（或没在 6199 上听），每 5 秒重试一次，属正常 |
| `[MsgPush.Unknown] Event0x210 unknown subType=382` | 上游推来一种它还不想处理的事件类型，记一笔就过去了 |
| `[Hook] load failed: PID=N err=component loading failed [COMPONENT_LOAD_FAILED]` | 真的失败，多半是 QQ 刚升级、内部结构变了 |

---

## 3. 注入到底做了什么

这部分是 `/` 里的实现，从 `index.mjs` 直接读出来的，不是猜的。

平台分派很直白：

- Windows：可注入体是 **DLL**（`platformInjectableExt()` 返回 `"dll"`），目标进程名是 `QQ.exe`；
- macOS：DYLD 插入模型；
- Linux：另有 zygote/renderer 过滤。

Windows 侧的注入是这一句：

```js
{ method: "loadModuleManual", handle: await addon.loadModuleManualAsync(pid, dllPath) }
```

`dllPath` 就是 `bots/SnowLuma/native/snowluma-win32-x64.dll`（472576 字节）。
`loadModuleManualAsync` 干的事是**在目标进程里 LoadLibrary 我们的 DLL** —— 让它自己把我们的模块加载进去，
不是 `WriteProcessMemory` 硬改别人的代码，也不是打补丁。对应的卸载是 `unloadModuleManualAsync`，
UI 上「进程注入」页的「卸载」按钮走的就是它。

注入之后，两边靠**命名管道**说话，名字是 mojo 风格的：

```
\\.\pipe\mojo.<pid>.control
\\.\pipe\mojo.<pid>.recv
```

只有这两条：`control` 双向下命令，`recv` 单向收事件。
管道名里带 PID，所以同时挂两个 QQ 进程不会串。

一个细节值得知道：判断「那个进程还挂着吗」用的是一次 **250 毫秒**的探测（`DEFAULT_PIPE_PROBE_TIMEOUT_MS = 250`），
而且**不真的打开管道**，只连一下。因为第一次真正打开管道的客户端会占住它，探测要是抢了，后面就接不上了。

每个 QQ 进程对应一个 `HookSession`，它自己的注释写得很清楚：
「owns the lifecycle of one QQ.exe process: injection, pipe client, login state, and the public status field」。
一个会话的三种起步方式在日志里是 `hook_session_branch … branch=existing_pipe|inject_begin|inject_completed`，
`method` 记的是 `reconnect` 或 `loadModuleManual`。

---

## 4. 它是怎么认出「真正登录的那个 QQ」的

这个地方很容易做错。QQ 不是一个进程，它是一堆进程（主进程、渲染进程、各种 helper）。
往渲染进程里装 hook 会把 QQ 的 IPC 和登录界面搞坏 —— Linux 侧代码里那句注释就是这么写的：
往 zygote 注入会让每个 renderer 继承 hook 线程，结果整个 QQ 都不对劲。

Windows 侧的做法挺巧：**按 QQ 的数据库文件句柄反查持有者进程**。
也就是问系统「`nt_msg.db`（会话库）这个文件现在被谁开着」，答案就是那个真正登录着的 QQ 主进程。
实现是 native addon 的 `getFileHoldersAsync` → `getWindowsHolders(dbPath)`，外面包成 `listHookProcesses()`。

所以「检测到 N 个可加载 QQ 进程」这个数字是**真的登录中的 QQ**，不是随便枚举出来的 `QQ.exe`。

---

## 5. 登录态是怎么判定的

不是看窗口标题，也不是猜。进程通过管道回一个状态帧，`applyLoginStateFrame(frame)` 里这么判：

```js
PipeFlagLoggedIn = 4      // 这一位表示已登录
PipeFlagWantReply = 1     // 这一位表示这帧要回执
loggedIn = (frame.flags & PipeFlagLoggedIn) !== 0 || frame.status !== 0
```

登录了就把 UIN 从 `frame.value0`（BigInt）或 `frame.msg` 里取出来。

之后靠 **QQ 自己的心跳**维持：`receive health armed by QQ heartbeat: PID=N UIN=…`。
心跳没了就按超时逐级降级，几个常量：

| 常量 | 值 | 干什么的 |
| --- | --- | --- |
| `INITIAL_CONNECTION_TIMEOUT_MS` | 60000 | 首次连上给多久（日志里的 `timeoutMs=60000`） |
| `ACK_TIMEOUT_MS` | 90000 | 命令回执等多久 |
| `RECEIVE_STALE_CONFIRM_MS` | 15000 | 多久没消息就把它当可疑 |
| `DEFAULT_REPLY_TIMEOUT_MS` | 30000 | 一般调用等回包的上限 |
| `SESSION_RELEASE_DEADLINE_MS` | — | 会话释放的截止线 |

---

## 6. 从 QQ 会话到 OneBot 11

雪露玛对外只说 OneBot 11。`index.mjs` 里注册了 **146 个 action**，覆盖面比一般实现宽得多，大致分四类：

- **消息**：`send_private_msg` / `send_group_msg` / `send_msg` / `delete_msg` / `get_msg` / 转发（`send_forward_msg`、`upload_forward_msg`）/ 合并转发 / 各类已读标记；
- **联系人**：`get_friend_list` / `get_group_list` / `get_group_info_ex` / `get_stranger_info` / `get_recent_contact` / 好友分组与备注；
- **群管理**：`set_group_add_request` / `set_essence_msg` / `set_group_reaction` / `set_group_anonymous` / 群标签 / 群文件；
- **扩展**：一大堆 Qzone（`get_qzone_feeds`、`send_qzone_msg`、`comment_qzone`…）、`flash_file`、`fileset`、`get_cookies` / `get_csrf_token` / `get_clientkey` 这类凭据接口、`set_qq_profile` / `set_self_longnick` / `set_online_status`。

配置是**按 QQ 号分文件**的：

| 文件 | 作用 |
| --- | --- |
| `config/onebot.json` | 全局模板。新号第一次登录时照它生成自己那份 |
| `config/onebot_<号>.json` | 那个号自己的配置 |

生成的这份里有个 `mode` 字段：

- `"overlay"` —— 和全局配置叠加；
- `"snapshot"` —— 独立快照，不跟全局走（本机小号 3259570870 那份就是 snapshot）。

默认模板里的两个网络端点是：`http-default`（127.0.0.1:3000）、`ws-default`（127.0.0.1:3001），
`accessToken` 每次随机生成 32 字节的 base64url，`messageFormat` 是 `array`（标准 OneBot 段），`reportSelfMessage` 是 `false`。

接 AstrBot 时要用的是 **wsClients**（SnowLuma 当客户端去连 AstrBot 的 6199），
不是上面那两个默认 endpoint —— 默认模板里 `wsClients` 是空数组，得在 WebUI 里加一条。
本机小号那份长这样：

```json
{
  "mode": "snapshot",
  "networks": {
    "wsClients": [{
      "name": "astrbot",
      "url": "ws://127.0.0.1:6199/ws",
      "role": "Universal",
      "accessToken": "…",
      "messageFormat": "array",
      "reportSelfMessage": false,
      "reconnectIntervalMs": 5000
    }]
  },
  "statusCommand": { "enabled": true, "swallow": false, "cooldownSeconds": 5, "trigger": "#sl" },
  "historySync": { "enabled": true }
}
```

---

## 7. 内置的状态命令与历史补齐

**状态命令**（`statusCommand`）：默认开着，触发词 `#sl`，冷却 5 秒，`swallow: false`。
发 `#sl` 会回一条这个号的版本、平台、运行时长。两个开关值得注意：

- `swallow: true` —— 命中的 `#sl` **不再往下游投递**，AstrBot 收不到这条消息（但仍会回复、仍会本地记录）。默认是透传。
- `cooldownSeconds` 设成 0 表示不限制。上限一年（`STATUS_COMMAND_COOLDOWN_MAX = 31536000`），用来当「关掉但值合法」。

**历史补齐**（`historySync`）：只在**登录那一刻**跑一次，把上次断线期间的消息补进本地库，好让 AstrBot 拿到上下文。
它的预算很小，是故意的：

| 参数 | 值 |
| --- | --- |
| 启动延迟 | 30 秒（等上游先稳住） |
| 扫描范围 | 群 100 / 私聊 100 |
| 实际处理 | **最多 3 个群 + 3 个好友** |
| 每个会话 | 最多 20 条 |
| 两次请求间隔 | 至少 2 秒 |

它**只静默写入本地消息库**，不重放历史事件、也不改 QQ 的已读状态。
日志里 `selected=0/1` 这种「扫到 3 个、选中 0 个群」很常见 —— 因为没读过的会话才需要补。

---

## 8. 文件地图

```
bots/SnowLuma/
  node.exe                93 MB，Node v24.22.1（engines 要求 ^24.22.1 || >=26.12.1）
  index.mjs               12 MB，单文件 bundle，无任何 runtime npm 依赖
  launcher.bat            先 check-node-version.cjs 再 index.mjs
  check-node-version.cjs  Node 版本闸门，不满足直接报错退出
  package.json            @snowluma/runtime 的清单
  release.json            发布清单（本机是 2.4.0 / win32-x64 / 9 个 entry）
  EULA.md / PRIVACY.md    协议原文
  start.cmd               components.json 生成的启动脚本
  client/                 Vite 打包的 WebUI（index.html + assets/）
  native/
    snowluma-win32-x64.dll        472 KB —— 注入 QQ 的那个 DLL
    snowluma-win32-x64.node       359 KB —— Node 侧的注入器
    websocket-win32-x64.node      163 KB
    ffmpeg/ffmpegAddon.win32.x64.node   6.8 MB —— 语音/视频转码
    sqlite/prebuilds/             本地消息库
  config/
    consent.json        EULA/隐私同意记录
    runtime.json        WebUI 端口、日志策略、hookAutoLoad
    webui.json          WebUI 密码（scrypt hash + salt，不是明文）
    ui.json             外观（主题、强调色、侧栏行为）
    onebot.json         全局 OneBot 模板
    onebot_<号>.json    每个号自己的 OneBot 配置
    notifications.json  通知渠道
  data/
    sys-face-catalog.json     系统表情目录（176 KB）
    <号>/messages.db 等       消息库、reaction 库、identity 库
  logs/
    snowluma-YYYY-MM-DD.log   每天一个，本机留 7 天
```

`native/` 里没有任何 `node_modules` —— `package.json` 的 description 明写了所有 native binding 都是
`dist/native/*.node`，用 `process.dlopen()` / `createRequire()` 加载，**production 包是自包含的**。
这就是为什么它能整包扔进 `bots/SnowLuma/` 直接跑。

---

## 9. WebUI 各页在管什么

地址 `http://127.0.0.1:5099`，只绑本机。五个页面：

### 总览

可拖拽的卡片面板：主机资源（CPU/内存/本进程）、在线会话、协议端点连接状态、最近告警、便签、链接。
「检测到 N 个可加载 QQ 进程」的入口也在这里（→ 进程注入）。

### 进程注入

这一页就是 §3 的手动版。每个 QQ 进程一行：名称、状态（可加载 / 加载中 / 等待连接 / 等待登录 / 已在线 / 错误 / 已断开）、操作。

- 「加载」→ 往那个 PID 装 DLL；
- 「卸载」→ 卸 DLL（会提示「可能导致当前会话断开」，因为它真会断）；
- 「刷新」→ 重新枚举进程。

开了 `SNOWLUMA_HOOK_AUTOLOAD=1` 的话通常不用手动点，这一页是给「自动挂载没生效」时兜底用的。

### 账号配置

左边是账号列表，右边三块：

1. **在线连接 / 通知渠道** —— 这个号上下线往哪些渠道推。渠道是全局定义的，这里只是勾选。
2. **登录历史补齐** —— 对应 §7 的 `historySync.enabled`。文案已写明「下次账号登录或重启后生效」。
3. **内置状态命令** —— 触发词、是否 swallow、冷却秒数。

### 节点配置（OneBot）

这张表是接 AstrBot 的地方。四类节点：

| 类型 | 方向 | 用途 |
| --- | --- | --- |
| HTTP 服务端 | 本地监听 | 别人 POST 过来调它 |
| HTTP 客户端 | 主动 POST | 往远端 URL 推事件 |
| WebSocket 服务端 | 本地监听 | 别人连进来（可复用 HTTP 端口与 Token，可开 SSE `/_events`） |
| WebSocket 客户端 | 主动连接 | **接 AstrBot 用的就是这个** |

每条的字段：名称、鉴权 Token（≥16 字符，留空会关鉴权，只建议本机用）、消息格式（`array` 标准 / `string` 兼容）、角色（收发合一 Universal / 收发分离）、上报自身消息、事件上报开关。

### 日志

实时 SSE 推送。三档预设（开发 = 全部级别 2000 行 / 运维 = INFO 以上 1000 行 / 精简 = 仅 WARN+ERROR 500 行）、
关键词高亮规则、导出当前视图、导出完整 TRACE、清空视图。
**「开启 TRACE」要谨慎**：它会产生极大量可能未脱敏的数据，只适合小规模复现问题。
注意文件日志等级由环境变量决定（默认 `debug`），网页上调的是控制台/实时流那一档。

### 系统设置

主题（跟随系统/浅色/深色）、强调色、无障碍（减弱动效、关闭全部动效）、修改访问密码、双重验证（2FA，含恢复码）、
通知渠道（邮件 / 钉钉群机器人）、账号状态通知。

---

## 10. WebUI 密码与协议同意

这两件事只在**第一次**发生一次，之后改文件不再生效，所以值得单独说。

### 密码

`config/webui.json` 里存的是 scrypt 的 hash + salt（`N=16384, r=8, p=1, keylen=64`），不是明文。

第一次启动时如果 `SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD` 有值且长度 ≥ 8，就用它 seed；
否则随机生成一个，只打在启动终端里。seed 成功时日志有一行
`webui credentials seeded from SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD`。

密码规则（`PASSWORD_RULES`）四条全过才算强密码：**≥10 位、含小写、含大写、含特殊符号、不含空格**。
WebUI 里改密码时它会实时算强度、并且先做一次「演练」。

之后要改密码只有两条路：登进 WebUI 改，或者删掉 `webui.json` 让它重新 seed。

### 协议同意

`SNOWLUMA_ACCEPT_EULA` / `SNOWLUMA_ACCEPT_PRIVACY` 的**合法值只有 `1` / `true` / `0` / `false`**（大小写无关），
**写别的值会直接抛错退出**，比如写 `=yes` 起不来。

同意记录落在 `config/consent.json`：

```json
{ "version": "dcb31a7b03a0b64d", "acceptedAt": "2026-11-06T07:47:52.749Z" }
```

那个 `version` 是协议文本的摘要。**上游更新协议后这个值会变，你的旧同意就失效了**，
WebUI 会重新卡在 `awaiting EULA/PRIVACY consent before the panel unlocks` —— 这时只能人工点同意，环境变量也救不了（除非你同步更新它认可的版本）。

---

## 11. 环境变量

一共 37 个，按用途分组（`components.json` 生成的 `start.cmd` 只设了最关键的三个 + 密码）：

| 组 | 变量 |
| --- | --- |
| 同意 / 开发 | `SNOWLUMA_ACCEPT_EULA` `SNOWLUMA_ACCEPT_PRIVACY` `SNOWLUMA_DEV_MODE` `SNOWLUMA_DEV_NO_NATIVE` `SNOWLUMA_DEV_WEBUI` |
| Hook | `SNOWLUMA_HOOK_AUTOLOAD` `SNOWLUMA_HOOK_AUTOLOAD_ALL` `SNOWLUMA_HOOK_RUNTIME_DIR` `SNOWLUMA_HOOK_ACK_TIMEOUT_MS` |
| WebUI | `SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD` `SNOWLUMA_WEBUI_HOST` `SNOWLUMA_WEBUI_PORT` `SNOWLUMA_WEBUI_TARGET` `SNOWLUMA_WEBUI_TLS` `SNOWLUMA_WEBUI_TRUST_PROXY` |
| 日志 | `SNOWLUMA_LOG_DIR` `SNOWLUMA_LOG_FILE` `SNOWLUMA_LOG_LEVEL` `SNOWLUMA_LOG_FILE_LEVEL` `SNOWLUMA_LOG_MAX_MB` `SNOWLUMA_LOG_MAX_TOTAL_MB` `SNOWLUMA_LOG_RETAIN_DAYS` `SNOWLUMA_LOG_PER_UIN` `SNOWLUMA_TRACE_BUFFER` |
| OneBot | `SNOWLUMA_ONEBOT_HTTP_PORT` `SNOWLUMA_ONEBOT_WS_PORT` `SNOWLUMA_PACKET_TIMEOUT_MS` `SNOWLUMA_SESSION_RELEASE_DEADLINE_MS` |
| 下载 / 通知 | `SNOWLUMA_HTTP_DOWNLOAD_TIMEOUT_MS` `SNOWLUMA_DOWNLOAD_FILE_TIMEOUT_MS` `SNOWLUMA_MAX_BINARY_DOWNLOAD_BYTES` `SNOWLUMA_NOTIFICATION_HTTP_TIMEOUT_MS` `SNOWLUMA_STREAM_DIR` |
| 更新 / 其他 | `SNOWLUMA_UPDATE_CHECK` `SNOWLUMA_UPDATE_ROOT` `SNOWLUMA_VERBOSE_WARMUP` |

`SNOWLUMA_WEBUI_TRUST_PROXY=1` 会警告：只有在真的放在反向代理后面时才安全，否则限流按 `socket peer` 算的那套就失效了。

`SNOWLUMA_DEV_MODE=1` 时有个固定开发密码 `snowluma-dev`，正常运行别开。

---

## 12. 日志

- 目录：默认 `logs/`（相对工作目录），可用 `SNOWLUMA_LOG_DIR` 改；
- 文件名：`snowluma-YYYY-MM-DD.log`，同一天超限转成 `.1` `.2`；
- 单文件上限默认 50 MB，总量默认 1024 MB，留存天数读 `runtime.json` 的 `logRetainDays`（本机 7 天）；
- `SNOWLUMA_LOG_PER_UIN=1` 时还会按号分文件，前缀是 `[3259570870]`。

所以「日志是空的」通常是找错目录了：QQ 那边的日志在 `bots/SnowLuma/logs/`，AstrBot 的在 `bots/AstrBot/run.log`。

---

## 13. 和工作台、AstrBot 怎么接

```
桌面 QQ（真客户端，人工登录）
      │  ← native/snowluma-win32-x64.dll 被 LoadLibrary 进去
      │  ← 双命名管道 \\.\pipe\mojo.<pid>.control / .recv
      ▼
SnowLuma（node.exe index.mjs）
      ├─ WebUI  http://127.0.0.1:5099
      └─ OneBot ws 客户端 ──► ws://127.0.0.1:6199/ws
                                      │
                                AstrBot（aiocqhttp 反向 WS 在听 6199）
                                      │
                                 DeepSeek 等模型 → 回到 QQ
```

端口的完整表：

| 端口 | 谁在听 | 用途 |
| --- | --- | --- |
| 5099 | SnowLuma | WebUI，只绑 127.0.0.1 |
| 6199 | AstrBot | aiocqhttp 反向 WS（SnowLuma 连进来） |
| 6185 | AstrBot | Dashboard / Web 后台 |
| 8137 | Breeze | 本机语音 |
| 11434 | Ollama | 本机模型 |

工作台判断「登录端在不在」就是探 5099（SnowLuma）或 6099（NapCat），
判断「QQ 真的登上了没」则是另一套：`tools/verify-manual.ps1 -Kind qq` 去 AstrBot 的 6199 上看
有没有**已建立**的 TCP 连接、且对端进程落在 `bots/SnowLuma/` 或 `bots/NapCat/` 下。
**软件装好 ≠ 登录完成**，扫码这一步只能人来。

工作台自己起服务时**不走 `start.cmd`**，是直接 `SpawnDetached(node.exe, "index.mjs", cwd, env, LogPath(0))` 并把
同样几个环境变量传进进程（见 `win32/src/ui_pages.inc` 的 StartService 分支）。两边要一致，改一个记得看另一个。

---

## 14. 版本、安装包与授权

### 本机是 2.4.0，清单钉的是 2.4.2

`tools/components.json` 的 `snowluma` 组件钉的是 **2.4.2**（`SnowLuma-v2.4.2-win-x64.zip`，
43361462 字节，sha256 `0912926c…bad81a`），而本机 `bots/SnowLuma/` 实际是 **2.4.0**
（`release.json` 与 `package.json` 都写着 2.4.0）。

这是**故意留着没动**的：重装要重下 43 MB、要重启登录端、小号还得重新扫码。
新装的机器拿到的会是 2.4.2；已经跑起来的这台继续用 2.4.0。两者在本文描述的机制上没有差别。

### 安装包要不要联网

默认**要**。安装包本身不含 SnowLuma，装完由 `tools/bootstrap.ps1` 按 `components.json` 下载到
`<工作区>\bots\SnowLuma\`，校验 sha256 后解压。

出包时加上 `-BundleSnowLuma` 开关（`installer/build-installer.bat -BundleSnowLuma`），
那一版安装包会把官方原版 zip 打进去（落在 `{app}\pack\snowluma\`），
安装时 `bootstrap.ps1` 认出 `pack/snowluma/` 里有校验通过的包就直接用、不联网。
两种情况下**解压出来的东西一模一样**，都是上游原版，一字节没改。

### 授权

SnowLuma 的 EULA 第 5.4 条明文要求：「将其并入第三方安装包或 Docker 镜像、通过自动化脚本部署」
须**事先取得著作权人的书面授权**。所以内置通道是**显式构建开关、默认关闭**的，
`docs/THIRD-PARTY.md` 里有完整说明，`installer/prepare-snowluma.ps1` 每次跑都会再打印一次提示。
谁打开这个开关，谁负责去确认授权。细节看 [THIRD-PARTY.md](THIRD-PARTY.md)。

---

## 15. 排查：按现象查

| 现象 | 先查 |
| --- | --- |
| WebUI 能开，但没会话 | 桌面 QQ 装了没、登了没；日志里有没有 `login detected` |
| 有 `[Hook] awaiting login` | QQ 进程在，但那个号没登录 |
| `load failed … COMPONENT_LOAD_FAILED` | QQ 刚自动升级，SnowLuma 还没跟上；换 NapCat 或等上游更新 |
| `process enumeration timed out after 4000ms` | 进程枚举超时，不是致命错误；重开 QQ |
| 反复 `already has SnowLuma pipe; will reconnect` | 正常重连 |
| WebUI 卡在同意页 | `consent.json` 的 version 和它认的对不上了（上游更新过协议），人工点同意 |
| WebUI 密码怎么输都不对 | `private/snowluma-webui.txt` 里写了 `password=` 前缀或多行；或者 `webui.json` 已经 seed 过、改文件无效 |
| 起不来、立刻退出 | `SNOWLUMA_ACCEPT_EULA` / `ACCEPT_PRIVACY` 写了非法值（只收 1/true/0/false） |
| AstrBot 那边没连上 | 6199 在不在听；两边 Token 是否一致；`onebot_<号>.json` 里那条 wsClient 是否 enabled |
| 群里 @ 没反应、私聊正常 | 白名单格式、群号有没有进 `id_whitelist`、`ignore_at_all` |
| 想临时关掉 `#sl` 回复 | WebUI → 账号配置 → 内置状态命令，关掉或改触发词 |

排错三件套：**端口、Token、白名单**。

---

## 16. 几个常见误解

**「SnowLuma 登了我的 QQ，所以我的密码给它了。」**
不是。它拿不到密码，也不参与登录。密码只在桌面 QQ 里输入，SnowLuma 是在登录**之后**从进程里取会话。

**「装了 SnowLuma 就能不开 QQ 挂机器人。」**
不行。要么让桌面 QQ 开着并登录，要么换 NapCat 那条自登路线（`private/protocol.txt` 里改）。

**「它的 WebUI 端口是 5099，那 OneBot 也在 5099。」**
不是。5099 是网页后台；OneBot 的端点是 `onebot_<号>.json` 里那几条，接 AstrBot 用 wsClients。

**「日志里一堆 WARN，是不是坏了。」**
`process enumeration timed out`、`ECONNREFUSED 6199`（AstrBot 没起时）、`Event0x210 unknown subType` 都是正常噪音。
真正要看的是 `login detected` 有没有、`pipe connected` 有没有、`connected ws://` 有没有。

**「换台机器把 bots/SnowLuma 复制过去就行。」**
目录可以复制，但 `config/webui.json` 里是旧密码、`data/<号>/` 是旧会话、扩展名绑定的是 win32-x64。
新机器建议走一键装（`bootstrap.ps1`），它会把该重下的重下、该重新 seed 的重新 seed。
