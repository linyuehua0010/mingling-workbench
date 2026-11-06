# 冥零工作台 v2.1 修改计划（5 项需求）

> 状态：计划（未动代码）
> 基线：`beifen` @ `93cde4f`
> 目标分支：`feat/v2.1-fixes`
> 约束：严格 Win32 + GDI+，不引第三方 UI/库；耗时操作一律工作线程 + `PostMessage` 回 UI；不新增链接库。

## 0. 这份计划怎么用

1. 从 `beifen` 开分支：`git switch -c feat/v2.1-fixes`（本文件即首个提交）。
2. 按第 6 节的提交切片推进，**每个切片都能单独编过**（`cd win32 && build.bat`）。
3. 每项需求做完立刻跑第 7 节对应验收，不要攒到最后一起验。
4. 全部做完再跑 `installer\build-installer.bat`，装一遍干净机验证第 3 项。

**开工前必读的两个坑**

- `SettingSet` 会整文件重写 `settings.json`，只保留 `paths.cpp:74` 白名单里的键。本计划新增的 `secrets` / `notify_every` / `mirror_node` **必须**加进那个数组，否则安装器写进去的键会被下一次保存抹掉。
- `Button()` 在 `ui.cpp:332-358`，末尾是 `if (enabled) AddHit(r, id);` —— 禁用按钮**连命中区都不生成**，点击完全静默。这是「点了没反应」这类 bug 的通用温床。

---

## 1. Ollama / Breeze「在跑却显示要修」

### 现象
Ollama 在跑 → 记忆卡显示「Ollama 在跑，但记忆没开」，红点 +「要修」；Breeze 在跑 → 语音卡显示「服务在跑，但语音没启用」，同样红。

### 根因（已定位）

| 位置 | 问题 |
|---|---|
| `win32/src/her/her_status.cpp:425-438` | `!w.installed \|\| !w.on` 分支里，只要 `Listening(11434)` 为真且 `want==false`，直接 `c.state = L"bad"` |
| `win32/src/her/her_status.cpp:526-535` | 只要 `Listening(8137)` 为真，直接 `c.state = L"bad"` |
| `win32/src/ui_maint.inc:174-180` | `StateColor` 把除 `ok/warn/busy/off` 外的状态全涂 `C_ERR` |
| `win32/src/ui_maint.inc:182-188` | `StateWord` 默认返回「要修」 |

本质：状态机只有一维（功能开没开），没有「服务存活」这一维。

### 目标状态机

| 服务进程 | 功能开关 | `state` | chip | 小字 `pill` | 修复按钮 |
|---|---|---|---|---|---|
| 不在 | 关 | `off` | 关着 | — | 否 |
| 在 | 关 | **`ok`** | **正常** | 记忆未开 / 语音未开 | 否 |
| 在 | 开但没接好（模型缺/密钥缺） | `bad` | 要修 | — | 是 |
| 不在 | 开 | `bad` | 要修 | — | 是 |
| 在 | 用户明确选了要它，插件却关着 | `bad` | 要修 | — | 是 |

### 改动

**A. 记忆卡**（替换 `her_status.cpp:425-438` 整段）

```cpp
} else if (!w.installed || !w.on) {
    const bool ollamaUp = Listening(11434);
    if (ollamaUp) c.pill = L"Ollama 在跑";
    if (want && w.installed) {
        // 用户明确选了「要记忆」，插件却关着：这才是真要修
        c.state = L"bad";
        c.text  = L"选了要记忆，但记忆插件关着（上次多半没接好），她记不住事。交给 Agent 接回去。";
    } else if (want) {
        c.state = L"warn";   // 想要但没装上：留意，不是崩了
        c.text  = L"选了要记忆，但记忆插件没装上（Ollama 开着也没用）。交给 Agent 补一下。";
    } else if (ollamaUp) {
        c.state = L"ok";
        c.name  = L"记忆 · Ollama 在跑";
        c.pill  = L"记忆未开";
        c.text  = L"Ollama 在跑，记忆还没开——她记不住新的事（以前记住的还在）。"
                  L"想让她记事，在「维护」页把记忆开关打开。";
    } else {
        c.state = L"off";
        c.text  = L"没开。想要的话去「交给 Agent」。";
    }
}
```

**B. 语音卡**（替换 `her_status.cpp:526-535`）

```cpp
} else if (Listening(8137)) {
    c.name  = L"语音 · Breeze 在跑";
    c.state = L"ok";
    c.pill  = L"语音未开";
    c.text  = L"Breeze 开着，但语音没启用——她现在只打字。"
              L"想让她说话，在「维护」页把语音开关打开，或交给 Agent 选个声音。";
} else {
```

> 这两张卡变 `ok` 后**不要**再挂 `fixAct`，否则会出现「正常」卡片顶着「一键修复」。

**C. 词表补齐**（`ui_maint.inc:174-188`）

```cpp
static ARGB StateColor(const wstring& st) {
    if (st == L"ok")   return C_OK;
    if (st == L"warn") return C_WARN;
    if (st == L"busy") return C_ACCENT2;
    if (st == L"off" || st == L"unk") return 0xFFB7C2D6;   // 查询失败 ≠ 要修
    return C_ERR;
}
static wstring StateWord(const wstring& st) {
    if (st == L"ok")   return L"正常";
    if (st == L"warn") return L"留意";
    if (st == L"busy") return L"在忙";
    if (st == L"off")  return L"关着";
    if (st == L"unk")  return L"没查到";
    return L"要修";
}
```

