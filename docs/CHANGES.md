# 变更清单

本文记录每次改版「为什么这么改」，以及改完之后的契约。README 只讲怎么用，这里讲取舍。

---

## 0. V3-snapshot-3：界面重做（内嵌 HTML + 冥零人设）

**选择**：保留 snapshot-2 的 C++ 后端，把七页界面整个换成内嵌 HTML（WebView2 渲染），
并按 `冥零人设.md` 重写文案与视觉——深夜蓝的房间、冰蓝高光、她的立绘和头像、短句与括号动作。

**理由**：

- 人设本身（蓝发、深蓝眼睛、爱睡懒觉、嘴硬心软、QQ 打字腔）和上一版「冷白高调」的办公风对不上；
  只换颜色救不回来，页名、语气、留白、密度都要重来。
- HTML + CSS 改这种「气质」一次到位：布局、渐变、立绘遮罩、动效都能写细；C++ 自绘每调一次都要重编。
- 页面、立绘、头像一起编进 exe，地址走 `https://mingling.local/` 内存资源，不开端口、不落临时文件。

**没选的做法**：

- 不换后端：状态、配置备份、台账、sidecar、体检命令全部沿用 snapshot-2，UI 只消费 JSON。
- 不引前端框架：一个 `index.html` 里的原生 JS，没有构建步骤，`build.bat` 直接编资源。
- 不把原生 UI 删掉：WebView2 Runtime 缺失时仍能退回旧界面（`ui.cpp` 那套还在编）。

**契约定下来**：

- 文案分两层：状态、数字、报错原因照实写（不许为语气吞掉），包在外面的句子用她的口吻；
  页名固定为 总览 / 一起看看 / 做过的事 / 日志 / 哪儿卡了 / 照顾她 / 帮帮忙，`TABS[]` 与文档占位符同源。
- 消息桥只认白名单动作（`tab` / `section` / `action` / `watch` / `configsave` / `asksave` / `feed` …），
  所有动态文本先转义；CSP 禁外链、禁表单提交、禁框架。
- 配置保存只提交改动过的字段，密码框留空 = 保留；状态推送不重建正在编辑的表单。
- 外观检查用临时状态目录 + `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port`，
  不碰真实配置（细节见 [ui-html.md](ui-html.md)）。

> v2 里「不改用 WebView2」那一条（见 §1）是当时的取舍：干净机不保证 Runtime、v2 定位原生自绘。
> 这一版明确改为「分发 WebView2Loader，运行时缺失就提示并退回原生」，所以那条不再适用。

---

## 1. 架构选择：内置 sidecar，而不是重写 C++，也不再依赖 DSH

**选择**：把上游 `dsh-bili-whale` 0.4.6（MIT）作为私有 sidecar 随安装包分发，
用 `sidecar\node\node.exe` 跑，ffmpeg 放在 sidecar 里，工作台只做 UI/编排/台账。

**理由**：

- B 站看片真正的难点是 `wbi` 签名、Cookie 校验、字幕解析、ffmpeg 抽帧与九宫格。
  这些逻辑上游已经稳定，用 C++ 重写会引入大量网络/编码边界问题，
  违背「优先稳定封装」。
- 直接把 DSH 当运行时不可接受：干净机器没有 DSH，DSH 还有自己的 profile、宿主 HTTP、
  更新节奏。sidecar 只依赖 node.exe，node 和 ffmpeg 都能随包分发。
- 上游 CLI 已经是「命令 + 文本输出」的稳定接口，工作台解析文本比解析私有 RPC 更抗升级。
- 许可证是 MIT，允许分发与修改；修改点集中在三个文件，脚本 `tools\patch-sidecar.mjs` 可复现。

**没有选择**：

- 不把 bili-whale 做成 Windows 服务：单用户、按需执行，服务化只会增加权限和生命周期问题。
- 不引入 Python 运行时：node 已经是 sidecar 的唯一依赖，多一个运行时只增加安装包体积和故障面。
- 不改用 WebView2：v2 的定位就是原生自绘，且干净机不保证 WebView2。

## 2. 路径契约

