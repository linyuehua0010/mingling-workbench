# Criterion 2 — 来源完整性（supply-chain integrity）审计

- 审计对象：`F:\dsh工作区\MinglingWorkbench`（Windows，MSYS bash + PowerShell 5.1）
- 审计时间：2026-11-09，工作树 83 项未提交改动（只读审计，未修改任何产品文件；仅新增本目录 3 个文件）
- 审计人：teammate `integrity-audit`（只读分析员）
- 机读结果：`acceptance/analysis/integrity.json`；SoulX 专项：`acceptance/analysis/soulx.md`
- 判定口径（本文件"**真实端到端路径**"的定义）：①清单/锁内存在固定摘要；②存在 fail-closed 代码，在资产被使用**之前**把实际计算出的摘要与期望值比较；③失配时中断安装或拒绝使用，不静默降级。**只做格式校验（"是不是 64 位 hex"）不算**；语义错误（固定了错误的 digest、或固定的 digest 从未被安装路径读取）也不算。

---

## 1. 结论速览

| 分类 | 数量 | 组件 |
|---|---|---|
| A. 有真实端到端校验（比对 + 失配 throw） | **12** | webview2, node\*, ffmpeg\*, uv, python, astrbot(锁), snowluma, breeze, ollama, bili-whale(源码树), edge-tts(锁), **memory-plugin**（`tools/self-setup.ps1:845-860`，不在 bootstrap 内） |
| B. 清单里有哈希但**未被消费 / 语义错误** | **3** | bili-bridge-plugin（树清单无安装步骤消费）、soulx-singer（归档哈希未用，实为 `git clone` 默认分支 HEAD）、embedding-model（config digest 当 manifest pin + 装后只按名 verify） |
| C. 无资产 / 纯人工（哈希为 `e3b0c442…` 空串占位） | **6** | ollama-service, dsh-pet, bots-launchers, qq-login, bili-login, deepseek-provider |
| 合计 | 21 | — |

\* node/ffmpeg 有真实的下载校验，但存在旁路（随包二进制 / PATH 探针，见 §7）。**再扣除这两条旁路**后，对**全部用户可见字节**做了强校验的组件只有 **10** 个；node/ffmpeg 的 detect 在 `sidecar\node\node.exe` / `command ffmpeg` 已存在时直接判定"已满足"，不再触发下载校验，而这两个随包二进制本身在构建期无任何哈希。

**未签名的安装包**：`dist/MinglingWorkbench-3.1.0-setup.exe` = **NotSigned**，88,869,111 字节，SHA256 `AB8443BB94678115BBA720C8FA8012F48DE067702A9043055056C0751D172FBF`。整条"下载→安装"链路的最终信任锚是 **HTTPS + 清单里的 sha256 + 用户手动核对**，没有 Authenticode。

---

## 2. 校验原语（代码级，file:line 为 `tools/bootstrap.ps1`，共 1086 行）

### 2.1 下载步骤 `Invoke-DownloadStep`（:473-529）
| 阶段 | 行 | 行为 |
|---|---|---|
| 预检 | :475-476 | `if (-not $sha -or $sha.Length -ne 64) { throw ('清单里 {0} 的下载没有有效 sha256，拒绝盲下' -f $Comp.id) }` |
| 缓存命中 | :489-494 | 已有文件 `Get-FileHash` 与 `$sha` 比对，通过则复用；不通过继续下载 |
| 离线 | :495-496 | 无有效缓存直接 `throw ('离线模式：本机没有校验通过的缓存 {0}' …)` |
| 下载 | :503 | 调 `Get-File -Sha256 $sha`（见 2.2） |
| 下载后复检 | :504-505 | 再算一次 `Get-FileHash`，不等于 `$sha` 则 `throw ('SHA256 校验失败：' + $name)` |

失配后果：**硬失败**（该组件 `##FAIL`，`##RESULT ok=0`），不回退到"能跑就行"。

### 2.2 镜像轮询 `tools/common.ps1:12-105` `Get-File`
- :18-19 目标文件已存在且哈希通过 → 直接复用（不联网）
- :56-60 已下满但哈希不符 → 删除后重下
- :62-96 按镜像顺序 `curl -C - --retry 3` 下载；:89-92 **每个镜像下完都做一次 `Get-FileHash`**，不符则删文件换下一个源
- :100 所有源都失败 → `throw`（"几个下载地址都没下完…"）

镜像清单来自 `components.json` 的 `mirrors.github`（`Resolve-Urls` :455-471 给 GitHub URL 套 `gh.dpik.top` / `edgeone.gh-proxy.com` / `gh-proxy.org` 等第三方代理前缀）→ 代理只影响**可达性**，不影响摘要，因为摘要校验在下载之后、与源无关。这是本仓库设计上最扎实的一点。

### 2.3 Python 依赖锁（uv）——强约束
| 行 | 行为 |
|---|---|
| :581 | `$expectedLock = [string]$StepObj.requirements_sha256` |
| :583 | 对 `requirements.txt` 本体做 `Get-FileHash`，与 `requirements_sha256` 不等 → `throw '依赖锁 SHA256 校验失败'`（**锁文件被改即拒绝**） |
| :593 | `uv pip install --python <venvPython> --requirements <req> --require-hashes --no-build --no-python-downloads --cache-dir <cache> --find-links pack\mingling-vendor\wheels` |
| :610 | 组件没带带哈希的锁 → `throw ('{0} 未提供带哈希的依赖锁，拒绝执行不固定版本的 uv 安装')` |

`--require-hashes` + `--no-build` + `--no-python-downloads` 的组合语义：**每个包必须是 wheel 且哈希匹配**，禁止 sdist 现场构建、禁止 uv 自行下载解释器。这是全仓库最强的一条链。

