# 冥零工作台 v2 · 五项需求改造方案

> 对象：`win32\src\` 原生 Win32 + GDI+ 工作台。
> 结论先说：**需求 1、5 已经有一半代码在仓库里**（`her_setup.cpp` 的一键配置、`ui_watch.inc` 的看门狗 + 托盘气泡），缺的是「装到 `<工作区>\bots\`」和「文案可配」。**需求 3 有一个必须先拆的雷**：`settings.json` 现在只能存扁平字符串，写字典会被下一次 `SettingSet` 整个抹掉（`paths.cpp:108`）。

## 0. 现状 ⇄ 改动一览

| # | 需求 | 现状锚点 | 主要改动文件 | 新增文件 |
|---|------|----------|--------------|----------|
| 1 | 一键装 AstrBot/SnowLuma/Breeze/Ollama/bili-whale 到 `<工作区>\bots\` | `her/her_setup.cpp:203` `AutoSetup()`；`ui_maint.inc:423` `StartAutoSetup()`；`ui_maint.inc:392` 按钮 `op:autosetup` | `paths.cpp`、`core.h`、`her/her_setup.cpp`、`her/her_config.cpp`、`her/her.h`、`ui_maint.inc`、`win32/build.bat` | `tools/auto-setup.ps1` |
| 2 | 冥零专属 Skill 模板（人设留 `{user_persona}`） | `ui_help.inc:11-39` `ASKS[]`（11 张卡）；AstrBot 人设 API `/api/v1/personas` | `her/her_actions.cpp`、`her/her.h`、`her/her_config.cpp` | `plugin/mingling_skill/mingling_skill.json`、`plugin/mingling_skill/persona/mingling.md`、`tools/import-mingling.ps1` |
| 3 | 求助页文字用户可改 | `ui_help.inc:70-71` 直接画 `ASKS[i].title/.text` | `paths.cpp`（设置读写底座）、`ui_help.inc`、`ui_pages.inc`、`main.cpp`（子窗口配色）、`ui.h` | —— |
| 4 | 帮助页显示 AstrBot/SnowLuma/Breeze 绝对路径，检测统一到 `<工作区>\bots\` | `ui_help.inc:138` `HelpText()` 只有 3 行；`her/her_status.cpp:301,346,500-545` 用 `P("SnowLuma")` / `P("breeze-tts")` | `ui_help.inc`、`her/her_status.cpp`、`her/her_probe.cpp`、`her/her_config.cpp` | —— |
| 5 | 每分钟掉线检测 + 冥零风格提醒（气泡/横幅，文案可配） | `ui_watch.inc:27` `WatchdogTick()`；`main.cpp:69` `TrayBalloon()`（标题写死） | `ui_watch.inc`、`main.cpp`、`ui_pages.inc`、`ui.h` | —— |

---

## 1. 先立地基：`<工作区>\bots\` 目录契约（需求 1、4 共用）

现在全部组件都装在 `Base`（默认就是工作区上一级，本机 `D:\`），`paths.cpp` 里没有 `bots` 这个概念。第一步把它做成**契约**，后面两件事才有地方落。

### 1.1 `paths.cpp` 新增

```cpp
// ------------------------------------------------ <工作区>\bots（需求 1/4 的落地目录）
// settings.botRoot 已经写在旧白名单里但一直没人读，这里把它接上；
// 读不出来就固定 <工作区>\bots，跟安装包文档、帮助页文案保持同一句话。
std::wstring BotRoot() {
    std::wstring v = SettingGet(L"botRoot");
    if (!v.empty()) return v;
    return JoinPath(WorkspaceDir(), L"bots");
}

std::wstring BotDir(const std::wstring& name) { return JoinPath(BotRoot(), name); }
```

`EnsureWorkspaceLayout(root)`（`paths.cpp:170`）里追加一句建目录，保证「打开工作区」立刻能看到空目录：

```cpp
void EnsureWorkspaceLayout(const std::wstring& root) {
    // …原样保留 out / tmp / logs / logs\jobs / StateDir()\bili-state\shots…
    std::wstring bots = JoinPath(root, L"bots");
    CreateDirectoryW(bots.c_str(), nullptr);          // ← 新增
}
```

`SecretsDir()` / `EnsureSecrets()` 不动：密钥留在 secrets / private，跟 bots 里的程序分开，卸载 bots 不会带走密码。

### 1.2 `core.h` 补声明

```cpp
// 工作区里的组件目录（需求 1/4）
wstring BotRoot();
wstring BotDir(const std::wstring& name);

// 任意 JSON 值的原文读写：对象/数组/字符串都能存（需求 3/5 的底座）
wstring SettingRaw(const wstring& key);
void    SettingRawSet(const wstring& key, const wstring& jsonValue);
```

### 1.3 旧布局怎么办（重要，别把老机器搞坏）

本机现在就是老布局（`D:\\SnowLuma` 等）。一键配置只往 `bots\` 装，**不搬、不删**老目录；检测端统一走「先新后旧」：

```cpp
// her_config.cpp —— bots 优先，老布局兜底，两个都没有返回新位置（用于提示「还没装」）
std::wstring BotPath(const wchar_t* name) {
    std::wstring fresh = BotDir(name);
    if (DirExists(fresh) || FileExists(fresh)) return fresh;
    std::wstring legacy = P(name);
    if (DirExists(legacy) || FileExists(legacy)) return legacy;
    return fresh;
}
```

好处：老用户升级后状态卡不会变红，新装的机器也不会同时出现两套。

---

## 2. 需求 1：一键配置环境

### 2.1 为什么不在 C++ 里写下载

`her_setup.cpp` 已经证明这条路能走（WinHTTP 流式下载 + tar/Expand-Archive），但五个组件的差异全在细节里：SnowLuma 要挑 `win-x64.zip` 而不是 `-lite.zip`、Breeze 要看 Vulkan 资产名、AstrBot 要 uv 工具目录、bili-whale 是 Node 包。把这些写成 C++ 会变成 2000 行正则。**分工**：

- C++：建目录、拉起脚本、逐行读进度、把结果翻成 UI 文案、留日志。
- PowerShell：所有「找最新 release / 挑资产 / 解压 / 写配置」，失败只影响自己那一步。

C++ 端沿用已有的 `RunCaptureStream()`（`core.h`：逐行回调 + `CREATE_NO_WINDOW` 已封装），不需要自己写 `CreateProcess`。

### 2.2 `her_setup.cpp` 追加 `BotsSetup()`

```cpp
// ---------------------------------------------------------------------------
// 需求 1：把五个组件装进 <工作区>\bots
// 协议见 tools/auto-setup.ps1 头部注释，一行一条，别改格式：
//   ##STEP 35|正在装 SnowLuma      → 进度条
//   ##OK   SnowLuma|<路径>          → 这一步成了
//   ##FAIL Breeze|<原因+怎么办>     → 这一步没过，脚本会继续跑后面的
//   ##RESULT ok=0 fixed=3           → 收尾（ok=0 表示有失败项）
// ---------------------------------------------------------------------------
namespace {

struct SetupPipe {
    const std::function<void(int, const std::wstring&)>* onStep = nullptr;
    her::SetupReport* rep = nullptr;
    std::wstring log;
};

void OnSetupLine(const std::wstring& raw, void* user) {
    SetupPipe* p = (SetupPipe*)user;
    std::wstring line = Trim(raw);
    if (line.empty()) return;
    p->log += line + L"\n";

    if (StartsWith(line, L"##STEP ")) {
        std::wstring body = line.substr(7);
        size_t bar = body.find(L'|');
        int pct = _wtoi(body.substr(0, bar == std::wstring::npos ? body.size() : bar).c_str());
        if (p->onStep && *p->onStep)
            (*p->onStep)(pct, bar == std::wstring::npos ? body : body.substr(bar + 1));
    } else if (StartsWith(line, L"##OK ") || StartsWith(line, L"##FAIL ")) {
        bool ok = (line[2] == L'O');
        std::wstring body = line.substr(7);
        size_t bar = body.find(L'|');
        SetupStep s;
        s.name = (bar == std::wstring::npos) ? body : body.substr(0, bar);
        s.detail = (bar == std::wstring::npos) ? std::wstring() : body.substr(bar + 1);
        s.ok = ok;
        p->rep->steps.push_back(s);
        if (ok) p->rep->fixed++;
    }
}

}  // namespace