| 内容 | 路径 | 谁写 |
| --- | --- | --- |
| 封面 / 九宫格 / 字幕条 / 原片 / 正文缓存 | `<工作区>\out\<BV>\` | sidecar |
| 中间帧 | `<工作区>\tmp\`（抽完即删） | sidecar |
| 台账 | `<工作区>\logs\jobs.jsonl` | 工作台 / 插件 |
| 单次正文 | `<工作区>\logs\jobs\<BV>-<unix>.txt` | 工作台 / 插件 |
| 工作区与机器人根设置 | `%APPDATA%\MinglingWorkbench\settings.json` | 安装器 / 工作台 |
| bili-whale 配置 | `%APPDATA%\MinglingWorkbench\bili-whale.config.json` | 工作台（从模板复制） |
| 日记 / quota / 作息 | `%APPDATA%\MinglingWorkbench\bili-state\` | sidecar |
| B 站凭据 | `%USERPROFILE%\.bili-ai\credentials.json` | 用户 / 扫码工具 |
| 程序 | `%LOCALAPPDATA%\Programs\MinglingWorkbench\` | 安装器 |

工作台通过环境变量把契约传给 sidecar：`BILI_ROOT`、`BILI_OUT_ROOT`、`BILI_TMP_ROOT`、
`BILI_LOGS_ROOT`、`DSH_HOME`（指向状态目录）、`BILI_WHALE_CONFIG`、`FFMPEG`。
sidecar 的 `DSH_HOME` 变量名保留是为了少改上游代码，但值不再是 `~/.dsh`。

## 3. 插件 ↔ 工作台调用契约

两边都调用同一个 CLI：

```
<sidecar>\node\node.exe <sidecar>\bili-whale\tools\bili.mjs debrief <BV> --grid 3x3
```

- 工作台：`source=console`，`chat=工作台`，正文写 `logs\jobs\<BV>-<unix>.txt`。
- 插件群聊：`source=qq`，`chat=<群号/会话>`。
- 插件 LLM 工具：`source=tool`。
- 失败也写台账：`status=fail` + `error=<错误码>`，不写正文。
- 台账每行 JSON：`{t,bv,title,up,source,chat,status,sink,seconds}`（失败多一个 `error`）。
- 产物目录两边都按 `out\<BV>\` 找，不各写一份。

环境变量与目录发现顺序写进了 [deploy-bili.md](deploy-bili.md)。

## 4. 删除项

### 大肥鱼配置包更新

- `her_actions.cpp`：`LatestPackVersion()`、`FetchUpdates` 的 pack 分支、
  `ParseUpdates` 的 `pack`、`ItemName/ItemWhat/JustVer` 的 pack 分支、
  `SkillUpdate` 里「换配置包」的 PowerShell、`kSkillRepo` 的配置包用途。
- `her_config.cpp`：`Versions()` 读取 `dafeiyu-config-pack\settings\pack.json`。
- 更新页：配置包行、「复制给 Agent 的话」里的配置包文案。

### 桌宠 / 桌宠桥

- `her_status.cpp`：`PetHealth()`、第 9 张桌宠卡、开机自启卡里的 `大肥鱼-桌宠桥.lnk` 行。
- `her_actions.cpp`：`RestartPetbridge()`（端口 26199、`start-petbridge.cmd`）、
  自启修复里的桌宠桥快捷方式、`RunAction` 的 `restart_petbridge`。
- `her_config.cpp` / `her.h`：`PetOn()`、`PetHealth()` 声明。
- `ui_maint.inc`：`MaintOpLabel` 的「重开桌宠桥」、一键动作里的桌宠桥按钮、九卡改八卡。
- `ui_help.inc`：`桌宠连不上` 求助卡、FAQ 里的桌宠字样。
- 维护页、更新页、帮助页、README、日志字符串里不再出现相关入口。

保留：Ollama、记忆、语音、游戏模式、掉线提醒、备份、诊断、更新检查、开机自启。

### 旧平台内容

- README 重写，只描述 v2；删除 v1/pywebview/FastAPI/8801/旧端口/`tools\dfy.py`/迁移对比表。
- 删除 `.venv`、`.venv312`、`.selftest`、`.env`、`tools\__pycache__`、`docs\ui-text-audit.md`。
- 插件删除 `~/.dsh` 探测、`D:\MinglingWorkbench` 硬编码、`D:\\astrbot\data\data_v4.db` 兜底。


## 4.1 交付前补的几处

- `util.cpp`：子进程输出不再落系统 `%TEMP%`，改到 `<状态目录>\run\run-<pid>-<tick>.log`，
  用完即删。原因之一是「临时目录不回收」本来就是禁止项；之二是某些受限环境里
  `%TEMP%` 不可写会让 `--feed`/`--watch` 直接失败（错误码 5）。
- `feed.mjs`（由 `tools/patch-sidecar.mjs` 的 P4 打补丁）：缺凭据时不再抛 Node 栈，
  改打印「还没有登录 B 站：缺 %USERPROFILE%\.bili-ai\credentials.json……」并退出 1。
- `main.cpp`：加 `WM_PRINTCLIENT` 处理，方便截图/打印；`GdiplusStartup` 之后调用
  `SetProcessMitigationPolicy(ProcessExtensionPointDisablePolicy)`，减少第三方
  AppInit/钩子注入带来的崩溃面（对已经注入的 DLL 无效，只是加固）。
- B 站页底部常显「工作区 …」，加「换工作区」；首次启动没有 `settings.json` 时询问一次；
  换工作区时若旧目录有 `out/logs` 会问要不要复制（`MigrateWorkspaceData`）。
- 安装版首次启动时 `RegisterUninstallEntry()` 往 HKCU 写卸载项（名称、版本、图标、
  静默卸载命令）。若机器策略禁止写入，就开始菜单的「卸载」快捷方式兜底。

## 4.2 用户第一次上手时暴露的三处（2026-11-05 晚）

都是「上游按 DSH 宿主写的判定，在工作台里恒为红」这一类问题，已连同界面一起修掉：

- **自检读错配置路径**：`commands/selftest.mjs` 只认 `$DSH_HOME/bili-whale.config.json`，
  而工作台把配置放在 `%APPDATA%\MinglingWorkbench\bili-whale.config.json`（`$BILI_WHALE_CONFIG`），
  于是「体检 → 自检」永远报 `配置文件 —— 没有 …\bili-state\bili-whale.config.json`。
  改为 `process.env.BILI_WHALE_CONFIG || path.join(DSH, 'bili-whale.config.json')`。
- **生物钟恒红**：`commands/deps.mjs` 要求有夜间计划文件，但工作台没有夜间调度器，
  这一项永远 `✗`，还会让 `selftest` 以退出码 1 结束。工作台启动 sidecar 时带上
  `MINGLING_WORKBENCH=1`，`deps` 见此直接输出「工作台按需开看，不跑夜间调度 —— 跳过 ✓」。
  同时 `deps` 以退出码 3 表示「有红项」，`selftest` 以前把它当成「没跑起来」，
  现在会读异常里的 stdout，显示「N 项红」。
- **自检里的 DSH 指引**：`selftest.mjs` 末尾原来让人去侧栏「工作区 → 未分组」找会话、
  给「完全访问」权限——工作台里没有这些概念。改为「B 站能力已经内置在工作台里，
  不用装 DSH、也不用开会话」并指向 B 站页和 `docs\deploy-bili.md`。
- **「重新登」按钮的死提示**：`her_actions.cpp` 的 `Relogin()` 只认 `<base>\tools\relogin.cmd`，
  新装机器没有这个脚本，点「重新登」只会弹「没找到掉线自救工具」。
  现在找不到脚本就退回：必要时先启动 SnowLuma/NapCat，再打开它的后台网页让用户扫码。
- **SnowLuma 明明在跑却报「没开着」**：`her_status.cpp` 只按进程路径判断，
  SnowLuma 用自带的 `node.exe` 启动时会被漏判。现在「进程在」或「5099/6099 在听」都算起来了。


## 4.3 第二次上手暴露的五个问题（2026-11-05 晚）

| 现象 | 根因 | 改法 |
| --- | --- | --- |
| 安装向导的许可协议整段乱码 | `docs\THIRD-PARTY.md` 是无 BOM 的 UTF-8，Inno 按系统 ANSI 读 | 文件加 UTF-8 BOM；同时补了官方 `ChineseSimplified.isl`，向导按钮/提示改成中文 |
| 维护页说「Ollama 没开」「Breeze 没开」，点一键又说「本来就开着」 | 卡片看的是「功能开关」，不是「服务在不在」 | 记忆卡：Ollama 在听就说「Ollama 在跑，但记忆没开」；语音卡：8137 在听就说「Breeze 在跑，但语音没启用」 |
| 连不上 AstrBot 后台（「private\backend.txt 里没有密码」） | `her::Base()` 还是旧布局的 `ExeDir` 往上两级猜；装到 `%LOCALAPPDATA%` 时整个机器人根都猜错，`private\`、`astrbot\`全部找不到 | `her::Base()` 改成跟工作台设置一致的 `BaseDir()`；`ReadKv`/`ReadJson` 兼容 BOM；后台密码在 `backend.txt` 缺省时回退 AstrBot 的 `dashboard.password` |
| 更新页只剩「冥零工作台」一行 | 版本探测只认 `uv\tools\astrbot\...` 与 `SnowLuma\release.json`，机器人根一错就全空；`DistVer` 还会先命中同名的 `astrbot` 包目录（无版本号） | `DistVer` 只认带版本号的 `.dist-info`；机器人根下有限深度兜底找 `astrbot-*.dist-info` / `release.json`；缓存缺项时也补出 AstrBot/SnowLuma/Skill 三行（「没找到」而不是消失） |
| 安装时选的工作区不生效 | 安装器只在 `settings.json` 不存在时才写 | 每次安装都写入选定工作区；向导默认值改成读现有 `settings.json` 的 `workspace` |

工作台自更新：更新页「冥零工作台」一行会读 `settings.json` 的 `repo`（`owner/name`），通过 GitHub Releases 比较版本；没配或还没发布就显示「本机」，不报错。配了以后有新版会给「去 GitHub 下载」按钮。

顺带：维护页卡片正文加了裁剪，长文案不再压到「补上」按钮上；开机自启卡文案缩短到四行以内。

## 5. 已知限制

1. **ffmpeg 是 GPL 构建**：为了省事直接分发 Gyan 的 essentials 构建。安装包因此受 GPL 分发约束，
   已在 `THIRD-PARTY.md` 给出源码与构建来源；需要更宽松许可时可换 LGPL 构建，路径不变。
2. **安装包未签名**：Windows SmartScreen 会提示「未知发布者」。选「更多信息 → 仍要运行」。
   要消除提示需要购买代码签名证书。
3. **每用户安装**：装到 `%LOCALAPPDATA%`，不需要管理员；多用户机器要各装一次。
   没有做 MSI/组策略分发。
4. **凭据仍在上游位置**：`%USERPROFILE%\.bili-ai\credentials.json` 是 bili-whale 的约定，
   工作台和插件共用。没有把 Cookie 搬进 settings.json，避免两处不同步。
5. **工作区切换不搬状态**：换工作区只搬 `out/tmp/logs`（会询问），
   `%APPDATA%` 里的日记/quota 仍属于这台机器。
6. **feed 依赖网络与 Cookie**：Cookie 过期、B 站风控、当天配额用完都会让「今晚看什么」变少或报错，
   工作台只负责把 sidecar 的原话展示出来。
7. **AstrBot 启动器发现是有限枚举**：`<base>\uv\bin`、`<base>\uv\Scripts`、
   `<base>\astrbot`、PATH 里的 `astrbot.exe`。非常规布局需要自己设置 `base` 或用 PATH。
8. **不做自动更新**：更新页只查版本并复制「让 Agent 更新」的话，替换动作交给 Agent。
9. **仅 Windows x64**：MinGW 静态编译，没有 ARM64 构建。
10. **sidecar 里的 `DSH_*` 变量名**保留上游命名，属于内部兼容，不表示依赖 DSH。
11. **卸载项登记靠程序自己写**：安装器进程写 `HKCU\…\Uninstall` 会被部分机器策略拒
    （`code 5`），所以安装包不碰这条键，由程序首次启动补；写不进去时开始菜单的
    「卸载 冥零工作台」仍可用。

## 6. 验证方式

见 [ACCEPTANCE.md](ACCEPTANCE.md)：命令行自检、隔离 USERPROFILE（无 `.dsh`）测试、
安装/卸载实测、台账与产物路径证据、关键词清理结果。


## 7. v2.1 修复（2026-11-06）

1. **服务在跑就是 ok**：记忆卡在 `Ollama 在跑、记忆没开` 时由 `bad` 改判 `ok` 并给 `记忆未开` 的 pill；语音卡同理（`Breeze 在跑` → `ok` + `语音未开`）。`ok` 状态不再挂「要修」的动作。「选了要记忆但插件关着」仍判 `bad`（那才是真要修），「选了但没装上」降为 `warn`。
2. **打游戏模式**：判定从「已登录」扩到「本机真有服务在跑」（`Listening(8137) || Listening(11434)`）；总览页右上角加了入口，三态（开打 / 打完了恢复 / 灰的但点得动，点了弹解释）；`game-mode.json` 新增 `local_voice` / `local_mem`，恢复时只把她真关掉的本机服务拉回来，在线服务不再被误动。按钮新增 `hitWhenDisabled`：灰也能点，点完给原因，不再按了没反应。
3. **密钥文件夹**：`<Base>\secrets`（可用 settings 的 `secrets` 或 `MINGLING_SECRETS` 覆盖），老 `private` 作回退；启动时建目录并写一份 `README.txt`。安装器建这个目录、装 README、卸载时保留并提示。`--paths` 多打一行「密钥目录」。
4. **一键自动配置**：新增 `her_setup.cpp`（Node / ffmpeg 下载解压、Python 可选、工作区与密钥目录、写配置；`mirror_node` / `mirror_ffmpeg` 可换源；Ollama 只提示不静默装）。界面在维护页第二排，另加了 `--autosetup` 命令行入口（进度经 `MINGLING_CLI_OUT` 留证）。
5. **掉线提醒**：工作台自己每 30/60/300 秒探一次（可在维护页切），连续两拍才认掉线，弹托盘气泡并闪烁任务栏；`logs\workbench-watch.json` 落心跳，`Watch()` 合并它，开关开着却没人在查时说明「开关开着，但没人在查」。用户自己关服务后 10 分钟静音，不报假掉线。

踩过的坑（下次改这些文件会再遇到）：

- `installer\mingling.iss` 是 **UTF-8 带 BOM**，编辑工具写回丢掉 BOM 会让 ISCC 按 GBK 解码，`[Tasks]` 里的全角「：」尾字节吃掉后面的引号，报 `Missing closing quote on parameter "GroupDescription"`。存回时确认前三字节是 `EF BB BF`。
- `settings.json` 的读取只认**带引号的字符串值**（`paths.cpp` 的 `ReadSettingsMap`），手写成 `"notify_every": 60`（数字）读不出来，还会在下一次 `SettingSet` 整文件重写时被抹掉。要写就写字符串。
- 跨盘搬文件必须带 `MOVEFILE_COPY_ALLOWED`，否则 `ERROR_NOT_SAME_DEVICE` 且没有任何报错——下载解压全成功却报「没搞到」。
- UI 的 `RootDir()` 是工作区，`her::Base()` 才是 `base`（机器人根）。心跳这类两边都要读的路径用错一个，症状是「永远显示没人在查」。

## 8. 安装包装不上（2026-11-06）

用户报「安装包无法安装」。根因不在 v2.1，而是 `installer\mingling.iss` 里 `ExistingWorkspace` 的老代码：

- 它从 `%APPDATA%\MinglingWorkbench\settings.json` 里找 `workspace`，但把两次**相对偏移**当绝对下标相加（先 `p := Pos(':', Copy(String(raw), p, Length(String(raw))))`，再 `Copy(String(raw), p + q, ...)`）。
- 对真实内容 `{"workspace": "F:/MinglingWorkbench", "base": "F:/"}` 算出来的 workspace 是 `":"`。向导校验目录名，弹「文件夹名不能包含下列任何字符: / : * ? " < > |」，接着 `Failed to proceed to next wizard page; aborting.`，安装就此结束。
- 只要这台机器**装过一次或跑过一次**工作台（settings.json 已存在）就必撞；全新机器没有这个文件、走 `{userdocs}` 回退，所以首发能装、重装必失败——这正是用户遇到的情形。

修法：

- 新增 `JsonStringValue(raw, key)`，全程用绝对下标取字符串值；新增 `LooksLikePath(s)`（`X:\` 或 `X:/` 才认）。
- `ExistingWorkspace` 只用这两个函数；取不到或不像路径就回空串，走 `{userdocs}\冥零工作台`。
- `GetSecretsDir` 同样加固：不像路径就用 `{userdocs}`，`base` 不是盘符就取 workspace 前两位。
- 向导「下一步」加一道校验：不像完整路径就弹「工作区要写成完整路径，例如 D:\MinglingWorkbench。」并留在当前页。

验证（`dist\MinglingWorkbench-2.0.0-setup.exe` 静默装到 `tmp\`，日志 `tmp\final1.log` 等）：

| 场景 | 结果 |
| --- | --- |
| settings.json 已存在（用户场景） | rc=0，`Installation process succeeded`，settings.json 原样 |
| 删掉 settings.json（全新用户） | rc=0，secrets 落在 `Documents\secrets` |
| `/WORKSPACE=D:\MinglingWorkbench\tmp\wsx` | rc=0，`tmp\secrets\README.txt` 生成 |
| 带图标重装 | 4 个 .lnk 全部生成 |

踩过的坑：

- 在 MSYS bash 里跑安装器必须加 `MSYS2_ARG_CONV_EXCL='*'`，否则 `/VERYSILENT` 被当成 POSIX 路径换成 `.../win32-x64/VERYSILENT`，安装器进交互模式弹框卡住，看起来也像「装不上」。
- **本会话里子进程的写权限被限制在工作区**：同一个 8 行 Win32 程序写 `D:\MinglingWorkbench\tmp` 成功，写 `C:\Users\...\AppData\Roaming`、`C:\Users\...\Documents`、`F:\` 根目录一律 `ERROR_ACCESS_DENIED(5)`。原因是沙箱把仓库树打了 **Low 完整性标签**，从树里启动的进程以 Low IL 跑，写不了 Medium 的目录（详见 8.1）。

## 8.1 真正让用户「装不上」的第二道坎：Low 完整性标签（2026-11-06）

修好 `:` 之后用户再装，弹的是另一句：

```
安装程序不能创建目录 "C:\Users\<user>\AppData\Local\Temp\is-1QRB2.tmp"。错误 5: 拒绝访问。
```

原因不在 Inno，也不在 ACL：

```
D:\MinglingWorkbench\dist\MinglingWorkbench-2.0.0-setup.exe   label=0x1000 mask=0x1   ← Low + NO_WRITE_UP
D:\MinglingWorkbench\dist                                      label=0x1000 mask=0x1
bin\MinglingWorkbench.exe                                  label=0x2000 mask=0x1   ← Medium
```

**从 Low 标签的 exe 启动，进程就是 Low IL**，而 `%TEMP%`、`%APPDATA%` 都是 Medium，于是连临时目录都建不出来。原先「安装器写不了 settings.json」的结论也一并作废：那不是 Inno 的毛病，是同一个 Low IL 假象。

处置：

- 现有包已改标签：`icacls "dist\MinglingWorkbench-2.0.0-setup.exe" /setintegritylevel Medium`，现在 `label=0x2000`。
- **每次重建安装包后都要重做这一条**（ISCC 新写出的文件会带上目录的 Low 标签），或者把包拷到桌面再双击（目标目录没有标签，副本就是 Medium）。
- 复验：改标签后用 WMI `Win32_Process.Create` 拉起安装（脱离本会话），`Installation process succeeded`，并且 `%APPDATA%\MinglingWorkbench\settings.json` 真的被写出来了——这条路终于是通的。

---

## 9. 五项新需求的落地（2026-11-06）

需求来自「维护页一键装组件 / 冥零 Skill / 求助页可改字 / 帮助页路径与检测 / 掉线提醒」这一组。方案见 `docs\plan-5-features.md`，这里只记取舍和坑。

### 9.1 先修的是 settings.json 的读写，不是 UI

原来的 `ReadSettingsMap()` 只认 7 个白名单键，`SettingSet()` 又是整文件重写：任何字典（`custom_help_texts`）、任何未知键，在下一次保存时都会静默消失。需求 3/5 都要存「对象」和「新键」，所以先把存储换成**有序键值对 + 值原文**：

- `SettingRaw(key)` / `SettingRawSet(key, jsonValue)`：值按 JSON 原文存取，字符串、对象、数组都行。
- `SettingGet` / `SettingSet` 变成薄壳（一个负责去引号与斜杠归一，一个负责删键或写引号），**未知键原样保留**。
- 自测：写一个对象 + 一个普通键，再删第三个键，重新读文件，对象和别的键都还在（见第 6 节验证方式）。

### 9.2 组件统一到 `<工作区>\bots\`

- `BotRoot()`：`MINGLING_BOTS` → `settings.botRoot` → `<工作区>\bots`；`BotDir(name)` 拼一级目录；`EnsureWorkspaceLayout` 顺手建 `bots`。
- `her::BotPath(name)`：**先看 bots，再回头看老布局**（`astrbot` / `SnowLuma` / `breeze-tts` / `Ollama` 等）。老装法的人不用搬目录，新装法的人只有一份。
- 检测、启动、帮助页路径全部走 `BotPath`，所以「状态检测统一到工作区」和「老用户不炸」是同一件事。

### 9.3 一键配置是两段，不是一段

`AutoSetup()` 本来就有（Node、ffmpeg、Python、工作区、密钥），只差五个组件的下载与配置。做法是把下载丢给 `tools\auto-setup.ps1`，C++ 只负责拉起和读进度：

- `BotsSetup()` 用 `RunCaptureStream` 跑 PowerShell，逐行解析 `##STEP` / `##OK` / `##FAIL` / `##RESULT`，进度直接回 UI 线程。
- `StartAutoSetup()` 先跑 `AutoSetup`（0–50%），再跑 `BotsSetup`（50–100%），两段步骤都进 `logs\setup.log`。
- 判成败看脚本自己的 `##RESULT ok=…`，不看 PowerShell 的退出码（PS 里 `Write-Error` 不改退出码，这点很容易踩）。