### 2.4 npm `Invoke-NpmStep`（:630-678）——**非强制**
- :653-660 argv：`npm install --omit=dev --no-audit --no-fund --ignore-scripts`（离线加 `--offline`；配了镜像加 `--registry <url>`）
- :664-668 成功后只做 `require.resolve('$pkg')` 存在性验证
- :677 失败才 `throw ('npm install {0} 失败：{1}')`
- **没有 `npm ci`、没有 `--prefer-offline`、没有对 `package-lock.json` 做哈希固定、没有断言 npm 一定复用锁里的 `integrity`**。锁文件本身作为 `copy_file` 随包复制，integrity 字段是否生效完全取决于 npm 自身行为 → 归类为 best-effort。

### 2.5 源码树 `copy_tree` + `tools/source-manifest.ps1`（bootstrap :704-723）
- 步骤带 `manifest` 时调用 `powershell source-manifest.ps1 -Root $from -Verify -Manifest <json>`，读 stdout digest 与 `step.sha256` 比较；:715 不等 → `throw ('源码树 SHA256 校验失败：' …)`
- `source-manifest.ps1` 摘要算法：`sha256(` 逐文件 `path\0size\0file_sha256` 排序后 UTF-8`)`；排除 `.git`、`node_modules`、`Thumbs.db`、`.DS_Store`、`*.tmp|temp|log`
- `-Verify` 逐文件比 size/sha256，并检出"清单外新增文件"和"缺失文件"；不符处 :65 `throw "源码树摘要不符：清单 $($saved.digest)，实际 $digest"`
- 覆盖范围：只有**源码树内容**，不含 npm 依赖（`node_modules` 被排除，依赖靠 2.4 的 npm 自校验）

### 2.6 Ollama 模型（`components.json` 的 `embedding-model`）
- 拉取命令：`{bots}\Ollama\ollama.exe pull bge-m3@sha256:0c4c9c2a325fb1cdafec606e6809cb745f1cb26a6d919994400d27372303e276`（`needs_network`，timeout 3600）
- 安装后 verify：`ollama list` 正则匹配 `bge-m3` —— **只匹配名字，不比对 digest**
- 固定的 `0c4c9c2a…` 实测是 manifest JSON 里 `config.digest`（config blob，size 337），既不是 manifest 的 sha256（实测 `7907646426070047a77226ac3e684fbbe8410524f7b4a74d02837e43f2146bab`），也不是 layer digest（`daec91ff…` 1,157,671,200 B；`a406579c…` 1,068 B）。`ollama pull name@sha256:<config digest>` 在语义上是错的，真按此 pin 拉取会失败或落到非预期 manifest → 归类为"**有 pin 但 pin 错**"，实际生效的是 ollama 自己的 manifest 校验（TLS + 内容寻址），workbench 未参与。

### 2.7 安装后探针 `Test-Probe`（:1033 调用）
- 每个组件在 install 后跑 `verify` 探针（file 存在 / `min_bytes` / `command` / 正则）
- **只证明"装上了/能跑"**，不证明"装的是期望的字节"；`min_bytes` 是尺寸门限，可被同尺寸替换绕过。属于可用性检查，不属于来源完整性。

### 2.8 安装前预检（:881-893）
- 选中组件的所有 `download` step 必须带 64 位 sha256，否则 :891 `throw ('清单里 {0} 的下载缺少 sha256，拒绝安装')`
- 这是**格式校验**（防呆），真正的比对在 2.1。

---

## 3. 21 个组件逐资产表

> `sha256` 列取清单值前 8 位；"随包"= installer 发货；"下载"= 安装时联网取。  
> `mandatory`：Y=代码强制且不可跳过；Y\*=强制但存在旁路（随包二进制/PATH 探针先满足）；N=无校验或未生效。