### 验收
- [ ] Ollama 在跑 + 记忆未开 → 绿点「正常」+ 小字「记忆未开」+ 正文带开启指引，**无**红色按钮
- [ ] Breeze 在跑 + 语音未启用 → 绿点「正常」+ 小字「语音未开」
- [ ] 选了要记忆但插件被关 → 仍是「要修」（这条不能误伤）
- [ ] `MinglingWorkbench.exe --her-status` 对应 `ITEM` 行第 3 字段为 `ok`

---

## 2. 「打游戏模式」点了没反应

### 现象
总览页右上角点不动；维护页头部那个按钮也时常点不动。

### 根因：三层叠加

1. **总览页根本没有这个按钮**。`DrawHero`（`ui_pages.inc:454-514`）只有「让她看视频」「打开日记」；快捷卡也没有。用户看到的其实是维护页头部那个。
2. **禁用按钮没有命中区**（`ui.cpp:357`）→ 点击静默：无手型光标、无 toast、无日志。
3. **`can` 判定踩中需求 1 的同一个坑**（`her_status.cpp:656`）：
   ```cpp
   st.gameCan = vc == 4 || Memory() == 1;   // 只认开关，不认「服务在跑」
   ```
   截图场景是 `vc==0`（语音没启用）+ `Memory()==0`，虽然 8137 在跑 → `can=false` → 永久禁用。另外首次进维护页时 `g_mLoaded==false`，异步 status 未回，按钮也是死的 1~3 秒。

### 改动

**2.1 `gameCan` 承认本机服务在跑**（`her_status.cpp:656`）

```cpp
// 打游戏模式 = 把本机占显卡/内存的语音、记忆先放下。只要本机真有服务在跑就该能点
st.gameCan = vc == 4 || Memory() == 1 || Listening(8137) || Listening(11434);
```

**2.2 GameOn / GameOff 记住「当时停了什么」**（`her_actions.cpp:425-428` 与 `:509-510`）

```cpp
// GameOn 开头
int vc = Voice();
bool localVoice = Listening(8137);
bool localMem   = Listening(11434) && (MemoryWiring().ollama || Memory() == 1);
bool voice = vc == 4 || localVoice;
bool mem   = Memory() == 1 || localMem;
if (!voice && !mem) return Bad(L"本机没有在跑的语音或记忆，打游戏不用关她。");
...
g.Set(L"local_voice", JBool(Listening(8137)));   // 新增两键
g.Set(L"local_mem",   JBool(Listening(11434)));

// GameOff 读盘时
bool voice = vc == 4 || g.Bool(L"local_voice");
bool mem   = Memory() == 1 || g.Bool(L"local_mem");
```

> 不做这步：语音只在 `vc==4` 时才被重启，`vc==0`（Breeze 在跑但语音没启用）的情况下「打完了，恢复」会把 Breeze 忘在市场里。

**2.3 按钮永远可点**（`ui.cpp:332-358`）

```cpp
static void Button(Graphics& g, const RectF& r, const wstring& label, const std::string& id,
                   int kind = 0, bool small = false, bool enabled = true,
                   bool hitWhenDisabled = false) {
    ...
    if (enabled || (hitWhenDisabled && !id.empty())) AddHit(r, id);
}
```

维护页（`ui_maint.inc:239-243`）：

```cpp
bool can = g_mGameCan || g_mGameOn;
if (g_mGameOn)
    Button(g, gb, L"打完了，恢复", "op:game_off", 1, true, !g_mBusy);
else if (can)
    Button(g, gb, L"开打游戏模式", "op:game_on", 0, true, !g_mBusy);
else
    Button(g, gb, L"打游戏模式", "op:game_hint", 0, true, !g_mBusy, true);   // 灰的但点得动
```

**2.4 点不动时给解释**（`ui_pages.inc:1152-1161` 的 `op` 分派）

```cpp
if (op == L"game_hint") {
    RefreshStatus(false);
    UiToast(g_mLoaded ? L"语音和记忆用的都是在线服务，不占这台电脑——打游戏不用关她。"
                      : L"还在查她的状态，等一秒再点。");
    return;
}
```

**2.5 总览页右上角补按钮**

先把游戏态提到 `ui.cpp` 全局（`PaintOverview` 在 `ui_pages.inc:516`，早于 `ui_maint.inc` 的 include，编译期看不到）：

- 删 `ui_maint.inc:13` 的 `static bool g_mGameOn = false, g_mGameCan = false;`
- 在 `ui.cpp`（`#include "ui_pages.inc"` 之前）加回这两个 `static bool`

`DrawHero` 末尾（`ui_pages.inc:513` 之后）：

