# 冥零工作台 V3.0.0 预奏快照版 · 计划与验收

> 分支：`feat/v3.0.0-snapshot`，基线 `main`（V2.3.1）。
> 这一版是 **V3.0.0 的预奏快照**，不是正式大版本：不换安装器骨架、不动 sidecar 契约、
> 不改 bili-whale 上游 CLI，只把 V3 要做的五件事按「可单独编译、可单独回退」的切片先落一半。
> 版本号仍然只有一个出处：`win32\src\version.h`（本版 `V3.0.0` / `3.0.0.0`）。

## 0. 取舍先摆出来

| 决定 | 理由 | 没选的做法 |
| --- | --- | --- |
| 版本**显示**就是 `V3.0.0`，不带 `-snapshot` 后缀 | 界面、`--version`、exe 属性、卸载列表五处必须同一句话；后缀一混就又是两个版本源 | 界面留在 V2.3.x、只在文档里标快照（那会让「版本从哪来」重新变成谜） |
| 安装包文件名允许带 `-snapshot` | 文件名是产物名，不是版本源；`installer\build-installer.bat` 照旧从 `version.h` 取版本 | 改 `version.h` 去迁就文件名 |
| 五件事都做成**工作台内**的入口，不新增进程 | 快照版只动 UI 与本地编排，出问题 `git revert` 一片就回到 V2.3.1 | 给 B 站/链接/对话各起一个后台服务 |
| 未知配置键一律原样保留 | `bili-whale.config.json` 是上游的，字段会随版本加；写死字段表就是下一版的 bug | 用固定结构体重写整份配置 |
| 「读取其他应用」只到 MVP 边界 | 分享文本提 URL + 本地 `.lnk/.exe` 只做「打开」；进程注入/屏幕读取/内容抓取一律不做 | 先做应用内容抓取（本快照版只输出设计，见 §6） |

## 1. 需求 1：更新页「冥零工作台」牵引到 GitHub Releases

现状：`ui_update.inc:71` `PaintUpRow()` 已经在 `it.id == "wb" && state == "new"` 时画
「去 GitHub 下载」（`up:wbdl`），但版本号来自 `her_actions.cpp:923` 写死的 `up.Set(L"wb", JStr(L"2.0"))`，
仓库地址只在用户自己写了 `settings.json` 的 `repo` 时才查（`her_actions.cpp:916`）。

改动：

- `her_actions.cpp`：`kDefaultWbRepo = L"linyuehua0010/mingling-workbench"`；`repo` 没配就用它（仍可被 `repo` 覆盖），
  `wb` 本机版本改成 `APP_VERSION_PLAIN`（引 `version.h`），最新版只在**比本机新**时才算「有新版」；
  `LatestGithub()` 顺带把 release 的 `html_url` 带回来，缓存里存 `wbUrl` / `wbRepo`。
- `her.h`：`UpdatesInfo` 增加 `wbRepo` / `wbUrl`（只是多两个字段，旧缓存读出来是空，不炸）。
- `ui_update.inc`：工作台那一行的状态词在「没查到/没配/无 release/断网」时统一显示
  **「本机 / 没查到」**，并且把「在查哪个仓库」写在描述里；按钮打开 `wbUrl`，没有就退回
  `https://github.com/<repo>/releases/latest`。

不做：自动下载 exe、静默替换、安装包自更新——快照版只把人送到浏览器。

## 2. 需求 2：维护页显示当前工作台版本

现状：`ui_maint.inc:226-234` 的版本行只拼 `g_mVers`（AstrBot / SnowLuma / Breeze 的组件版本），
工作台自己是版本源，却一个字都没显示。

改动：同一行前段固定是 `工作台 ` + `APP_VERSION`（宏，不硬编码），后面再接组件版本；
组件还没查到就只显示工作台版本，不再显示「版本还没取到」。

## 3. 需求 3：B 站相关统合 + bili-whale 配置界面 + DSH 对话 API

### 3.1 入口收进 B 站页

- B 站页（`ui_pages.inc:664` `PaintBili()`）右栏输入框下面加一行入口：
  **配置 / 诊断（登录·配额·风控·自检）/ 产物目录 / 队列**；
