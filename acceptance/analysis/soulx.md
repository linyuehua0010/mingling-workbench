# SoulX 本地唱歌 — 单件依赖与可固定性分析

- 组件：`soulx-singer`（`tools/components.json`，`version: "manual"`, `optional: true`, `default_install: false`, `manual: true`）
- 结论先行：**SoulX 唱歌不是"自动化安装"，是"人工触发的半自动脚本"**。整条链上唯一已有可信固定哈希的是**源码归档**（`b1a1e961…` / commit `81a3eb3a…`），而**实际脚本根本不用它**（用 `git clone` 默认分支 HEAD）。其余 5 类下载（Python 3.10 解释器、CUDA torch、pip 依赖、2.8 GB 模型、可选对齐模型）全部**无哈希**，只有"版本号"或"文件大小"门槛。
- 本文件只读分析；未联网、未安装、未运行 setup 脚本。所有 `file:line` 已逐行核对。

---

## 1. 入口链

```
工作台 / 用户
  └─ powershell -File "{repo}\pack\mingling-pack\plugins\astrbot_plugin_dafeiyu_sing\sing_server\setup_windows.ps1" -Root "{base}\sing"
       └─ (9 行包装：往上 5 级解析 repo，再转调)
            └─ powershell -File "{repo}\tools\setup-singing.ps1" -Base "{base}" -Action install [-Root "{base}\sing"]
                 └─ 见下：git clone → uv venv 3.10 → torch cu128 → pip 依赖 → curl 模型 → 复制服务/音色 → check-singing-env.py
```

- 包装脚本：`pack/mingling-pack/plugins/astrbot_plugin_dafeiyu_sing/sing_server/setup_windows.ps1`（9 行，仅路径解析 + 转调）。
- 主脚本：`tools/setup-singing.ps1`（158 行，11,399 字节）；`-Action` 可选 `install|start|check|test|voice_existing|voice_breeze`。
- bootstrap 侧：`tools/bootstrap.ps1:987` 对 `manual` 组件**只做 detect 探针**；装后统一 `verify`（:1033）。`soulx-singer` 的 `detect`/`verify` 是同一个 `file` 探针 + `min_bytes`，**没有任何哈希比对**。
- 插件侧：`pack/.../astrbot_plugin_dafeiyu_sing/main.py:41-42` `self.conf.get("backend") or "doubao"` → 即使 SoulX 装好，也要**显式**把 backend 切成 SoulX，默认仍是豆包。

---

## 2. 实际会下载什么（按执行顺序）

| # | 资产 | 来源 URL | 版本/大小 | 现有哈希？ | 脚本是否校验 | 分类 |
|---|---|---|---|---|---|---|
| 1 | SoulX-Singer 源码 | `https://github.com/Soul-AILab/SoulX-Singer.git`（`setup-singing.ps1:78` `git clone --depth 1`） | 默认分支 **HEAD**（无 commit/tag pin） | 仓库外已有：归档 `b1a1e9615f8832012396aa306a5de5a6157f4c193c4ce08b3ee35a7983dcee7b`（commit `81a3eb3ae772c70093c3de74dc23c92d983801ae4`，12,975,795 B） | **否**（脚本只判断 `$source\.git` 是否存在） | **pinnable-and-verifiable（已有值，但脚本未用）** |
| 2 | Python 3.10 解释器 | `uv venv {Root}\venv --python 3.10`（:80）→ uv 自行从 python-build-standalone 取 | 3.10.x 具体 build **未知**（uv 内部选择） | 无 | 否 | **unknown**（uv 侧的下载/选择不可见） |
| 3 | PyTorch CUDA 12.8 | `uv pip install torch==2.7.1 torchaudio==2.7.1 --index-url https://download.pytorch.org/whl/cu128`（:82） | 版本固定 2.7.1；cu128 wheel，体积约 2.5 GB（估算） | 无（未生成带哈希的锁） | 否（无 `--require-hashes`） | **pinnable（需生成哈希锁）** |
| 4 | 唱歌服务 pip 依赖 | `uv pip install -r {assets}\requirements.txt einops rotary-embedding-torch beartype 'huggingface-hub<1'`（:84） | `requirements.txt` 10 行：`numpy<2`, `scipy`, `librosa`, `soundfile`, `omegaconf`, `transformers==4.41.2`, `accelerate`, `tqdm`, `pypinyin`, `praat-parselmouth`；只有 transformers 锁版本，其余是范围/无版本 | 无 | 否 | **pinnable（需冻结版本 + 哈希）** |
| 5 | **model.pt** | `https://hf-mirror.com/Soul-AILab/SoulX-Singer/resolve/main/model.pt`，失败再 `https://huggingface.co/...`（:88）；`curl -fL --retry 3 --retry-delay 2 -C - -o model.pt.part`（:90） | 下游门槛 **2818092278 B**（:85/:91），约 2.8 GB | **无**（只有大小判定） | 仅 `Length -lt 2818092278 → throw '模型文件不完整'` | **pinnable（哈希可得：HF LFS oid），当前未固定** |
| 6 | 对齐模型（仅 `voice_existing` / `voice_breeze`） | `modelscope.hub.snapshot_download('iic/speech_timestamp_prediction-v1-16k-offline', cache_dir={Root}\models\alignment)`（`tools/prepare-singing-voice.py:100-108`） | 未固定 revision | 无 | 否（先 `local_files_only`，失败转联网） | **pinnable（需固定 revision/哈希），当前 unknown** |
| 7 | 参考音色（voice/prompt.wav、prompt.json） | 从 `{assets}\voice` 复制（:110-113） | 随仓库 | 仅内置旧音色有硬编码哈希（:102-103：`prompt.wav 7CBC3550…`、`prompt.json 3B3FB352…`），**用于判断"是否旧内置"以便备份**，不用于校验新文件 | 否 | **pinnable（随 git 提交固定）；自定义音色无校验** |