| # | id | 版本 | 资产 / URL | 摘要来源 | 校验路径（file:line + 函数） | mandatory | 失配行为 | 随包/下载 |
|---|---|---|---|---|---|---|---|---|
| 1 | webview2 | 156.0.4314.58 | `msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/d5cc3c1c-…/MicrosoftEdgeWebView2RuntimeInstallerX64.exe`（镜像不适用，微软 CDN） | components.json `sha256 62863f0f…`，trust=winget-pkgs manifest 1.28.0 | bootstrap.ps1:473 `Invoke-DownloadStep` → :503 `Get-File -Sha256` → common.ps1:89-92 每镜像 `Get-FileHash` → :504-505 复检 | Y | throw `SHA256 校验失败：webview2…`，组件 FAIL | 下载（存 `{base}\logs\setup\dl\…`，再 `/silent /install`，accept_exit `0,-2147219416,-2147219187`，timeout 900s） |
| 2 | node | 22.14.0 | `npmmirror.com/mirrors/node/v22.14.0/node-v22.14.0-win-x64.zip` → `nodejs.org/dist/…`（双源） | `sha256 55b63929…` size 34,906,389 | 同 #1；dest `{sidecar}\node` flatten | **Y\*** | 下载路径同 #1；但 detect 先看 `{sidecar}\node\node.exe`，随包已存在即跳过 | **随包**（`sidecar\node\node.exe`，93,580,104 B，sha256 `ba4e6d11…`，清单里无此值）＋下载 |
| 3 | ffmpeg | autobuild-2026-11-08-12-35（N-128691-gcc583787bb） | `github.com/…/FFmpeg-Builds/releases/…/ffmpeg-N-128691-gcc583787bb-win64-gpl.zip`（走 GitHub 镜像前缀） | `sha256 33c5d91e…` size 201,796,363 | 同 #1；dest `{sidecar}\ffmpeg\bin`，`find_parent` 定位 `ffmpeg.exe` | **Y\*** | 同上；detect 另有 `command ffmpeg` 探针 → **PATH 里任何 ffmpeg 都算已满足，完全不校验** | **随包**（`sidecar\bili-whale\bin\ffmpeg.exe`）＋下载 |
| 4 | uv | 0.13.7 | `github.com/astral-sh/uv/releases/…/uv-x86_64-pc-windows-msvc.zip` | `sha256 0cdc5b38…` size 15,236,317 | 同 #1；dest `{base}\uv\bin` flatten | Y | 同 #1 | 下载（`uv/` 目录不进安装包） |
| 5 | python | 3.12.16+20261026 | `npmmirror.com` registry binary `python-build-standalone…install_only_stripped.tar.gz` → `github.com/astral-sh/python-build-standalone` 同名 | `sha256 1f2ab538…` size 22,014,416，trust="GitHub asset digest" | 同 #1；dest `{bots}\AstrBot\python` flatten | Y | 同 #1 | 下载 |
| 6 | astrbot | 4.29.4 | PyPI（uv tool install `astrbot`），依赖锁 `tools\astrbot-requirements.txt` | 锁本体 `requirements_sha256 53d20a66…`；另声明 `package_sha256 189e9b07…`（**bootstrap 从不读取**） | bootstrap.ps1:581-583 锁文件哈希 → :593 `uv pip install --require-hashes --no-build --no-python-downloads` → :610 无锁则 throw | Y | `依赖锁 SHA256 校验失败` / 逐包哈希不符时 uv 退出 → 组件 FAIL | 下载（PyPI + `pack\mingling-vendor\wheels` 本地 wheel） |
| 7 | snowluma | 2.4.2 | `github.com/…/SnowLuma/releases/download/v2.4.2/SnowLuma-v2.4.2-win-x64.zip` | `sha256 0912926c…` size 43,361,462 | 同 #1；dest `{bots}\SnowLuma` flatten | Y | 同 #1 | 下载 |
| 8 | breeze | 0.1.7 | `github.com/HoppouAI/Breeze-TTS-2.cpp/releases/…/breeze-tts-2-v0.1.7-windows-x64-vulkan.zip` | `sha256 63fb117e…` size 72,930,161 | 同 #1；dest `{bots}\Breeze` flatten | Y | 同 #1 | 下载 |
| 9 | ollama | 0.40.15 | `github.com/ollama/ollama/releases/…/ollama-windows-amd64.zip` | `sha256 9ca74a7a…` size 1,614,941,966（1.6 GB） | 同 #1；dest `{bots}\Ollama` flatten | Y | 同 #1 | 下载 |
| 10 | ollama-service | — | 无资产（`source.kind=none`，sha256 `e3b0c442…` 空串哈希） | 无 | 无；install 只跑 `start-ollama.ps1 -Base -Exe {bots}\Ollama\ollama.exe` | N（无资产） | 不适用 | 随包脚本 |
| 11 | bili-whale | 0.4.6 | `{repo}\sidecar\bili-whale`（随包） | source.sha256 `ee758a98…` + `tools\source-manifests\bili-whale.json`（126 文件） | bootstrap.ps1:704-723 `copy_tree` → `source-manifest.ps1 -Verify` 比 stdout digest；:715 throw | Y（内容） | `源码树 SHA256 校验失败` | **随包**；`copy_file package-lock.json` + `npm_install qrcode@1.5.4`（npm 侧 best-effort，见 §5） |
| 12 | memory-plugin | manual（组件级） | `codeload.github.com/lxfight/astrbot_plugin_livingmemory/tar.gz/f8bfee88…` | source `sha256 ff2056ce…` size 2,352,991 | **不在 bootstrap 内，而在自设定脚本**：`tools/self-setup.ps1:844-860` — 读 `components.json` 取 sha256 → :845 非 64 hex 则 `FailLine "清单缺长期记忆插件的固定 SHA256，拒绝从市场盲装"` → :851 缓存 `memory-plugin-<12hex>.tar.gz` 哈希比对 → :853 离线无有效缓存 FailLine → :857-860 下载后再算 `Get-FileHash`，不符则删缓存 + `FailLine "SHA256 校验失败，已删除缓存并拒绝安装"` | Y（memory 块启用时） | FailLine + `return $false`，块失败 | 下载（用户跑 `-Only memory` 时） |
| 13 | bili-bridge-plugin | manual | `plugin\astrbot_plugin_bili_bridge`（随包） | `e060e1b5…` + `tools\source-manifests\bili-bridge-plugin.json`（9 文件） | 同上机制存在，但 install 只有 `manual`（"在自设定 plugins 块启用"）→ **没有 copy_tree 步骤，清单不被消费** | N | 不适用 | **随包** |
| 14 | embedding-model | bge-m3 | Ollama registry (`ollama pull`) | `sha256:0c4c9c2a…`（**实为 config.digest**；manifest 自身 sha256 `79076464…`） | install 命令做 pin；verify 只 `ollama list` 正则 `bge-m3` | N（pin 错、verify 只按名） | 名字在即 PASS，digest 不符不会失败 | 下载（`needs_network`，timeout 3600s） |
| 15 | soulx-singer | manual | `codeload.github.com/Soul-AILab/SoulX-Singer/tar.gz/81aeb3ae…` | `sha256 b1a1e961…` size 12,975,795 | **安装步骤不用该哈希**：`git clone --depth 1` 默认分支 HEAD；bootstrap 只 detect | N | 不适用（见 soulx.md） | 下载（人工路径）＋模型 2.8 GB 另下 |
| 16 | dsh-pet | manual | 无（`kind=none`, `e3b0c442…`） | 无 | 无；人工跑 `tools\setup-pet.ps1` | N | 不适用 | 随包脚本 |
| 17 | edge-tts | PyPI | `uv tool install edge-tts`，锁 `tools\edge-tts-requirements.txt`，python=`{bots}\AstrBot\tools\astrbot\Scripts\python.exe` | `requirements_sha256 889c13b3…` | bootstrap.ps1:581-583 + :593（同 #6） | Y | 同 #6 | 下载 |
| 18 | bots-launchers | — | 无（`kind=none`, `e3b0c442…`） | 无 | 无；只 `write_file {bots}\start-all.cmd` | N | 不适用 | 随包脚本 |
| 19 | qq-login | manual | 无（`kind=none`, `e3b0c442…`） | 无 | 只有 detect 探针 | N | 不适用 | — |
| 20 | bili-login | manual | 无（`kind=none`, `e3b0c442…`） | 无 | 只有 detect 探针 | N | 不适用 | — |
| 21 | deepseek-provider | manual | 无（`kind=none`, `e3b0c442…`） | 无 | 只有 detect 探针 | N | 不适用 | — |

