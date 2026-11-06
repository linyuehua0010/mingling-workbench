// 冥零工作台 · 路径与设置（工作区契约的唯一来源）
//
// 目录契约（工作台 / QQ 插件 / 内置 sidecar 三方共用）：
//   <工作区>\out\<BV>\     封面、九宫格、字幕条、原片、正文缓存
//   <工作区>\tmp\          中间帧（抽完即删）
//   <工作区>\logs\         台账 jobs.jsonl、正文 jobs\*.txt、缓存与日志
//   %APPDATA%\MinglingWorkbench\   工作台自身设置（settings.json）
//   %APPDATA%\MinglingWorkbench\bili-state\  日记、quota、作息等 sidecar 状态
//   %USERPROFILE%\.bili-ai\        凭据（B站 Cookie，和上游一致，可备份迁移）
#include "core.h"
#include "version.h"

#include <shlobj.h>
#include <shellapi.h>

// ---------------------------------------------------------------- 小工具
static void EnsureDirTree(const wstring& dir) {
    if (dir.empty() || DirExists(dir)) return;
    size_t pos = dir.find_last_of(L"\\/");
    if (pos != wstring::npos && pos > 2) EnsureDirTree(dir.substr(0, pos));
    CreateDirectoryW(dir.c_str(), nullptr);
}

wstring ParentDir(const wstring& p) {
    wstring d = p;
    while (!d.empty() && (d.back() == L'\\' || d.back() == L'/')) d.pop_back();
    size_t i = d.find_last_of(L"\\/");
    return i == wstring::npos ? wstring() : d.substr(0, i);
}

wstring AppDir() { return ExeDir(); }

wstring StateDir() {
    // 排障 / 验收时临时隔离：MINGLING_STATE_DIR 指哪就写哪，正式使用不设它。
    wchar_t ov[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"MINGLING_STATE_DIR", ov, MAX_PATH * 2);
    if (ov[0]) {
        wstring d = ov;
        EnsureDirTree(d);
        return d;
    }
    wchar_t buf[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH * 2);
    wstring base = buf[0] ? buf : JoinPath(UserProfile(), L"AppData\\Roaming");
    wstring d = JoinPath(base, L"MinglingWorkbench");
#if APP_SNAPSHOT
    // 快照版和正式版并存：settings.json / bili-state / 运行临时目录各写各的，
    // 装快照不会改掉正式版的设置，卸掉快照也不会带走正式版的配置。
    d = JoinPath(d, L"snapshot");
#endif
    EnsureDirTree(d);
    return d;
}

wstring SettingsFile() { return JoinPath(StateDir(), L"settings.json"); }

// ---------------------------------------------------------------- settings.json
// 只存路径和几行小设置，不值得引入 JSON 库。但必须「原文编辑」：
// 键序保留、未知键保留、对象/数组值原样保留 —— 否则 custom_help_texts 这类
// 字典会在下一次 SettingSet 整份重写时被抹掉。
static wstring JsonUnescapeSimple(const wstring& s) {
    wstring o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == L'\\' && i + 1 < s.size()) {
            wchar_t c = s[++i];
            if (c == L'n') o += L'\n';
            else if (c == L't') o += L'\t';
            else o += c;
        } else o += s[i];
    }
    return o;
}

static wstring JsonEscapeSimple(const wstring& s) {
    wstring o;
    for (wchar_t c : s) {
        if (c == L'\\') o += L"\\\\";
        else if (c == L'"') o += L"\\\"";
        else if (c == L'\n') o += L"\\n";
        else if (c == L'\r') continue;
        else o += c;
    }
    return o;
}

struct SettingEntry {
    wstring key;
    wstring raw;      // 值的 JSON 原文（字符串带引号，对象/数组原样）
};

static size_t SkipWs(const wstring& t, size_t i) {
    while (i < t.size() && (t[i] == L' ' || t[i] == L'\t' || t[i] == L'\r' || t[i] == L'\n')) i++;
    return i;
}

// i 指向值的第一个字符，返回值的结束位置（不含）。字符串/对象/数组都能整段跳过。
static size_t ScanValue(const wstring& t, size_t i) {
    if (i >= t.size()) return i;
    wchar_t c = t[i];
    if (c == L'"') {
        for (i++; i < t.size(); i++) {
            if (t[i] == L'\\' && i + 1 < t.size()) { i++; continue; }
            if (t[i] == L'"') return i + 1;
        }
        return t.size();
    }
    if (c == L'{' || c == L'[') {
        int depth = 0;
        bool inStr = false;
        for (; i < t.size(); i++) {
            wchar_t d = t[i];
            if (inStr) {
                if (d == L'\\' && i + 1 < t.size()) { i++; continue; }
                if (d == L'"') inStr = false;
                continue;
            }
            if (d == L'"') { inStr = true; continue; }
            if (d == L'{' || d == L'[') depth++;
            else if (d == L'}' || d == L']') {
                if (--depth == 0) return i + 1;
            }
        }
        return t.size();
    }
    while (i < t.size() && t[i] != L',' && t[i] != L'}' && t[i] != L']') i++;
    while (i > 0) {
        wchar_t p = t[i - 1];
        if (p == L' ' || p == L'\t' || p == L'\r' || p == L'\n') i--;
        else break;
    }
    return i;
}