补充：`torch==2.7.1+cu128` / `torchaudio==2.7.1+cu128` 在 `voice_existing|voice_breeze` 分支（:58）用 `--extra-index-url` + `--index-strategy unsafe-best-match` 安装——`unsafe-best-match` 明确放松了索引优先级，**该分支的依赖来源更不可控**。

---

## 3. 分类汇总（诚实口径）

### 3.1 pinnable-and-verifiable（今天就能固定并真正校验）
| 项 | 固定什么 | 现成材料 |
|---|---|---|
| SoulX 源码 | GitHub commit `81a3eb3a…` 的 codeload tar.gz sha256 `b1a1e961…` | `components.json` 已写；`.workbuddy/acceptance/SoulX-Singer-81a3eb3a.tar.gz` 实测 12,975,795 B、sha256 `b1a1e961…` ✅；**只差安装脚本改用归档解压** |

### 3.2 pinnable，但需要一次性取哈希/生成锁（今天可做，尚未做）
| 项 | 做法 |
|---|---|
| `model.pt` | 从 HuggingFace 的 LFS pointer / API 取该文件 `sha256`（`sha256:<oid>`）写进脚本，下载后 `Get-FileHash` 比对；同时去掉 `hf-mirror.com` 优先（第三方镜像无法证明与 HF 同字节），或要求镜像侧也给出同一 oid |
| torch/torchaudio cu128 | 用 `uv pip compile --generate-hashes` 生成锁（含 `download.pytorch.org/whl/cu128` 的 wheel），安装时 `--require-hashes` |
| 唱歌服务依赖 | 冻结 10 个包 + 4 个额外包的精确版本并生成哈希锁 |
| 对齐模型 | `snapshot_download(..., revision=<fixed>)` 并用文件哈希核对 |
| Python 3.10 | 像 `python` 组件那样固定到某个 python-build-standalone release + sha256，而不是让 uv 自选 |

### 3.3 manual-only（无法用哈希"固定"的部分）
- NVIDIA 驱动 / GPU 可用性（`check-singing-env.py:117-119` 实际验算显卡）——驱动只能要求最低版本，不能固定字节。
- 磁盘空间（源码 + venv + CUDA torch + 2.8 GB 模型，保守估计 8–12 GB）。
- 网络可达性（GitHub / PyTorch 索引 / hf-mirror / huggingface.co）。
- Git 是否存在（:74-75 直接报错要求人工安装）。
- 若用自定义音色：录音/标注本身是人工产物（`:110-113` 只复制，不校验）。

### 3.4 unknown（今天既没固定也无法从仓库内确定）
- uv 为 `--python 3.10` 选择的 **具体 build 与来源**（无日志、无 pin）。
- `hf-mirror.com` 返回的 `model.pt` 是否与 `huggingface.co` 同字节（无 oid 比对，脚本只是"先试镜像"）。
- modelscope 对齐模型的 revision（未记录）。
- `transformers==4.41.2` 之外的依赖最终解析到哪个版本（范围约束 + 无锁）。