```cpp
// 右上角：打游戏模式
{
    const float bw = S(150), bh = S(32);
    RectF br(r.X + r.Width - bw - S(24), r.Y + S(24), bw, bh);
    Round(g, RectF(br.X - S(6), br.Y - S(6), br.Width + S(12), br.Height + S(12)), S(12), 0xCCFFFFFF, 0);
    if (g_mGameOn) {
        Chip(g, RectF(br.X - S(78), br.Y + S(6), S(66), S(20)), L"打游戏中", C_ACCENT, 0x1F3E5FBF);
        Button(g, br, L"打完了，恢复", "op:game_off", 1, false);
    } else if (g_mGameCan) {
        Button(g, br, L"开打游戏模式", "op:game_on", 0, false);
    } else {
        Button(g, br, L"打游戏模式", "op:game_hint", 0, false, true);
    }
}
```

**2.6 总览页也刷状态**（`UiTick`，`ui_pages.inc:1489`）

```cpp
if (g_tab == 0 || g_tab == 5) RefreshStatus(false);   // 45s 缓存 + busy 短路，不会反复查
```

### 状态与持久化
- 状态写盘：`Base\logs\game-mode.json`（`{on, since, tts, mem, local_voice, local_mem}`）
- 重启自动失效：`since < BootUnix()` 时视为关（`her_config.cpp:493-502`），这是原设计意图，**保留**
- 反馈链：`RunHerOp → TK_OP → UiToast` + 完成后 `RefreshStatus(true)` 让按钮文案翻转
- 若确实要跨重启保持，才去掉 `BootUnix()` 判断（不推荐）

### 验收
- [ ] 总览页右上角有按钮，文案随状态变「开打游戏模式 / 打完了，恢复」
- [ ] 语音未启用但 Breeze 在跑 → 按钮可点，点了能进游戏模式（Breeze 被关）
- [ ] 「打完了，恢复」之后 Breeze 重新起来（回到原状态）
- [ ] 语音和记忆都是在线服务 → 点击弹解释 toast，而不是毫无反应
- [ ] 首次进页面 1 秒内点：有「还在查」提示，不静默

---

## 3. 安装包增加 `secrets` 密钥文件夹

### 设计
- 目录：`<Base>\secrets`（`Base` 已在安装器算过：`mingling.iss:152` 的 `b := ExtractFileDir(WsPath)`）
- 读取优先级：`%MINGLING_SECRETS%` → `settings.json` 的 `secrets` 键 → `<Base>\secrets` → **回退** `<Base>\private`（兼容老用户）
- 卸载保留：目录在 `{app}` 之外，且**不写** `[UninstallDelete]`

### 改动

**3.1 `core.h` 新增**

```cpp
wstring SecretsDir();                        // <Base>\secrets
wstring SecretFile(const wchar_t* name);     // secrets\name 优先，private\name 兜底
bool    EnsureSecrets();                     // 建目录 + 写 README（幂等）
```

**3.2 `paths.cpp` 实现**

```cpp
wstring SecretsDir() {
    wchar_t buf[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_SECRETS", buf, MAX_PATH * 2) && buf[0])
        return WithTrailingSep(buf);
    wstring s = SettingGet(L"secrets");
    if (!s.empty()) return WithTrailingSep(s);
    return JoinPath(BaseDir(), L"secrets");
}

wstring SecretFile(const wchar_t* name) {
    wstring a = JoinPath(SecretsDir(), name);
    if (FileExists(a)) return a;
    wstring b = JoinPath(JoinPath(BaseDir(), L"private"), name);
    if (FileExists(b)) return b;
    return a;   // 都没有时返回「应该放在哪」，错误提示直接指着它
}

bool EnsureSecrets() {
    wstring dir = SecretsDir();
    CreateDirectoryW(dir.c_str(), nullptr);
    wstring readme = JoinPath(dir, L"README.txt");
    if (!FileExists(readme))
        WriteTextFile(readme,
            L"这个文件夹放密钥，重装/卸载都不会删。\r\n\r\n"
            L"snowluma-webui.txt  SnowLuma 网页后台密码（password=…）\r\n"
            L"backend.txt         AstrBot 后台账号（username=… / password=…）\r\n"
            L"deepseek-key.txt    DeepSeek API Key（sk-…）\r\n"
            L"protocol.txt        QQ 协议端类型（napcat / snowluma）\r\n");
    return true;
}
```

**3.3 读取点替换**（`ReadKv` 逻辑不动，只换路径来源）

| 文件:行 | 原 | 改 |
|---|---|---|
| `her_config.cpp:201` | `P(L"private\\deepseek-key.txt")` | `SecretFile(L"deepseek-key.txt")` |
| `her_config.cpp:99` | `P(L"private\\protocol.txt")` | `SecretFile(L"protocol.txt")` |
| `her_astr.cpp:69,79,80` | `P(L"private\\backend.txt")` | `SecretFile(L"backend.txt")` |
| `ui_pages.inc:171` | `JoinPath(JoinPath(BaseDir(), L"private"), L"snowluma-webui.txt")` | `SecretFile(L"snowluma-webui.txt")` |

- `private\qq-watch-off.txt` 不是密钥，**不动**
- `her_astr.cpp` 的错误文案里写死的路径改成 `SecretFile(...)` 动态拼
- `main.cpp` 的 `--paths`（`:156-171`）加一行 `Out(L"密钥目录 : " + SecretsDir());`

**3.4 启动初始化**（`UiInit`，`ui_pages.inc:1439`）

```cpp
EnsureWorkspaceLayout(WorkspaceDir());
EnsureSecrets();                 // 首次启动就建好，别等用户去找
```