### 9.4 求助页改字：卡片要有 id

硬编码的 `AskCard{title,text}` 换成 `AskDef{id,title,text}`，11 张卡各有一个稳定 id（`role` / `voice` / `breeze` 等）。`settings.json` 里：

```json
"custom_help_texts": {
  "role": "换成我自己的角色",
  "role.title": "换成我的角色",
  "voice": "换个更温柔的声音"
}
```

`<id>` 改正文、`<id>.title` 改标题，没写的用默认值。编辑入口是每张卡上的「改文字」按钮，点开是原生多行 `EDIT` 浮层，保存写回。浮层开着时 `UiOnChar` / `UiOnKeyDown` 直接 return，不然按键会漏到页面快捷键上。

### 9.5 掉线提醒：气泡是兜底，横幅才是主路径

- 服务表从 2 个变 3 个（SnowLuma 5099 / AstrBot 6199 / Breeze 8137，Breeze 只在本机语音模式下盯）。
- 文案 `notify_title` / `notify_body`，支持 `{name}` 和 `{time}`；头像 `notify_avatar`，走 GDI+ 转 `HICON` 后 `NIIF_USER | NIIF_LARGE_ICON`。
- **Win11 会把自定义托盘气泡折进通知中心，很多时候干脆不弹**，所以主路径改成主界面右上角的滑入横幅（350ms 进、15s 后出），气泡和 `FlashWindowEx` 只当兜底。
- 同一个服务 10 分钟内只提醒一次，避免每分钟一条；`private\qq-watch-off.txt` 仍然一键静音。

