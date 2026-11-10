# 安装与环境自动化（V3.1.0）

工作台的「补环境 / 装组件」现在只有一套实现：

- 清单：`tools/components.json` —— 每个组件怎么检测、从哪下、怎么校验、怎么装、怎么验证。
- 引擎：`tools/bootstrap.ps1` —— 按依赖拓扑排序，逐个「检测 → 安装 → 验证」，可重复跑。
- 调用方：工作台「一键自动配置」、`MinglingWorkbench.exe --autosetup / --bots-setup`、
  `installer/mingling.iss`、`skill/mingling-install`、旧脚本 `tools/auto-setup.ps1`（转发壳）
  全部指向同一个 `bootstrap.ps1`，不再各写一套下载逻辑。

八块自设定（provider → platform → chat → plugins → memory → voice → persona → verify）
仍由 `tools/self-setup.ps1` 负责；本次给它加了只读的 `-Verify` 模式，每块都有 apply 与 verify 两条路径。

---

## 1. 最快用法

```powershell
# 只检测：必需组件全齐退出码 0，有缺项退出码 2（不下载、不写文件）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -Check

# 补齐默认组件（可选且默认不装的不会装）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1

# 只补某几个（依赖会自动带上）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -Component node,ffmpeg

# 连可选组件一起装（本地嵌入模型、SoulX、桌宠等「可选且默认不装」的也会选进来）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -IncludeOptional

# 离线：只用已存在的文件和 logs\setup\dl 里校验通过的缓存，不联网
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -Offline

# 走代理（http/https/socks5）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -Proxy http://127.0.0.1:7890

# 指定工作区、日志落点
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 `
    -Base "D:\冥零 工作台" -Workspace "D:\冥零 工作台" -Bots "D:\冥零 工作台\bots" `
    -LogFile "D:\冥零 工作台\logs\setup\my.log"
```

工作台图形入口：维护页「一键自动配置」= 补环境（Node/ffmpeg/Python/WebView2）→ 装组件
（AstrBot、SnowLuma、Breeze、Ollama、bili-whale、启动脚本）→ 自设定八块，三段共用同一批脚本。

## 2. bootstrap.ps1 参数

| 参数 | 说明 |
| --- | --- |
| `-Base <dir>` | 工作台数据根。给 `{base}` 兜底、`logs\setup\` 与 settings.json 的位置。缺省先取 `MINGLING_BASE`，再读 `%APPDATA%\MinglingWorkbench\settings.json` 的 `base`，最后为脚本上一级（仓库根）。 |
| `-Workspace <dir>` | 工作区（机器人根）。缺省先取 `MINGLING_WORKSPACE`，再读 settings 的 `workspace`，最后等于 `-Base`。 |
| `-Bots <dir>` | 组件安装目录。缺省依次取环境变量 `MINGLING_BOTS`（且目录存在）、settings 的 `botRoot`、`<Workspace>\bots`。 |
| `-Component <id[,id]>` | 只处理点名的组件（逗号/顿号/分号/空白分隔），会按 `requires` 递归带上依赖。点名的可选组件也算「必需」，失败会让退出码非 0。 |
| `-Exclude <id[,id]>` | 从本次选择里排除；如果被选中的组件依赖它，直接报错，不会装出半套。 |
| `-Check` | 只检测：不下载、不解压、不建 dl/tmp 目录。 |
| `-Offline` | 禁止一切 `needs_network` 步骤；下载只接受 `logs\setup\dl` 里 sha256 对得上的缓存。 |
| `-Proxy <url>` | 写入 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY`（大小写都写）。日志里只记 `主机:端口`，不记账号密码。 |
| `-IncludeOptional` | 把 `optional=true 且 default_install=false` 的组件也纳入默认选择。 |
| `-Force` | 已满足也重装（重下、重解压、重写文件）。 |
| `-LogFile <path>` | 覆盖默认日志路径（父目录会自动创建）。 |

环境变量：`MINGLING_SIDECAR` 可把 sidecar 指到别处（node 装到 `<sidecar>\node`，
ffmpeg 装到 `<sidecar>\ffmpeg\bin`），验收脚本就是用它做隔离的。

## 3. 退出码与输出协议

