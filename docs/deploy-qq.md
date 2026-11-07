# 在一台新电脑上部署 QQ 机器人

目标：Windows 10/11 x64 上，用 **SnowLuma 登录 QQ**、**AstrBot 当大脑**，让工作台能一键起停，
让群里的 @ 有回应。全程不需要旧平台、不需要预装 Python/Node（AstrBot 自己会带）。

最终会长成这样：

```
D:\bot\                        <- 工作台设置里的 base（机器人根）
├── SnowLuma\                  登录 QQ 的程序（自带 node.exe）
│   └── node.exe
├── astrbot\                    AstrBot 的数据目录（data\、run.log）
│   └── data\
├── private\
│   └── snowluma-webui.txt     SnowLuma 的 WebUI 密码（工作台启动时读它）
└── (可选) uv\bin\astrbot.exe  工作台优先找这个启动器
```

工作区可以另放，例如 `E:\冥零工作区`。工作台里 `workspace` 和 `base` 是分开的两个设置。

---

## 1. 装 AstrBot

AstrBot 4.x 用 uv 分发，一条命令装好：

```powershell
winget install --id astral-sh.uv -e
# 或者：irm https://astral.sh/uv/install.ps1 | iex
```

关掉终端重开，然后：

```powershell
uv tool install astrbot
astrbot --version
```

`astrbot.exe` 一般在 `%USERPROFILE%\.local\bin`（uv 会把它加进 PATH）。
工作台起服务时会按这个顺序找启动器：

1. `<base>\uv\bin\astrbot.exe`
2. `<base>\uv\Scripts\astrbot.exe`
3. `<base>\astrbot\astrbot.exe`
4. PATH 里的 `astrbot.exe`

所以用 `uv tool install` 就够了，不用手工搬。

建数据目录并跑第一次：

```powershell
mkdir D:\bot\astrbot
cd D:\bot\astrbot
astrbot run
```

看到 Dashboard 地址后先别关。浏览器打开 `http://127.0.0.1:6185`，
默认账号 `astrbot` / 密码 `astrbot`，第一次登录会要求改密码。

> 工作台启动 AstrBot 时的工作目录就是 `<base>\astrbot`，参数是 `run`。
> 所以 `data\`、`run.log` 都会落在这里，日志页读的也是这个 `run.log`。

---

## 2. 装 SnowLuma 并登录 QQ

1. 从 SnowLuma 的 release 页下载 Windows x64 压缩包，解压到 `D:\bot\SnowLuma`。
2. 双击 `launcher.bat`（或 `node.exe index.mjs`）启动。第一次会让你扫码登录 QQ，
   建议用一个不常用的小号。
3. 打开 `http://127.0.0.1:5099`，设置 WebUI 密码。
   工作台会用这个密码启动 WebUI，所以把它写进：

   ```
   D:\bot\private\snowluma-webui.txt
   ```

   文件里只放密码一行，不要有引号或多余空格。
4. 登录成功后，SnowLuma 的 `config\onebot.json` 里会出现这个 QQ 的配置。
   下一步把它的 OneBot 连接指向 AstrBot。

---

## 3. 把 SnowLuma 接到 AstrBot（aiocqhttp 反向 WS）

### 3.1 AstrBot 这边

Dashboard → 配置 → 平台 → 新增平台：

| 字段 | 值 |
| --- | --- |
| 类型 | `aiocqhttp` |
| ID | 随便起，例如 `qq`（白名单里会用到） |
| 启用 | 开 |
| 反向 WS Host | `127.0.0.1` |
| 反向 WS 端口 | `6199` |
| Token | 自己生成一串，例如 `openssl rand -hex 16`，两边必须一致 |

保存后 AstrBot 会监听 `ws://127.0.0.1:6199/ws`。

### 3.2 SnowLuma 这边

WebUI → OneBot 11 → WS 客户端 → 新增：

| 字段 | 值 |
| --- | --- |
| 名称 | `astrbot` |
| URL | `ws://127.0.0.1:6199/ws` |
| Access Token | 与上一步相同 |
| 消息格式 | `array` |
| 角色 | `Universal` |
| 重连间隔 | `5000` ms |

