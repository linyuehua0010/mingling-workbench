// 冥零工作台 · 配置：路径、answers.json、private\*.txt、astrbot 的几份 json、版本号
// 全部按「只读为主、要改就整份原子替换」来做，跟 python 那版的行为一致。
#include "her.h"

#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <ctime>

namespace her {

namespace {

std::wstring Up(const std::wstring& d) {
    size_t i = d.find_last_of(L"\\/");
    return i == std::wstring::npos ? d : d.substr(0, i);
}

std::wstring Lower(std::wstring s) {
    for (auto& c : s)
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
    return s;
}

J g_answers;
bool g_answersOk = false;

J& AnswersJson() {
    if (!g_answersOk) {
        g_answers = ReadJson(JoinPath(Base(), L"answers.json"));
        g_answersOk = true;
    }
    return g_answers;
}

}  // namespace

// ---------------------------------------------------------------- 路径
// 机器人根：跟工作台设置里的 base 一致（旧版按 exe 往上两级猜，装到 %LOCALAPPDATA% 时就猜歪了）
std::wstring Base() {
    static std::wstring b;
    if (!b.empty()) return b;
    b = BaseDir();
    return b;
}

std::wstring Root() {
    static std::wstring r;
    if (!r.empty()) return r;
    r = Up(ExeDir());
    return r;
}

std::wstring P(const wchar_t* rel) { return JoinPath(Base(), rel); }
// 组件目录：新布局 <工作区>\bots\<name> 优先，老布局 <Base>\<原名> 兜底。
// 都没有时返回新位置——报错、安装、打开都指着它，用户能看懂该往哪放。
std::wstring BotPath(const wchar_t* name) {
    std::wstring inBots = BotDir(name);
    if (DirExists(inBots)) return inBots;
    struct Alias {
        const wchar_t* want;
        const wchar_t* old1;
        const wchar_t* old2;
    };
    static const Alias kAlias[] = {
        {L"AstrBot", L"astrbot", L"AstrBot"},
        {L"SnowLuma", L"SnowLuma", L"snowluma"},
        {L"NapCat", L"NapCat", L"napcat"},
        {L"Breeze", L"breeze-tts", L"Breeze"},
        {L"Ollama", L"Ollama", L"ollama"},
        {L"uv", L"uv", L""},
        {L"bili-whale", L"bili-whale", L"bili_whale"},
    };
    for (auto& a : kAlias) {
        if (_wcsicmp(name, a.want) != 0) continue;
        std::wstring c1 = P(a.old1);
        if (DirExists(c1)) return c1;
        if (a.old2[0]) {
            std::wstring c2 = P(a.old2);
            if (DirExists(c2)) return c2;
        }
        break;
    }
    return inBots;
}


std::wstring Data() {
    static std::wstring d;
    if (!d.empty()) return d;
    // 新布局：组件在 <工作区>\bots\AstrBot；老布局在 <Base>\astrbot。
    std::wstring ba = BotPath(L"AstrBot");
    std::wstring cands[] = {JoinPath(ba, L"data"), JoinPath(ba, L"core\\data"),
                            JoinPath(Base(), L"astrbot\\data")};
    for (auto& c : cands) {
        if (DirExists(c)) {
            d = c;
            return d;
        }
    }
    // 不是 CLI 安装的话，实例目录一般叫 AstrBot*，找一个带 data 的（老位置和 bots 下都看）
    for (const std::wstring& root : {Base(), BotRoot()}) {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(JoinPath(root, L"AstrBot*").c_str(), &fd);
        if (h == INVALID_HANDLE_VALUE) continue;
        do {
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
            std::wstring cand = JoinPath(JoinPath(root, fd.cFileName), L"core\\data");
            if (!DirExists(cand)) cand = JoinPath(JoinPath(root, fd.cFileName), L"data");
            if (DirExists(cand)) {
                d = cand;
                break;
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
        if (!d.empty()) return d;
    }
    d = cands[2];
    return d;
}

std::wstring Answers(const wchar_t* key, const wchar_t* def) {
    const J* v = AnswersJson().Get(key);
    if (!v) return def;
    if (v->t == J::STR) return v->s;
    if (v->t == J::NUM) return v->NumText();
    if (v->t == J::BOOL) return v->b ? L"1" : L"0";
    return def;
}

int Voice() { return _wtoi(Answers(L"voice", L"0").c_str()); }
int Memory() { return _wtoi(Answers(L"memory", L"0").c_str()); }
int Video() { return _wtoi(Answers(L"video", L"0").c_str()); }

bool IsCli() {
    return FileExists(JoinPath(Base(), L"start-astrbot.cmd")) ||
           FileExists(JoinPath(BotPath(L"AstrBot"), L"start.cmd"));
}

std::wstring Protocol() {
    std::wstring p = Trim(ReadTextFile(SecretFile(L"protocol.txt"), 4096));
    if (!p.empty()) return Lower(p);
    if (FileExists(JoinPath(Base(), L"start-snowluma.cmd"))) return L"snowluma";
    if (FileExists(JoinPath(Base(), L"start-napcat.cmd"))) return L"napcat";
    // bots 布局：启动脚本就在组件目录里，名字是 start.cmd
    std::wstring sl = BotPath(L"SnowLuma"), nc = BotPath(L"NapCat");
    if (FileExists(JoinPath(sl, L"start.cmd")) || FileExists(JoinPath(sl, L"start-snowluma.cmd")))
        return L"snowluma";
    if (FileExists(JoinPath(nc, L"start.cmd")) || FileExists(JoinPath(nc, L"start-napcat.cmd")))
        return L"napcat";
    return L"snowluma";
}

int BackendPort() {
    std::wstring url = Answers(L"base_url", L"http://127.0.0.1:6185");
    size_t c = url.find_last_of(L':');
    if (c == std::wstring::npos) return 6185;
    int p = _wtoi(url.c_str() + c + 1);
    return p > 0 ? p : 6185;
}

// ---------------------------------------------------------------- 文本小工具
std::wstring ReadKv(const std::wstring& path, const std::wstring& key) {
    std::wstring txt = ReadTextFile(path, 65536);
    std::wstring want = Lower(key);
    for (auto& raw : SplitLines(txt)) {
        std::wstring line = Trim(raw);
        if (!line.empty() && line[0] == 0xFEFF) line = Trim(line.substr(1));  // 记事本存的 UTF-8 BOM
        if (line.empty() || line[0] == L'#') continue;
        size_t c = line.find_first_of(L":：");
        if (c == std::wstring::npos) continue;
        std::wstring k = Trim(line.substr(0, c));
        if (Lower(k) == want) return Trim(line.substr(c + 1));
    }
    return L"";
}

std::wstring MaskQQ(const std::wstring& qq) {
    std::wstring t = Trim(qq);
    if (t.size() < 5) return t;
    for (wchar_t c : t)
        if (c < L'0' || c > L'9') return t;
    return t.substr(0, 2) + L"****" + t.substr(t.size() - 2);
}

std::wstring PrettyDur(long long sec) {
    if (sec < 0) sec = 0;
    long long d = sec / 86400, h = (sec % 86400) / 3600, m = (sec % 3600) / 60;
    if (d > 0) return std::to_wstring(d) + L" 天 " + std::to_wstring(h) + L" 小时";
    if (h > 0) return std::to_wstring(h) + L" 小时 " + std::to_wstring(m) + L" 分";
    if (m > 0) return std::to_wstring(m) + L" 分钟";
    return std::to_wstring(sec) + L" 秒";
}

std::wstring NowLocal(const wchar_t* fmt) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    struct tm t {};
    t.tm_year = st.wYear - 1900;
    t.tm_mon = st.wMonth - 1;
    t.tm_mday = st.wDay;
    t.tm_hour = st.wHour;
    t.tm_min = st.wMinute;
    t.tm_sec = st.wSecond;
    wchar_t buf[128];
    if (!wcsftime(buf, 128, fmt, &t)) return std::wstring();
    return buf;
}

long long BootUnix() {
    long long now = (long long)time(nullptr);
    long long up = (long long)(GetTickCount64() / 1000);
    return now - up;
}

// ---------------------------------------------------------------- json 文件
J ReadJson(const std::wstring& path, bool* ok) {
    std::wstring txt = ReadTextFile(path);
    if (!txt.empty() && txt[0] == 0xFEFF) txt = txt.substr(1);  // AstrBot 的 json 常带 BOM
    if (txt.empty()) {
        if (ok) *ok = false;
        return J();
    }
    bool good = false;
    J j = J::Parse(txt, &good);
    if (ok) *ok = good;
    return j;
}

bool WriteJsonAtomic(const std::wstring& path, const J& v) {
    std::wstring tmp = path + L".tmp";
    if (!WriteTextFile(tmp, v.Dump(2))) return false;
    if (MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) return true;
    // 目标被占用（astrbot 正读着）就退一步：直接覆盖
    return WriteTextFile(path, v.Dump(2));
}

J CmdConfig() { return ReadJson(JoinPath(Data(), L"cmd_config.json")); }

bool CmdConfigSave(const J& cfg) { return WriteJsonAtomic(JoinPath(Data(), L"cmd_config.json"), cfg); }

bool WhitelistOn() {
    const J* v = CmdConfig().Path(L"platform_settings.enable_id_white_list");
    return v && v->t == J::BOOL ? v->b : false;
}

// ---------------------------------------------------------------- DeepSeek 余额
static std::wstring DeepSeekKey() {
    std::wstring path = SecretFile(L"deepseek-key.txt");
    std::wstring k = ReadKv(path, L"key");
    if (k.empty()) k = ReadKv(path, L"deepseek_key");
    if (k.empty()) k = ReadKv(path, L"api_key");
    if (!k.empty()) return k;
    for (auto& raw : SplitLines(ReadTextFile(path, 4096))) {
        std::wstring t = Trim(raw);
        if (!t.empty() && t[0] != L'#') return t;
    }
    return L"";
}

Balance DeepSeekBalance(bool force) {
    Balance b;
    std::wstring key = DeepSeekKey();
    if (key.empty()) {
        b.state = L"nokey";
        return b;
    }
    b.has = true;
    std::wstring cachePath = JoinPath(JoinPath(Root(), L"logs"), L"cache.json");
    J cache = ReadJson(cachePath);
    const J* old = cache.Get(L"balance");
    long long now = (long long)time(nullptr);
    if (old && old->t == J::OBJ) {
        b.at = old->Int(L"at");
        b.state = old->Str(L"state", L"net");
        b.amount = old->Num(L"amount");
        b.currency = old->Str(L"currency", L"CNY");
        long long ttl = (b.state == L"ok") ? 600 : 120;
        if (!force && b.at > 0 && now - b.at < ttl) return b;
    }

    Http r = HttpGetJson(L"https://api.deepseek.com/user/balance", key, 8000);
    if (r.code == 200) {
        J j = J::Parse(r.body);
        const J* infos = j.Get(L"balance_infos");
        if (infos && infos->t == J::ARR && !infos->a.empty()) {
            const J& i0 = infos->a[0];
            b.state = L"ok";
            std::wstring amt = i0.Str(L"total_balance");
            if (amt.empty()) amt = i0.Get(L"total_balance") ? i0.Get(L"total_balance")->NumText() : L"0";
            b.amount = _wtof(amt.c_str());
            b.currency = i0.Str(L"currency", L"CNY");
            const J* av = j.Get(L"is_available");
            if (av && av->t == J::BOOL && !av->b) b.state = L"empty";
        } else {
            b.state = L"http";
        }
    } else if (r.code == 401 || r.code == 403) {
        b.state = L"auth";
    } else if (r.code == 0) {
        b.state = L"net";
    } else {
        b.state = L"http";
    }
    b.at = now;

    // 写回缓存：别把 updates 那部分冲掉
    J bal = JObj();
    bal.Set(L"state", JStr(b.state));
    bal.Set(L"amount", JNum(b.amount));
    bal.Set(L"currency", JStr(b.currency));
    bal.Set(L"at", JNum((double)b.at));
    cache.Set(L"balance", bal);
    J day = JObj();
    day.Set(L"date", JStr(NowLocal(L"%Y-%m-%d")));
    day.Set(L"amount", JNum(b.amount));
    day.Set(L"at", JNum((double)b.at));
    cache.Set(L"balance_day", day);
    WriteJsonAtomic(cachePath, cache);
    return b;
}

// ---------------------------------------------------------------- 长期记忆接线
Wiring MemoryWiring() {
    Wiring w;
    std::wstring pluginDir = JoinPath(Data(), L"plugins\\astrbot_plugin_livingmemory");
    w.installed = DirExists(pluginDir);

    // preferences 里 inactivated_plugins 记着被停用的插件
    w.on = w.installed;
    {
        Sqlite db;
        if (db.OpenRead(JoinPath(Data(), L"data_v4.db"))) {
            std::vector<std::vector<std::wstring>> rows;
            if (db.QueryTexts(L"SELECT value FROM preferences WHERE key='inactivated_plugins'", rows) && !rows.empty()) {
                J v = J::Parse(rows[0][0]);
                const J* val = v.Get(L"val");
                const J* arr = val ? val : &v;
                if (arr->t == J::ARR) {
                    for (auto& it : arr->a) {
                        if (it.t != J::STR) continue;
                        if (it.s.find(L"livingmemory") != std::wstring::npos) w.on = false;
                    }
                }
            }
        }
    }

    // 它用哪个 embedding
    J lm = ReadJson(JoinPath(JoinPath(Data(), L"config"), L"astrbot_plugin_livingmemory_config.json"));
    const J* ps = lm.Get(L"provider_settings");
    if (ps) w.provider = ps->Str(L"embedding_provider_id");
    if (w.provider.empty()) w.provider = lm.Str(L"embedding_provider_id", L"ollama_embedding");
    w.model = L"bge-m3";

    J cfg = CmdConfig();
    const J* provs = cfg.Get(L"provider");
    if (provs && provs->t == J::ARR) {
        for (auto& p : provs->a) {
            if (p.Str(L"id") != w.provider) continue;
            w.base = p.Str(L"api_base");
            if (w.base.empty()) w.base = p.Str(L"base_url");
            std::wstring model = p.Str(L"model");
            if (!model.empty()) w.model = model;
            w.key = p.Str(L"api_key");
            std::wstring type = Lower(p.Str(L"type"));
            std::wstring base = Lower(w.base);
            w.ollama = type.find(L"ollama") != std::wstring::npos || base.find(L":11434") != std::wstring::npos;
            w.online = !w.ollama && (base.find(L"127.0.0.1") == std::wstring::npos &&
                                     base.find(L"localhost") == std::wstring::npos);
            break;
        }
    }
    if (w.base.empty()) {
        w.ollama = w.provider.find(L"ollama") != std::wstring::npos;
        if (w.ollama) w.base = L"http://127.0.0.1:11434";
    }
    return w;
}

// ---------------------------------------------------------------- 语音 / 看视频
std::wstring AsrState() {
    std::wstring dir = Answers(L"asr_dir", L"");
    if (dir.empty()) dir = P(L"asr");
    std::wstring model = JoinPath(dir, L"model.int8.onnx");
    bool core = FileExists(JoinPath(dir, L"sherpa-onnx-offline.exe")) && FileExists(model) &&
                FileExists(JoinPath(dir, L"tokens.txt"));
    auto sizeOf = [](const std::wstring& p) -> long long {
        WIN32_FILE_ATTRIBUTE_DATA d{};
        if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &d)) return 0;
        return ((long long)d.nFileSizeHigh << 32) | d.nFileSizeLow;
    };
    if (core && sizeOf(model) > 200LL * 1024 * 1024) {
        bool plus = FileExists(JoinPath(dir, L"funasr-nano\\llm.int8.onnx"));
        return plus ? L"plus" : L"local";
    }
    J vid = ReadJson(JoinPath(JoinPath(Data(), L"config"), L"astrbot_plugin_dafeiyu_video_config.json"));
    if (!vid.Str(L"asr_key").empty()) return L"online";
    if (FileExists(model)) return L"half";
    return L"none";
}