| 退出码 | 含义 |
| --- | --- |
| `0` | 必需的、非人工的组件全部已满足或已装好 |
| `2` | 有必需组件缺失/安装失败（`-Check` 下即「有缺项」） |
| `1` | 脚本自身出错（清单坏了、参数非法、代理写错、拓扑有环等） |

标准输出里给人看的之外，还有给工作台/安装器解析的协议行（一行一条）：

```
##STEP <0-100>|<正在做什么>
##OK <id>|<已满足 或 装好了：证据>
##FAIL <id>|<缺什么 或 为什么失败>
##RESULT ok=<0|1> fixed=<n> satisfied=<n> manual=<n> missing=<n> failed=<n>
```

约定：`##FAIL` 只给「要求装却没成」的组件；可选项缺失打印 `[可选]` 说明但不阻断；
人工项打印 `[人工] <id>：未完成。<步骤>`，检测到已完成时给 `##OK`，永远不伪造成功。
出错时最后一行是 `##RESULT ok=0 error=<原因>`。

## 4. 清单格式（tools/components.json）

顶层：

```jsonc
{
  "schema": 1,
  "说明": "…",
  "tokens":  { "base": "…", "workspace": "…", "bots": "…", "sidecar": "…", "repo": "…", "astrbot_data": "…" },
  "mirrors": { "github": ["https://gh.dpik.top/", "…", ""], "npm": [...], "pip": [...],
               "huggingface": [...], "uv_python": [...] },
  "defaults": { "download_dir": "{base}\\logs\\setup\\dl",
                "temp_dir": "{base}\\logs\\setup\\tmp",
                "command_timeout_seconds": 600, "install_timeout_seconds": 1800 },
  "components": [ /* … */ ]
}
```

词元 `{base} {workspace} {bots} {sidecar} {repo} {astrbot_data}` 会先做字面替换，再做
`%ENV%` 展开；路径里带中文和空格都按字面处理（全程用 `-LiteralPath` / 引号包裹）。

组件字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 唯一标识，命令行 `-Component` 用它 |
| `name` / `version` / `notes` | 否 | 展示与说明 |
| `requires` | 否 | 依赖的组件 id，按拓扑排序后先装依赖 |
| `optional` | 否 | 可选组件：缺了不阻断必需项判定 |
| `default_install` | 否 | 默认全量跑时是否安装；`optional=true` 且为 `false` 的只有 `-IncludeOptional` 或点名才装 |
| `manual` | 否 | 只能人工完成的步骤（扫码登录、填 Key 等），bootstrap 只检测、不装、不算失败 |
| `manual_steps` | 否 | 人工步骤说明，缺项时原样打印 |
| `detect` / `verify` | 是 | 探针，见下 |
| `source` | 否 | 下载源信息（`kind/url/urls/sha256/size/note`），给人看，也方便维护者核对 |
| `install` | 是 | `{ "steps": [...], "fallbacks": [...] }`；`steps` 依次执行，全失败才依次试 `fallbacks` |

探针（`detect` 与 `verify` 同一套，可嵌套）：

- `file`：`paths[]` + 可选 `min_bytes`，任何一个存在即通过（目录也算存在）。
- `file_glob`：`patterns[]`，支持 `*`，取第一个命中。
- `file_recursive`：`dir` + `filter`，递归找第一个。
- `registry_value`：`root`（如 `HKLM`）、`key`、`name`、可选 `expect_regex`。
- `command`：`exe`、`args[]`、`expect_exit`（默认 0）、`expect_regex`、`timeout`。
  命中 `expect_regex` 时报告里显示命中的那一行，而不是整段输出。
- `any` / `all`：`probes[]`，任一通过 / 全部通过。

安装步骤 `kind`：