**3.5 安装器**（`installer/mingling.iss`）

```pascal
[Files]
Source: "..\installer\secrets-README.txt"; DestDir: "{code:GetSecretsDir}"; DestName: "README.txt"; \
    Flags: onlyifdoesntexist uninsneveruninstall

[Dirs]
Name: "{code:GetSecretsDir}"; Permissions: users-modify

[Code]
function GetSecretsDir(Param: String): String;
var
  b: String;
begin
  b := ExtractFileDir(WsPath);
  if b = '' then b := WsPath;
  Result := b + '\secrets';
end;
```

`CurUninstallStepChanged` 的 `MsgBox`（`:200-204`）补一句：

```pascal
MsgBox('程序已卸载。' + #13#10 + '工作区还在：' + #13#10 + ws +
       #13#10 + #13#10 + '密钥文件夹也保留了：' + #13#10 + GetSecretsDir('') +
       #13#10 + '重新装回来就能直接用。', mbInformation, MB_OK);
```

`installer/build-installer.bat` 加前置校验：`installer\secrets-README.txt` 必须存在。

### 验收
- [ ] 干净机安装 → `<Base>\secrets\README.txt` 存在
- [ ] 把 `deepseek-key.txt` 放进 secrets，删掉 `private` 里同名文件 → 余额/密钥仍能读到
- [ ] 只放 `private`（老布局）→ 照样能读到（回退生效）
- [ ] 卸载 → 程序目录没了，`secrets` 与工作区都在
- [ ] 重新安装 → 老密钥文件未被覆盖（`onlyifdoesntexist`）

---

## 4. 一键自动配置环境

### 设计
新增纯 C++ 的自检/补齐模块，跑在现有 `RunHerOp` 的工作线程模型里，进度用新消息 `WM_APP_AUTOCFG` 回 UI。

- 新文件 `win32/src/her/her_setup.cpp`（**记得加进 `win32/build.bat:21` 的编译列表**）
- 新消息 `WM_APP_AUTOCFG (WM_APP + 4)`：`wParam = 百分比`，`lParam = new wstring(当前步骤)`

### 检测矩阵

| 依赖 | 检测 | 补齐来源（按顺序） |
|---|---|---|
| Node 运行时 | `SidecarNodeExe()` / `where node` | ① 自带 `sidecar\node\node.exe` ② 下载官方 zip 解到 `SidecarDir()\node\` |
| ffmpeg | `SidecarFfmpegExe()` / `where ffmpeg` | ① 自带 ② 下载 build 解到 `SidecarDir()\ffmpeg\bin\ffmpeg.exe`（匹配 `paths.cpp:198-201` 第一候选） |
| Python（可选） | `Base\tools\python\pythonw.exe`、`Base\python\pythonw.exe` | ① 安装包 `sidecar\python\` ② `winget install -e --id Python.Python.3.12 --scope user --silent` ③ 跳过并说明 |
| Ollama | `OllamaExe()` / `Listening(11434)` | **只提示，不静默装**（体积大，须用户同意） |
| 工作区/密钥 | `EnsureWorkspaceLayout` + `EnsureSecrets` | 直接建 |
| sidecar 配置 | `bili-whale.config.template.json` | `whale.cpp:42-46` 已自动复制 |
| `tools\qq_watch.py`、`qq-toast.ps1` | `FileExists` | 从 `plugin\`/`sidecar\` 复制；没有就报告「这一版没带」 |

### 改动

**4.1 `her.h`**

```cpp
struct SetupStep { std::wstring name; bool ok; std::wstring detail; };
struct SetupReport {
    bool ok = false;
    int fixed = 0;
    std::vector<SetupStep> steps;
    std::wstring summary;
};
SetupReport AutoSetup(const std::function<void(int, const std::wstring&)>& onStep);
```

**4.2 `her_setup.cpp` 骨架**

```cpp
#include "her.h"
#include <shellapi.h>