保存后看 AstrBot 日志出现 `aiocqhttp` 连接成功、SnowLuma 日志出现 `pipe connected` 就通了。

### 3.3 端口一览

| 端口 | 谁在听 | 用途 |
| --- | --- | --- |
| `5099` | SnowLuma | WebUI（只绑 127.0.0.1） |
| `6199` | AstrBot | aiocqhttp 反向 WS（SnowLuma 连进来） |
| `6185` | AstrBot | Dashboard |

工作台判断「服务在不在」就是探 `5099` / `6199` 这两个端口；F10 停止时也是按端口找进程。

---

## 4. 白名单与 @ 触发

AstrBot → 配置 → 平台设置：

- `enable_id_white_list`：打开。只有名单里的会话会被回复。
- `id_whitelist`：每条格式是

  ```
  <平台ID>:GroupMessage:<群号>
  <平台ID>:FriendMessage:<QQ号>
  ```

  例如 `qq:GroupMessage:1071366691`、`qq:FriendMessage:123456789`。
  平台 ID 就是 3.1 里填的那个 ID。
- `wl_ignore_admin_on_group` / `wl_ignore_admin_on_friend`：管理员是否绕过白名单，按需开。

@ 触发：

- 群里默认要 **@机器人** 才会回；想加前缀唤醒，把 `wake_prefix` 设成 `["/"]`，
  这样 `/帮助` 也能唤醒。
- 私聊默认不需要唤醒词（`friend_message_needs_wake_prefix = false`）。
- 不想让它抢话，把 `ignore_at_all` 打开（@全体成员 不响应）。

---

## 5. 启动顺序

1. 先 AstrBot（它要先在 6199 上听）。
2. 再 SnowLuma（它是 WS 客户端，连不上会每 5 秒重连）。

工作台 F9「全起」会先起 SnowLuma 再起 AstrBot；因为 SnowLuma 会自动重连，
最终状态一样。F10「全停」按端口收进程。日常最省事的顺序是：

```
打开工作台 → F9 → 等两个灯都变绿 → 群里 @ 试一句
```

开机自启：维护页「修开机自启」会把 AstrBot / SnowLuma / 掉线提醒写进启动文件夹；
也可以在维护页的「掉线提醒」里选择通知频率。

---

## 6. 让工作台认得这套目录

编辑 `%APPDATA%\MinglingWorkbench\settings.json`：

```json
{
  "workspace": "E:\\冥零工作区",
  "base": "D:\\bot"
}
```

或者：工作台 → B 站页底部「换工作区」只改 workspace；`base` 目前写在设置文件里。
改完重开工作台，总览页的两个服务卡应该能显示端口状态，点「启动」能把它们拉起来。

验证：

```bat
MinglingWorkbench.exe --paths
```

确认 `机器人根` 是 `D:\bot`，`SnowLuma 日志`、`AstrBot 日志` 指向 `D:\bot\...`。

---

## 7. 常见问题

| 症状 | 查什么 |
| --- | --- |
| AstrBot 起不来，日志空白 | `D:\bot\astrbot\run.log`；确认 `astrbot.exe` 在 PATH 或 `<base>\uv\bin` |
| SnowLuma 起来但 AstrBot 收不到消息 | 6199 端口是否在听；两边 Token 是否一致；SnowLuma 的 WS 客户端是否启用 |
| 群里 @ 没反应 | 白名单格式；平台 ID 是否写对；`ignore_at_all`；是否被 `wake_prefix` 拦了 |
| 私聊有反应、群里没有 | 群号没进 `id_whitelist`，或群里没 @ |
| 工作台显示服务在线但机器人不回 | 日志页看 AstrBot；多半是模型 Key 或余额问题（维护页 DeepSeek 卡） |
| 掉线后不提醒 | 维护页「掉线提醒」是否开着；SnowLuma 通知配置 |
| 换 QQ 号 | SnowLuma 里退出重登；AstrBot 不用改，平台 ID 和 Token 不变 |

QQ 相关排错只碰三样：**端口、Token、白名单**。三样都对还不行，再看 AstrBot 的
`data\cmd_config.json` 里 `platform` 段是不是真的写进去了。