### 9.6 踩到的三个编译坑

- `sal.h` 把 `IN` / `OUT` 定义成空宏，顺手写 `const DWORD IN = 350` 会导致 `HOLD` 未声明这种莫名报错，动画常量改名 `ANIM_IN` / `HOLD_MS` / `ANIM_OUT`。
- MinGW 的 gdiplus 没有 `Font::ToHFont()`，编辑框字体要么用 `CreateFontW` 自己造，要么就别用 `Font`。
- C++ 字符串里 `L"tools\import-mingling.ps1"` 少一个反斜杠会变成 `\i` 未识别转义（只是 warning，但路径真的错了）。

### 9.7 接管已有安装时踩到的两件事（2026-11-06 下午）

**一、`settings.json` 的 `base` 写错，整个「统一到 bots」都是假的**

现场是 `{"workspace": "F:/MinglingWorkbench", "base": "F:/"}`，而机器人实际装在 `D:\`。`BotPath()` 的新旧双查是在 `Base()` 下面找老目录的，`base` 错了就一个都找不到，状态卡会全红。把 `base` 改成 `D:\` 后，`--paths` 立刻能报出 `D:\\astrbot`、`D:\\SnowLuma`、`D:\\breeze-tts`、`D:\\Ollama`，维护页的 AstrBot / SnowLuma / Breeze 三张卡也回到「正常」。

顺带说明 `workspace` 那一条：`D:\MinglingWorkbench` 不存在时，`WorkspaceDir()` 会按设计回落到开发树（`<仓库>`）并把结果写回设置，所以它会自己变，不是 bug。

**二、`auto-setup.ps1` 会写用户级环境变量，测试一次就留一条**

脚本第 370 行附近有两句：

```powershell
[Environment]::SetEnvironmentVariable("MINGLING_BOTS", $Bots, "User")
[Environment]::SetEnvironmentVariable("OLLAMA_MODELS", (Join-Path $Bots "Ollama\models"), "User")
```

这是有意为之（下次启动不用再问路径），但**`OLLAMA_MODELS` 指到哪，Ollama 就只认哪的模型**。早前一次 `-Skip*` 冒烟测试把它指到了 `tmp\ws\bots\Ollama\models`，结果 `ollama list` 会看起来一个模型都没有。收尾时已改回 `D:\\ollama-models`，并删掉测试用的 `MINGLING_BOTS`。

结论：跑 `auto-setup.ps1` 之前先想清楚 `-Bots` 指哪儿；跑完可以用 `--paths` 的「组件根」一行核对。

---

## 9.8 冥零人设导入：四处坑与改法

**一、`-PersonaFile`：模板骨架不能直接导入**

`plugin\mingling_skill\persona\mingling.md` 是**骨架**，`{user_persona}` / `{user_tone}` 没填时会被替换成「（这里还没填：…）」的提示句——直接导入等于把填空提示当人设。所以 `import-mingling.ps1` 加了 `-PersonaFile <md>`：给一份写好的整篇人设就跳过填空，只做占位符替换（`{OWNER_QQ}` 也在内）。这一次用的是 `dafeiyu-config-pack\persona\大肥鱼.md`——它正文就是冥零，只是人设 id 叫“大肥鱼”。

**二、PowerShell 变量名大小写不敏感，参数被脚本自己覆盖**

脚本里原本 `$personaFile = Join-Path …`，而参数叫 `$PersonaFile`——PowerShell 视作**同一个变量**，参数值在第 57 行就被模板路径覆盖，`-PersonaFile` 静默无效。改法：内部变量改名 `$personaPath`。

**三、PS 5.1 的 `Invoke-RestMethod` 中文会变 `??`**

发：字符串 body 默认按 ANSI 编码 → 人设正文全变问号（第一次建出来的人设 id 甚至变成 `??`，只能删掉重建）。
收：服务端没写 charset 时按 ANSI 解码 → `GET /personas/{id}` 读回来的 `persona_id` 是 `??`，跟 `冥零` 比不相等，于是脚本以为人设不存在、反复 POST，报 400「already exists」。

改法：`Send-Json`（`UTF8.GetBytes` + `application/json; charset=utf-8`）与 `Get-Json`（`Invoke-WebRequest` 取 `RawContentStream` 自己按 UTF-8 解）。

**四、`/config-profiles/default` 的 PUT 收的是配置本体**

先 GET 拿 `{data:{config:{…},metadata:{…}}}`，PUT 时要**直接发 `config` 那一层**；套一层 `{config:…}` 会 400 `agent_runner must be an object`。脚本里已改，并保留注释。

**结果**：`personas` 表新增 `冥零`（1659 字，与 `logs\mingling-persona.filled.md` 逐字相同），`agent_runner.config.persona.persona_id` = `冥零`，`platform_settings.id_whitelist` 六条前缀全部改成 `冥零:`；原来的 `大肥鱼` 人设原样保留，随时可切回。导入前的备份在 `astrbot\data\cmd_config.json.bak-*` 与 `data_v4.db.bak-*`。

---

## 9.9 v2.2.0 打包

**版本号三处一起改**（漏一处就出现「关于里 2.2.0、卸载列表里 2.0.0」）：

| 位置 | 字段 |
|------|------|
| `win32\res\app.rc` | `FILEVERSION` / `PRODUCTVERSION` / 字符串表 |
| `win32\src\paths.cpp:399` | `RegisterUninstallEntry` 的 `DisplayName` / `DisplayVersion` |
| `installer\mingling.iss` | `#define AppVer`（`OutFile` 跟着变） |

外加 `installer\mingling.nsi`（老的 NSIS 脚本，留着备用）与 `README.md` 里的产物名。

**新增 `docs\使用说明.md`**：装完第一件事（核对 base / 组件根）、一键配置、人设导入、求助页改字、帮助页路径、掉线提醒文案、`settings.json` 全键表、常见问题、卸载与回滚。安装包会把它复制到 `<安装目录>\docs\`，开始菜单加一条「使用说明」。

**顺手修的两件事**：

- `installer\build-installer.bat` 用的是 **Inno Setup 6**（`tools\innosetup6\app\ISCC.exe`），README 里写成 NSIS 3.10 了，已改。
- `build.bat` 最后一步复制 exe 时，如果工作台正开着会 `The process cannot access the file`——**看着像成功其实没换成**（`[3/3] copy` 后面那行报错容易被刷过去）。打包前先关掉窗口，或用 `Get-Process MinglingWorkbench | Stop-Process`。

**产物**：`dist\MinglingWorkbench-2.2.0-setup.exe`（51,258,334 字节，Inno Setup 6，`Successful compile (28.312 sec)`）。
静默装到 `tmp\inst-test` 验证过：`MinglingWorkbench.exe` FileVersion = `2.2.0.0`，`docs\使用说明.md` 在包里，装好的 exe 跑 `--paths` 六行路径正确、sidecar 找到安装目录下的那一份。

---

## 9.10 版本号收成一个源（SemVer）

**问题**：2.2.0 发版时，版本号散在 `win32\res\app.rc`、`win32\src\paths.cpp`、`installer\mingling.iss` 三处，外加 `README.md` 里手抄的安装包名。少改一处，就会出现「关于里 2.2.0、卸载列表里 2.0.0」这种自相矛盾。

**改法**：

- 新增 `win32\src\version.h`，四个数字（`APP_VERSION_MAJOR/MINOR/PATCH/BUILD`）加派生的窄字符串、宽字符串，是整个工程唯一的版本源。
- 用它替换：`app.rc` 的 `FILEVERSION`/`FileVersion`/`ProductVersion`、侧边栏「工作台 · V2.2.0」（`ui_pages.inc:427`）、帮助页开头（`ui_help.inc:259`）、卸载登记的 `DisplayName`/`DisplayVersion`（`paths.cpp:400`）、窗口标题、`--paths` 第一行，并新增 `--version`。
- `win32\build.bat` 的 windres 加 `-I src`，编译前先跑 `tools\check-version.ps1`：数字和字符串对不上就报错停下，不再产出人造版本。
- `installer\build-installer.bat` 从 `version.h` 生成 `installer\version_auto.iss`（`AppVer` / `AppVerTag`），`mingling.iss` 只 `#include` 它；安装包文件名和向导标题都跟着变。
- 新增 `docs\VERSIONING.md`：三段号码各自的升法、改一个文件就够、发版六步。

**验证**：`check-version.ps1` 故意把 `APP_VERSION_TAG` 改成 `V2.3.0` → 退出码 1 并指出应为 `V2.2.0`；改回后 0。`--version` 打「冥零工作台 V2.2.0 / 文件版本 2.2.0.0」；exe 属性 FileVersion `2.2.0.0`、ProductVersion `V2.2.0`；`--paths` 第一行「版本 : V2.2.0（2.2.0.0）」；安装包仍是 `dist\MinglingWorkbench-2.2.0-setup.exe`，其 ProductVersion `2.2.0`。

---

## 10. v2.2.1 补丁（2026-11-06）