补充事实：
- `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` 是空字符串的 SHA256，被用作"无资产"占位而不是 `null`；`Invoke-DownloadStep` 对 `kind=none` 不执行，因此不会误报，但**统计/审计时容易误算成"有哈希"**。
- 7 个 `manual` 组件在 bootstrap 中只走 detect（:987），装后统一 verify（:1033）；manual 不等于"已校验"。

---

## 4. Python wheels / requirements 锁

| 文件 | 逻辑行 | requirement 数 | `--hash=sha256:` 数 | 缺哈希的 requirement | 环境标记 | 文件 sha256 | 与清单一致 |
|---|---|---|---|---|---|---|---|
| `tools/astrbot-requirements.txt` | 516（3768 物理行，含续行） | 154 | 3252 | **0** | 0 | `53d20a66ed025b7305db0227dcf02d1d5d5c8456cda436cf31ba0d2817f44317`（285,804 B） | ✅ `requirements_sha256` |
| `tools/edge-tts-requirements.txt` | 39（780 物理行） | 14 | 741 | **0** | 0 | `889c13b325e79e7377d04e4cbf314168d0d4b50438a8c44cdc821efafd6f3261`（64,080 B） | ✅ `requirements_sha256` |

- 两锁去重后共 **3263** 个 sha256。
- 无 `--no-binary`、无 sdist 直链、无 `-e`、无 `--index-url` 覆盖（索引由 uv 默认 + 本地 `--find-links` 决定）；配合 `--no-build`，**任何 sdist 都会被拒绝**。
- 本地 `pack\mingling-vendor\wheels` 的两个 wheel 哈希均在锁内：`aiocqhttp-1.4.4-py3-none-any.whl` = `c706536d2399cf8f58ab9d5e4bba23d0eed104d497df6cf86ad0cf5862aa9ee2`，`jieba-0.42.1-py3-none-any.whl` = `bb0b3f305325e2cc7df2b95de34275094a420bc6836bc6db40941433706ffdad`（`--find-links` 的包同样受 `--require-hashes` 约束）。
- **锁的生成过程不在仓库内**（无 `uv.lock`、无脚本记录由谁在何时解析），只固定了结果。锁文件本体又有 `requirements_sha256` 二次固定 → 可防止"锁被换成另一份自洽的锁"。这一层是 criterion 要求的实质内容。
- 例外：`memory-plugin`（tarball，哈希校验在 `tools/self-setup.ps1:845-860`）与 `soulx-singer`（全链无哈希）都不使用这两份 pip 锁，也没有 `--require-hashes`。

---

## 5. npm（`sidecar/bili-whale`）

| 项 | 值 |
|---|---|
| lockfileVersion | 3 |
| name | `dsh-bili-whale` |
| `packages` 条目 | 30（含根） |
| `node_modules/*` 条目 | 29 |
| 带 `integrity` 的条目 | **29 / 29**（缺 0） |
| 根 `dependencies` | `{"qrcode": "1.5.4"}` |
| 安装方式 | `npm install --omit=dev --no-audit --no-fund --ignore-scripts`（bootstrap.ps1:653-660） |
| 是否 `npm ci` | **否** |
| 是否断言锁被使用 | **否**（:664-668 只 `require.resolve`） |
| 锁文件本身是否有哈希固定 | **否**（`copy_file` 直接复制，无 expected hash） |

结论：`package-lock.json` 的 29 个 `integrity` 字段是真实的（格式 `sha512-…`），但 workbench **没有**任何代码路径断言"安装时使用了这份锁且 integrity 全部匹配"。npm 在存在 lockfile 且版本满足时通常会复用 integrity；一旦 npm 决定重新解析（例如 registry 元数据变化、缓存损坏、`--registry` 指向不同源），workbench 不会察觉。→ **best-effort，非强制**。另 `--ignore-scripts` 是正确的（阻断 install 钩子执行任意代码）。

---

## 6. 随包二进制与构建期缺口（`tools/fetch-runtime.ps1`）

| 文件 | 现状 | 哈希固定？ |
|---|---|---|
| `sidecar\node\node.exe` | 93,580,104 B，sha256 `ba4e6d110e8c1592a1ecd390f6b05f3da124b13871a5be62b341a07a853c6c32` | **否**：`fetch-runtime.ps1:33` 取 `nodejs.org/dist/index.json` 的"最新 LTS"，:38 `Invoke-WebRequest` 直下 node.exe；无哈希、无大小校验、无版本固定 |
| `sidecar\bili-whale\bin\ffmpeg.exe` | 随包 | **否**：`fetch-runtime.ps1:48-51` 下 `gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip`（"release"滚动标签）解压取 ffmpeg.exe |
| `uv\bin\uv.exe`（开发树） | 31,803,184 B，sha256 `1791d7a9ed5b6df13ccf80f102e025c333010d96326b4ff0262aa3b578835c5a`，`uv --version` = `uv 0.13.7 (316c827e0 2026-11-03 x86_64-pc-windows-msvc)` | 版本号与清单一致，但**不是**清单固定的那个 zip 的产物，且 `uv/` 不进安装包 |

安装包（`installer/mingling.iss`）会把这些**未固定哈希的构建产物**直接发给用户；用户在本地跑 `bootstrap.ps1` 时，node/ffmpeg 的 detect 探针看到它们就判"已满足"，于是**下载路径的 sha256 校验根本不会触发**。这是 §1 中"12 → 10"的实质原因，也是 criterion 意义上最该修的一处：**构建期必须在打包时把 node.exe/ffmpeg.exe 的实际 sha256 写回 components.json（或在 .iss 里做编译期校验）**。