bool LauncherAutostart() {
    HKEY k = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_READ, &k) !=
        ERROR_SUCCESS)
        return false;
    bool has = false;
    if (RegQueryValueExW(k, L"AstrBot Launcher", nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS) has = true;
    RegCloseKey(k);
    if (!has) return false;
    // StartupApproved\Run 的二进制第一位：1 表示启用
    HKEY a = nullptr;
    bool enabled = true;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run", 0, KEY_READ, &a) ==
        ERROR_SUCCESS) {
        BYTE buf[64];
        DWORD len = sizeof(buf), type = 0;
        if (RegQueryValueExW(a, L"AstrBot Launcher", nullptr, &type, buf, &len) == ERROR_SUCCESS && len > 0)
            enabled = (buf[0] & 1) != 0;
        RegCloseKey(a);
    }
    return enabled;
}

// ---------------------------------------------------------------- 表情包
static int CountImages(const std::wstring& dir, int depth = 0) {
    if (depth > 4) return 0;
    int n = 0;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring full = dir + L"\\" + name;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            n += CountImages(full, depth + 1);
            continue;
        }
        std::wstring low = Lower(name);
        if (low.size() > 4) {
            std::wstring ext = low.substr(low.size() - 4);
            std::wstring ext3 = low.size() > 5 ? low.substr(low.size() - 5) : L"";
            if (ext == L".png" || ext == L".jpg" || ext == L".gif" || ext == L".bmp" || ext3 == L".webp")
                n++;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return n;
}