**症状**：双击 `dist\MinglingWorkbench-2.2.0-setup.exe`，第一屏还没出来就弹
「安装程序不能创建目录 `C:\Users\<你>\AppData\Local\Temp\is-XXXX.tmp`，错误 5：拒绝访问」。

**根因不在安装脚本**：`F:\` 那棵项目树被打了 **Low 强制完整性标签**
（`icacls "F:\…\bili"` 显示 `Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)`），
编出来的 exe 靠继承也带上这个标签。Windows 的 no-write-up 规则：低完整性进程不能往
中等完整性目录里写。`%TEMP%` 是中等完整性，Inno 第一步就要在那里解包，于是 CreateDirectory
直接 `ERROR_ACCESS_DENIED`。ACL 里同时还留着 AppContainer 包 SID 与 `CodexSandboxUsers` 组，
是早前某个沙箱/容器进程写过这棵树留下的——和「脚本写错了」一点关系都没有。

**修法**（1883 个文件全转 Medium，0 个 Low）：

```powershell
icacls "F:\…\bili" /setintegritylevel "(OI)(CI)Medium" /T /C /Q
icacls "%LOCALAPPDATA%\Programs\MinglingWorkbench" /setintegritylevel "(OI)(CI)Medium" /T /C /Q
```

下次再犯，一条命令就能判断：`icacls <路径> | findstr Mandatory`，看到 `Low` 就是它。
（`icacls` 的 `"(OI)(CI)Medium"` 在 MSYS bash 里会被路径转换改坏，得在 PowerShell 里调。）

**同版顺手改的两处**：

- 总览页 DrawHero 右上角的「打游戏模式」三态按钮整块删掉，立绘改通栏；维护页的那三个状态照旧保留，帮助页指向也照旧。
- `win32\build.bat` 复制 exe 失败时不再假成功：`copy` 后面接 `if errorlevel 1 goto copylocked`，
  打印「bin 里现在还是旧 exe」并 `exit /b 1`。这次就是被它坑过一回——窗口开着的状态下编译，
  脚本照样打 `OK` 和旧的 size。

**产物**：`dist\MinglingWorkbench-2.2.1-setup.exe`，`bin\MinglingWorkbench.exe` FileVersion `2.2.1.0`、
ProductVersion `V2.2.1`；静默安装 `exit=0`，日志 `Installation process succeeded.`。
版本号只改了 `win32\src\version.h` 一处（`check-version.ps1` 通过），外加 `installer\mingling.nsi` 与
`README.md` 里手抄的产物名。

## 11. 自设定：一键自动配置的第三段（2026-11-06）

**问题**：一键自动配置装完五个组件，机器人只是「能启动」——没有 DeepSeek 提供商、没有 QQ 平台、聊天设置是默认的、人设是空的。用户按下按钮之后还得自己去后台点一遍，等于「装好了但不会说话」。

**选择**：把「配置」也做成数据驱动的一段，放在装组件之后，模型改成**配置包**（`pack\mingling-pack\pack.json`）而不是写死在 C++ 里。

**理由**：

- 配置项的名字和形状是 AstrBot 的内部契约（`/config-profiles/default`、`/provider-sources`、`/bots`），写死在 C++ 里一升级就碎；写成包，AstrBot 改了只改 JSON 和 `self-setup.ps1`。
- 和「大肥鱼配置包」同一个形状：`pack\<id>\pack.json` + `blocks[]`，以后加插件块、语音块不用改窗口。
- 真活留给 PowerShell（`tools\self-setup.ps1`），C++ 只负责拉起进程、翻译 `##STEP/##OK/##FAIL/##RESULT`、落日志。这条路 `auto-setup.ps1` 已经验证过，能流式给进度。

**六块**（`-Only provider|platform|chat|plugins|persona|verify` 可单跑）：

1. `provider`：`provider-sources` 建/更新 `deepseek` → 拉模型列表挑 `deepseek-flash` → `providers/test` 测通；
2. `platform`：按 `pack.platform.id` 精确匹配 `aiocqhttp`；零个才建（`ws_reverse_port=6199`，令牌生成到 `private
apcat-ws-token.txt`）；多个且没同名就报错，不猜；
3. `chat`：按 `pack.chat` 的点路径写 13 项（分段回复、`compression.max_turns=30`、安全模式、`computer_use_runtime=none`……）；
4. `persona`：子进程跑 `tools\import-mingling.ps1`，只认它的 `RESULT ok=1`；
5. `verify`：跑 `tools\diag-config.ps1`，统计 `CHECK bad`。

**两条保守规则**（都是被现场数据逼出来的）：

- **白名单只加不删**：原来的六条一条不动，只补缺的。第一次干跑把前缀从「大肥鱼」改成「冥零」后按前缀找不到，白名单检查直接红；改成精确匹配 + 并集之后就绿了。
- **默认模型不抢**：`agent_runner.config.model.provider_id` 非空且没 `-Force` 就不动。验收机的默认模型是 `mirarouter/deepseek-v4.1-flash`，换掉会让她当场失声。

**快照与回退**：真改之前 `Take-Snapshot "selfsetup"` 落 `private\snapshots\before-selfsetup-<时间>.json`（config + personas + bots，留最近 20 份），`-Restore` 按 id 补/改人设、按 id PUT 平台，config 保留当前 dashboard 再整份写回。验收时真跑 → 核对 → 回退 → 再核对，两步都过。

**入口**：维护页「自设定」（`op:selfsetup`，`StartAutoSetup` 第三段进度 75+pct/4）、`--selfsetup [--dry]`、`--her-op selfsetup [块名|dry]`。

**四个坑**（都记在 `docs\ACCEPTANCE.md` 第 13 节）：命令行收尾 `\` 吃引号、协议行必须 `##RESULT`、`$pid` 只读、PS 5.1 没有 `-SkipLast`；另外两个脚本必须存成 **UTF-8 with BOM**，否则 PS 5.1 按 GBK 读出一堆 Parser 错（编辑工具会把 BOM 弄丢，改完要重存）。