---

## 7. 安装包签名

```
PS> Get-AuthenticodeSignature 'dist\MinglingWorkbench-3.1.0-setup.exe' | Format-List *
Status            : NotSigned
StatusMessage     : The file F:\dsh工作区\MinglingWorkbench\dist\MinglingWorkbench-3.1.0-setup.exe is not digitally signed. …
SignerCertificate : <none>
Size              : 88,869,111 字节
SHA256            : AB8443BB94678115BBA720C8FA8012F48DE067702A9043055056C0751D172FBF
```

- 与 `acceptance/stage/checksums.txt` 中记录的 `ab8443bb…` **一致**（说明发布侧至少留了正确的 sha256 记录）。
- `dist/` 存在 `.sha256` 边车惯例（如 `MinglingWorkbench-3-snapshot-3-setup.exe.sha256`，107 B），但**没有任何代码消费它**：安装器不校验自身，自更新器只在 release 附了 `.sha256` 时"顺手比一下"（§8）。
- 威胁含义：用户从任何镜像/网盘拿到 setup.exe，没有任何方法验证来源；User Account Control 只显示"未知发布者"。

---

## 8. 自更新与 skill 自更新（两条未覆盖链）

### 8.1 程序自更新（`win32/src/her/her_selfupdate.cpp` + `ui_update.inc`）
- :409-443 从 GitHub release 资产里找名字含 `setup` 的 `.exe`；:432-434 顺带找 `<setup名>.sha256` 存进 `a.shaUrl`。
- `ui_update.inc:306-313` 先只比 `(long long)a.size`（期望大小 vs 下载大小）。
- `ui_update.inc:314-333` best-effort 校 sha256：注释原文「release 上挂了 .sha256 就核对；没挂就只能信大小」；:323 调 `her::Sha256File(dest, nullptr)`；`.sha256` 缺失或下载失败时**静默跳过**；:326 文案「校验没通过（哈希对不上），已经放弃安装」。
- `Sha256File` 定义 `her_selfupdate.cpp:141`，全仓库只有两处调用：`main.cpp:503`（`--wb-get` CLI）与 `ui_update.inc:323`。
- 安装阶段 `RunInstaller`（`her_selfupdate.cpp:571-595`）直接 `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /WORKSPACE … /DIR … /LOG …`，**无签名校验、无二次哈希**。
- `tools/finish-update.ps1:25` 对 `.new` 算 sha256，:42-43 复制后再算 target 比对（不符 `exit 6`）→ 只保证复制完整，**不是真伪**（`.new` 本身就是下载来的）。
- 结论：更新链的完整性 = TLS + GitHub 账号安全 + 可选 `.sha256`；**若攻击者能改 release 资产（或劫持 token），缺少任何本地信任锚**。

### 8.2 Skill 自更新（`win32/src/her/her_actions.cpp:1312-1346`）——最弱环节
```
:1312-1330  用 PowerShell 从 https://github.com/<repo>/releases/latest/download/mingling-install.zip 下载
            （私有仓库走 api.github.com assets + token，:1322）
:1332       唯一校验： if ((Get-Item $zp).Length -gt 10000) { $got = $true }
:1335       只检查包内存在 SKILL.md / version.json / scripts\finish.ps1
:1346       & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fin -Dir $Dir
```
即：**任何 >10 KB 的 zip，只要根目录有三样名字对得上的文件，其内的 `finish.ps1` 就会被 `-ExecutionPolicy Bypass` 直接执行**。没有哈希、没有签名、没有发布者身份校验。这是用户机器上"可被远程替换代码执行"的口子；即使仓库是私有的，信任也完全依赖 GitHub 账号/token 的保密性。

---

## 9. 磁盘本地副本哈希核对（实际执行）

| 对象 | 期望值（来源） | 实测 | 结果 |
|---|---|---|---|
| `tools/components.json` | 无独立清单；`acceptance/stage/checksums.txt` 记 `f9ac5a78…` | `f9ac5a7890ff3ee3a6c4f250021bef0138281df5720b2260573c55780eb0b02c`（50,504 B） | ✅ 与 stage/checksums 一致；`acceptance/stage/components.json` 与仓库版**逐字节相同** |
| `tools/astrbot-requirements.txt` | `requirements_sha256 53d20a66…` | 同 | ✅ |
| `tools/edge-tts-requirements.txt` | `requirements_sha256 889c13b3…` | 同 | ✅ |
| `sidecar/bili-whale` 树 | `ee758a98…`（`bili-whale.json`） | `source-manifest.ps1 -Verify` → `ee758a98…`，exit 0 | ✅ |
| `plugin/astrbot_plugin_bili_bridge` 树 | `e060e1b5…` | `-Verify` → `e060e1b5…`，exit 0 | ✅ |
| `pack/mingling-pack/plugins/astrbot_plugin_dafeiyu_sing` 树（16 文件） | `f1eb34a5…`（`tools/source-manifests/dafeiyu-sing-plugin.json`） | `-Verify` → `f1eb34a503098954e8c93ae697cda6b696441a8f515f0d3b4292538e33ad2839`，exit 0 | ✅ **但全仓库无任何引用该清单的安装步骤 → 死资产** |
| `.workbuddy/acceptance/SoulX-Singer-81aeb3a.tar.gz` | `b1a1e961…`（soulx 组件 source.sha256） | 12,975,795 B，`b1a1e9615f8832012396aa306a5de5a6157f4c193c4ce08b3ee35a7983dcee7b` | ✅ |
| `.workbuddy/acceptance/livingmemory-f8bfee8.tar.gz` | `ff2056ce…` | 2,352,991 B，`ff2056ce7c048072117c393f5c2e73555107f2d10a865cd2091c6b2788276822` | ✅ |
| `.workbuddy/acceptance/bge-m3-manifest.json` | 无独立期望 | 563 B，sha256 `7907646426070047a77226ac3e684fbbe8410524f7b4a74d02837e43f2146bab`；内容 `config.digest=0c4c9c2a…`、layers `daec91ff…`/`a406579c…` | ⚠️ 与清单 pin 的 `0c4c9c2a…` 不是同一层语义（见 §2.6） |
| `sidecar/node/node.exe` | **无期望值** | 93,580,104 B，`ba4e6d11…` | ❌ 无覆盖 |
| `uv/bin/uv.exe`（开发树） | 清单固定的是 zip 的 sha256，不是 exe | 31,803,184 B，`1791d7a9…`，版本自报 0.13.7 | ⚠️ 版本对、哈希无对照 |
| `dist/MinglingWorkbench-3.1.0-setup.exe` | `acceptance/stage/checksums.txt` `ab8443bb…` | 88,869,111 B，`AB8443BB…172FBF` | ✅ 文件未损坏；**但未签名（§7）** |