namespace her {
namespace {

// 下载源做成常量 + settings 覆盖，不要在代码里散落版本号
static const wchar_t* kNodeZip =
    L"https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip";
static const wchar_t* kFfmpegZip =
    L"https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/"
    L"ffmpeg-master-latest-win64-gpl.zip";

static std::wstring UrlFor(const wchar_t* key, const wchar_t* def) {
    std::wstring v = SettingGet(key);
    return v.empty() ? def : v;
}

static bool DownloadTo(const std::wstring& url, const std::wstring& dst);  // WinHTTP 流式落盘

static bool Unzip(const std::wstring& zip, const std::wstring& dest) {
    // Win10 1809+ 自带 bsdtar，能直接解 zip，不引第三方库
    CreateDirectoryW(dest.c_str(), nullptr);
    CmdResult r = RunCapture(L"tar.exe", L"-xf \"" + zip + L"\" -C \"" + dest + L"\"",
                             L"", EnvList(), 300000);
    return r.code == 0;
}

static std::wstring FirstExeUnder(const std::wstring& dir, const wchar_t* name);

}  // namespace

SetupReport AutoSetup(const std::function<void(int, const std::wstring&)>& onStep) {
    SetupReport rep;
    auto step = [&](int pct, const wchar_t* name) { if (onStep) onStep(pct, name); };

    step(5, L"检查 Node 运行时");
    std::wstring node = SidecarNodeExe();
    if (node.empty()) {
        wstring dir = JoinPath(SidecarDir(), L"node");
        wstring zip = JoinPath(JoinPath(StateDir(), L"tmp"), L"node.zip");
        if (DownloadTo(UrlFor(L"mirror_node", kNodeZip), zip) && Unzip(zip, dir)) {
            node = FirstExeUnder(dir, L"node.exe");
            rep.fixed++;
        }
    }
    rep.steps.push_back({L"Node 运行时", !node.empty(),
                         node.empty() ? L"没搞到，B 站看片会不可用" : node});

    step(35, L"检查 ffmpeg");   // 同型
    step(60, L"检查 Python（可缺）");
    step(75, L"检查工作区与密钥目录");
    EnsureWorkspaceLayout(WorkspaceDir());
    EnsureSecrets();
    rep.steps.push_back({L"工作区", true, WorkspaceDir()});
    rep.steps.push_back({L"密钥目录", true, SecretsDir()});

    step(88, L"写配置");
    if (SettingGet(L"workspace").empty()) SettingSet(L"workspace", WorkspaceDir());
    if (SettingGet(L"base").empty())      SettingSet(L"base", BaseDir());

    step(100, L"完成");
    int bad = 0;
    for (auto& s : rep.steps) if (!s.ok) bad++;
    rep.ok = (bad == 0);
    rep.summary = rep.ok
        ? L"环境齐了：Node、ffmpeg、工作区、密钥目录都在位，可以开始用了。"
        : (L"还差 " + std::to_wstring(bad) + L" 项，看报告里的红字。");
    return rep;
}
}  // namespace her
```

> 进程启动复用 `RunCapture(exe, args, cwd, env, timeoutMs)`（`core.h`），别新写一套。

**4.3 UI 挂载**

`ui.h`：

```cpp
#define WM_APP_AUTOCFG (WM_APP + 4)
void UiOnAutoCfg(int pct, wstring* step);
```

`main.cpp` WndProc（`WM_APP_PROGRESS` 之后）：

```cpp
case WM_APP_AUTOCFG:
    UiOnAutoCfg((int)wp, (std::wstring*)lp);
    return 0;
```

维护页第二排 6 → 7 项（`ui_maint.inc:374-381`）：

```cpp
Btn rowB[7] = {
    {L"开语音 Breeze", "op:start_breeze", 0},
    {L"开本机 Ollama", "op:start_ollama", 0},
    {L"打开工作区",   "doc:base", 0},
    {L"修开机自启",   "op:autostart_fix", 0},
    {L"一键自动配置", "op:autosetup", 1},      // 新增
    {L"更新技能",     "op:skill_update", 0},
    {L"打开日志",     "doc:logs", 0},
};
float bwid = (w - S(10) * 6) / 7.0f;
```

进度处理与线程（`ui_maint.inc` 尾部）：

```cpp
void UiOnAutoCfg(int pct, wstring* step) {
    std::unique_ptr<wstring> hold(step);
    g_mNote = L"自动配置 " + std::to_wstring(pct) + L"% · " + (hold ? *hold : wstring());
    UiRequestRepaint();
}