**P1（同一晚补上）：插件块**。把大肥鱼那 10 个插件原样收进 `pack\mingling-pack\plugins\`（MIT，附 `LICENSE-dafeiyu-config-pack.txt`），`pack.json` 里写成 `plugins.items[]`，每条带 `enable` 与 `config`：

- 装：后台没有的目录打成 zip（`ZipFile::CreateFromDirectory`）传 `POST /plugins/install/upload`；装过就跳过；
- 配：`GET /plugins/config` → 占位 `{主人会话}`/`{ffmpeg}`/`{asr_dir}`/`{硅基流动key}` 换得到才写、换不到跳过，`PUT` 只写有变化的；
- 开：`PATCH /plugins/enabled` 按 `enable`；改过的再 `POST /plugins/reload`；
- 默认只开 6 个（clean、memelog、groupimage、resetkeep、signature、video），petlink 与三个语音插件只装不开。

验收：`-Only plugins` 真跑新装 3 个、10 个全在位（6 开 4 关），配置落盘核对正确（`owner_session`、`ffmpeg_path`、`sing.backend`），`diag-config.ps1` 加一项插件 CHECK 后八项全 ok。
**P2（同一晚再补）：长期记忆与语音**。`pack.json` 的 blocks 扩到八块，新增 `memory`（`default_mode "0"`；1 本机 Ollama `bge-m3` → `冥零记忆-本机`；2 硅基流动 `BAAI/bge-m3` → `冥零记忆-硅基流动`；plugin `astrbot_plugin_livingmemory`（市场 id `lxfight/astrbot_plugin_livingmemory`）；scope `global` + 主人会话/桌宠/群）与 `voice`（`default_mode "0"`；1 Edge / 3 豆包 / 4 本机 Breeze / 5 Breeze 在线，四路 id 都以 `冥零语音-` 开头；`trigger_probability 0.33`）。`self-setup.ps1` 加 `Do-Memory`（Step 68–74）与 `Do-Voice`（Step 76–80）：embedding 与 TTS 都先 `POST /providers` 建源、`POST /providers/test` 测通，再写插件/全局设置；测不通就把 provider `enable=false` 并 FAIL，不动你现有的设置。本机 Breeze 先查 `/v1/voices`，包里要的 `mingling` 音色不在列表就**不动现场**、直接报「先做声音」。`diag-config.ps1` 加「记忆」「语音」两项 CHECK。踩坑补充：`$pid` 这种只读自动变量在参数位也会炸（`Get-ProviderConf` 的参数改名 `$providerId`）；快照回退不覆盖插件配置文件，退回后要手工 PUT `/plugins/config` 指回旧值（`DELETE /providers/{id}` 打不通）。

## 12. 功能页与 V2.3.0（2026-11-06）

**问题**：配置包里默认关着的几样（桌宠 petlink、唱歌 sing、豆包语音、在线 Breeze）和记忆/语音路线，只有改 `pack.json` / `answers.json` 才动得了。对用户来说等于「有这功能，但看不见」。

**选择**：新增侧栏第 8 页「功能」，把它们摆成开关，而不是加一堆新命令。

- 六个开关：四个插件二选一（开/关）、长期记忆三选一（关 / 本机 bge-m3 / 硅基流动）、语音路线五选一（关 / Edge / 豆包 / 本机 Breeze / 在线 Breeze）；
- 点一下只做两件事：写覆盖文件（`<base>\private\features.txt` 一行 `插件名=1|0`；`memory-mode.txt`、`voice-mode.txt` 各一行数字），再自动跑对应的自设定块（插件→`plugins`，记忆→`memory`，语音→`plugins,voice`）。真正的后台改动仍然只发生在引擎里，和命令行走同一条路；
- 覆盖文件优先于 `pack.json` 的 `enable`：`self-setup.ps1` 的 `Do-Plugins` 加了 `Get-Feature` 覆盖，`Do-Voice` 选豆包/在线时用 `Ensure-PluginOn` 顺手把对应插件打开；
- C++ 侧：`her::FeatureOn` / `her::ModeNum` / `her::SetFeature`（`her_config.cpp`）+ op `feature`；界面在 `win32\src\ui_setup.inc`，TABS 扩到 10 项，`0` 键新增到帮助页。

**没选**：没做成「设置对话框」或新的配置文件格式——覆盖文件是纯文本一行一个，用户手改、Agent 读都容易；也没把这四个插件直接改成默认开——桌宠要另装桌宠桥、豆包和在线语音要各自的 key，默认开会让新装的人一上来就撞失败。

**验收**：功能页真点「桌宠 开」→ 写 `features.txt` → 跑 `plugins` 块 → 10 在位 7 开 3 关（快照 `before-selfsetup-20261106-210052.json`）；删覆盖文件再跑一遍回到 6 开 4 关。版本升 `V2.3.0`（按 VERSIONING：`Vx.x.0` 新增功能），`dist\MinglingWorkbench-2.3.0-setup.exe` 51,553,244 B。

**踩坑**：`version.h` 是 **UTF-8 无 BOM**，用 GBK 读改会写坏中文注释（`APP_NAME` 的收尾引号被吃掉，编译报 `stray 'L'`）；改它要按 UTF-8 读写。另外 PowerShell 截 DPI-aware 窗口要先 `SetThreadDpiAwarenessContext(-4)` + `PrintWindow`，否则 `GetClientRect` 只报 150% 缩放后的逻辑尺寸，截出来的图右边和下边被裁掉——一度误判成「开关 chip 没画出来」。
## 13. v2.3.1 补丁：组件目录只认 <工作区>\bots（2026-11-06）

**问题**：从 v2.2.0 起组件统一装进 `<工作区>\bots`（`bots\AstrBot`、`bots\SnowLuma`、`bots\Breeze`、`bots\Ollama`、`bots\uv`，各自带 `start.cmd`），可 C++ 里还留着一批硬编码的老布局路径：`P(L"breeze-tts\start-breeze.cmd")`、`P(L"breeze-tts")`、`P(L"SnowLuma\logs")`、`P(L"astrbot\data\cmd_config.json")`、`P(L"Ollama\ollama.exe")`。`BotPath()`（`her_config.cpp:58`）本来就会先找 `bots\<name>`、再退回 alias 表里的老目录，但这些地方绕过了它，于是：语音卡 canfix 永远红（它只看 `ComponentStartCmd`）、GameOn/GameOff 的 Breeze 启停落空、AstrBot 登录密码读不到、版本扫描扫不到 Breeze、开机自启的快捷方式还指老路径。

**选择**：不再逐处修补，而是收成两个函数。

- `BotPath(name)` 作为唯一出口：`<工作区>\bots\<name>` 存在就用它，否则回退 alias（`breeze-tts`/`astrbot`/`snowluma` 这类老目录），一个函数同时兼容两种布局；
- 新增 `her::ComponentStartCmd(name, baseCmd)`（`her.h:67-70`）：依次找 `<组件目录>\start.cmd` → `<组件目录>\start-breeze.cmd` → `<机器人根>\<baseCmd>`，谁先存在用谁；
- 改走它们的点：`StartAstrBot`、`Relogin`/`RestartQQ`、`StartBreeze`、`GameOn` 的 `PidsUnder/KillUnder`、`GameOff` 的重启、`AutostartFix`、`her_astr.cpp` 的两处 `cmd_config.json`、`her_config.cpp` 的版本扫描（`FindFirstFileW(JoinPath(BotPath(L"Breeze"), L"bin\*"))`、`DistVer(JoinPath(BotPath(L"uv"), …))`）、`her_status.cpp:515` 的 canfix。

**没选**：

- 没在磁盘上建 junction 把 `breeze-tts` 指到 `Breeze`——alias 表已经能兼容，多一层链接只会在卸载/搬家时留下悬空引用；
- 没保留「先试老路径、再试新路径」的双份硬编码——那正是这次出问题的原因；
- 没改 `tools\auto-setup.ps1` 的目录名：`bots\Breeze` 本来就是它装的，是 C++ 该跟上它，不是反过来。

**验收**：`--paths` 五个组件全在 `bots\` 下；`--her-status` 八张卡全 ok（语音卡 canfix 由 `ComponentStartCmd` 命中 `bots\Breeze\start.cmd`），`VER Breeze 0.1.3` 证明 `bots\Breeze\bin` 的版本扫描生效；`tools\self-setup.ps1 -DryRun` 八块全过（`##RESULT ok=1 done=8 fail=0`）。`bin\MinglingWorkbench.exe` 1,290,240 B、FileVersion `2.3.1.0`；`dist\MinglingWorkbench-2.3.1-setup.exe` 51,566,870 B。