**未发现任何哈希失配**：仓库内被清单覆盖的文件都与清单一致。风险不来自"文件坏了"，而来自"有些文件根本没被固定"。

---

## 10. 代表性篡改拒绝测试（真实执行）

### T1 — 下载缓存投毒（通过）
```bash
T=$(mktemp -d /tmp/mltamper.XXXX)
mkdir -p "$T/logs/setup/dl"
printf 'THIS-IS-NOT-NODE-ZIP' > "$T/logs/setup/dl/node-node-v22.14.0-win-x64.zip"
powershell -NoProfile -ExecutionPolicy Bypass -File tools/bootstrap.ps1 \
  -Base "$(cygpath -w "$T")" -Component node -Offline -LogFile "$(cygpath -w "$T")\t.log"
```
实际输出：
```
[安装] Node.js 运行时（22.14.0）
##FAIL node|装失败：离线模式：本机没有校验通过的缓存 node-node-v22.14.0-win-x64.zip
##RESULT ok=0 fixed=0 satisfied=0 manual=1 missing=0 failed=1
```
（`-Component node` 会带上 manual 依赖 `bili-login`，故 `manual=1`。）证明：**缓存里的字节不可信 → 拒绝使用**（bootstrap.ps1:490/496）。

### T2 — 源码树篡改（通过）
```bash
cp -r plugin/astrbot_plugin_bili_bridge /tmp/mltree
printf '\n# tampered\n' >> /tmp/mltree/main.py
powershell -NoProfile -ExecutionPolicy Bypass -File tools/source-manifest.ps1 \
  -Root /tmp/mltree -Verify -Manifest tools/source-manifests/bili-bridge-plugin.json
```
实际输出（stderr/异常）：
```
源码树摘要不符：清单 e060e1b57194297f783ec0c93610d7e737f06bdeade7792ad69901dc35b28d4f，实际 370ab5e182a4b8726d886a7b94fd19bcdc598ab488a2051bfc642e1da350f9ac
```
throw 于 `tools/source-manifest.ps1:65`，进程 `exit 1`。证明：单文件内容篡改会改变树摘要并被拒绝；该函数就是 `copy_tree` 依赖的那一个。

### T3 — uv 逐包哈希（**未执行，环境阻断**）
尝试用全零哈希对 `aiocqhttp` 做 `uv pip install --require-hashes`，uv 0.13.7 在本机连缓存/暂存目录都无法创建：
```
error: 拒绝访问。 (os error 5) at path "C:\Users\Mingling\AppData\Local\Temp\.tmpNrnosC"
failed to open file ...\uvtamper\cache\.lock: 拒绝访问。 (os error 5)
```
`uv venv` 亦失败（默认 `C:\Users\Mingling\AppData\Local\uv\cache\.lock` 同样拒绝访问）。未联网、未安装任何东西。
→ 该机制目前只有**代码可证**（`--require-hashes` 的语义由 uv 保证，且 :583 的锁文件哈希已被 T2 同类机制覆盖），**没有实测证据**。criterion 若要求"对实际启用的机制执行代表性篡改拒绝测试"，T1/T2 已满足两条主力链路，T3 应记为"代码可证、环境未实测"。

### 未做的测试（诚实声明）
- 未篡改**已签名/已发布**的 setup.exe 或其下载源（需要改 CDN / 中间人，超出只读与网络约束）。
- 未对 Windows 的 `dist/` 资产做"换包"测试（dist 是只读审阅对象，不移动）。
- 未测 npm integrity 拒绝（需要联网 + 可写 npm 缓存；本机 npm 缓存目录权限受限，未尝试写入）。

---

## 11. 未覆盖清单（"未覆盖范围"，criterion 要求逐项列明）