MemeInfo MemeState() {
    MemeInfo m;
    J pack = ReadJson(P(L"dafeiyu-config-pack\\settings\\pack.json"));
    const J* packs = pack.Get(L"meme_packs");
    if (!packs) packs = pack.Get(L"memes");
    if (packs && packs->t == J::ARR) m.expected = (int)packs->a.size();

    J reg = ReadJson(JoinPath(JoinPath(Data(), L"plugin_data\\meme_manager"), L"registry.json"));
    const J* inst = reg.Get(L"installed_packs");
    if (inst && inst->t == J::ARR) {
        for (auto& p : inst->a) {
            if (p.t != J::OBJ) continue;
            if (!p.Bool(L"enabled", true)) continue;
            m.installed++;
            std::wstring id = p.Str(L"id");
            if (!id.empty())
                m.pictures += CountImages(JoinPath(JoinPath(Data(), L"plugin_data\\meme_manager\\packs"), id));
        }
    }
    std::wstring imp = ImportLogState(L"memes");
    if (imp == L"running") m.note = L"正在装新的表情包…";
    else if (!imp.empty()) m.note = imp;
    return m;
}

std::wstring ImportLogState(const wchar_t* block) {
    std::wstring path = JoinPath(JoinPath(Base(), L"logs"), std::wstring(L"import-") + block + L".log");
    if (!FileExists(path)) return L"";
    std::wstring txt = ReadTextFile(path, 400000);
    if (txt.empty()) return L"";
    std::wstring result;
    for (auto& line : SplitLines(txt)) {
        std::wstring t = Trim(line);
        if (!StartsWith(t, L"RESULT")) continue;
        result = t;
    }
    bool running = result.empty();
    if (running) {
        WIN32_FILE_ATTRIBUTE_DATA d{};
        if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &d)) {
            ULARGE_INTEGER u;
            u.HighPart = d.ftLastWriteTime.dwHighDateTime;
            u.LowPart = d.ftLastWriteTime.dwLowDateTime;
            long long at = (long long)(u.QuadPart / 10000000ULL) - 11644473600LL;
            running = (long long)time(nullptr) - at < 180;
        }
    }
    if (running) return L"running";
    // RESULT ok=… reason=… next=…
    std::vector<std::wstring> f;
    std::wstring cur;
    for (wchar_t c : result) {
        if (c == L' ' || c == L'\t') {
            if (!cur.empty()) {
                f.push_back(cur);
                cur.clear();
            }
        } else {
            cur.push_back(c);
        }
    }
    if (!cur.empty()) f.push_back(cur);
    std::wstring state, reason, next;
    for (auto& kv : f) {
        if (StartsWith(kv, L"ok=")) state = kv.substr(3);
        else if (StartsWith(kv, L"reason=")) reason = kv.substr(7);
        else if (StartsWith(kv, L"next=")) next = kv.substr(5);
    }
    if (state == L"ok") return L"上次装好了";
    if (state.empty()) return L"";
    return L"上次没装成" + (reason.empty() ? std::wstring() : (L"（" + reason + L"）"));
}