**踩坑**：工作区根目录的 `start-astrbot.cmd` / `start-snowluma.cmd` 是上一版脚本用「UTF-8 无 BOM + 中文绝对路径」写的，在 `chcp 65001` 下 cmd 会把中文路径读成乱码，脚本直接静默退出（`run.log` 一直不更新，看着像进程起不来）。改成纯 ASCII + `%~dp0` 相对路径后正常，顺带也就不怕工作区改名字了。这类「现场生成、不进仓库」的东西（`start-*.cmd`、`answers.json`、`旧版\` 备份）一并写进 `.gitignore`。

## 14. V3.0.0-snapshot 预奏快照（2026-11-07）

**这是什么**：V3.0.0 的预奏快照，不是正式大版本。五项需求先落地、单独发一条渠道（版本串带 `-snapshot` 后缀），正式版之后从同一条主线切出去。**升级不需要动任何已有配置**：新增的键都是可选项，不写就按默认值走。

**为什么单独一条通道**（用户拍板：快照版不与正式版共通）：

- 版本串：`V3.0.0-snapshot`，文件版本 `3.0.0.0-snapshot`；数字部分仍是 `3.0.0.0`，比大小一律用 `APP_VERSION_PLAIN`。`version.h` 新增 `APP_VERSION_SUFFIX`（正式版 `""`）与 `APP_SNAPSHOT`（正式版 `0`），`tools\check-version.ps1` 会检查两者一致。
- 分流清单：状态目录 `%APPDATA%\MinglingWorkbench\snapshot`、卸载键 `MinglingWorkbench_snapshot_is1`、窗口类 `MinglingWorkbench.snapshot`、AUMID `Mingling.Workbench.snapshot`、安装目录 `MinglingWorkbench-snapshot`、安装包 `MinglingWorkbench-3.0.0-snapshot-setup.exe`。
- 共用清单：工作区（`out`/`tmp`/`logs`/`bots`）和 `<Base>\secrets`。看片产物、台账、密钥两边都能用，不复制两份。
- 想回正式版：把 `version.h` 的 `APP_VERSION_SUFFIX` 改回 `""`、`APP_SNAPSHOT` 改回 `0`，再按 VERSIONING 发版；快照的状态目录和安装目录不会被删，留着随时能切回来。

**1. 更新页牵引 GitHub Releases**

- 工作台那一行不再拿本机数字糊弄：读 `settings.json` 的 `repo_snapshot`（快照通道专用；默认空 = 不联网，**绝不**回退到正式版的 `repo`），走 GitHub Releases API 比 tag。
- 未配置 / 断网 / 限流 / 仓库没有 release：显示「本机 / 没查到」，安静降级，不报错、不卡 UI。tag 里不带 `snapshot` 的 release 不算快照。
- 有新快照时「去 GitHub 下载」打开对应 Releases 页面（API 的 `html_url`；走代理兜底时用 `/releases/tag/<tag>`）。不做自动更新、不下载 exe、不静默替换。

**2. 维护页显示当前工作台版本**

- 头部版本行固定先画 `工作台 V3.0.0-snapshot`（取 `APP_VERSION`，不硬编码），后面再接组件版本；组件版本再也盖不掉它。
- 侧边栏版本行先量宽度、放不下先缩一号字、再放不下就只留版本号——`-snapshot` 不会被省略号吃掉，和 `--version`、帮助页、卸载列表对得上。

**3. B 站相关统合 + bili-whale 配置界面**

- B 站页顶部一条工具带：`bili-whale 配置 / 登录 / 配额 / 风控 / 自检 / 产物 / 问一句`。维护页只留一个「B 站页」入口；体检页、日志页原有的 B 站命令保留，点了会切到体检页看结果。
- 配置浮层读写 `BILI_WHALE_CONFIG`（实际就是 `%APPDATA%\MinglingWorkbench\snapshot\bili-whale.config.json`）。字段名逐个对着 `sidecar\bili-whale.config.template.json` 抄，共 25 行：`preferences.like/dislike/keywords`、`risk.*` 七个、`quota.shareDaily`、`night.skipChance/minGapMin/maxVideos/maxWakesPerDay`、`diary.enabled/push`、`share.enabled/minScore/silentAfterDays/aiCommentGuard`、`listen.comment/commentIntervalSec`；`night.windows` 这种数组套对象只读展示摘要。
- 没往 bili-whale 配置里加「九宫格」「超时」——那是 `debrief` 的命令行参数，归工作台的 `settings.json`：`bili_grid`（默认 `3x3`）与 `bili_timeout_sec`（默认 420，30–3600）。
- 保存前把原文件备成 `.bak-<时间戳>`（同一秒存两次自动加 `-2`），写完重新按 JSON 解析一遍，坏掉就用备份回滚；未知键原样保留（实测塞 `futureUnknown.block.deeper` 进去，存完还在）。

**4. DSH 对话以 HTTP API 接入（不安装、不启动 DSH）**

- `win32\src\biliapi.cpp` 新增 `DshApiCfg` / `DshApiLoad` / `DshApiSave` / `DshChat`：OpenAI 兼容 `POST <base><path>`，默认基址留空、路径 `/chat/completions`、模型 `deepseek-chat`、超时 60 秒（夹在 5–300）。解析 `choices[0].message.content`，兼容 `choices[0].text` 和 `error.message`。
- Key 存 `<Base>\secrets\dsh-api-key.txt`，**不写 settings.json**；`EnsureSecrets` 的 README 补了一行说明，老装机只追加这一行、不覆盖用户内容。
- 配置浮层里加「对话 API（可选）」区（启用开关 / Base URL / 路径 / 模型名 / 超时 / API Key）和「测试连接」；B 站页「问一句」浮层用同一套，解释当前这条片。失败只影响这两处，bili-whale CLI 看片一条路都不受影响。

**5. 输入框支持复制粘贴**

- `Ctrl+V` / `Ctrl+C` / `Ctrl+X` / `Ctrl+A` / `Shift+Insert`，外加右键菜单（粘贴 / 粘贴(Shift+Insert) / 复制 / 剪切 / 全选 / 清空）。粘贴走 `OpenClipboard` + `CF_UNICODETEXT`，把换行、制表、U+2028/U+2029 换成空格再 `Trim`，长度上限 200 → 600。
- 输入框有焦点、或配置/问一句浮层打开时，`1–9` 只当字符进去，不切页。

**6. 其他链接 / 分享文本读取（MVP）**

- 新增 `win32\src\webfetch.cpp`：`ClassifyInput` 把输入分成 B 站（BV/URL/短链）、其他 `http(s)`、分享文本、本地路径、认不出；分享文本里提第一个链接。本地 `.lnk`/`.exe` 只打开，不注入进程、不读屏幕、不抓应用内容。
- 其他链接走 `FetchWebPage`：单次 GET、跟随重定向、15 秒超时、512 KB 上限、按 charset 解码（GBK 也能认）、抽 `<title>` 和正文摘要。读到的内容显示在结果区，台账新增可选 `type:"link"`（`bv` 字段放 URL、`sink` 是 `logs\jobs\link-<unix>.txt`）。
- B 站链路一个字没改：老台账行没有 `type` 键照样能读，新写的 B 站行也不会塞空键。
- 「读取应用内容」（QQ/微信窗口里的东西）这一版**只写设计**，在 `docs\plan-v3.0.0-snapshot.md` §6。

**顺手修掉一个 V2.3.1 就在崩的老 bug**

- `her_config.cpp` 的 `WhitelistOn()` 原来是 `const J* v = CmdConfig().Path(...)`：`CmdConfig()` 返回临时对象，这条语句一结束就析构，`v` 立刻悬垂，下一句读 `v->t` 是 use-after-free。表现是维护页 ↔ 更新页来回切的时候偶发 `0xc0000005`（V2.3.1 的 `0x60f51` 也是它，不是这次引入的）。改成先接住 `J cfg = CmdConfig()` 再取指针；3 轮 × 16 次快速切页不再崩。
- 顺带：`her_probe.cpp` 的 `Net()` 改成按值返回（原来是函数内 static，被看门狗、维护页、更新检查几个线程一起读，而它自己会 `clear()`），`ImagePath()` 的静态缓存加锁。

**私有仓库的更新检查**（2026-11-07 补）：仓库本身是私有的，未授权去查 `releases/latest` 只会拿到 404，更新页就永远显示「本机 / 没查到」。所以 `LatestGithub()` 现在会先看 `<base>\secrets\github-token.txt`：有这个文件就用它发 `Authorization: Bearer …` 查 API，没有就照旧匿名查。token 无效/过期仍按「没查到」处理，不报错、不打扰。`EnsureSecrets()` 的 README 里补了 `github-token.txt` 这一行（老装机只追加这一行，不动已有内容）。

**预发布不在 latest 里**（2026-11-07 再补）：GitHub 的 `/releases/latest` 只认正式版，快照按约定发成 prerelease，所以配了 `repo_snapshot`、放好 token 之后还是显示「没查到」——问 latest 拿到的永远是正式版 V2.3.1，tag 里没有 `snapshot` 就被判成「别的通道」。改成带通道标记时问 `/releases?per_page=100`、挑 tag 里带 `snapshot` 的第一条；列表里没有就老实说没查到，绝不退回正式版的版本号。

**验收**：见 `docs\ACCEPTANCE.md` 第 15 节（构建、版本一致、快照隔离、更新页降级、配置保存与备份、DSH API、剪贴板、链接读取、崩溃回归、安装包）。

## 15. V2.4.0 正式版：安装包补全 + 冥零自己的安装 Skill（2026-11-07）

**为什么升正式版**：V3.0.0-snapshot 这条线把工作台做成了「一个 exe + bots\ 组件 + pack\ 配置包」的产品形态，
但安装包一直只打 exe / sidecar / art / docs——干净机器装完点「自设定」只会得到「没找到 tools\self-setup.ps1」，
自设定引擎、配置包、人设清单三样全不在包里。V2.4.0 把这些补齐，并把「安装 Skill」换成冥零自己的那一份。

**安装包补全**（`installer\mingling.iss`）

- 新增 `tools\*.ps1 / *.py / *.cmd / *.txt`（self-setup、auto-setup、common、diag、backup、import-pack、import-mingling、relogin、qq_watch、qq-toast、autostart、setup-pet 等），排除本机私有的 `skill-home.txt`、`pet-*-mine.txt`。
- 新增 `tools\python\*`：掉线提醒按 `tools\python\pythonw.exe` 找解释器，包里没它就开不起来。
- 新增 `pack\mingling-pack\*`：`tools\self-setup.ps1` 默认从 `<根>\pack\mingling-pack\pack.json` 读八块清单。
- 新增 `plugin\mingling_skill\*`：人设注入要读 `plugin\mingling_skill\mingling_skill.json`。
- 这 15 个运行时脚本原来在 `.gitignore` 里（注释写着「工作区里现场带着，不属于仓库」），这次改为**纳入源码**——否则从干净 clone 打出来的包是残的。`tools\python\`、`tools\innosetup6\` 仍忽略。

**内置安装 Skill**（`skill\mingling-install\`）

- 新写的一套 Skill（SKILL.md 10 KB + version.json 0.1.0 + `scripts\probe.ps1` 体检 + `scripts\finish.ps1` 收尾 + `references\自设定八块.md`、`references\发布.md`），和观众那份 `dafeiyu-install` 彻底分开。
- `her_actions.cpp` 新增 `ApplyBundledSkill()` / `EnsureBundledSkill()`：启动（或任何 `--her-op`）时把 `skill\mingling-install` 铺到 `%USERPROFILE%\.agents\skills\mingling-install`，本机版本更高就不覆盖，覆盖前先备份到 `<机器人根>\旧版\<MMdd-HHmm>-Skill<版本>`，最后写 `tools\skill-home.txt` 与 `tools\skill-version.json`。
- 踩坑：把这个函数放进匿名命名空间会报 `call of overloaded 'EnsureBundledSkill()' is ambiguous`，必须定义在匿名段之外。

**更新页认自己的 Skill**

- `kSkillRepo` 从 `zexuanw958-svg/dafeiyu-config-pack` 改成 `linyuehua0010/mingling-workbench`，`kSkillDir` = `mingling-install`；`SkillHome()` 优先找 `mingling-install`（`.agents` / `.dsh` / `.workbuddy`），`dafeiyu-install` 只作兜底。
- 私有仓库的版本清单改走 `api.github.com/…/contents/skill/mingling-install/version.json?ref=main`（`Accept: application/vnd.github.raw` + token）。原来是查 `raw.githubusercontent.com`：curl 和 WinHTTP COM 都 200，但 exe 里的 `HttpCall` 连响应都拿不到（`logs\skill-check.log` 记 `ok=0 code=0`），所以放弃那条路。
- 正式版只查正式通道：`#if APP_SNAPSHOT` 之外用 `LatestGithub(kSkillRepo, …, L"")`，不再把 `V3.0.0-snapshot` 当成「有新版」。
- 「一键更新」脚本：先问 `releases?per_page=30` 找 `mingling-install.zip` 资产，带 token + `Accept: application/octet-stream` 下（GitHub 会 302 到签名地址，第二跳不需要 token），失败再走加速站。

**其它一起修的**