| kind | 主要字段 | 行为 |
| --- | --- | --- |
| `download` | `urls[]`、`sha256`、`size`、`dest`、`layout`（`direct`/`flatten`/`find_parent`）、`find` | 先查缓存，校验 sha256 与字节数；解压到临时目录再按 layout 安置；失败自动清理临时目录。**缺 64 位 sha256 直接拒绝安装**（不盲下）。 |
| `copy_tree` | `from`、`to`、`exclude[]` | 复制目录内容，跳过排除项（如 `node_modules`）。 |
| `copy_file` | `from`、`to`、`only_if_missing` | 默认覆盖；`only_if_missing` 用于配置模板。 |
| `write_file` | `path`、`content`、`encoding`（`ansi`/`utf8`/`utf8bom`） | 内容相同就不重写（幂等）；`content` 里的词元会展开。 |
| `mkdir` | `paths[]` | 建目录。 |
| `winget` | `id`、`scope`（`user`）、`silent` | 用户级静默安装；失败走 `fallbacks`。 |
| `uv_tool` | `package`、`uv_exe`、`tool_dir`、`bin_dir`、`python_dir`、`python_version` | 设好 `UV_TOOL_DIR/UV_TOOL_BIN_DIR/UV_PYTHON_INSTALL_DIR`，`uv tool install --force`，按 pip 镜像顺序回退，最后核对 `<bin>\<package>.exe`。 |
| `uv_python` | `version`、`install_dir`、`uv_exe` | 用 uv 装 Python（不可用 winget 时的备选），带 uv_python 镜像。 |
| `npm_install` | `dir`、`packages[]` | 只装缺的包；按 npm 镜像顺序回退，`--omit=dev --no-audit --no-fund`。 |
| `command` | `exe`、`args[]`、`timeout` | 跑命令，非 0 视为失败（如 `ollama pull`）。 |
| `env_user` | `name`、`value` | 写用户环境变量（如 `OLLAMA_MODELS`），失败不致命。 |
| `manual` / `none` | `steps[]` | 人工步骤占位 / 空操作。 |

镜像策略：GitHub 直链按 `mirrors.github` 顺序加前缀（空串代表直连）逐个试；
npm/pip/uv_python 在各自镜像列表里轮询，全部失败才报错。下载统一走 `tools/common.ps1`
的 `Get-File`：断点续传、大小与 sha256 双重校验、坏包删除、多地址依次尝试。

## 5. 状态、日志与脱敏

- 每次运行写一份日志：默认 `<Base>\logs\setup\bootstrap-<yyyyMMdd-HHmmss>.log`（`-LogFile` 可改）。
- 状态文件：`<Base>\logs\setup\state.json`（先写 `.tmp` 再原子替换），含本次参数快照、
  计数汇总，以及每个组件的 `{id,name,version,status,detail,optional,manual,at}`；
  `status` ∈ `ok / fixed / missing / failed / manual`（可选跳过记 `skipped`）。重跑时据此只补缺项。
- 所有写到屏幕、日志、state.json 的文本都过一层脱敏：`sk-*`、`Bearer …`、
  `api_key/token/secret/password=…`、URL 里的查询参数、`gh*_` 形式的 GitHub token、
  URL 里的 `user:pass@`、`QQ/账号=数字`。代理只记主机端口。
- 下载缓存：`<Base>\logs\setup\dl\<id>-<文件名>`，校验通过才复用；离线模式只认这些。

## 6. 密钥与账号

- bootstrap **不写任何密钥**，也不碰 `private/`、`secrets/`。
- 敏感项优先放 `<机器人根>\secrets\`；旧教程里的 `<机器人根>\private\` 仍然认：
  `self-setup.ps1` 的 `Read-Secret` 在清单/答案给的位置找不到时，会自动去另一个目录
  找同名文件（两边都有时按清单写的位置，通常是 `private\`）。常见文件：
  `deepseek-key.txt`、`owner-qq.txt`、`backend.txt`、`napcat-ws-token.txt`。
- 安装包只带 `secrets-README.txt` 说明；真实 Key / QQ 账号不进安装包，也不进日志。
- 八块自设定读这些文件；安装包只带 `pack/` 模板，不带真实 Key。
- 需要人工的：QQ 扫码登录（SnowLuma/NapCat）、B 站登录（bili-whale 扫码）、
  填 DeepSeek / 硅基流动 Key、AstrBot 插件市场装 LivingMemory、SoulX 唱歌、DSH 桌宠。
  清单里这些组件标 `manual=true` 并附 `manual_steps`。

## 7. 八块自设定：apply 与 verify

```powershell
# apply（默认）：provider → platform → chat → plugins → memory → voice → persona → verify
powershell -NoProfile -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Base "<机器人根>"