// ---------------------------------------------------------------- 掉线提醒 / 打游戏
WatchInfo Watch() {
    WatchInfo w;
    w.on = !FileExists(P(L"private\\qq-watch-off.txt"));
    w.can = true;
    long long now = (long long)time(nullptr);
    {   // ① python 老链路（tools\\qq_watch.py）
        J j = ReadJson(P(L"logs\\qq-watch.json"));
        w.at = j.Int(L"at");
        w.state = j.Str(L"state");
        w.note = j.Str(L"note");
        if (w.at > 0 && now - w.at < 600) w.running = true;
    }
    {   // ② 工作台自己的心跳（首选，不需要 python）
        J j = ReadJson(P(L"logs\\workbench-watch.json"));
        long long at = (long long)j.Int(L"at");
        if (at > 0 && now - at < 900) {
            w.running = true;
            w.at = at;
        }
    }
    if (w.on && !w.running) w.note = L"开关开着，但没人在查";
    return w;
}

GameInfo Game() {
    GameInfo g;
    J j = ReadJson(P(L"logs\\game-mode.json"));
    if (!j.Obj()) return g;
    g.on = j.Bool(L"on") && j.Int(L"since") >= BootUnix();
    g.since = j.Int(L"since");
    g.tts = j.Bool(L"tts");
    g.mem = j.Bool(L"mem");
    return g;
}