static void StartAutoSetup() {
    if (g_mBusy) { UiToast(L"上一件事还在做，等它一下"); return; }
    g_mBusy = true; g_mOpName = L"一键自动配置"; g_mNote = L"正在看环境…";
    std::thread([]() {
        TaskData* d = new TaskData();
        d->kind = TK_OP; d->opName = L"autosetup";
        her::SetupReport r = her::AutoSetup([](int pct, const std::wstring& s) {
            PostMessageW(g_hwnd, WM_APP_AUTOCFG, (WPARAM)pct, (LPARAM)new std::wstring(s));
        });
        d->ok = r.ok; d->text = r.summary;
        for (auto& s : r.steps)
            AppendLineLog(JoinPath(JoinPath(RootDir(), L"logs"), L"setup.log"),
                          (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail);
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}
```

`UiOnClick` 的 `op` 分支先特判：

```cpp
if (op == L"autosetup") { StartAutoSetup(); return; }
```

### 注意
- 下载/解压全在工作线程；`onStep` 回调里**只允许 PostMessage**，不能直接改全局
- `tar.exe` 只在 Win10 1809+，更老系统回退 `powershell Expand-Archive`
- 若将来装到 `Program Files`（卸载了 `PrivilegesRequired=lowest`），`sidecar` 不可写 → 回退 `StateDir()\tools`，并把 `FindNodeExe`/`FindFfmpeg` 的候选列表同步加上

### 验收
- [ ] 删掉 `sidecar\node` 后点「一键自动配置」→ 进度从 5% 走到 100%，Node 被补回，`--paths` 能看到 node 路径
- [ ] 断网时点它 → 不卡界面，最后报告「还差 N 项」，`logs\setup.log` 有明细
- [ ] 配置齐全时再点 → 秒完，返回「环境齐了」
- [ ] 配置期间拖窗口、切页、点其它按钮：界面不冻结，其它按钮显示「在查…」

---

## 5. 掉线提醒（真正落到托盘）

### 现状：四个缺口
1. 开关有动作（`her_actions.cpp:302-325`），但只是拉起 python 的 `tools\qq_watch.py`；找不到 `pythonw.exe` 就只剩一句「后台程序没起来」，**工作台自己从不检测**
2. `WM_APP_TOAST` 定义了却**没有任何地方处理**（`ui.h:5`，`main.cpp` WndProc 只接 JOB/PROGRESS）
3. **全仓没有托盘图标**：`Shell_NotifyIcon` 零命中 → 气泡没地方挂
4. 频率只有开关，没有间隔，也没有持久化

### 改动

**5.1 `main.cpp`：托盘 + 气泡 + 点击回窗口**

```cpp
#include <memory>
#define WM_APP_TRAY (WM_APP + 5)

static NOTIFYICONDATAW g_nid{};
static bool g_trayOk = false;

static void TrayAdd(HWND h) {
    g_nid = {};
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = h;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON,
                                    GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    if (!g_nid.hIcon) g_nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(g_nid.szTip, L"冥零工作台", ARRAYSIZE(g_nid.szTip));
    g_trayOk = Shell_NotifyIconW(NIM_ADD, &g_nid) != FALSE;
}

static void TrayRemove() {
    if (g_trayOk) Shell_NotifyIconW(NIM_DELETE, &g_nid);
    g_trayOk = false;
}

static void TrayBalloon(const std::wstring& text, const std::wstring& title = L"冥零工作台 · 掉线提醒") {
    if (!g_trayOk) return;
    g_nid.uFlags = NIF_INFO;
    g_nid.dwInfoFlags = NIIF_INFO;
    g_nid.uTimeout = 10000;
    lstrcpynW(g_nid.szInfoTitle, title.c_str(), ARRAYSIZE(g_nid.szInfoTitle));
    lstrcpynW(g_nid.szInfo, text.c_str(), ARRAYSIZE(g_nid.szInfo));
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    // 专注助手会压掉气泡，闪任务栏兜底
    FLASHWINFO fw{sizeof(fw), FindWindowW(CLS_NAME, nullptr), FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0};
    if (fw.hwnd) FlashWindowEx(&fw);
}
```

WndProc 补三处：

```cpp
case WM_CREATE:
    UiInit(hwnd);
    TrayAdd(hwnd);                       // 新增
    SetTimer(hwnd, 1, 1000, nullptr);
    return 0;

case WM_APP_TOAST: {                     // 之前完全没处理
    std::unique_ptr<std::wstring> s((std::wstring*)lp);
    if (s) TrayBalloon(*s);
    return 0;
}

case WM_APP_TRAY:
    if (LOWORD(lp) == NIN_BALLOONUSERCLICK || LOWORD(lp) == WM_LBUTTONUP) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        UiToast(L"我在。");
    }
    return 0;

case WM_DESTROY:
    KillTimer(hwnd, 1);
    TrayRemove();                        // 新增
    UiShutdown();
    PostQuitMessage(0);
    return 0;
```

> `WM_APP_TOAST` 的 `lParam` 约定 `new std::wstring`，**由窗口线程 delete**（`unique_ptr` 接管）。任何后台线程都能发。

**5.2 新文件 `win32/src/ui_watch.inc`**（在 `ui.cpp:471` 的 `#include "ui_pages.inc"` 之后再 include）

```cpp
// 掉线提醒（本机心跳）：不依赖 python，工作台自己查
#include <atomic>

static std::atomic<bool> g_hbStop{false};
static HANDLE g_hbWake = nullptr;          // 立刻叫醒，不必等满一个周期
static std::thread g_hbThread;
static int g_hbEvery = 60;
static long long g_hbMuteUntil = 0;        // 手动关服务后 10 分钟内不报

static int NotifyEverySeconds() {
    int v = _wtoi(SettingGet(L"notify_every").c_str());
    if (v < 30) v = 30;
    if (v > 600) v = 600;
    return v;
}

static bool NotifyArmed() {
    // 开关持久化沿用老语义：private\qq-watch-off.txt 存在 = 关
    return !FileExists(JoinPath(JoinPath(BaseDir(), L"private"), L"qq-watch-off.txt"));
}

static void WatchdogTick(bool first) {
    struct Svc { int port; const wchar_t* name; };
    static const Svc SVC[2] = {{5099, L"SnowLuma（QQ 登录）"}, {6199, L"AstrBot（大脑）"}};
    static bool up[2] = {false, false};
    static int miss[2] = {0, 0};
    static bool armed[2] = {false, false};
    bool mute = NowUnix() < g_hbMuteUntil;

    for (int i = 0; i < 2; i++) {
        bool now = PortOpen(SVC[i].port, 250) && PidOnPort(SVC[i].port) != 0;
        if (now) {
            up[i] = true; miss[i] = 0;
            if (!armed[i]) armed[i] = true;        // 先见过它在跑，之后掉线才报
        } else if (up[i]) {
            if (++miss[i] >= 2 && armed[i]) {      // 连续两拍才认掉线，避开重启抖动
                armed[i] = false;
                if (!mute)
                    PostMessageW(g_hwnd, WM_APP_TOAST, 0,
                                 (LPARAM)new std::wstring(std::wstring(SVC[i].name) +
                                                          L" 掉线了。要我把它拉起来吗？"));
            }
        }
        up[i] = now;
    }
    if (!first)
        WriteTextFile(JoinPath(JoinPath(RootDir(), L"logs"), L"workbench-watch.json"),
                      L"{\"at\": " + std::to_wstring(NowUnix()) +
                      L", \"every\": " + std::to_wstring(g_hbEvery) + L"}");
}

static void WatchdogLoop() {
    bool first = true;
    while (!g_hbStop) {
        DWORD wait = (DWORD)g_hbEvery * 1000;
        if (g_hbWake) WaitForSingleObject(g_hbWake, wait); else Sleep(wait);
        if (g_hbStop) break;
        if (!NotifyArmed()) continue;
        g_hbEvery = NotifyEverySeconds();
        WatchdogTick(first);
        first = false;
    }
}

static void StopWatchdog() {
    if (!g_hbThread.joinable()) return;
    g_hbStop = true;
    if (g_hbWake) SetEvent(g_hbWake);
    g_hbThread.join();
    if (g_hbWake) { CloseHandle(g_hbWake); g_hbWake = nullptr; }
    g_hbStop = false;
}

static void StartWatchdog() {
    if (g_hbThread.joinable()) { if (g_hbWake) SetEvent(g_hbWake); return; }
    if (!g_hbWake) g_hbWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_hbStop = false;
    g_hbEvery = NotifyEverySeconds();
    g_hbThread = std::thread(WatchdogLoop);
}

static void MuteWatchdogFor(int seconds) { g_hbMuteUntil = NowUnix() + seconds; }
```

**5.3 接入点**

- 启动（`UiInit` 末尾）：`if (NotifyArmed()) StartWatchdog();`
- 开关（`UiOnClick` 的 `op` 分支）：
  ```cpp
  if (op == L"watch_on")  { StartWatchdog(); }
  if (op == L"watch_off") { StopWatchdog(); }
  if (op == L"watch_every") {
      int v = NotifyEverySeconds();
      v = (v == 30) ? 60 : (v == 60 ? 300 : 30);     // 30s → 1min → 5min → 30s
      SettingSet(L"notify_every", std::to_wstring(v));
      if (g_hbWake) SetEvent(g_hbWake);
      RefreshStatus(true);
      UiToast(L"掉线提醒改成每 " + std::to_wstring(v) + L" 秒查一次。");
      return;
  }
  ```
- 防误报：`StopService`（5099/6199）和 `btn:allstop` 成功后 `MuteWatchdogFor(600);` —— 用户自己关掉的不算掉线
- 收尾：`UiShutdown` 开头 `StopWatchdog();`（必须在 `PostQuitMessage` 之前 join）

**5.4 维护页频率可见可切**（`ui_maint.inc:348-359` watch 列，`chipW` 改 `S(46)`）

```cpp
if (wstring(rows[i].key) == L"watch") {
    float cw2 = S(46);
    {   // 间隔芯片，点击循环
        int ev = _wtoi(SettingGet(L"notify_every").c_str());
        if (ev < 30) ev = 60;
        wstring w = ev >= 300 ? L"5 分" : (ev >= 60 ? L"1 分" : L"30 秒");
        RectF er(cx + 2 * (cw2 + S(6)) + S(4), cy, cw2, S(28));
        Round(g, er, S(9), C_PANEL2, C_LINE);
        Txt(g, w, er, Fnt(HINT_SIZE, 1, 0), C_SUB, 1);
        AddHit(er, "op:watch_every");
    }
    {   // 试一条
        float tx2 = cx + 3 * (cw2 + S(6)) + S(4);
        RectF tr(tx2, cy, S(60), S(28));
        bool en = !g_mBusy && g_mWatchCan;
        Round(g, tr, S(9), C_PANEL2, C_LINE);
        Txt(g, L"试一条", tr, Fnt(HINT_SIZE, 1, 0), en ? C_SUB : C_FAINT, 1);
        if (en) AddHit(tr, "op:watch_test");
    }
    wstring note = !g_mWatchCan ? L"这一版没放"
                  : (g_mWatchOn ? (g_mWatchRun ? L"开着 · 后台在跑" : L"开着 · 后台没起")
                                : L"关着 · 掉线不通知");
    Txt(g, note, RectF(cx, cy + S(32), colW - S(14), S(16)), Fnt(MICRO_SIZE, 1, 0),
        g_mWatchOn && g_mWatchRun ? C_OK : C_FAINT, 0, true);
}
```

**5.5 让「后台在跑」真的会亮**（`her_config.cpp:480-491`）

```cpp
WatchInfo Watch() {
    WatchInfo w;
    w.can = true;
    w.on = !FileExists(P(L"private\\qq-watch-off.txt"));
    long long now = (long long)time(nullptr);

    {   // ① python 老链路
        J j = ReadJson(P(L"logs\\qq-watch.json"));
        w.at = (long long)j.Int(L"at");
        w.state = j.Str(L"state");
        w.note = j.Str(L"note");
        if (w.at > 0 && now - w.at < 600) w.running = true;
    }
    {   // ② 工作台自己的心跳（首选，不需要 python）
        J j = ReadJson(P(L"logs\\workbench-watch.json"));
        long long at = (long long)j.Int(L"at");
        if (at > 0 && now - at < 900) { w.running = true; w.at = at; }
    }
    if (w.on && !w.running) w.note = L"开关开着，但没人在查";
    return w;
}
```

**5.6 持久化白名单**（`paths.cpp:74`）

```cpp
const wchar_t* keys[] = {L"workspace", L"base", L"botRoot",
                         L"secrets", L"notify_every", L"mirror_node"};
```

| 键 | 值 | 默认 |
|---|---|---|
| `notify_every` | `30` / `60` / `300` | 60 |
| `secrets` | 自定义密钥目录 | 空 → `<Base>\secrets` |
| `mirror_node` | 下载镜像 URL | 官方 |

「开/关」继续用 `Base\private\qq-watch-off.txt`（不改语义，否则老用户开关会漂）。

### 验收
- [ ] 托盘出现图标；点它 → 窗口到前面
- [ ] 杀掉 AstrBot → 30~120 秒内右下角弹「AstrBot（大脑）掉线了」，即使气泡被压掉任务栏也闪
- [ ] 关掉开关再杀 → 不弹
- [ ] 手动「全部关闭」→ 不弹（静音窗口生效）
- [ ] 重启工作台：开关（private 文件）与间隔（settings）都还在
- [ ] `--her-status` 的 `WATCH` 行 `running=1`，维护页显示「开着 · 后台在跑」为绿

---

## 6. 提交切片（每片可单独编译）

| # | 提交 | 触及文件 | 前置 |
|---|---|---|---|
| 1 | `docs: v2.1 修改计划` | `docs/plan-v2.1-fixes.md` | — |
| 2 | `refactor(paths): 增加 secrets 目录与配置键白名单` | `core.h`, `paths.cpp` | — |
| 3 | `feat(secrets): 密钥优先从 secrets 读取` | `her_config.cpp`, `her_astr.cpp`, `ui_pages.inc`, `main.cpp` | #2 |
| 4 | `feat(installer): 安装时创建 secrets 并保留` | `installer/mingling.iss`, `installer/secrets-README.txt`, `installer/build-installer.bat` | #2 |
| 5 | `fix(status): 服务存活与功能启用分开判定` | `her_status.cpp`, `ui_maint.inc` | — |
| 6 | `feat(game): 打游戏模式可点、总览页入口、恢复正确` | `her_status.cpp`, `her_actions.cpp`, `ui.cpp`, `ui_pages.inc`, `ui_maint.inc` | #5 |
| 7 | `feat(setup): 一键自动配置环境` | `her_setup.cpp`, `her.h`, `ui.h`, `main.cpp`, `ui_maint.inc`, `build.bat` | #2 |
| 8 | `feat(watch): 托盘气泡 + 本机心跳掉线提醒` | `main.cpp`, `ui.cpp`, `ui_watch.inc`, `her_config.cpp`, `ui_maint.inc` | #2 |

编译校验：`cd win32 && build.bat`；安装包：`installer\build-installer.bat`。

```bat
:: 自检（不进 UI）
MinglingWorkbench.exe --paths        :: 多一行「密钥目录」
MinglingWorkbench.exe --her-status   :: ITEM 的 state / GAME 的 can / WATCH 的 running
MinglingWorkbench.exe --her-op game_on
MinglingWorkbench.exe --her-op game_off
```

---

## 7. 全局检查清单

- [ ] `paths.cpp:74` 白名单已含 `secrets` / `notify_every` / `mirror_node`
- [ ] `Button()` 新增第 8 参数后，所有旧调用点仍能编过（默认值兜底）
- [ ] `g_mGameOn` / `g_mGameCan` 在 `ui.cpp` 定义，`ui_maint.inc:13` 的那行已删（否则重复定义）
- [ ] `ui_watch.inc` 在 `ui.cpp` 里被 include（`build.bat` 只编 `src\ui.cpp`，不会自动发现新 `.inc`）
- [ ] `her_setup.cpp` 已加进 `build.bat:21`
- [ ] `UiShutdown` 里 `StopWatchdog()` 在 `PostQuitMessage` 之前
- [ ] `WM_APP_TOAST` / `WM_APP_AUTOCFG` 的 `lParam` 由窗口线程 `delete`
- [ ] 所有新线程只 `PostMessage`，不直接碰 UI 全局
- [ ] 没有新增链接库（`shell32`、`ws2_32`、`gdiplus` 已在 `build.bat`）

## 8. 风险与回退

| 风险 | 影响 | 回退方式 |
|---|---|---|
| 托空气泡被「专注助手」压掉 | 用户收不到提醒 | 已加 `FlashWindowEx` 兜底；仍不行就再加一个 `MessageBox` 可选设置 |
| `tar.exe` 在 Win10 1809 以下不存在 | 自动配置解压失败 | 回退 `powershell Expand-Archive` |
| 下载源失效 | 自动配置补不了 Node/ffmpeg | 源做成 `settings.json` 可覆盖（`mirror_node`） |
| 心跳误报（服务重启 1~2 拍） | 骚扰 | 连续两拍才认掉线 + 手动停止静音 10 分钟 |
| `game-mode.json` 新增键 | 旧版本读不到新键 → 视为 false | 兼容：`local_voice`/`local_mem` 缺省时退回旧判定 |