// 顶层对象拆成有序键值对；坏内容不抛异常，读到哪算哪。
static vector<SettingEntry> ReadSettingsEntries() {
    vector<SettingEntry> out;
    wstring t = ReadTextFile(SettingsFile(), 256 * 1024);
    size_t i = SkipWs(t, 0);
    if (i >= t.size() || t[i] != L'{') return out;
    i++;
    for (;;) {
        i = SkipWs(t, i);
        if (i >= t.size() || t[i] == L'}') break;
        if (t[i] != L'"') { i++; continue; }      // 坏内容：跳过这个字符继续找
        size_t ks = i + 1, ke = ks;
        while (ke < t.size() && t[ke] != L'"') {
            if (t[ke] == L'\\') ke++;
            ke++;
        }
        SettingEntry e;
        e.key = JsonUnescapeSimple(t.substr(ks, ke > ks ? ke - ks : 0));
        i = SkipWs(t, ke + 1);
        if (i < t.size() && t[i] == L':') i = SkipWs(t, i + 1);
        size_t ve = ScanValue(t, i);
        e.raw = Trim(t.substr(i, ve > i ? ve - i : 0));
        out.push_back(e);
        i = SkipWs(t, ve);
        if (i < t.size() && t[i] == L',') i++;
    }
    return out;
}

static void WriteSettingsEntries(const vector<SettingEntry>& es) {
    wstring out = L"{\n";
    for (size_t i = 0; i < es.size(); i++) {
        if (i) out += L",\n";
        out += L"  \"" + JsonEscapeSimple(es[i].key) + L"\": " + es[i].raw;
    }
    out += L"\n}\n";
    WriteTextFile(SettingsFile(), out);
}

// 取值的原文；键不在或文件坏了返回空串。
wstring SettingRaw(const wstring& key) {
    for (auto& e : ReadSettingsEntries())
        if (e.key == key) return e.raw;
    return wstring();
}

// 整段写回一个值（调用方保证是合法 JSON：字符串用引号包好）。
void SettingRawSet(const wstring& key, const wstring& jsonValue) {
    auto es = ReadSettingsEntries();
    bool hit = false;
    for (auto& e : es)
        if (e.key == key) {
            e.raw = jsonValue;
            hit = true;
        }
    if (!hit) es.push_back({key, jsonValue});
    WriteSettingsEntries(es);
}

static wstring QuoteJson(const wstring& v) { return L"\"" + JsonEscapeSimple(v) + L"\""; }

static wstring UnquoteJson(const wstring& raw) {
    if (raw.size() >= 2 && raw.front() == L'"') return JsonUnescapeSimple(raw.substr(1, raw.size() - 2));
    return raw;   // 数字/布尔/对象：原样交给调用方
}

wstring SettingGet(const wstring& key) {
    wstring v = UnquoteJson(SettingRaw(key));
    // 安装器/手写 JSON 可能用正斜杠，统一回 Windows 习惯的写法再往下传。
    if (key == L"workspace" || key == L"base" || key == L"secrets" || key == L"botRoot")
        for (auto& c : v)
            if (c == L'/') c = L'\\';
    return v;
}

void SettingSet(const wstring& key, const wstring& value) {
    if (value.empty()) {
        auto es = ReadSettingsEntries();
        vector<SettingEntry> keep;
        for (auto& e : es)
            if (e.key != key) keep.push_back(e);
        WriteSettingsEntries(keep);
        return;
    }
    SettingRawSet(key, QuoteJson(value));
}

// ---------------------------------------------------------------- 工作区
// 开发树里 exe 在 <仓库>\bin\，工作区就是 <仓库>；安装后 exe 在 <安装目录>\，
// 默认给 %USERPROFILE%\Documents\冥零工作台（安装器会先写入用户选的路径）。
static bool LooksLikeDevTree(const wstring& dir) {
    return DirExists(JoinPath(dir, L"win32")) && FileExists(JoinPath(dir, L"win32\\build.bat"));
}

wstring DefaultWorkspaceDir() {
    wstring up = ParentDir(ExeDir());
    if (LooksLikeDevTree(up)) return up;
    wstring docs;
    wchar_t buf[MAX_PATH * 2] = {0};
    if (SHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, 0, buf) == S_OK && buf[0]) docs = buf;
    else docs = JoinPath(UserProfile(), L"Documents");
    return JoinPath(docs, L"冥零工作台");
}