// ---------------------------------------------------------------- 版本
static std::wstring DistVer(const std::wstring& dir, const std::wstring& prefix) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(JoinPath(dir, prefix + L"*").c_str(), &fd);
    std::wstring found;
    if (h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring n = fd.cFileName;
            if (n.size() <= prefix.size()) continue;
            std::wstring rest = n.substr(prefix.size());
            bool dist = rest.size() > 10 && rest.substr(rest.size() - 10) == L".dist-info";
            if (dist) rest = rest.substr(0, rest.size() - 10);
            while (!rest.empty() && (rest[0] == L'-' || rest[0] == L'_')) rest.erase(0, 1);
            bool hasDigit = false;
            for (wchar_t c : rest)
                if (c >= L'0' && c <= L'9') hasDigit = true;
            // site-packages 里常有同名的包目录（astrbot），要挑带版本号的 dist-info
            if (!dist || !hasDigit) continue;
            found = rest;
            break;
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return found;
}

static std::wstring VerDigits(const std::wstring& s) {
    std::wstring out;
    bool any = false;
    for (size_t i = 0; i < s.size(); i++) {
        wchar_t c = s[i];
        if (c >= L'0' && c <= L'9') {
            out.push_back(c);
            any = true;
        } else if (c == L'.' && any) {
            out.push_back(c);
        } else if (any) {
            break;
        }
    }
    while (!out.empty() && out.back() == L'.') out.pop_back();
    return any ? out : std::wstring();
}