- 维护页只留 B 站状态摘要 + 「打开 B 站页」按钮（`maint:bili`）；
- 体检页、日志页原有的 `check:*` / CLI 一条不删，从 B 站页点诊断会跑同一条命令再翻到体检页看输出。

### 3.2 bili-whale 配置界面

- 文件：`FindWhale().config`（`%APPDATA%\MinglingWorkbench\bili-whale.config.json`，可被
  `BILI_WHALE_CONFIG` 覆盖），字段**按现有模板**取，不臆造（`sidecar\bili-whale.config.template.json`）：
  `preferences.like` / `preferences.dislike` / `preferences.keywords`、`diary.enabled` / `diary.push`、
  `quota.shareDaily`、`night.maxVideos` / `night.maxWakesPerDay` / `night.skipChance` / `night.minGapMin`、
  `risk.minGapMs` / `risk.readHourly` / `risk.readDaily` / `risk.writeHourly` / `risk.writeDaily`、
  `persona.name`；
- `grid` / `timeout` 不在配置文件里（是 `debrief --grid 3x3` 与看片超时的命令行参数），所以落到
  **工作台自己的** `settings.json`：`bili_grid`（默认 `3x3`）、`bili_timeout_sec`（默认 420）；
- 保存规则：先备份 `bili-whale.config.json.bak-<时间>`，改完 `her::J::Parse` 复核一遍 JSON，
  写失败就用备份回滚并提示；未知键（`listen` / `share` / `notify` / `owner` / `self` / `toolsPath` / `home`）
  原样保留；
- API Key 不写这份配置：DSH 对话的 key 走 `<Base>\secrets\dsh-api-key.txt`。

### 3.3 DSH 对话按 HTTP API 接

- 不装 DSH、不起 DSH、不读 `~/.dsh`；只做 OpenAI 兼容的 `POST <base><path>`（默认
  `https://api.deepseek.com` + `/chat/completions`），字段可配；
- `settings.json`：`dshapi_enabled`、`dshapi_base`、`dshapi_model`、`dshapi_path`、`dshapi_timeout`；
  key 在 `secrets\dsh-api-key.txt`；
- 配置面板给「启用 / Base URL / 模型 / 路径 / 超时 / 测试连接」；失败只影响对话，不影响 bili-whale 看片；
- 结果用在 B 站配置页的对话/解释场景（例如「帮我写一组 feed 偏好」），不进看片主链路。

## 4. 需求 4：输入框复制粘贴

现状：`ui_pages.inc:121` 只有 `CopyText()`（往剪贴板写），输入框只有一个 `g_editFocus` + `WM_CHAR`
追加字符（`ui_pages.inc:1340`），没有粘贴、没有右键菜单；`Ctrl+V` 落到 `WM_CHAR` 的 0x16 被 `ch >= 32` 挡掉。

改动：

- `webfetch.cpp`（新文件）加 `GetClipboardText()` / `SetClipboardText()`，走
  `OpenClipboard` + `CF_UNICODETEXT`，读出来 `Trim`；
- `UiOnKeyDown()`：输入框有焦点时自己吃 `Ctrl+V` / `Ctrl+C` / `Ctrl+X` / `Ctrl+A` / `Shift+Insert`，
  不再往下走到 1–9 切页；
- `WM_RBUTTONUP`（`main.cpp` 新增分支）→ `UiOnRClick()`：命中输入框就弹「粘贴 / 复制 / 全选 / 清空」；
- 粘贴上限从 200 放宽到 600 字符（分享文本比 BV 号长），仍然 `Trim`。

## 5. 需求 5：其他链接 / 分享文本读取 MVP

- 新增输入分类器 `ClassifyInput()`（`webfetch.cpp`）：B 站 BV/URL → 原 `StartWatch()` 链路（一点不改）；
  其他 `http(s)` → 通用读取；QQ/微信/抖音/小红书分享文本 → 提取首个 URL；本地 `.lnk/.exe` → 只「打开」；
- 通用读取：WinHTTP GET（跟随重定向、超时 `link_timeout` 默认 20s、大小上限 `link_max_kb` 默认 3072），
  解码按 `Content-Type`/`<meta charset>`，抽 `<title>` 和可读文本摘要，显示在结果区；