wstring WorkspaceDir() {
    wchar_t env[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_WORKSPACE", env, MAX_PATH * 2) && DirExists(env)) return env;
    wstring s = SettingGet(L"workspace");
    if (!s.empty() && DirExists(s)) return s;
    wstring d = DefaultWorkspaceDir();
    EnsureDirTree(d);
    SettingSet(L"workspace", d);
    return d;
}

void SetWorkspaceDir(const wstring& dir) {
    if (dir.empty()) return;
    EnsureDirTree(dir);
    SettingSet(L"workspace", dir);
    EnsureWorkspaceLayout(dir);
}

// 组件根：AstrBot/SnowLuma/Breeze/Ollama/bili-whale 统一装到 <工作区>\bots。
// 老机器上它们散在 <Base> 下，由 her::BotPath() 负责「新优先、旧兜底」。
wstring BotRoot() {
    // 环境变量只在目录真的存在时才算数：从别处继承来的旧值（比如测试留下的
    // MINGLING_BOTS=F:/x/tmp/ws/bots，目录早删了）不该把整台机器的组件根搬到空气里。
    wchar_t env[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_BOTS", env, MAX_PATH * 2) && env[0] && DirExists(env))
        return wstring(env);
    wstring s = SettingGet(L"botRoot");
    if (!s.empty()) return s;
    return JoinPath(WorkspaceDir(), L"bots");
}

wstring BotDir(const wstring& name) { return JoinPath(BotRoot(), name); }


// 机器人根目录：SnowLuma / AstrBot / private / uv 的上一级。
// 默认跟工作区同级（工作区 = <机器人根>\bili），可用 base 覆盖。
wstring BaseDir() {
    wstring b = SettingGet(L"base");
    if (!b.empty() && DirExists(b)) return b;
    return ParentDir(WorkspaceDir());
}

void SetBaseDir(const wstring& dir) {
    if (dir.empty()) return;
    SettingSet(L"base", dir);
}

void EnsureWorkspaceLayout(const wstring& root) {
    if (root.empty()) return;
    EnsureDirTree(root);
    EnsureDirTree(JoinPath(root, L"out"));
    EnsureDirTree(JoinPath(root, L"tmp"));
    EnsureDirTree(JoinPath(root, L"logs"));
    EnsureDirTree(JoinPath(root, L"bots"));
    EnsureDirTree(JoinPath(root, L"logs\\jobs"));
    EnsureDirTree(JoinPath(JoinPath(StateDir(), L"bili-state"), L"shots"));
}

// ---------------------------------------------------------------- 密钥目录
// 安装器把密钥放在 <Base>\secrets：它在 {app} 之外，重装/卸载都不动。
// 老版本写在 <Base>\private，SecretFile 回退到那里读，旧文件不用搬。
wstring SecretsDir() {
    wchar_t env[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_SECRETS", env, MAX_PATH * 2) && env[0]) return wstring(env);
    wstring s = SettingGet(L"secrets");
    if (!s.empty()) return s;
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
    EnsureDirTree(dir);
    wstring readme = JoinPath(dir, L"README.txt");
    const wstring kDshLine = L"dsh-api-key.txt     B 站页「对话 API」的 Key（不写 settings.json）\r\n";
    const wstring kGhLine = L"github-token.txt    更新检查用的 GitHub token（只有私有仓库才需要）\r\n";
    if (!FileExists(readme))
        WriteTextFile(readme,
                      L"这个文件夹放密钥，重装/卸载都不会删。\r\n\r\n"
                      L"snowluma-webui.txt  SnowLuma 网页后台密码（password=…）\r\n"
                      L"backend.txt         AstrBot 后台账号（username=… / password=…）\r\n"
                      L"deepseek-key.txt    DeepSeek API Key（sk-…）\r\n"
                      L"protocol.txt        QQ 协议端类型（napcat / snowluma）\r\n" + kDshLine + kGhLine);
    else {
        // 老装机：只补缺的那几行，别覆盖用户自己加的
        wstring cur = ReadTextFile(readme, 65536);
        bool addDsh = cur.find(L"dsh-api-key.txt") == wstring::npos;
        bool addGh = cur.find(L"github-token.txt") == wstring::npos;
        if (addDsh) WriteTextFile(readme, kDshLine, true);
        if (addGh) WriteTextFile(readme, kGhLine, true);
    }
    return true;
}

// ---------------------------------------------------------------- 内置 sidecar
// 顺序：$MINGLING_SIDECAR → <exe>\sidecar → <exe 上级>\sidecar（开发树 bin\..）
wstring SidecarDir() {
    wchar_t env[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_SIDECAR", env, MAX_PATH * 2) && DirExists(env)) return env;
    vector<wstring> cands = {JoinPath(ExeDir(), L"sidecar"),
                             JoinPath(ParentDir(ExeDir()), L"sidecar"),
                             JoinPath(ParentDir(ParentDir(ExeDir())), L"sidecar")};
    for (auto& c : cands) {
        if (FileExists(JoinPath(JoinPath(JoinPath(c, L"bili-whale"), L"tools"), L"bili.mjs"))) return c;
    }
    return cands[0];
}

wstring SidecarWhaleDir() { return JoinPath(SidecarDir(), L"bili-whale"); }

wstring SidecarNodeExe() {
    wstring p = JoinPath(JoinPath(SidecarDir(), L"node"), L"node.exe");
    return FileExists(p) ? p : wstring();
}

wstring SidecarFfmpegExe() {
    const wchar_t* rel[] = {L"ffmpeg\\bin\\ffmpeg.exe", L"ffmpeg\\ffmpeg.exe",
                            L"bili-whale\\bin\\ffmpeg.exe"};
    for (auto r : rel) {
        wstring p = JoinPath(SidecarDir(), r);
        if (FileExists(p)) return p;
    }
    return wstring();
}

// ---------------------------------------------------------------- 选文件夹
wstring PickFolder(HWND owner, const wstring& title, const wstring& initial) {
    BROWSEINFOW bi{};
    bi.hwndOwner = owner;
    bi.lpszTitle = title.c_str();
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_USENEWUI;
    wstring init = initial;
    bi.lpfn = [](HWND hwnd, UINT msg, LPARAM, LPARAM data) -> int {
        if (msg == BFFM_INITIALIZED && data) SendMessageW(hwnd, BFFM_SETSELECTIONW, TRUE, data);
        return 0;
    };
    bi.lParam = (LPARAM)init.c_str();
    LPITEMIDLIST idl = SHBrowseForFolderW(&bi);
    if (!idl) return wstring();
    wchar_t path[MAX_PATH * 2] = {0};
    bool ok = SHGetPathFromIDListW(idl, path) != FALSE;
    CoTaskMemFree(idl);
    return ok ? wstring(path) : wstring();
}

// ---------------------------------------------------------------- 迁移（复制 out\tmp\logs）
static void CopyTree(const wstring& from, const wstring& to) {
    if (!DirExists(from)) return;
    EnsureDirTree(to);
    WIN32_FIND_DATAW fd{};
    HANDLE h = FindFirstFileW(JoinPath(from, L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        wstring src = JoinPath(from, name), dst = JoinPath(to, name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) CopyTree(src, dst);
        else CopyFileW(src.c_str(), dst.c_str(), FALSE);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

void MigrateWorkspaceData(const wstring& from, const wstring& to) {
    if (from.empty() || to.empty() || from == to) return;
    const wchar_t* sub[] = {L"out", L"tmp", L"logs"};
    for (auto s : sub) CopyTree(JoinPath(from, s), JoinPath(to, s));
}

// ---------------------------------------------------------------- 卸载项（应用和功能）
void RegisterUninstallEntry() {
    wstring app = AppDir();
    wstring unins = JoinPath(app, L"unins000.exe");
    if (!FileExists(unins)) return;  // 开发目录直接跑 exe 时没有卸载器
    HKEY key = NULL;
#if APP_SNAPSHOT
    // 快照版自己的卸载项：和正式版各占一行，谁也别删谁
    const wchar_t* sub = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\MinglingWorkbench_snapshot_is1";
#else
    const wchar_t* sub = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\MinglingWorkbench_is1";
#endif
    if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, NULL, 0, KEY_WRITE, NULL, &key, NULL) != ERROR_SUCCESS)
        return;
    auto setStr = [&](const wchar_t* name, const wstring& val) {
        RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*)val.c_str(),
                       (DWORD)((val.size() + 1) * sizeof(wchar_t)));
    };
    setStr(L"DisplayName", std::wstring(APP_NAME) + L" " + APP_VERSION);
    // 显示完整串（含渠道后缀）：应用和功能列表里一眼能分出正式版和快照版
    setStr(L"DisplayVersion", APP_VERSION);
    setStr(L"Publisher", L"冥零工作台");
    setStr(L"InstallLocation", app);
    setStr(L"DisplayIcon", JoinPath(app, L"MinglingWorkbench.exe"));
    setStr(L"UninstallString", L"\"" + unins + L"\"");
    setStr(L"QuietUninstallString", L"\"" + unins + L"\" /VERYSILENT");
    DWORD one = 1;
    RegSetValueExW(key, L"NoModify", 0, REG_DWORD, (const BYTE*)&one, sizeof(one));
    RegSetValueExW(key, L"NoRepair", 0, REG_DWORD, (const BYTE*)&one, sizeof(one));
    RegCloseKey(key);
}