// 在 root 下面有限深度找一个文件名（SnowLuma\release.json、astrbot-*.dist-info 这类）
static std::wstring FindUnder(const std::wstring& root, const std::wstring& name, int depth) {
    if (depth < 0) return std::wstring();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(JoinPath(root, L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return std::wstring();
    std::vector<std::wstring> dirs;
    std::wstring hit;
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L"..") continue;
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            std::wstring sub = JoinPath(root, n);
            // dist-info 是目录，版本藏在里面的 METADATA
            if (Lower(n).find(name) != std::wstring::npos && FileExists(JoinPath(sub, L"METADATA"))) {
                hit = JoinPath(sub, L"METADATA");
                break;
            }
            dirs.push_back(sub);
        }
        else if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && Lower(n).find(name) != std::wstring::npos) {
            hit = JoinPath(root, n);
            break;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (!hit.empty()) return hit;
    for (auto& d : dirs) {
        hit = FindUnder(d, name, depth - 1);
        if (!hit.empty()) return hit;
    }
    return std::wstring();
}

std::vector<std::pair<std::wstring, std::wstring>> Versions() {
    std::vector<std::pair<std::wstring, std::wstring>> v;
    v.push_back({L"工作台", L"2.0"});
    std::wstring astr = DistVer(JoinPath(Base(), L"uv\\tools\\astrbot\\Lib\\site-packages"), L"astrbot");
    if (astr.empty()) {
        std::wstring hit = FindUnder(Base(), L"astrbot-", 5);
        if (!hit.empty()) astr = DistVer(Up(hit), L"astrbot");
    }
    if (!astr.empty()) v.push_back({L"AstrBot", astr});
    J sl = ReadJson(P(L"SnowLuma\\release.json"));
    std::wstring slv = sl.Str(L"version");
    if (slv.empty()) {
        std::wstring hit = FindUnder(Base(), L"release.json", 3);
        if (!hit.empty()) slv = ReadJson(hit).Str(L"version");
    }
    if (!slv.empty()) v.push_back({L"SnowLuma", slv});
    // Breeze：bin 里那个带 -v0.1.3 的目录
    {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW(P(L"breeze-tts\\bin\\*").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                std::wstring n = fd.cFileName;
                size_t vp = n.find(L"-v");
                if (vp == std::wstring::npos) continue;
                std::wstring ver;
                for (size_t i = vp + 2; i < n.size(); i++) {
                    wchar_t c = n[i];
                    if (c >= L'0' && c <= L'9') ver.push_back(c);
                    else if (c == L'.' && !ver.empty()) ver.push_back(c);
                    else break;
                }
                while (!ver.empty() && ver.back() == L'.') ver.pop_back();
                if (!ver.empty()) {
                    v.push_back({L"Breeze", ver});
                    break;
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }
    // Ollama：记忆用本机的时候才显示
    if (Memory() == 1 && Listening(11434)) {
        Http r = HttpGetJson(L"http://127.0.0.1:11434/api/version", L"", 4000);
        if (r.ok) {
            bool ok = false;
            J j = J::Parse(r.body, &ok);
            std::wstring ov = ok ? j.Str(L"version") : L"";
            if (!ov.empty()) v.push_back({L"Ollama", ov});
        }
    }
    return v;
}

}  // namespace her