her::SetupReport BotsSetup(const std::function<void(int, const std::wstring&)>& onStep) {
    her::SetupReport rep;
    std::wstring script;
    const std::wstring cands[] = {
        JoinPath(JoinPath(Root(), L"tools"), L"auto-setup.ps1"),      // 开发树
        JoinPath(JoinPath(AppDir(), L"tools"), L"auto-setup.ps1"),    // 安装版
    };
    for (const auto& c : cands)
        if (FileExists(c)) { script = c; break; }
    if (script.empty()) {
        rep.ok = false;
        rep.summary = L"这一版没带 tools\\auto-setup.ps1，先重装一遍工作台。";
        return rep;
    }

    if (onStep) onStep(2, L"准备 " + BotRoot());
    CreateDirectoryW(BotRoot().c_str(), nullptr);
    EnsureWorkspaceLayout(WorkspaceDir());   // 顺带把 bots 建出来（1.1）

    std::wstring args =
        L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + L"\"" +
        L" -Workspace \"" + WorkspaceDir() + L"\"" +
        L" -Bots \""      + BotRoot()      + L"\"" +
        L" -Base \""      + BaseDir()      + L"\"";

    EnvList env;
    env.push_back({L"PYTHONUTF8", L"1"});
    env.push_back({L"PYTHONIOENCODING", L"utf-8"});

    SetupPipe pipe;
    pipe.onStep = &onStep;
    pipe.rep = &rep;

    // 45 分钟：Ollama 模型 + uv 拉 Python 一起跑，比 AutoSetup 长得多
    CmdResult r = RunCaptureStream(L"powershell.exe", args, Root(), env,
                                   45 * 60 * 1000, OnSetupLine, &pipe);

    std::wstring logPath = JoinPath(JoinPath(Root(), L"logs"), L"bots-setup.log");
    WriteTextFile(logPath, pipe.log);

    if (!r.started) {
        rep.ok = false;
        rep.summary = L"拉起 PowerShell 失败（系统里找不到 powershell.exe？）。";
        return rep;
    }
    if (r.timeout) {
        rep.ok = false;
        rep.summary = L"装到 45 分钟还没完，先停了。已经装好的不会坏，再点一次会接着补。";
        return rep;
    }

    int bad = 0;
    for (const auto& s : rep.steps) if (!s.ok) bad++;
    rep.ok = (r.code == 0 && bad == 0);
    rep.summary = rep.ok
        ? L"五个组件都在 <工作区>\\bots 里了，去「维护」点「全部启动」看看。"
        : L"还差 " + std::to_wstring(bad) + L" 项，看 logs\\bots-setup.log 最后一条 ##FAIL。";
    if (onStep) onStep(100, L"完成");
    return rep;
}
```

`her.h` 里补一句声明（跟 `AutoSetup` 并排）：

```cpp
SetupReport BotsSetup(const std::function<void(int, const std::wstring&)>& onStep);
std::wstring BotPath(const wchar_t* name);   // 1.3
```

### 2.3 UI：一个按钮跑两段（`ui_maint.inc:423`）

工作台自己的运行时（Node/ffmpeg/Python）和五个组件是两件事，但用户只想点一次：

```cpp
static void StartAutoSetup() {
    if (g_mBusy) { UiToast(L"上一件事还在做，等它一下"); return; }
    g_mBusy = true;
    g_mOpName = L"一键配置环境";
    g_mNote = L"正在看环境…";
    std::thread([]() {
        TaskData* d = new TaskData();
        d->kind = TK_OP;
        d->opName = L"autosetup";

        // 前 50%：工作台自己的运行时（Node / ffmpeg / Python / 工作区）
        her::SetupReport a = her::AutoSetup([](int pct, const std::wstring& s) {
            PostMessageW(g_hwnd, WM_APP_AUTOCFG, (WPARAM)(pct / 2),
                         (LPARAM)new std::wstring(s));
        });
        // 后 50%：五个组件（#<工作区>\bots）
        her::SetupReport b = her::BotsSetup([](int pct, const std::wstring& s) {
            PostMessageW(g_hwnd, WM_APP_AUTOCFG, (WPARAM)(50 + pct / 2),
                         (LPARAM)new std::wstring(s));
        });

        d->ok = a.ok && b.ok;
        d->text = a.summary + L"\n" + b.summary;

        std::wstring log;
        for (const auto& s : a.steps) log += (s.ok ? L"[ok] " : L"[!!] ") + s.name + L" — " + s.detail + L"\n";
        for (const auto& s : b.steps) log += (s.ok ? L"[ok] " : L"[!!] ") + s.name + L" — " + s.detail + L"\n";
        WriteTextFile(JoinPath(JoinPath(Root(), L"logs"), L"setup.log"), log, true);
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}
```

按钮文案从「一键自动配置」改成「一键配置环境」（`ui_maint.inc:392`，`op:autosetup` 不用改，`UiOnClick` 已认）。

### 2.4 `tools/auto-setup.ps1` 的核心逻辑

只做四件事：**取最新 release → 挑对资产 → 解压到 `bots\<名字>` → 写启动脚本与配置**。完整文件已放在仓库 `tools/auto-setup.ps1`，关键段落：

```powershell
# 每个组件一个函数，返回 $true/$false，失败只喊 ##FAIL 不终止
function Install-Ollama([string]$dst) {
    $zip = Join-Path $tmp 'ollama.zip'
    Get-File -Urls @('https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip') `
             -OutFile $zip
    Expand-ZipSafe $zip $tmp\ollama
    Move-Tree (Join-Path $tmp 'ollama') $dst
    if (-not (Test-Path (Join-Path $dst 'ollama.exe'))) { return $false }
    return $true
}

function Install-SnowLuma([string]$dst) {
    # 资产名有两种：SnowLuma-v2.4.0-win-x64.zip / -lite.zip，只挑非 lite 的 win-x64
    $u = Get-ReleaseAsset -Repo 'TomyJan/SnowLuma' -Pattern 'win-x64\.zip$' -Exclude 'lite'
    ...
    # 启动脚本跟官方 Release 的 launcher.bat 对齐，密码仍读 private\
    & {
      "@echo off", "cd /d `"$dst`"",
      "if not exist private\snowluma-webui.txt echo off",
      ...
    } | Set-Content (Join-Path $dst 'start.cmd') -Encoding default
}

function Install-AstrBot([string]$dst) {
    # uv 自举：uv.exe 优先用 -Base\uv\bin\uv.exe，没有就下 astral-sh/uv 的 zip
    $uv = Find-Uv
    $env:UV_TOOL_DIR       = Join-Path $dst 'tools'
    $env:UV_TOOL_BIN_DIR   = Join-Path $dst 'bin'
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $dst 'python'
    & $uv tool install astrbot      # 装进 bots\AstrBot\tools\astrbot
    Get-ChildItem $env:UV_TOOL_BIN_DIR -Filter astrbot.exe | Select-Object -First 1
}
```

环境变量分两层写（**不改系统级**，避免装完影响别的软件）：

| 变量 | 值 | 写入位置 |
|------|-----|----------|
| `MINGLING_BOTS` | `<工作区>\bots` | 用户级（`[Environment]::SetEnvironmentVariable(...,'User')`），方便手动排错 |
| `OLLAMA_MODELS` | `<工作区>\bots\Ollama\models` | 同上，模型不落在系统盘 |
| `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` / `UV_PYTHON_INSTALL_DIR` | `bots\AstrBot\{tools,bin,python}` | 只在本脚本进程内 + 写进 `bots\AstrBot\env.cmd` |

`bots\.setup.json` 是给人看、也给工作台读的清单（需求 4 显示版本用）：

```json
{ "at": "2026-11-06 08:40", "bots": "<工作区>\\bots",
  "items": { "AstrBot": "4.5.2", "SnowLuma": "2.4.0", "Breeze": "0.1.6",
             "Ollama": "0.12.3", "bili-whale": "0.3.1" } }
```

脚本还会顺手写两个东西：

- `bots\start-all.cmd`：按 Ollama → SnowLuma → Breeze → AstrBot 的顺序各起一个最小化窗口，`timeout /t 6` 隔开（QQ 登录要先于大脑连上）。维护页「全部启动」直接拉这个文件。
- `bots\AstrBot\env.cmd`：`UV_TOOL_DIR / UV_TOOL_BIN_DIR / UV_PYTHON_INSTALL_DIR` 三条，手动排错时双击就有同样的环境。

**两个坑（照抄会踩）：**

1. **编码**：`RunCaptureStream()` 按 UTF-8 解管道（`util.cpp:506` `Utf8ToW(line)`），PowerShell 5.1 默认按 OEM 代码页（中文机器是 936）往管道写，中文会全变乱码。脚本开头必须先把控制台输出改成 UTF-8：

   ```powershell
   try {
       $utf8 = New-Object System.Text.UTF8Encoding $false
       [Console]::OutputEncoding = $utf8
       $OutputEncoding = $utf8
   } catch {}
   ```

2. **`Write-Host` 也会进管道**：重定向时它跟 `Write-Output` 走同一个 stdout，所以 C++ 会同时收到 `##STEP …` 和 `  [ 35%] …` 两种行。`OnSetupLine` 只认 `##` 前缀、其余只进日志，正好；但也别把进度信息全写进 `Write-Host`——UI 认的是 `##STEP`。

---

## 3. 需求 2：冥零专属 Skill 模板

### 3.1 文件结构

```
plugin/mingling_skill/
├─ mingling_skill.json        # 模板清单：人设占位、注入目标、默认设置
├─ persona/mingling.md        # 人设正文，{user_persona} 等占位
├─ persona/mingling-persona.sample.json   # 不想改模板文件就填这份，复制到 <Base>\private\
└─ README.md                  # 给使用者看的「怎么填 + 常见问题」
tools/import-mingling.ps1     # 注入器：填占位 → 写 AstrBot 人设 → 切默认人设 → 出桌宠人设
```

### 3.2 `mingling_skill.json`（结构仿 dafeiyu 配置包，但人设留空）

```json
{
  "id": "mingling_skill",
  "name": "冥零",
  "version": "2026.11.06",
  "persona": {
    "id": "{persona_id}",
    "file": "persona/mingling.md",
    "persona_template": "{user_persona}",
    "notes": "人设正文留了 {user_persona}，导入时不填就保持原样，后台里能直接改。"
  },
  "placeholders": {
    "user_persona": "（你的角色设定：性格、说话习惯、称呼、边界…）",
    "owner_qq":     "（你的 QQ 号，用来做白名单，不会写进人设正文）",
    "owner_name":   "（她怎么叫你）",
    "bot_name":     "（她在 QQ 上显示的名字）"
  },
  "inject": {
    "astrbot": { "api": "/api/v1", "persona_endpoint": "/personas",
                 "default_persona_path": "agent_runner.config.persona.persona_id" },
    "snowluma": { "supported": false,
                  "why": "SnowLuma 只负责登 QQ 和收发消息，没有人设字段；人设只在 AstrBot。" },
    "pet": { "file": "tools/pet-persona.txt", "why": "桌宠走同一个文本文件" }
  },
  "defaults": {
    "agent_runner.config.persona.safety_mode": true,
    "agent_runner.config.persona.safety_mode_strategy": "system_prompt"
  }
}
```

### 3.3 注入 AstrBot 的真实步骤（已核实）

人设不在 `cmd_config.json` 里，而在后端 SQLite：`astrbot\data\data_v4.db` 表 `personas`（`astrbot/core/db/po.py:150`，字段 `persona_id / system_prompt / begin_dialogs / tools / skills / custom_error_message`）。所以必须走后台 HTTP，不能改文件：

1. `POST /api/v1/auth/login {username,password}` → `token`（密码先明文、失败再 md5，跟 `her_astr.cpp:78` 一致）。
2. `GET /api/v1/personas/{persona_id}`：命中就 `PUT /api/v1/personas/{id}`，否则 `POST /api/v1/personas`。
3. 把 `agent_runner.config.persona.persona_id` 切成新 id（`GET /config-profiles/default` → 改 → `PUT`），这一步不做，人设存进去也不会生效。
4. 白名单里旧人设名的条目要跟着换（`platform_settings.id_whitelist` 形如 `"大肥鱼:FriendMessage:2957389852"`）。

`tools/import-mingling.ps1` 的核心（节选，完整版在仓库）：

```powershell
$p = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$md = Get-Content (Join-Path $PackRoot $p.persona.file) -Raw -Encoding UTF8
$md = $md.Replace('{user_persona}', $Fill.user_persona).
          Replace('{bot_name}', $Fill.bot_name).
          Replace('{owner_name}', $Fill.owner_name)
# owner_qq 只进白名单，不进正文
$pid_ = if ($Fill.persona_id) { $Fill.persona_id } else { '冥零' }

$api = "http://127.0.0.1:$port/api/v1"
$login = Invoke-RestMethod "$api/auth/login" -Method Post -Body (@{username=$u;password=$pw}|ConvertTo-Json)
$h = @{ Authorization = "Bearer $($login.data.token)" }

$found = $null
try { $found = Invoke-RestMethod "$api/personas/$([uri]::EscapeDataString($pid_))" -Headers $h } catch {}
$body = @{ persona_id = $pid_; system_prompt = $md; begin_dialogs = @(); tools = $null } | ConvertTo-Json -Depth 6
if ($found -and $found.data.persona_id -eq $pid_) {
    Invoke-RestMethod "$api/personas/$([uri]::EscapeDataString($pid_))" -Method Put -Headers $h -Body $body
} else {
    Invoke-RestMethod "$api/personas" -Method Post -Headers $h -Body $body -ContentType 'application/json'
}
# 1) 切默认人设  2) 白名单换名字  3) 出桌宠文本
Write-Output "RESULT ok=1 persona=$pid_ next=重启 AstrBot 生效"
```

### 3.4 工作台入口

- `her_actions.cpp` 分派表（`:1009-1028`）加一行：`import_skill` → 调 `RunCaptureStream(powershell, "-File tools\\import-mingling.ps1 -Pack plugin\\mingling_skill", ...)`，把 `RESULT` 行当结果文案。
- `ui_maint.inc` rowB 把 `op:skill_update`（拉线上 Skill）改成两个：`op:import_skill`（用本地模板注入）和保留的更新按钮。
- 求助页「换成我自己的角色」卡片的正文补一句：**先填 `plugin\mingling_skill\persona\mingling.md` 的 `{user_persona}`，再点维护页「导入冥零人设」**。

---

## 4. 需求 3：求助页文字可编辑

### 4.1 先拆雷：`settings.json` 存不住字典

`paths.cpp` 的读写是「白名单 + 扁平字符串 + 整文件重写」：

- `ReadSettingsMap()`（`:70`）只认 7 个键，别的键读出来直接丢；
- `SettingSet()`（`:108`）用 map 重新拼整个文件，于是 `custom_help_texts` 这种对象、以及任何不在白名单的键，**下一次保存设置就没了**。

所以先换底座：**原地编辑原文，只动目标键的值区间**，其他字节一个不碰。

```cpp
// paths.cpp —— 把「读出来重组」改成「在原文上换值」
static bool IsWs(wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n'; }
static size_t SkipWs(const std::wstring& t, size_t q) {
    while (q < t.size() && IsWs(t[q])) q++;
    return q;
}

// 找 "key" 后面的冒号；找不到返回 npos
static size_t KeyColon(const std::wstring& t, const std::wstring& key) {
    std::wstring pat = L"\"" + key + L"\"";
    size_t p = 0;
    while ((p = t.find(pat, p)) != std::wstring::npos) {
        size_t q = SkipWs(t, p + pat.size());
        if (q < t.size() && t[q] == L':') return q;
        p += pat.size();
    }
    return std::wstring::npos;
}

// 从值的起点量一个 JSON 值的结束位置：字符串认转义，括号要配对
static size_t ValueEnd(const std::wstring& t, size_t v) {
    if (v >= t.size()) return v;
    if (t[v] == L'"') {
        for (size_t i = v + 1; i < t.size(); i++) {
            if (t[i] == L'\\') { i++; continue; }
            if (t[i] == L'"') return i + 1;
        }
        return t.size();
    }
    if (t[v] == L'{' || t[v] == L'[') {
        wchar_t open = t[v], close = (open == L'{') ? L'}' : L']';
        int depth = 0;
        bool inStr = false;
        for (size_t i = v; i < t.size(); i++) {
            wchar_t c = t[i];
            if (inStr) {
                if (c == L'\\') { i++; continue; }
                if (c == L'"') inStr = false;
                continue;
            }
            if (c == L'"') { inStr = true; continue; }
            if (c == open) depth++;
            else if (c == close && --depth == 0) return i + 1;
        }
        return t.size();
    }
    size_t i = v;                                   // 数字 / true / null
    while (i < t.size() && t[i] != L',' && t[i] != L'}' && t[i] != L']' && !IsWs(t[i])) i++;
    return i;
}

std::wstring SettingRaw(const std::wstring& key) {
    std::wstring t = ReadTextFile(SettingsFile(), 256 * 1024);
    size_t c = KeyColon(t, key);
    if (c == std::wstring::npos) return std::wstring();
    size_t v = SkipWs(t, c + 1);
    return t.substr(v, ValueEnd(t, v) - v);
}

void SettingRawSet(const std::wstring& key, const std::wstring& jsonValue) {
    std::wstring t = ReadTextFile(SettingsFile(), 256 * 1024);
    if (Trim(t).empty()) t = L"{\n}\n";
    size_t c = KeyColon(t, key);
    if (c != std::wstring::npos) {
        size_t v = SkipWs(t, c + 1);
        t = t.substr(0, v) + jsonValue + t.substr(ValueEnd(t, v));     // 只换这一段
    } else {
        size_t close = t.find_last_of(L'}');
        if (close == std::wstring::npos) {
            t = L"{\n  \"" + key + L"\": " + jsonValue + L"\n}\n";
        } else {
            std::wstring head = t.substr(0, close);
            size_t nb = head.find_last_not_of(L" \t\r\n");
            bool emptyBody = (nb != std::wstring::npos && head[nb] == L'{');
            t = head + (emptyBody ? L"\n  " : L",\n  ") + L"\"" + key + L"\": " +
                jsonValue + L"\n}\n";
        }
    }
    WriteTextFile(SettingsFile(), t);
}
```

`SettingGet` / `SettingSet` 改成薄壳（对老调用完全兼容）：

```cpp
std::wstring SettingGet(const std::wstring& key) {
    std::wstring raw = SettingRaw(key);
    if (raw.size() < 2 || raw[0] != L'"') return std::wstring();   // 对象值不给扁平常量
    std::wstring v = JsonUnescapeSimple(raw.substr(1, raw.size() - 2));
    if (key == L"workspace" || key == L"base" || key == L"secrets")
        for (auto& c : v) if (c == L'/') c = L'\\';
    return v;
}

void SettingSet(const std::wstring& key, const std::wstring& value) {
    if (value.empty()) { /* 删键：略，见仓库实现 */ return; }
    SettingRawSet(key, L"\"" + JsonEscapeSimple(value) + L"\"");
}
```

> 白名单可以整个删掉——原地编辑不需要它。删掉之后 `botRoot`、`mirror_*` 这些键继续有效，同时不再有「保存一次吞一个键」的问题。

### 4.2 卡片加 id，文案进字典

现在的卡片只有下标，插一张就全错位。改成稳定 id，并在 `ui_help.inc` 顶部读设置：

```cpp
struct AskDef { const wchar_t* id; const wchar_t* title; const wchar_t* text; };

static const AskDef ASKS[] = {
  { L"role",     L"换成我自己的角色", L"……原文……" },
  { L"voice",    L"换个声音",         L"……" },
  { L"breeze",   L"换成 Breeze 在线版", L"……" },
  { L"dialect",  L"听懂更多方言",     L"……" },
  { L"group",    L"让她进我的 QQ 群", L"……" },
  { L"silent",   L"她不回话了",       L"……" },
  { L"always",   L"电脑关机她也在线", L"……" },
  { L"napcat",   L"QQ 升级后先换成 NapCat", L"……" },
  { L"backup",   L"用备份还原",       L"……" },
  { L"uninstall",L"卸载她",           L"……" },
  { L"memory",   L"记忆没接上",       L"……" },
};
static const int ASK_N = (int)(sizeof(ASKS) / sizeof(ASKS[0]));

// key 约定："<id>" 改正文，"<id>.title" 改标题
static std::map<std::wstring, std::wstring> g_helpText;
static bool g_helpTextReady = false;

static void LoadHelpTexts() {
    g_helpText.clear();
    std::wstring raw = SettingRaw(L"custom_help_texts");
    bool ok = false;
    her::J j = her::J::Parse(raw, &ok);
    if (ok && j.Obj())
        for (const auto& kv : j.o)                     // J 的对象是 vector<pair<wstring,J>>
            if (kv.second.t == her::J::STR) g_helpText[kv.first] = kv.second.s;
    g_helpTextReady = true;
}

static std::wstring AskTitle(int i) {
    auto it = g_helpText.find(std::wstring(ASKS[i].id) + L".title");
    return it == g_helpText.end() ? std::wstring(ASKS[i].title) : it->second;
}
static std::wstring AskBody(int i) {
    auto it = g_helpText.find(ASKS[i].id);
    return it == g_helpText.end() ? std::wstring(ASKS[i].text) : it->second;
}

static void SetHelpText(const std::wstring& key, const std::wstring& value) {
    if (value.empty()) g_helpText.erase(key); else g_helpText[key] = value;
    her::J j = her::JObj();                              // 写成对象，交给 SettingRawSet 原样落盘
    for (const auto& kv : g_helpText) j.Set(kv.first, her::J(kv.second));
    SettingRawSet(L"custom_help_texts", j.Dump(2));
}
```

绘制处把 `ASKS[i].title` / `ASKS[i].text` 换成 `AskTitle(i)` / `AskBody(i)`（`ui_help.inc:70-71`），复制按钮（`ui_pages.inc:1132`）也换成 `AskBody(i)`。

### 4.3 编辑入口：卡片右下角「改文字」+ 原生 EDIT 浮层

用系统 `EDIT` 控件而不是自绘输入框：多行、滚动、输入法、Ctrl+A 全是现成的，符合「不引入第三方 UI 库」。

```cpp
// ui_help.inc
static HWND g_askEdit = nullptr, g_askSave = nullptr, g_askCancel = nullptr;
static int  g_askEditIdx = -1;
static RectF g_askCardRc[ASK_N];          // 每帧记下卡片位置，浮层贴着卡片弹

static void CloseAskEditor(bool save) {
    if (!g_askEdit) return;
    if (save && g_askEditIdx >= 0) {
        wchar_t buf[8000] = {};
        GetWindowTextW(g_askEdit, buf, 8000);
        SetHelpText(ASKS[g_askEditIdx].id, Trim(buf));
    }
    if (g_askSave)   DestroyWindow(g_askSave);
    if (g_askCancel) DestroyWindow(g_askCancel);
    DestroyWindow(g_askEdit);
    g_askEdit = g_askSave = g_askCancel = nullptr;
    g_askEditIdx = -1;
    SetFocus(g_hwnd);
}

static void OpenAskEditor(int i) {
    CloseAskEditor(false);
    g_askEditIdx = i;
    RectF r = g_askCardRc[i];
    int x = (int)r.X + (int)S(10), y = (int)r.Y + (int)S(46);
    int w = (int)r.Width - (int)S(20), h = (int)r.Height - (int)S(96);

    g_askEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", AskBody(i).c_str(),
        WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | ES_WANTRETURN,
        x, y, w, h, g_hwnd, (HMENU)0x9101, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(g_askEdit, WM_SETFONT, (WPARAM)Fnt(BODY_SIZE, 0, 0)->ToHFont(), TRUE);
    SendMessageW(g_askEdit, EM_SETSEL, 0, -1);

    g_askSave = CreateWindowExW(0, L"BUTTON", L"保存",
        WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
        x, y + h + (int)S(6), (int)S(90), (int)S(28), g_hwnd, (HMENU)0x9102,
        GetModuleHandleW(nullptr), nullptr);
    g_askCancel = CreateWindowExW(0, L"BUTTON", L"恢复默认",
        WS_CHILD | WS_VISIBLE, x + (int)S(98), y + h + (int)S(6), (int)S(110), (int)S(28),
        g_hwnd, (HMENU)0x9103, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(g_askSave, WM_SETFONT, (WPARAM)Fnt(HINT_SIZE, 0, 0)->ToHFont(), TRUE);
    SendMessageW(g_askCancel, WM_SETFONT, (WPARAM)Fnt(HINT_SIZE, 0, 0)->ToHFont(), TRUE);
    SetFocus(g_askEdit);
}
```

`main.cpp` 的 `WndProc` 认这几条（**不写会画成白底方框，跟深色主题打架**）：

```cpp
case WM_COMMAND: {
    int id = LOWORD(wp);
    if (id == 0x9102) { CloseAskEditor(true);  UiRequestRepaint(); return 0; }
    if (id == 0x9103) { CloseAskEditor(false); UiRequestRepaint(); return 0; }
    break;
}
case WM_CTLCOLOREDIT:
case WM_CTLCOLORBTN: {
    HDC dc = (HDC)wp;
    SetTextColor(dc, RGB(0xEA, 0xEF, 0xF7));
    SetBkColor(dc, RGB(0x16, 0x1B, 0x26));
    static HBRUSH br = CreateSolidBrush(RGB(0x16, 0x1B, 0x26));
    return (LRESULT)br;
}
```

`UiOnClick` 加两条（在 `ask:<i>` 旁边）：

```cpp
if (p[0] == "ask")     { if (idx < ASK_N) OpenAskEditor(idx); ... }      // 原样保留复制
if (p[0] == "askedit") { OpenAskEditor(atoi(p[1].c_str())); return; }   // 卡片角上的「改文字」
```

卡片里加小按钮（`ui_help.inc:76` 之后）：

```cpp
Button(g, RectF(r.X + r.Width - S(88), r.Y + r.Height - S(40), S(76), S(26)),
       L"改文字", "askedit:" + std::to_string(i), 0, true);
```

### 4.4 键盘与焦点要挡一下

编辑框打开时，主窗口的 `UiOnChar` 会继续往 `g_bvInput` 塞字符（`ui_pages.inc:1318`），`UiOnKeyDown` 的 `1-9` 也会切页。两个函数开头各加一行：

```cpp
if (g_askEdit) return;   // 编辑卡片文字时，快捷键全部让路
```

`UiPaint` 末尾如果编辑框在，重绘别把它盖掉——`UiPaint` 走的是 `BitBlt` 到窗口 DC，子窗口天然浮在上面，不用特殊处理；只要记得 `g_askCardRc` 每帧更新（`PaintAsk` 里 `g_askCardRc[i] = r;`），否则滚动后弹窗位置会错。

### 4.5 默认值与示例

`settings.json` 示例（旧机器 `SettingRaw` 读不到就是空，全部回落默认文案，零迁移）：

```json
{
  "workspace": "D:\\MinglingWorkbench",
  "botRoot": "D:\\\\bots",
  "notify_every": "60",
  "custom_help_texts": {
    "voice":       "换个更温柔的声音",
    "group":       "让她进我的 QQ 群",
    "backup":      "用备份还原中的……",
    "role.title":  "换成我自己的角色"
  }
}
```

---

## 5. 需求 4：帮助页路径与状态检测

### 5.1 `HelpText()`（`ui_help.inc:138`）追加一段

```cpp
std::wstring HelpText() {
    std::wstring s = FAQ_TEXT;
    s += L"\n════ 当前路径 ════\n";
    s += L"工作区：" + WorkspaceDir() + L"\n";
    s += L"组件目录：" + BotRoot() + L"\n";
    s += L"  AstrBot："  + BotPath(L"AstrBot")  + L"\n";
    s += L"  SnowLuma：" + BotPath(L"SnowLuma") + L"\n";
    s += L"  Breeze："   + BotPath(L"Breeze")   + L"\n";
    s += L"  Ollama："   + BotPath(L"Ollama")   + L"\n";
    s += L"  bili-whale：" + BotPath(L"bili-whale") + L"\n";
    s += L"台账：" + JobsFile() + L"\n";
    s += L"状态：" + StateDir() + L"\n";
    // 装了哪一版：一键配置写的清单（需求 1）
    std::wstring man = ReadTextFile(JoinPath(BotRoot(), L".setup.json"), 64 * 1024);
    if (!man.empty()) s += L"安装清单：" + JoinPath(BotRoot(), L".setup.json") + L"\n" + man + L"\n";
    return s;
}
```

路径太长会撑破一行，`DrawRich` 已有按字符折行；如果确定要单行显示，`BotPath` 结果前加 `\n  ` 缩进即可（现有 FAQ 里已有这种写法）。

`PaintHelp`（`:147`）再加一个直达按钮：

```cpp
Button(g, ..., L"打开组件目录", "doc:bots", 0);
```

`UiOnClick` 的 `doc:` 分支（`ui_pages.inc:1144`）加 `p[1] == "bots"` → `ShellExecuteW(nullptr, L"open", BotRoot().c_str(), ...)`。

### 5.2 状态检测统一到 bots（`her_status.cpp`）

| 位置 | 现在 | 改成 |
|------|------|------|
| `:301` | `proot = P(proto=="napcat"? L"NapCat" : L"SnowLuma")` | `proot = BotPath(proto=="napcat"? L"NapCat" : L"SnowLuma")` |
| `:346` | `prun = !PidsUnder(Lc(proot)).empty() \|\| Listening(...)` | 不变（`proot` 已经动了），但补 `\|\| FileExists(proot + L"\\node.exe")` 让「装了没跑」也能区分 |
| `:307-334` AstrBot 卡 | `AstrBotPids()` + `Listening(BackendPort())` | `PidsUnder(Lc(BotPath(L"AstrBot")))` 或 `PidsUnder(Lc(P(L"uv")))` 二选一，先新后旧 |
| `:500-545` Breeze 卡 | `Listening(8137)`、`P("breeze-tts\\start-breeze.cmd")` | `BotPath(L"Breeze")`，启动文件 `JoinPath(BotPath(L"Breeze"), L"start.cmd")` |
| `:557` ffmpeg | `P("ffmpeg\\bin\\ffmpeg.exe")` | 不动（仍是工作台自带） |

`her_probe.cpp:184` `AstrBotPids()` 同样把 `P(L"uv")` 扩成两处：

```cpp
std::vector<int> AstrBotPids() {
    std::vector<int> v = PidsUnder(Lower(P(L"uv")));                       // 老布局
    std::wstring fresh = Lower(BotPath(L"AstrBot"));                       // 新布局
    std::vector<int> w = PidsUnder(fresh);
    v.insert(v.end(), w.begin(), w.end());
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v;
}
```

卡片文案建议顺手改成「AstrBot（<工作区>\bots\AstrBot）」，用 `exe` 的父目录而不是全路径，否则卡片会换行。

### 5.3 `her::Data()` 也要跟着走（不然后台配置读不到）

`Data()` 现在是「`<Base>\astrbot\data` 优先，否则找 `AstrBot*\core\data`」。改到 bots 布局后，AstrBot 的数据目录是 `<bots>\AstrBot\data`，所以要加一个最高优先级候选：

```cpp
std::wstring Data() {
    std::wstring fresh = JoinPath(BotPath(L"AstrBot"), L"data");     // 新布局优先
    if (DirExists(fresh)) return fresh;
    // …原样保留：<Base>\astrbot\data → AstrBot*\core\data → AstrBot*\data
}
```

同理 `IsCli()`（判断 `<Base>\start-astrbot.cmd` 在不在）、`Protocol()`（看 `start-snowluma.cmd` / `start-napcat.cmd`）都要加一条 `bots\` 下的启动脚本判断——一键配置给每个组件都写了 `start.cmd`，判断条件用「`<dir>\start.cmd` 或 `index.mjs` / `node.exe` 任一个在」。

### 5.4 维护页的「装到哪」也一起改

维护页状态卡（`ui_maint.inc:196` 起）里的路径文案走同一个 `BotPath`，避免「帮助页说 bots、维护页说 Base」的两套说法。

---

## 6. 需求 5：冥零风格掉线提醒

### 6.1 现状与缺口

- 已有：`ui_watch.inc` 60s 看门狗线程、连续 2 次 miss 才报、见过在跑才报（不会开机就喊）、`WM_APP_TOAST` → `TrayBalloon()`。
- 缺：文案写死、标题写死、没有自定义头像、没有主界面横幅、端口硬编码（改 bots 后要跟着走）。

### 6.2 新增设置键（都是扁平字符串，`SettingGet` 直接读）

| 键 | 默认 | 说明 |
|----|------|------|
| `notify_every` | `60` | 已有，30..600 |
| `notify_title` | `冥零 · 掉了` | 气泡标题 |
| `notify_body` | `哎呀，{name} 掉线了，快重启一下大脑吧~` | 正文，支持 `{name}` `{time}` |
| `notify_avatar` | 空 | 自定义头像 PNG，空则用 exe 内置图标 |
| `notify_banner` | `1` | `0` 关掉主界面顶部横幅，只留气泡 |
| `notify_action` | `1` | 气泡/横幅点一下执行「拉起来」（调 `RunAction("restart_qq"/"restart_brain")`） |

### 6.3 `ui_watch.inc`：模板化 + 走 bots

```cpp
static std::wstring Tpl(const wchar_t* key, const wchar_t* def) {
    std::wstring v = SettingGet(key);
    return v.empty() ? std::wstring(def) : v;
}

static std::wstring Fill(std::wstring s, const std::wstring& name) {
    s = ReplaceAll(s, L"{name}", name);
    s = ReplaceAll(s, L"{time}", NowStamp());
    return s;
}

// 端口也从配置来（一键配置改了端口也不瞎）
static int NotifyPort(const wchar_t* key, int def) {
    std::wstring v = SettingGet(key);
    return v.empty() ? def : _wtoi(v.c_str());
}

static void ReportDown(const std::wstring& name, const std::wstring& action) {
    NotifyReq* req = new NotifyReq();
    req->title = Fill(Tpl(L"notify_title", L"冥零 · 掉了"), name);
    req->body  = Fill(Tpl(L"notify_body", L"哎呀，{name} 掉线了，快重启一下大脑吧~"), name);
    req->icon  = SettingGet(L"notify_avatar");
    req->action = action;                                   // "restart_qq" / "restart_brain"
    PostMessageW(g_hwnd, WM_APP_NOTIFY, 0, (LPARAM)req);     // main.cpp 负责托盘 + 横幅
}
```

`WatchdogTick()`（`:27`）里把硬编码的 `SVC[2]` 换成：

```cpp
struct Svc { const wchar_t* name; const wchar_t* dir; int port; const wchar_t* act; };
static const Svc SVC[] = {
    { L"SnowLuma（QQ 登录）", L"SnowLuma", 5099, L"restart_qq" },
    { L"AstrBot（大脑）",     L"AstrBot",  6199, L"restart_brain" },
};
// 检测：文件在 + 端口在 才算「活着」；进程名在但端口没起 = 半死，也报
bool alive = PortOpen(s.port, 250) && PidOnPort(s.port) != 0;
bool installed = DirExists(BotPath(s.dir));
if (!installed) continue;                    // 没装就别喊
```

### 6.4 `main.cpp`：自定义头像的气泡 + 横幅

`NIIF_USER` + `hBalloonIcon` 才认自定义图：

```cpp
#define WM_APP_NOTIFY (WM_APP + 6)

struct NotifyReq { std::wstring title, body, icon, action; };

// PNG → HICON：给 hBalloonIcon 用；没有 alpha 图标工程也能接受
static HICON IconFromPng(const std::wstring& path, int px) {
    if (path.empty() || !FileExists(path)) return nullptr;
    Gdiplus::Bitmap bmp(path.c_str());
    if (bmp.GetLastStatus() != Gdiplus::Ok || bmp.GetWidth() == 0) return nullptr;
    Gdiplus::Bitmap scaled(px, px, PixelFormat32bppARGB);
    Gdiplus::Graphics gg(&scaled);
    gg.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    gg.DrawImage(&bmp, 0, 0, px, px);

    HBITMAP color = nullptr;
    scaled.GetHBITMAP(Gdiplus::Color(0, 0, 0, 0), &color);
    HBITMAP mask = CreateBitmap(px, px, 1, 1, nullptr);
    ICONINFO ii{};
    ii.fIcon = TRUE; ii.hbmColor = color; ii.hbmMask = mask;
    HICON ic = CreateIconIndirect(&ii);
    DeleteObject(color); DeleteObject(mask);
    return ic;
}

static void TrayNotify(const NotifyReq& n) {
    if (!g_trayOk) return;
    static HICON s_ic = nullptr;
    static std::wstring s_icPath;
    if (n.icon != s_icPath) {                       // 路径变了才重做
        if (s_ic) { DestroyIcon(s_ic); s_ic = nullptr; }
        s_ic = IconFromPng(n.icon, 32);
        s_icPath = n.icon;
    }
    g_nid.uFlags = NIF_INFO;
    g_nid.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
    g_nid.hBalloonIcon = s_ic ? s_ic : nullptr;
    g_nid.uTimeout = 10000;
    lstrcpynW(g_nid.szInfoTitle, n.title.c_str(), 64);
    lstrcpynW(g_nid.szInfo,      n.body.c_str(), 256);
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    FlashWindowEx(...);                              // 保留原兜底
}
```

> 现实提醒：Windows 11 会把气泡换成「专注助手」通知，`NIIF_USER` 的图未必显示、10 秒超时也被忽略。**所以横幅不是锦上添花，是主路径**（下面 6.5）。

### 6.5 主界面顶部滑动横幅（自绘，不依赖系统）

```cpp
// ui_pages.inc（全局）
struct Banner { bool on = false; std::wstring text, action; ULONGLONG at = 0; float x = 0; };
static Banner g_banner;

// main.cpp 收到 WM_APP_NOTIFY：既发气泡，也让主界面挂横幅
case WM_APP_NOTIFY: {
    std::unique_ptr<NotifyReq> n((NotifyReq*)lp);
    TrayNotify(*n);
    g_banner.on = (SettingGet(L"notify_banner") != L"0");
    g_banner.text = n->title + L" · " + n->body;
    g_banner.action = n->action;
    g_banner.at = GetTickCount64();
    g_banner.x = 0.f;
    UiRequestRepaint();                              // 窗口在后台也会被 UiTick 带出来
    return 0;
}
```

`UiTick()` 里推进动画（每秒一次就够，不用另起线程）：

```cpp
// 顶部横幅：0.8s 滑入，停 8s，0.5s 滑出
if (g_banner.on) {
    float t = (float)(GetTickCount64() - g_banner.at) / 1000.f;
    if (t < 0.8f)       g_banner.x = -1.f + t / 0.8f;             // -1 → 0
    else if (t < 8.8f)  g_banner.x = 0.f;
    else if (t < 9.3f)  g_banner.x = (t - 8.8f) / 0.5f;           // 0 → 1
    else                g_banner.on = false;
    UiRequestRepaint();
}
```

`UiPaint` 在 `PaintSidebar` 之后、页面之前画横幅（这样页面滚动不会把它推走）：

```cpp
static void PaintBanner(Gdiplus::Graphics& g) {
    if (!g_banner.on) return;
    float w = g_w - S(220), h = S(46);
    float y = S(12) + g_banner.x * -(h + S(20));
    RectF r(S(220) + S(12), y, w - S(24), h);
    Round(g, r, S(10), C_ACCENT, C_ACCENT2, 1.0f);
    Txt(g, g_banner.text, RectF(r.X + S(14), r.Y, r.Width - S(150), r.Height),
        Fnt(BODY_SIZE, 0, 0), C_TEXT);
    Button(g, RectF(r.X + r.Width - S(120), r.Y + S(9), S(104), S(28)),
           L"拉起来", "banner:fix", 1, true);
    AddHit(r, "banner:hit");
}
```

`UiOnClick` 加 `banner:` 分支：`fix` → `RunHerOp(g_banner.action)`；`hit` → 关掉横幅。

### 6.6 不打扰（这几点比动画重要）

1. **只在见过在跑之后才报**（已有 `seen` 逻辑），不然开机自启顺序一反就误报。
2. **连续 2 次 miss 才算掉线**（已有）——端口扫描 250ms，单次抖动不算。
3. **静音开关**：`MuteWatchdogFor(seconds)` 已有，把「静音 1 小时」摆到横幅右上角；`private\qq-watch-off.txt` 继续是全关。
4. **失败也别连环喊**：同一组件 10 分钟内只报一次（`std::map<wstring,ULONGLONG> g_lastNotify`）。
5. **提醒里带动作**：`notify_action=1` 时点一下就 `RunAction`，这就是「快重启一下大脑吧」真正能一键做到的部分。

---

## 7. 改动清单

| 文件 | 改动 |
|------|------|
| `win32/src/core.h` | 加 `BotRoot/BotDir/SettingRaw/SettingRawSet` 声明 |
| `win32/src/paths.cpp` | `BotRoot/BotDir` 实现；`EnsureWorkspaceLayout` 建 `bots`；`SettingGet/SettingSet` 改走 `SettingRaw/RawSet`；删白名单 |
| `win32/src/her/her.h` | 加 `BotsSetup/BotPath` |
| `win32/src/her/her_config.cpp` | `BotPath()`（新→旧双查）、`BotRootDir()` |
| `win32/src/her/her_setup.cpp` | 加 `SetupPipe/OnSetupLine/BotsSetup`（2.2） |
| `win32/src/her/her_status.cpp` | `:301/:307-334/:346/:500-545` 换 `BotPath`，卡片文案带目录 |
| `win32/src/her/her_probe.cpp` | `AstrBotPids()` 新旧合并（5.2） |
| `win32/src/her/her_actions.cpp` | 加 `import_skill`（调 `import-mingling.ps1`）；`restart_qq/restart_brain` 用 `BotPath` 下的启动脚本 |
| `win32/src/ui_maint.inc` | `StartAutoSetup` 两段（2.3）；rowB 加「导入冥零人设」 |
| `win32/src/ui_help.inc` | `AskDef` 带 id、`LoadHelpTexts/AskTitle/AskBody/SetHelpText`；编辑浮层；`HelpText()` 加组件路径；`doc:bots` |
| `win32/src/ui_pages.inc` | `UiOnClick` 加 `askedit/banner/doc:bots`；`UiOnMove` 白名单加 `askedit/banner`；`UiOnChar/UiOnKeyDown` 加 `if (g_askEdit) return;`；`UiTick` 推横幅动画；`UiPaint` 画横幅 |
| `win32/src/main.cpp` | `WM_APP_NOTIFY`、`NotifyReq`、`IconFromPng`、`TrayNotify`（NIIF_USER）、`WM_COMMAND`/`WM_CTLCOLOR*` 给编辑框上色 |
| `win32/src/ui.h` | `WM_APP_NOTIFY`、`struct NotifyReq` |
| `win32/src/ui_watch.inc` | 模板化文案、`SVC` 带目录/动作、`g_lastNotify` 节流、调 `ReportDown` |
| `win32/build.bat` | 若新增 `.cpp` 才要动；本方案没加新编译单元 |
| `tools/auto-setup.ps1` | **新增**：五个组件装进 `bots\`（含 `start-all.cmd`、`.setup.json`） |
| `tools/import-mingling.ps1` | **新增**：填占位 → 注入 AstrBot → 切默认人设 → 出桌宠文本 |
| `plugin/mingling_skill/mingling_skill.json` | **新增**：Skill 清单（占位符、注入目标、默认值） |
| `plugin/mingling_skill/persona/mingling.md` | **新增**：人设模板（`{user_persona}` / `{user_tone}` 留空） |
| `plugin/mingling_skill/persona/mingling-persona.sample.json` | **新增**：填表样例 |
| `plugin/mingling_skill/README.md` | **新增**：怎么填、怎么排错 |
| `docs/plan-5-features.md` | 本文 |

## 8. 验证

1. **编译**：`win32\build.bat` 出 0 error 0 warning（`-Wall` 下注意 `_wtoi` 的 `<cstdlib>`、`Gdiplus::Bitmap` 的 `<gdiplus.h>` 顺序）。
2. **settings 不再吞键**：手写一个带 `custom_help_texts` 和 `botRoot` 的 `settings.json` → 在 UI 里改工作区 → 退出 → 文件里两个键都还在、格式没被压平。
3. **一键配置**：清空 `bots\`，点按钮 → 进度条走到 100 → `bots\{AstrBot,SnowLuma,Breeze,Ollama,bili-whale}` 都在，`bots\.setup.json` 有版本号；故意断网再点一次，应看到 `##FAIL` 对应的红字而不是整体失败。
4. **Skill 注入**：`tools\import-mingling.ps1 -DryRun` 打印将写的人设 → 真跑一次 → 后台「人格」里出现「冥零」且是默认；`cmd_config.json` 的 `agent_runner.config.persona.persona_id` 同步；`{user_persona}` 未被替换时人设正文里保持原样（说明占位没丢）。
5. **求助页**：改一张卡 → 退出重进还在 → 「恢复默认」回到原文；编辑时按 `1`~`9` 不切页。
6. **帮助页**：五个路径段都在，「打开组件目录」能开；拔掉 `bots\SnowLuma` 目录后状态卡变红而不是崩。
7. **掉线提醒**：`taskkill /f /im astrbot.exe` → 约 2 分钟内收到气泡 + 顶部横幅；点「拉起来」AstrBot 起来；`notify_banner=0` 时只有气泡；`.setup.json` 里没装的组件不报。

## 9. 取舍与风险

- **不做迁移**：老布局保留、检测双查。理由：搬目录要停进程、改启动脚本、改自启 lnk，风险远大于收益；用户想要「干净的 bots」就重装一次。
- **AstrBot 用 uv 装而不是解压 zip**：官方发布没有便携 zip，uv 是它自己文档里的装法；代价是首次要拉一个 Python（~30MB 压缩），所以进度条给了 45 分钟上限。
- **人设只进 AstrBot**：SnowLuma 真没有人设字段（只有 onebot/notifications/runtime/ui/webui），硬塞只会让下次启动被覆盖。桌宠走 `pet-persona.txt`。
- **`NIIF_USER` 在 Win11 可能不显示图**：已经用横幅兜底；两者都关的用户至少还有 `logs\workbench-watch.json` 的落盘记录。

---

## 10. 落地记录（2026-11-06）

这一节是实施后补的，记录「计划里写的」和「实际落地的」差在哪。

### 10.1 实际改了哪些文件

| 文件 | 改了什么 |
| --- | --- |
| `win32\src\paths.cpp` | settings 换成「有序键值对 + 值原文」：`SettingRaw` / `SettingRawSet` / `QuoteJson` / `UnquoteJson`，`SettingGet` / `SettingSet` 变薄壳；新增 `BotRoot()` / `BotDir()`；`EnsureWorkspaceLayout` 建 `bots` |
| `win32\src\core.h` | 补 `SettingRaw` / `SettingRawSet` / `BotRoot` / `BotDir` 声明 |
| `win32\src\her\her.h` | 补 `BotPath()`、`BotsSetup()` 声明 |
| `win32\src\her\her_config.cpp` | `BotPath()`（bots 优先、老布局兜底）；`Data()` / `IsCli()` / `Protocol()` 认 bots |
| `win32\src\her\her_probe.cpp` | `AstrBotPids()` 合并新旧布局；`QqOnline()` 认四组目录 |
| `win32\src\her\her_status.cpp` | 协议端、Breeze、ffmpeg、Ollama 全部走 `BotPath`，老目录作为兜底 |
| `win32\src\her\her_setup.cpp` | 新增 `BotsSetup()` 与 `##STEP` / `##OK` / `##FAIL` / `##RESULT` 行协议解析 |
| `win32\src\her\her_actions.cpp` | 新增 `import_skill` 动作（跑 `tools\import-mingling.ps1`） |
| `win32\src\ui_maint.inc` | 按钮多一个「导入冥零人设」；`StartAutoSetup()` 改两段式 |
| `win32\src\ui_help.inc` | `AskDef` 加自定义文案读取、改文字浮层、组件路径段、「组件目录」按钮 |
| `win32\src\ui_watch.inc` | 整文件重写：3 服务、可配文案、头像气泡、右上角滑入横幅、`WatchTest()` |
| `win32\src\ui_pages.inc` | 横幅与浮层的事件分派、`doc:bots`、`op:watch_test`、前置声明与清理 |
| `win32\src\ui.h` | `WM_APP_NOTIFY`、`NotifyReq`、编辑器与托盘图标的导出函数 |
| `win32\src\main.cpp` | `TrayBalloon` 带头像、`WM_APP_NOTIFY` / `WM_CTLCOLOREDIT`、`--bots-setup`、`--paths` 补组件路径、Esc 关浮层 |

新增文件：`tools\auto-setup.ps1`、`tools\import-mingling.ps1`、`plugin\mingling_skill\`（清单 + 人设模板 + 样例 + README）。

### 10.2 与计划的差异

- **编辑框字体**：计划里写 `Fnt(...)->ToHFont()`，MinGW 的 gdiplus 没有这个方法，改成 `CreateFontW` 自建的 `AskEditorFont()`。
- **横幅常量**：`IN` / `OUT` / `HOLD` 撞了 `sal.h` 的空宏，改名 `ANIM_IN` / `ANIM_OUT` / `HOLD_MS`。
- **`Round()`**：没有默认的描边参数，所有调用都要给满 5 个参数。
- **Breeze 的 `##OK` 名字**：脚本里用它自己的显示名，C++ 侧不硬编码，避免两边改名后对不上。

### 10.3 验证

1. `cd win32 && build.bat` 得到 `OK: bin\MinglingWorkbench.exe`（1,249,792 字节），无 error。
2. `bin\MinglingWorkbench.exe --paths` 打印出 `组件根` 与 AstrBot / SnowLuma / Breeze / Ollama 的绝对路径。
3. `bin\MinglingWorkbench.exe --her-status` 退出码 0，状态采集没有因为 `BotPath` 改动崩掉。
4. settings 自测（临时 TU，跑完已删）：写入对象键与普通键，删除另一个键，重新读文件，对象与其余键都在，中文 UTF-8 正常。
5. `tools\auto-setup.ps1` 全 `-Skip*` 冒烟：输出 `##STEP …` 与 `##RESULT ok=0 fixed=0`，生成 `bots\.setup.json` 与 `start-all.cmd`。
6. `tools\import-mingling.ps1 -DryRun -Base D:/`：写出 `logs\mingling-persona.filled.md`，回 `RESULT ok=1`，字节能用 UTF-8 读回。

### 10.4 还没验证的（要动真环境才能验）

- 真实下载五个组件（会往 `bots\` 里写几百 MB）。
- 真把人设注入到正在跑的 AstrBot（会改数据库里的默认人设）。
- Win11 上托盘气泡与横幅的实际观感（气泡可能被系统吞掉，横幅一定能看到）。