- 台账：`AppendJob()` 增加**可选** `type`（`"link"`），其余字段不变；`ReadJobs()` 对没有 `type` 的旧行照旧能读；
- 失败文案明确：超时 / 连不上 / 非 HTML / 无标题，各说各的，不弹异常。

## 6. 没在这次做、只留设计的部分

**读取应用内容**（微信/QQ 窗口里的聊天记录、抖音界面）：需要进程注入或 UI Automation 抓控件树，
跨应用、跨权限、跨版本，还不稳定。设计方向（不在本快照版实现）：

1. 只做**用户主动拖入**的文件（截图、导出的聊天记录 txt/html），不碰别的进程；
2. 真要抓窗口，用 UI Automation 读可见文本，由用户逐次授权，且只读不写；
3. 任何情况下不做键盘记录、不截屏上报、不后台常驻。

## 7. 提交切片（每片都能 `cd win32 && build.bat` 通过）

| # | 提交 | 内容 |
| --- | --- | --- |
| 1 | `docs: V3.0.0-snapshot 计划与验收` | 本文件 + `version.h` 升到 V3.0.0 |
| 2 | `feat(update): 工作台更新牵引 GitHub Releases` | `her_actions.cpp`、`her.h`、`ui_update.inc`、`ui_pages.inc` |
| 3 | `fix(maint): 维护页显示当前工作台版本` | `ui_maint.inc` |
| 4 | `feat(bili): B 站入口统合 + bili-whale 配置界面` | `biliapi.cpp`（新）、`core.h`、`ui_pages.inc`、`ui_maint.inc`、`build.bat` |
| 5 | `feat(api): DSH 对话 HTTP API 配置与测试连接` | `biliapi.cpp`、`ui_pages.inc` |
| 6 | `fix(bili): 输入框复制粘贴` | `webfetch.cpp`（新）、`ui.h`、`main.cpp`、`ui_pages.inc`、`build.bat` |
| 7 | `feat(input): 其他链接/分享文本读取 MVP` | `webfetch.cpp`、`core.h`、`whale.cpp`（台账 `type`）、`ui_pages.inc` |
| 8 | `docs: CHANGES/ACCEPTANCE 更新` | `docs\CHANGES.md`、`docs\ACCEPTANCE.md` |

回退：每片独立 `git revert <sha>` 即可；`version.h` 只在第 1 片，回退最后一并回到 V2.3.1。

## 8. 验收清单

| 项 | 怎么验 | 期望 |
| --- | --- | --- |
| 编译 | `cd win32 && build.bat` | 0 error |
| 版本一致 | `tools\check-version.ps1`、`MinglingWorkbench.exe --version`、维护页、侧边栏、帮助页、卸载列表 | 全是 `V3.0.0` / `3.0.0.0` |
| 更新页 | `settings.json` 写 `repo` 指向真仓库后点「再查一遍」 | 有新版出「去 GitHub 下载」，无新版「最新」，断网/无 release「本机 / 没查到」 |
| 维护页 | 打开维护页 | 版本行含 `工作台 V3.0.0`，组件版本仍在 |
| B 站配置 | 改一个字段、保存 | `.bak-<时间>` 存在、JSON 可读、未知键还在 |
| DSH API | 填 Base URL + key 点「测试连接」；断网再点一次 | 成功显示回话；失败只影响该面板，看片照旧 |
| 剪贴板 | 输入框 `Ctrl+V` / 右键「粘贴」，分别粘 BV、完整 URL、QQ 分享文本 | 都能粘进来并被正确识别；输入时按 `1–9` 不切页 |
| 其他链接 | 粘一个普通网页地址点「让她看」 | 结果区有标题 + 摘要；台账多一行 `type:"link"` |
| B 站回归 | 随便看一条 BV | 产物、正文、台账字段与 V2.3.1 完全一致 |

---

详单与实跑记录见 [ACCEPTANCE.md](ACCEPTANCE.md) 的 V3.0.0-snapshot 节；
为什么这么改见 [CHANGES.md](CHANGES.md) 第 14 节。