**因此："default skip" 不等于"全自动"。** 它的真实语义是：默认**不下载、不安装、不切换 backend**；用户在自设定里点了"部署本地唱歌"之后，脚本才开始联网，且其中 5 类下载无哈希、2 类版本未固定、1 类完全由 uv 内部决定。把它描述成"自动装好"或"已校验"都不成立。

---

## 4. 两处会直接影响验收的一致性缺陷

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 1 | **尺寸门槛不一致**：components.json 用 `min_bytes: 2800000000`，安装脚本用 `< 2818092278` 判失败 | `tools/components.json`（soulx `detect`/`verify`） vs `tools/setup-singing.ps1:85,91` | 2,800,000,000–2,818,092,277 B 的**残缺模型**能通过 bootstrap 的 verify（`##RESULT ok=1`），但 `setup-singing.ps1` 会判"模型文件不完整"；验收若只看 bootstrap 会误判成功 |
| 2 | **安装根目录默认值不一致**：components.json 期望 `{base}\sing\SoulX-Singer` + `{base}\sing\models\SoulX-Singer\model.pt`；脚本默认 `Root = {base}\bots\SoulXSinger` | `tools/setup-singing.ps1:20` vs `components.json` probes | 不显式传 `-Root {base}\sing` 时，装到 `bots\SoulXSinger`，bootstrap 的 detect/verify **永远看不到**；用户看到"未安装"但磁盘上有一份完整环境 |
| 3（附） | `settings.sing.root` 可覆盖 Root（:19），没有任何提示/记录落到 `installed.json` 之外 | `setup-singing.ps1:19` | 同一个 base 下可能有多份 SoulX 环境，验收以哪个为准不明确 |

---

## 5. "今天能否固定可信哈希"逐项回答

| 问题 | 回答 |
|---|---|
| SoulX 源码能固定吗？ | **能，且已有现成值**（`b1a1e961…`，本地缓存已核对一致）。障碍只是脚本用 `git clone`。 |
| 2.8 GB 模型能固定吗？ | **能**——HuggingFace 用 LFS，pointer 里有 `sha256:<oid>`；取一次写死即可。当前**没有**。 |
| CUDA torch 能固定吗？ | **能**——wheel 在固定 URL 上，可生成带哈希的 uv 锁；当前只固定了 `==2.7.1`。 |
| Python 3.10 能固定吗？ | 能（固定 python-build-standalone release），但当前由 uv 自选 → **unknown**。 |
| 对齐模型能固定吗？ | 能（modelscope revision），当前未固定。 |
| 驱动/GPU 能固定吗？ | **不能**（只能给最低版本要求），属 manual-only。 |

## 6. 最小改造建议（如需让 SoulX 也进入 criterion 2 的"真实校验链"）

1. 删掉 `git clone`，改为下载已固定的归档 `b1a1e961…`（或 `git clone` 后 `git checkout 81a3eb3a…` 并校验 `git rev-parse HEAD`）。
2. 模型下载前后都做 `Get-FileHash`，期望值来自 HF LFS oid；镜像命中也要比对同一 oid。
3. `uv pip compile --generate-hashes` 生成 torch 与 requirements 两份锁，`--require-hashes --no-build`。
4. Python 3.10 固定到具体 python-build-standalone release + sha256。
5. 把 `min_bytes` 统一成 `2818092278`，并把默认 `Root` 改成 `{base}\sing`（或让 components.json 跟随 `settings.sing.root`）。
6. 在 `installed.json` 里记录每个资产的 sha256，让"已安装"可复核。

---

## 7. 本地已核对证据（只读）

| 对象 | 实测 |
|---|---|
| `.workbuddy/acceptance/SoulX-Singer-81aeb3a.tar.gz` | 12,975,795 B，sha256 `b1a1e9615f8832012396aa306a5de5a6157f4c193c4ce08b3ee35a7983dcee7b` ✅ 与 `components.json` 一致 |
| `pack/mingling-pack/plugins/astrbot_plugin_dafeiyu_sing` 树 | `source-manifest.ps1 -Verify` → `f1eb34a5…`，exit 0（16 文件）；但 `tools/source-manifests/dafeiyu-sing-plugin.json` 无任何安装步骤消费 |
| `tools/setup-singing.ps1` | 158 行 / 11,399 B；上述所有行号逐行核对 |
| `sing_server/requirements.txt` | 10 行；仅 `transformers==4.41.2` 有版本 pin，0 个哈希 |

未做：联网拉取 HF 的 LFS oid、未运行 `setup-singing.ps1`、未安装 torch/模型（任务约束：不装软件、不碰 VM）。