# 演练：不写配置，只报八块
powershell -NoProfile -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Base "<机器人根>" -DryRun

# 只核对，不改任何东西（不 PUT、不拍快照、不写文件）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Base "<机器人根>" -Verify

# 只核对某一块
powershell -NoProfile -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Base "<机器人根>" -Verify -Only memory
```

`-Verify` 与 `-DryRun/-Restore/-Apply` 互斥（同时给会以退出码 1 报参数冲突）。
verify 模式输出同样的 `##STEP/##OK/##FAIL`，`##RESULT` 里多一个 `mode=verify`；
失败是真失败（后台没起、模型不通、插件没装），不会写成通过。

## 8. 安装器里的调用

`installer/mingling.iss`：

- `[Files]` 带上 `tools\*.ps1`（含 `bootstrap.ps1`、`common.ps1`）与 `tools\components.json`。
- `[Run]` 末尾跑一次只检测，不阻塞安装、不让安装失败：

```
{sys}\WindowsPowerShell\v1.0\powershell.exe
  -NoProfile -ExecutionPolicy Bypass
  -File "{app}\tools\bootstrap.ps1"
  -Base "{code:WorkspacePath}" -Workspace "{code:WorkspacePath}" -Bots "{code:WorkspacePath}\bots"
  -Check -LogFile "{code:WorkspacePath}\logs\setup\installer-check.log"
```

`-Check` 只检测现有组件并向工作区日志留证据；当前 `[Files]` 没有打包 `bots\`，
首次安装的缺项仍需用户在工作台点「一键自动配置」补齐（联网下载几百 MB 不适合卡在安装向导里）。
`WorkspacePath` 在 `[Code]` 里定义，取 `/WORKSPACE` 或默认 `{userdocs}\冥零工作台`，
所以路径含中文/空格也能正确传参。

这条 `[Run]` 会建出 `<工作区>\logs\setup\` 并写一份 `installer-check.log`，除此不写任何文件
（`-Check` 不下载、不解压、不碰配置）。静默安装没带 `/WORKSPACE` 时，日志落在默认的
`{userdocs}\冥零工作台` 下，见第 11 节第 10 条。

自更新（`win32/src/her/her_selfupdate.cpp`）静默调安装包时会把当前工作区作为
`/WORKSPACE` 传进去，所以升级后这次体检查的是真工作区，不是默认目录。

## 9. 旧命令兼容

`tools/auto-setup.ps1` 保留原参数（`-Workspace -Bots -Base -Force -SkipOllama -SkipSnowLuma
-SkipBreeze -SkipAstrBot -SkipWhale`，另加 `-Offline/-Proxy`），内部把开关翻译成
`bootstrap.ps1 -Component … -Exclude …` 后原样转发输出和退出码。
老教程里的命令不用改，但新写的命令请直接用 `bootstrap.ps1`。

## 10. 升级安全（需求 7）

`win32/src/her/her_selfupdate.cpp` 的升级只覆盖八个程序目录
`bin / sidecar / tools / pack / plugin / skill / docs / art`，覆盖前把旧文件备份到
`<机器人根>\旧版\workbench-<tag>-<时间戳>\`；**不动** `bots\ private\ secrets\ out\ logs\`
以及用户工作区里的其它内容。

接入 V3.1.0 时唯一动到这套逻辑的地方：`RunInstaller()` 现在会把当前工作区作为
`/WORKSPACE` 传给安装包（以前不传，安装器只能按默认目录做收尾体检）。覆盖范围、备份位置、
静默参数都没改。

## 11. 已知限制（如实说明）

1. **清单里的 sha256 会随上游发版过期**。现在钉的是：node 22.14.0、uv 0.13.7、
   SnowLuma 2.4.2、Breeze 0.1.7、Ollama 0.40.15、FFmpeg autobuild-2026-11-08-12-35。
   上游换资产后要更新清单（`Get-FileHash` 取新值）；缺 hash 的下载会被拒绝而不是盲装。
2. **WebView2 走 winget**（`Microsoft.EdgeWebView2Runtime`），需要机器上有 winget；
   没有 winget 时只检测、不静默装（Evergreen 安装器也不适合静默分发）。
3. **安装器已在本机编译通过并实测静默安装**（V3.1.0 接入时）：用仓库自带的
   `tools\innosetup6\app\ISCC.exe` 编译 `installer\mingling.iss` 成功、无警告；
   装进含中文和空格的工作区后，`installer-check.log` 正常产出。语言文件走
   `compiler:Languages\ChineseSimplified.isl`（编译器自带那份，版本对得上），
   不要换成外部下载的 `.isl`——版本不一致会掉一批消息、退回英文。
   仍未验证：从 V3.0.0 正式版真实升级到 V3.1.0 的完整链路（只静态核对了升级目录与备份路径）。
4. **没有在本机跑完整全量安装**（Ollama 1.6GB、SoulX 2.8GB 模型等），只实测了
   下载/校验/解压/写文件/检测/离线/代理这些路径（node 22.14.0 实装成功）。
   2026-11-09 接手复测：隔离中文/空格目录真实安装 uv 0.13.7、SnowLuma 2.4.2、bots-launchers，
   exit 0，`##RESULT ok=1 fixed=3 satisfied=0 manual=0 missing=0 failed=0`；两个下载包 SHA256/字节数均匹配清单。