1. **安装包本体未签名**（§7）——无法验证"这个 setup.exe 是项目方发布的"。`dist/*.sha256` 边车存在但无消费者。
2. **随包 `sidecar\node\node.exe` 无任何哈希**（构建期 `fetch-runtime.ps1:33-38` 取"最新 LTS"，滚动版本）→ 用户机器上实际运行的 Node 从未被清单固定。
3. **随包 `sidecar\bili-whale\bin\ffmpeg.exe` 无任何哈希**（`fetch-runtime.ps1:48-51` 取 gyan.dev "release" 滚动包）。
4. **ffmpeg 的 detect 探针接受 PATH 里任意 `ffmpeg`**（components.json `command ffmpeg`）→ 系统里已有的 ffmpeg 直接满足，安装器不再下载/校验。
5. **node 的 detect 探针接受 `{sidecar}\node\node.exe` 即满足** → 组合第 2 条，下载路径的 sha256 通常不会被执行。
6. **npm 依赖无强制完整性**（§5）：无 `npm ci`、无锁哈希固定、无 integrity 断言；`package-lock.json` 的 29 个 integrity 仅在 npm 自愿复用时生效。
7. **`embedding-model` 的 ollama digest pin 语义错误 + verify 只按名字**（§2.6）：pull 的 `@sha256:0c4c…` 指向 config blob；`ollama list | match bge-m3` 不校验模型内容。
8. **`soulx-singer` 的归档哈希未被任何安装步骤使用**：清单固定 `b1a1e961…`（commit `81a3eb3a…`），实际脚本 `git clone --depth 1` 默认分支 HEAD；后续 2.8 GB 模型、CUDA torch、Python 3.10 解释器全部无哈希（详见 soulx.md）。
9. **`memory-plugin` 的校验不在 bootstrap 内**：它由 `tools/self-setup.ps1:845-860` 自己完成（要求 64 hex、缓存 `Get-FileHash`、失配删缓存并拒绝），但该逻辑只在用户真正跑 memory 块时执行；bootstrap 的 manual 步骤只 detect。没跑过 memory 块的机器上，这份哈希不提供任何保护，且该路径同样没有签名锚。
10. **`bili-bridge-plugin` 清单是死资产**：`tools/source-manifests/bili-bridge-plugin.json` 存在且当前树匹配，但没有任何 install step 引用它（install 只有 manual）。
11. **`dafeiyu-sing-plugin.json` 同样是死资产**：`tools/source-manifests/dafeiyu-sing-plugin.json` 匹配当前 16 文件树（`f1eb34a5…`），全仓库无引用。
12. **skill 自更新无任何校验并执行包内代码**（§8.2）→ 远程代码执行面。
13. **程序自更新只看大小 + 可选 `.sha256`**（§8.1），且从不校验 Authenticode。
14. **`guest-acceptance.ps1` 经明文 HTTP 下发**（`acceptance/stage/download-guest.txt`：`certutil -urlcache -f http://192.168.206.1:8000/guest-acceptance.ps1 …`）→ 测试基础设施本身就演示了"无哈希远程执行"。
15. **`uv python 3.10`（SoulX）与 uv 自带的解释器下载**：无版本+build 固定、无哈希。
16. **锁的生成过程不在仓库**：无法审计"这些哈希当初是从哪个索引、什么时间抓的"；若上游发生同名不同内容（例如被劫持的索引），锁只能保证"永远是那一份"，不能保证"那一份是干净的"——除非有人复核过。这是所有哈希锁的共性边界，列此以免夸大。
17. **installer 的 `_Check` 模式**（mingling.iss:126）只 detect，不校验已存在资产的哈希；即"装完再跑检查"也不会发现 node.exe/ffmpeg.exe 被替换。
18. **`tools/self-setup.ps1` 的 plugins 块无任何哈希校验**：全文件只有 memory 块（:844-860）出现 sha256 逻辑；其余 10 个随包插件（含 `astrbot_plugin_dafeiyu_sing`）走 AstrBot API 安装，来源是安装包内文件，**没有逐文件/逐树摘要**，也不消费 `tools/source-manifests/dafeiyu-sing-plugin.json`。

---

## 12. Criterion 2 判定

- 该 criterion 明确否定"只检查 SHA256 是否为 64 位字符串"。**代码层面确实超越了格式校验**：下载后比对（2.1）、镜像逐个校验（2.2）、锁文件哈希 + `--require-hashes`（2.3）、源码树内容摘要（2.5）都是真实实现，且有两条实测的篡改拒绝证据（T1、T2）。
- 但"逐资产覆盖"**不成立**：21 个组件里 12 个有强制链（其中 node/ffmpeg 可被随包二进制/PATH 旁路；memory-plugin 的校验在 `self-setup.ps1` 而非 bootstrap），3 个 pin 未被消费或语义错误（bili-bridge-plugin、soulx-singer、embedding-model），6 个无资产。另有 §11 的 18 项缺口，其中第 2、3、6、8、12、18 项属于"实际启用的机制上没有校验"。
- 因此：**"来源完整性"在核心二进制/Python 依赖链上成立，在随包二进制、npm、Ollama 模型、SoulX 人工链、自更新与 skill 自更新上不成立。** 若验收要求"全资产、含人工路径"，应判**部分满足**；给出的最小整改顺序：①构建期把 node.exe/ffmpeg.exe 的 sha256 写回清单并在 `-Check` 中比对；②`npm ci` + 锁文件哈希固定；③修 embedding-model 的 digest 语义并按 digest verify；④skill 自更新加 sha256（release 旁挂 `.sha256`）+ 拒绝执行未校验包；⑤SoulX 改 `git clone` 固定 commit 或直接解压已固定的归档。

---

## 13. TASK 2 — `bootstrap.ps1` 的拉起链（installer 布局 vs skill 布局）

### 13.1 所有拉起位置

| # | 位置 | 期望绝对路径 | 参数 | 有哈希校验吗 |
|---|---|---|---|---|
| 1 | `win32/src/her/her_setup.cpp:92`（工作台 GUI 安装/配置） | `Root()\tools\bootstrap.ps1`，其中 `script = JoinPath(JoinPath(Root(), L"tools"), L"bootstrap.ps1")` | `powershell -NoProfile -ExecutionPolicy Bypass -File "<script>" -Base "<Base>" -Workspace "<WorkspaceDir>" -Bots "<BotRoot>"` + `extra`（如 `" -Component webview2,node,ffmpeg,python"`） | **无** |
| 2 | 同上 `AutoSetup`（her_setup.cpp:142-168） | 同上 | `-Component webview2,node,ffmpeg,python` | **无** |
| 3 | 同上 `BotsSetup`（her_setup.cpp:~224） | 同上 | `-Component uv,astrbot,snowluma,breeze,ollama,bili-whale,bots-launchers` | **无** |
| 4 | `installer/mingling.iss:126`（安装收尾） | `{app}\tools\bootstrap.ps1` | `-Base {code:WorkspacePath} -Bots … -Check -LogFile …\installer-check.log`（只 detect） | **无** |
| 5 | `skill/mingling-install/scripts/bootstrap.ps1:5-14`（skill 包装） | `$program\tools\bootstrap.ps1`，`$program` 由 `resolve-program-root.ps1` 解析 | 原样转发 `@args`；先打印 `##BOOTSTRAP <path>` | **无** |