- `windres` 加 `-c 65001`：`res\app.rc` 是 UTF-8 带 BOM，原来按系统 ANSI 读，exe 属性里的中文变成「鍐ラ浂宸ヤ綔鍙?」（有损，问号救不回来）。
- 日志页、起停服务、体检脚本全部认 `<工作区>\bots\`：`ui_pages.inc` 新增 `CompDir()` / `ReadLogPath()` / `BiliLogPath()` / `SecondsSinceWrite()`，标签映射错位（AstrBot 取到 SnowLuma 的日志）一并修掉；`tools\common.ps1` 新增 `Get-BotsDir` / `Join-Bot`，`diag.ps1` 12 处路径改走它——「SnowLuma 没在运行」「记忆插件没装上」两条误报消失。
- B 站日志只剩旧版 `logs\bili-service.log` 时，页面上会前置一行说明「这是旧版留下的，已经 N 天没动过」。

**验收**

- `dist\MinglingWorkbench-2.4.0-setup.exe` 61,260,277 B；静默装到临时目录后，`{装好的}\tools\self-setup.ps1 -Base <机器人根> -DryRun` → `##RESULT ok=1 done=8 fail=0`（八块全 OK），而 V2.4.0 之前的包装出来这一步只会「没找到 tools\self-setup.ps1」。
- `--her-op updates` → AstrBot 4.29.4（最新）/ SnowLuma 2.4.0（最新）/ 冥零的安装 Skill 0.1.0（最新）/ 冥零工作台 V2.4.0（最新）。
- 卸载干净（`unins000.exe /VERYSILENT`，目录与 `MinglingWorkbench_is1` 注册项都不留），工作区外面的 `~\.agents\skills\mingling-install` 按设计保留。
- Release V2.4.0 三个资产：`MinglingWorkbench-2.4.0-setup.exe`（61,260,277 B）、`mingling-install.zip`（14,811 B）、`skill-version.json`（450 B）。

## 16. V3-snapshot-2：链接读取落地 + 七页整合 + 只覆盖自己的更新（2026-11-07）

**版本规则变了**：正式版 `V<主>.<次>.<补丁>`；快照版 `V<大版本>-snapshot-<序号>`，大版本 = 正式版最新大版本 + 1。
本轮 `V3-snapshot-2`（`version.h` 里 `APP_SNAPSHOT_N=2`、`BUILD=2`、`APP_VERSION_SHORT="3-snapshot-2"`），
旧的 `V3.0.0-snapshot` 按「V3-snapshot-1」认、不改名。`check-version.ps1`、`version_auto.iss`、
`her::WbCmp/WbIsSnapshotTag`、安装包文件名（`MinglingWorkbench-3-snapshot-2-setup.exe`）、`docs\VERSIONING.md` 一起改。

**1. 读链接从「可选增强」做成完整功能**

- 输入框统一入口：BV/B 站链接 → 看片；网页链接/分享文本 → 读链接；结果区统一给标题、摘要、来源、耗时、状态。
- `FetchWebPage` 补：URL 协议校验、跟随重定向、`WINHTTP_OPTION_DECOMPRESSION`（B 站返回 gzip，原来正文是压缩字节）、
  accept-encoding 按解压能力发 gzip/identity、超限截断时回退半个 UTF-8 字符（原来尾部半个汉字会让整页按 GBK 解成乱码）、
  编码没认出来给 `note`、站点 `description`/`og:description` 抽成摘要。
- 新增 `LinkCfg`（`link_read_enabled/timeout/maxkb/ua`，默认 15 s / 512 KB，只能往小调）与 `SettingsGuardApply`：
  写 settings 前备份 `.bak-<时间>`、写完重新解析、坏了写回备份。
- 新增「链接与应用」面板（`ui_link_cfg.inc`）：读链接四项 + 对话 API 六项 + 「测试连接」（真发一句）。
  Key 只进 `secrets\dsh-api-key.txt`；`DshApiSave` 改用 `SettingsGuardApply` 一次写五个键。
- 「问一句」支持链接结果：`DshPrompt()` 按 `g_linkMode` 换开场白与字段名。
- 新增 `--link` 命令行入口（分类 → 读取 → 打印 → 写 `logs\jobs\link-<t>.txt` + 台账 `type:"link"`）。

**2. B 站页并成四个分区**（`ui_pages.inc`）

- 分区：选题 / 看片与读链接 / 结果 / 配置（`g_bSec`），配置里再分 bili-whale / 链接与应用（`g_bCfgSub`）。
- 原「bili-whale 配置」「问一句」两个浮层改成页内区域：`PaintBiliCfg/PaintLinkCfg/PaintDshAsk` 都改成 `(Graphics&, const RectF&)`；
  `BiliCfgClose`/`LinkCfgClose` 从「关掉」变成「保存后留在原地」，底部按钮「保存 / 重新读」。
- 跑完一条自动跳到结果分区；`UiOnWheel/UiOnChar/UiOnKeyDown/UiOnRClick` 全部按分区改。
- 修的 bug：配置分区会把所有点击吃给自己，侧栏和帮助中心胶囊点不动——`tab:`/`hsec:` 的处理提到配置捕获之前。

**3. 更新只覆盖工作台自己**（新增 `her\her_selfupdate.cpp`）

- 白名单：`bin sidecar tools pack plugin skill docs art`（`UpdateProgramDirs()`）；`ProgramRoot()` 认两种布局
  （安装包：exe 就在安装根；开发目录：exe 在 `bin\`）。
- `PlanUpdate` → 备份到 `%WORKSPACE%\旧版\workbench-<tag>-<时间>\`（含 `_self\MinglingWorkbench.exe`）→ 复制自身到 `%TEMP%` →
  `--wb-update-run` 等父进程退出 → `RunInstaller`（`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOG=`）→
  非 0 退出就 `CopyProgramBack` 回滚 → 成功后重启。
- 自带 SHA-256（不引第三方库）、`HttpGetBinary` 下安装包（进度/大小/可选 `.sha256`）。
- 私有仓库的坑（发 V3-snapshot-2 时踩的）：`releases/download/<tag>/<file>` 不认 token（curl 带 token 也是 404），
  必须走 `api.github.com/repos/<repo>/releases/assets/<id>` + `Accept: application/octet-stream`。所以 `FindSetupAsset`
  在有 token 时把 `url/shaUrl` 换成资产接口地址；`HttpGetBinary` 自己跟跳转（最多 6 跳、换主机就摘掉 Authorization，
  免得签名地址被 S3 嫌「两种认证并存」），并且**要保住查询串**——早先只取 `lpszUrlPath`，签名参数全丢。
  `HeaderLine` 优先 `WINHTTP_QUERY_LOCATION`，原始头兜底时大小写统一。
- 新增 `--wb-get <owner/repo> <tag> [保存路径]`：命令行拉安装包并核对大小 / SHA-256（发版和排错都用它）。
- 更新页工作台行「一键更新」（`up:wbgo`），覆盖前用 `her::PidsNamed` 查有没有别的实例；`TK_SELFUPD` 收尾。
- 安装器审计：`installer\mingling.iss` 的 `[Files]` 只含程序文件，**没有 `[InstallDelete]`**，`[UninstallDelete]` 只有 `dirifempty {app}`，不碰 bots。

**4. 教程内置**（新增 `ui_docs.inc`）

- 帮助中心里三篇：`使用说明.md`、`deploy-bili.md`、`deploy-qq.md`；自写 Markdown 解析（标题/列表/代码块/表格/图片/引用），离线可读，图片只从 `docs\` 本地加载，不联网。
- 文档里的 `{{VERSION}} {{FILEVERSION}} {{TABS}} {{TABLIST}} {{HOTKEYS}}` 由程序注入（页签数与快捷键不再写死）；「用系统打开」把展开后的正文写到 `%TEMP%` 再交给系统。

**5. 页面整合：十页 → 七页**

- 侧栏：总览 / B站 / 队列 / 日志 / 体检 / 维护 / 帮助中心；快捷键 `1`–`7`，`0` 跳帮助中心，F5 按当前页/当前分段刷新。
- 「维护 + 功能」合一：维护页下半接 `PaintFeatures()` 六行（桌宠/唱歌/豆包语音/在线 Breeze/长期记忆/语音路线），动作仍走 `RunHerOp`。
- 「更新 + 求助 + 帮助」合成帮助中心（`ui_center.inc`，`g_hSec` 0/1/2），三段各自保留原功能（含 11 张求助卡与 `custom_help_texts`）。

**6. UI 重构**

- 设计 token 集中在 `win32\src\ui.cpp`：颜色、字号之外新增 `R_CARD/R_PANEL/R_PILL/R_SMALL/PAD_X/GAP_M/GAP_S`，卡片统一 `Card()`（25 处 `Round(...S(14)...)` 收编）。
- 空状态、报错文案沿用人设口吻（「她还没看过视频」「没读成：…」），但原因、路径、错误码一律照实写出。
- 高 DPI：仍按 `GetDpiForWindow` 缩放，字体仍是 Microsoft YaHei UI。

**回归**

- `--selfsetup --dry` 八块全 ok；`--her-op meme mid` exit 0；`--watch`/`--feed`/`--link` 都写台账；哨兵文件（`bots\`/`secrets\`/`out\`/`logs\`）在覆盖更新演练前后哈希不变。
- 截图见 `docs\screens\`；验收明细见 `docs\ACCEPTANCE.md` 第 16 节。