5. 可选项（Breeze、Ollama、bili-whale、embedding-model、SoulX、桌宠）失败默认不阻断
   必需项判定；但如果你 `-Component` 点名它们，失败就会让退出码变 2。
6. `write_file` 生成的是 ANSI 启动脚本（`start.cmd` 等），与仓库既有约定一致；
   在 UTF-8 编辑器里看到中文是乱码属正常，cmd 里执行正常。
7. SnowLuma/Breeze 的启动脚本按「目录里找 exe / 模型」生成，模型文件（`.gguf`）需要
   用户自备或另下，脚本只标注「缺模型」，不会假装装好。
8. 人工项（扫码、登录、填 Key、插件市场装记忆插件）脚本只检测完成状态，不代替用户完成。
9. 机器人根所在机器如果 PATH 里已经有 node/ffmpeg，检测会直接命中 PATH，不会强制把
   83 MB / 170 MB 的副本再下载进 `sidecar\`；验收「下载落盘」那条时要把 PATH 里的
   node/ffmpeg 临时去掉。
10. 安装器体检显式传入向导选择的 `WsPath`；已有 settings.json 时不会读取其中的真实工作区，
    因此**静默安装没带 `/WORKSPACE`** 时，这份体检可能检查的是默认目录，不能据此认定现有安装组件齐全。
    自更新会带 `/WORKSPACE`，那条路没有问题。
11. **清单认的是标准 bots 布局**：`{bots}\AstrBot\bin\astrbot.exe`、`{bots}\bili-whale\package.json` 等。
    手工搭的旧布局（例如 astrbot 装在 `bots\uv\bin`、数据在 `bots\<小写>\data`）会被判成「缺」，
    点了「一键自动配置」会按标准布局再装一份（Windows 目录不区分大小写，`data\` 还是同一个，
    但 exe 会多一份）。这类机器不用按钮、直接跑 `-Check` 看差哪几项再决定要不要补。
12. **已修的核对误报**：`self-setup.ps1 -Verify` 的自检块原先忽略诊断子进程退出码，
    没有任何 CHECK 输出也会成功。现在非 0 退出或无 CHECK 都返回失败；隔离替身回归 5/5，
    仍未在真实后台完成八块 apply/verify 端到端验证。

## 12. 排错

- 先看 `<Base>\logs\setup\bootstrap-*.log` 的最后 `##FAIL` 与 `[错误]` 行。
- `-Check` 退出码 2 但想确认到底缺哪个：看 `state.json` 里 `status=missing/failed` 的条目。
- 下载反复失败：加 `-Proxy`，或先手工把文件放进 `logs\setup\dl\<id>-<文件名>`（sha256 必须对）。
- 装了但工作台按钮仍红：确认 `-Bots` 指向的目录与工作台 settings 的 `botRoot` 一致；
  两边不一致时会在两个地方各装一套。
- 修改清单后先用 `-Check` 验证 JSON 与探针，再跑安装；拓扑有环/缺 sha256 会在第一步就报错。