入口：`win32/src/main.cpp:393`（`--bots-setup`）、`:406`（`--autosetup`）。超时/判定：`her_setup.cpp:118` `RunCaptureStream` 45 分钟；`:124-133` 只认 `##RESULT ok=1` 且无 `##FAIL`。

### 13.2 期望路径怎么来（两套解析器，可能不一致）

**工作台侧 `Root()`（`win32/src/her/her_config.cpp:48-63`）**：
1. exe 所在目录若含 `tools\` → 用它；
2. 否则 exe 在 `bin\` → 用上一级；
3. 否则在 `build\` → 用上两级；
4. 否则 `WorkspaceDir()`、再 `Base()`（哪个含 `tools\` 用哪个）；
5. 都不行 → exe 目录。

**skill 侧 `resolve-program-root.ps1:4-28`**：
1. `ValidRoot($p)` 要求 `<p>\tools\bootstrap.ps1` **存在**（:4-9）；
2. 候选顺序（:10-21）：`HKCU:\Software\MinglingWorkbench` 的 `ProgramRoot` → `HKCU:\...\Uninstall\MinglingWorkbench_is1` 的 `InstallLocation` → `%LOCALAPPDATA%\Programs\MinglingWorkbench`；
3. 全不中 → :28 报错，`bootstrap.ps1:11-13` 打印「程序目录里没有 bootstrap.ps1：$bootstrap」并 `exit 2`。

安装器在 `mingling.iss:336` 写 `HKCU\Software\MinglingWorkbench\ProgramRoot = {app}`，所以**安装版布局下两侧都解析到 `{app}\tools\bootstrap.ps1`，一致**。

### 13.3 会不一致的硬编码情形

| 情形 | 工作台 `Root()` 结果 | skill 结果 | 后果 |
|---|---|---|---|
| 安装版（标准 `{app}`） | `{app}` | `ProgramRoot = {app}` | 一致 |
| 自定义安装目录 + 注册表写入失败/被清理 | `{app}`（exe 同级有 tools\） | 回退 `%LOCALAPPDATA%\Programs\MinglingWorkbench`，若无 `tools\bootstrap.ps1` → exit 2 | skill 报"找不到程序目录"，GUI 正常 |
| dev/portable：exe 在 `bin\`，`tools\` 在工作区根 | 第 4 步回退到 `WorkspaceDir()` → `{工作区}\tools\bootstrap.ps1` | 只认注册表/LOCALAPPDATA；dev 机器通常没写 ProgramRoot → exit 2，或命中旧的安装版目录 → 跑**另一份** bootstrap.ps1 | 两侧执行不同脚本；由于都无哈希，**先在解析顺序里命中的那份胜出** |
| 用户把 skill 目录单独拷到另一台机器 | 不适用 | 无注册表、无 LOCALAPPDATA 安装 → exit 2 | skill 明确失败（比静默跑错脚本好） |
| 工作区里同时存在 `{工作区}\tools\bootstrap.ps1` 与 `{app}\tools\bootstrap.ps1` | 视 exe 位置而定（可能选工作区那份） | 选 `{app}` 那份 | **同一操作可能跑两份不同代码** |

`skill/mingling-install/SKILL.md:82` 的示例用 `<这个 skill>\scripts\bootstrap.ps1`，:86-87 明确警告"不要把路径写成 `<工作区>\tools\bootstrap.ps1`"——这条警告只对 skill 侧成立；工作台侧 `Root()` 在 dev 布局下**恰好**会回退到工作区那份，两者策略相反。

### 13.4 哈希：不存在

- 全仓库对 `bootstrap.ps1` 的哈希计算/校验：**零**。`her::Sha256File` 仅两处调用（`main.cpp:503` 的 `--wb-get`；`ui_update.inc:323` 的更新包校验），均与 bootstrap.ps1 无关。
- 因此"跑哪个 bootstrap.ps1"完全由文件系统与注册表决定；脚本内容被替换（同目录写权限即可）不会被任何一方发现。配合 §8.2 的 skill 自更新，攻击链为：替换 `{app}\tools\bootstrap.ps1` → 用户点"配置/安装" → 以当前用户权限执行任意 PowerShell。
- 若要让 TASK 2 的"期望绝对路径"可验证，最小改动：安装时把 `{app}\tools\bootstrap.ps1` 的 sha256 写进 `ProgramRoot` 旁的注册表值（或 `tools\bootstrap.ps1.sha256`），两侧拉起前都比对。

---

## 14. 复现命令（节选）

```powershell
# 安装包签名 + 大小 + 哈希
Get-AuthenticodeSignature 'dist\MinglingWorkbench-3.1.0-setup.exe' | Format-List Status,StatusMessage,SignerCertificate
(Get-Item 'dist\MinglingWorkbench-3.1.0-setup.exe').Length
(Get-FileHash 'dist\MinglingWorkbench-3.1.0-setup.exe' -Algorithm SHA256).Hash

# 源码树核对
powershell -NoProfile -ExecutionPolicy Bypass -File tools\source-manifest.ps1 `
  -Root sidecar\bili-whale -Verify -Manifest tools\source-manifests\bili-whale.json

# 锁覆盖率（Python）
python - <<'PY'
import re,sys
for f in ['tools/astrbot-requirements.txt','tools/edge-tts-requirements.txt']:
    txt=open(f,encoding='utf-8').read().replace('\\\n',' ')
    reqs=[l for l in txt.splitlines() if l.strip() and not l.strip().startswith('#')]
    print(f, len(reqs), sum(1 for l in reqs if '--hash=sha256:' in l))
PY
```

（`Get-FileHash` 输出的 `AB8443BB…` 与 `checksums.txt` 的 `ab8443bb…` 大小写不同，值相同。）
