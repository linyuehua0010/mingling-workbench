// 冥零工作台 · 维护页要的那些判断（原生版 collect_status）
// 八张卡：大脑、登 QQ、DeepSeek、记忆、语音、看图看视频、开机自启、表情包。
// 全是只读：看端口、看进程、看配置、看数据库、问一下 Ollama。
#include "her.h"

#include <shlobj.h>
#include <time.h>

#include <algorithm>
#include <cstdio>

namespace her {

namespace {

wstring AmtText(double v) {
    wchar_t buf[64];
    swprintf(buf, 64, L"%.2f", v);
    return buf;
}

bool BoolAt(const J& j, const wstring& dot) {
    const J* p = j.Path(dot);
    return p && p->t == J::BOOL && p->b;
}

wstring Lc(wstring s) {
    for (auto& c : s)
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
    return s;
}

bool EndsWithNoCase(const wstring& s, const wstring& tail) {
    if (s.size() < tail.size()) return false;
    return Lc(s.substr(s.size() - tail.size())) == Lc(tail);
}

long long ProcStartUnix(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    FILETIME c, e, k, u;
    long long out = 0;
    if (GetProcessTimes(h, &c, &e, &k, &u)) {
        ULARGE_INTEGER v;
        v.LowPart = c.dwLowDateTime;
        v.HighPart = c.dwHighDateTime;
        out = (long long)(v.QuadPart / 10000000ULL) - 11644473600LL;
    }
    CloseHandle(h);
    return out;
}

long long NowUnix() { return (long long)time(nullptr); }

// 今日统计：消息看 platform_stats（本地时间），回复/token 看 provider_stats（UTC），记忆看 livingmemory.db
Stat g_stat;
DWORD g_statAt = 0;

static wstring WebBase() { return L"http://127.0.0.1:" + std::to_wstring(BackendPort()) + L"/#/"; }

// 本地这一天的零点，换成 UTC 的「YYYY-MM-DD HH:MM:SS」：
// provider_stats.created_at 存的是 UTC，直接拿本地零点去比会多算前一天的
static wstring UtcMidnightText() {
    time_t now = time(nullptr);
    struct tm lt;
    localtime_s(&lt, &now);
    lt.tm_hour = 0;
    lt.tm_min = 0;
    lt.tm_sec = 0;
    time_t mid = mktime(&lt);
    struct tm g;
    gmtime_s(&g, &mid);
    wchar_t buf[32];
    wcsftime(buf, 32, L"%Y-%m-%d %H:%M:%S", &g);
    return buf;
}

static wstring DayKey() {
    time_t now = time(nullptr);
    struct tm lt;
    localtime_s(&lt, &now);
    wchar_t buf[16];
    wcsftime(buf, 16, L"%Y-%m-%d", &lt);
    return buf;
}

// 今日用量问大脑自己：GET /stats/provider-tokens?days=1 → today_total_calls / today_total_tokens
// 注意：GetJson 里的 Unwrap 已经把响应外层的 data 取出来了，这里拿到的就是 data 本身
TokStat ProviderTokens(int days) {
    TokStat t;
    AstrApi api;
    if (!api.Login()) return t;
    J r;
    if (!api.GetJson(L"/stats/provider-tokens?days=" + std::to_wstring(days), r)) return t;
    if (!r.Obj()) return t;
    t.todayCalls = r.Int(L"today_total_calls");
    t.todayTokens = r.Int(L"today_total_tokens");
    t.ok = true;
    return t;
}

bool QueryStat(Stat& st) {
    wstring dd = Data();
    if (dd.empty()) return false;
    Sqlite db;
    if (!db.OpenRead(dd + L"\\data_v4.db")) return false;
    time_t t = time(nullptr);
    struct tm lt;
    localtime_s(&lt, &t);
    wchar_t local0[32];
    wcsftime(local0, 32, L"%Y-%m-%d 00:00:00", &lt);
    wstring utc0 = UtcMidnightText();

    std::vector<long long> v;
    if (db.QueryLongs(L"select coalesce(sum(count),0) from platform_stats where timestamp >= '" + wstring(local0) + L"'", v) &&
        !v.empty())
        st.msgs = v[0];
    // 回复 / token：先问 AstrBot 后台（它按自己的「今日」口径算），问不到再读库兜底
    TokStat ts = ProviderTokens(1);
    if (ts.ok) {
        st.replies = ts.todayCalls;
        st.tokens = ts.todayTokens;
    } else {
        wstring cond = L"agent_type='internal' and status!='error' and created_at >= '" + utc0 + L"'";
        v.clear();
        if (db.QueryLongs(L"select count(*) from provider_stats where " + cond, v) && !v.empty()) st.replies = v[0];
        v.clear();
        if (db.QueryLongs(L"select coalesce(sum(token_input_other+token_input_cached+token_output),0) from provider_stats where " + cond, v) &&
            !v.empty())
            st.tokens = v[0];
    }
    db.Close();
    Sqlite mem;
    if (mem.OpenRead(dd + L"\\plugin_data\\astrbot_plugin_livingmemory\\livingmemory.db")) {
        std::vector<long long> m;
        if (mem.QueryLongs(L"select count(*) from documents", m) && !m.empty()) st.mems = m[0];
        mem.Close();
    }
    st.ok = true;
    return true;
}

// ---- 本机两个服务 ----
bool OllamaJson(const wchar_t* path, J& out) {
    Http r = HttpGet(L"http://127.0.0.1:11434" + wstring(path), 4000);
    if (!r.ok) return false;
    bool pok = false;
    out = J::Parse(r.body, &pok);
    return pok;
}

}  // namespace

wstring OllamaExe() {
    static wstring cache;
    if (!cache.empty()) return cache;
    // 安装包里带的：Ollama\ollama.exe
    // 新布局：<工作区>\bots\Ollama\ollama.exe
    wstring bots = JoinPath(BotPath(L"Ollama"), L"ollama.exe");
    if (FileExists(bots)) return cache = bots;
    wstring local = P(L"Ollama\\ollama.exe");
    if (FileExists(local)) return cache = local;
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n) {
        wstring p = wstring(buf) + L"\\Programs\\Ollama\\ollama.exe";
        if (FileExists(p)) return cache = p;
    }
    return L"";
}

bool LaunchOllama() {
    wstring exe = OllamaExe();
    if (exe.empty()) return false;
    EnvList env;
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        for (const wchar_t* name : {L"OLLAMA_MODELS", L"OLLAMA_KEEP_ALIVE"}) {
            wchar_t v[1024];
            DWORD cb = sizeof(v), type = 0;
            if (RegQueryValueExW(k, name, nullptr, &type, (LPBYTE)v, &cb) == ERROR_SUCCESS && type == REG_SZ)
                env.push_back({name, v});
        }
        RegCloseKey(k);
    }
    LaunchExe(exe, L"serve", BotPath(L"Ollama"), env, true);
    return true;
}

std::vector<wstring> OllamaModels(bool* ok) {
    if (ok) *ok = false;
    J j;
    if (!OllamaJson(L"/api/tags", j)) return {};
    if (ok) *ok = true;
    std::vector<wstring> out;
    const J* ms = j.Get(L"models");
    if (ms && ms->Arr())
        for (const J& m : ms->a) {
            wstring n = m.Str(L"name");
            if (n.empty()) n = m.Str(L"model");
            if (!n.empty()) out.push_back(n);
        }
    return out;
}

std::vector<wstring> StartupNames() {
    std::vector<wstring> out;
    wchar_t dir[MAX_PATH];
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_STARTUP, nullptr, 0, dir))) return out;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((wstring(dir) + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        if (fd.cFileName[0] == L'.') continue;
        out.push_back(fd.cFileName);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return out;
}

Stat TodayStats(bool force) {
    static wstring statDay;
    wstring day = DayKey();
    // 过了零点就作废：不然窗口开着过夜，第二天还挂着昨天的数
    if (!force && g_stat.ok && GetTickCount() - g_statAt < 30000 && statDay == day) return g_stat;
    Stat st;
    if (QueryStat(st)) {
        g_stat = st;
        g_statAt = GetTickCount();
        statDay = day;
    }
    return g_stat;
}

// ---- 三个频率开关（只读配置）----
wstring GroupReplyMode() {
    J cfg = CmdConfig();
    bool m = BoolAt(cfg, L"platform_settings.reply_with_mention");
    bool q = BoolAt(cfg, L"platform_settings.reply_with_quote");
    if (m && q) return L"both";
    if (m) return L"mention";
    if (q) return L"quote";
    return L"off";
}

wstring MemeMode() {
    wstring dd = Data();
    if (dd.empty()) return L"";
    J conf = ReadJson(dd + L"\\config\\meme_manager_config.json");
    const J* v = conf.Path(L"generation.emotion.probability");
    if (!v || v->t != J::NUM) return L"";
    double x = v->num;
    struct { const wchar_t* k; double v; } t[] = {{L"few", 30}, {L"mid", 60}, {L"many", 100}};
    const wchar_t* best = t[0].k;
    double bd = 1e9;
    for (auto& z : t) {
        double d = x > z.v ? x - z.v : z.v - x;
        if (d < bd) bd = d, best = z.k;
    }
    return best;
}

wstring VoiceMode() {
    J cfg = CmdConfig();
    wstring pid = cfg.Path(L"provider_tts_settings.provider_id") ? cfg.Path(L"provider_tts_settings.provider_id")->s : L"";
    if (pid.empty()) return L"";
    const J* p = nullptr;
    const J* arr = cfg.Get(L"provider");
    if (arr && arr->Arr())
        for (const J& x : arr->a)
            if (x.Str(L"id") == pid) {
                p = &x;
                break;
            }
    if (!p) return L"";
    wstring type = p->Str(L"type");
    bool whole = (type == L"seed_audio_tts" && p->Bool(L"seed_audio_whole_reply")) ||
                 (type == L"breeze_online_tts" && p->Bool(L"breeze_online_whole_reply"));
    double v = 0.33;
    if (whole) {
        const J* q = p->Get(type == L"breeze_online_tts" ? L"breeze_online_reply_probability" : L"seed_audio_reply_probability");
        v = (q && q->t == J::NUM) ? q->num : 0.33;
    } else {
        const J* q = cfg.Path(L"provider_tts_settings.trigger_probability");
        v = (q && q->t == J::NUM) ? q->num : 1.0;
    }
    struct { const wchar_t* k; double v; } t[] = {{L"few", 0.15}, {L"mid", 0.33}, {L"many", 0.66}};
    const wchar_t* best = t[0].k;
    double bd = 1e9;
    for (auto& z : t) {
        double d = v > z.v ? v - z.v : z.v - v;
        if (d < bd) bd = d, best = z.k;
    }
    return best;
}

bool CollectStatus(Status& st, wstring* err) {
    st = Status();
    int port = BackendPort();
    wstring proto = Protocol();
    bool cli = IsCli();
    bool up = Listening(port);
    wstring pname = proto == L"napcat" ? L"NapCat" : L"SnowLuma";
    wstring proot = BotPath(proto == L"napcat" ? L"NapCat" : L"SnowLuma");

    // ---- 1 大脑
    {
        Card c;
        c.id = L"brain";
        c.name = L"大脑 · AstrBot";
        std::vector<DWORD> ap = AstrBotPids();
        if (up) {
            c.state = L"ok";
            long long started = ProcStartUnix(ListenPid(port));
            c.text = started ? L"开着，已连续跑了 " + PrettyDur(NowUnix() - started) + L"。"
                             : L"开着，端口 " + std::to_wstring(port) + L" 在听。";
            c.linkLbl = L"打开后台";
            c.linkHref = L"http://127.0.0.1:" + std::to_wstring(port) + L"/#/";
        } else if (!ap.empty()) {
            long long newest = 0;
            for (DWORD pid : ap) newest = std::max(newest, ProcStartUnix(pid));
            if (newest && NowUnix() - newest < 180) {
                c.state = L"busy";
                c.text = L"正在起来，大约半分钟到一分钟。";
            } else {
                c.state = L"bad";
                c.text = L"程序开着，但后台一直没反应（卡住了）。重启一下就好。";
                if (cli) c.fixAct = L"restart_astrbot", c.fixLbl = L"重启大脑";
            }
        } else if (cli) {
            c.state = L"bad";
            c.text = L"没开，她现在回不了话。修复会把它打开，大约半分钟。";
            c.fixAct = L"start_astrbot";
            c.fixLbl = L"一键修复";
        } else {
            c.state = L"bad";
            c.text = L"打开 AstrBot 启动器，点这个实例的「启动」。启动器开着不等于实例开了。";
        }
        st.cards.push_back(c);
    }

    // ---- 2 登 QQ 的程序
    bool online = QqOnline();
    {
        Card c;
        c.id = L"qq";
        c.name = L"登 QQ 的程序 · " + pname;
        wstring bot = MaskQQ(Trim(ReadTextFile(JoinPath(P(L"private"), L"bot-qq.txt"), 65536)));
        wstring oldRoot = P(proto == L"napcat" ? L"NapCat" : L"SnowLuma");
        bool prun = !PidsUnder(Lc(proot)).empty() || !PidsUnder(Lc(oldRoot)).empty() ||
                    Listening(proto == L"napcat" ? 6099 : 5099);   // 进程名可能被包装过（自带 node.exe），端口在听也算起来了
        c.linkLbl = proto == L"napcat" ? L"NapCat 后台" : L"SnowLuma 后台";
        c.linkHref = proto == L"napcat" ? L"http://127.0.0.1:6099/webui" : L"http://127.0.0.1:5099";
        if (online) {
            c.state = L"ok";
            c.text = bot.empty() ? L"小号在线。" : L"小号 " + bot + L" 在线。";
        } else if (st.cards[0].state != L"ok") {
            c.state = L"bad";
            c.text = L"大脑没开，小号也连不上她。先把大脑开起来。";
            c.fixAct = L"relogin";
            c.fixLbl = L"重新登";
        } else if (!prun) {
            c.state = L"bad";
            c.text = pname + L" 没开着，小号连不上她。点「重新登」会把它打开。";
            c.fixAct = L"relogin";
            c.fixLbl = L"重新登";
        } else {
            c.state = L"bad";
            c.text = L"小号没登上。点「重新登」，照弹出来的窗口做。";
            c.fixAct = L"relogin";
            c.fixLbl = L"重新登";
        }
        st.cards.push_back(c);
    }

    // ---- 3 DeepSeek 余额
    {
        Balance b = DeepSeekBalance(false);
        bool wl = WhitelistOn();
        Card c;
        c.id = L"deepseek";
        c.name = L"DeepSeek · 她的饭";
        wstring tip = wl ? L"" : L"白名单没开：谁 @ 她都能用，花的是你的余额。";
        if (!b.has) {
            c.state = L"bad";
            c.text = L"还没填 DeepSeek 的密钥，她回不了话。交给 Agent 填一下。";
        } else if (b.state == L"ok") {
            c.state = b.amount < 2 ? L"warn" : L"ok";
            c.text = L"余额 " + AmtText(b.amount) + L" " + b.currency + L"。" +
                     (b.amount < 2 ? L"快用完了，记得充。" : L"够聊一阵。") + tip;
        } else if (b.state == L"auth") {
            c.state = L"bad";
            c.text = L"DeepSeek 说密钥不对，她回不了话。交给 Agent 换一把。";
        } else if (b.state == L"http" || b.state == L"net") {
            c.state = L"unk";
            c.text = L"查不到余额（网络或 DeepSeek 接口不通）。" + tip;
        } else {
            c.state = L"bad";
            c.text = L"还没填 DeepSeek 的密钥。";
        }
        if (!b.has) {
            c.linkLbl = L"管理密钥";
            c.linkHref = L"https://platform.deepseek.com/api_keys";
        } else if (b.state == L"ok" && b.amount >= 2) {
            c.linkLbl = L"看每天花了多少";
            c.linkHref = L"https://platform.deepseek.com/usage";
        } else {
            c.linkLbl = L"去充值";
            c.linkHref = L"https://platform.deepseek.com/top_up";
        }
        st.cards.push_back(c);
    }

    // ---- 4 记忆
    Stat today = TodayStats(false);
    st.stat = today;
    GameInfo gm = Game();
    Wiring w = MemoryWiring();
    {
        Card c;
        wstring mname = w.ollama ? L"记忆 · 本机 Ollama" : L"记忆";
        c.id = L"memory";
        c.name = mname;
        wstring mcount = today.ok ? L"记住了 " + std::to_wstring(today.mems) + L" 件事。" : L"";
        bool want = Memory() >= 1;
        if (gm.on && gm.mem && !w.on) {
            c.state = L"off";
            c.text = L"打游戏模式：先关着。她照样聊天，只是不记新的事（以前记住的还在）。";
            c.pill = L"打游戏中";
        } else if (!w.installed || !w.on) {
            bool ollamaUp = Listening(11434);
            if (ollamaUp) c.pill = L"Ollama 在跑";
            if (want && w.installed) {
                // 用户明确选了「要记忆」，插件却关着：这才是真要修
                c.state = L"bad";
                c.text = L"选了要记忆，但记忆插件关着（上次多半没接好），她记不住事。交给 Agent 接回去。";
            } else if (want) {
                c.state = L"warn";   // 想要但没装上：留意，不是崩了
                c.text = L"选了要记忆，但记忆插件没装上（Ollama 开着也没用）。交给 Agent 补一下。";
            } else if (ollamaUp) {
                c.state = L"ok";
                c.name = L"记忆 · Ollama 在跑";
                c.pill = L"记忆未开";
                c.text = L"Ollama 在跑，记忆还没开——她记不住新的事（以前记住的还在）。"
                         L"想让她记事，在「维护」页把记忆开关打开。";
            } else {
                c.state = L"off";
                c.text = L"没开。想要的话去「交给 Agent」。";
            }
        } else if (w.provider.empty()) {
            c.state = L"bad";
            c.text = L"记忆插件开着，但没接上记忆模型，她记不住事。交给 Agent 接一下。";
        } else if (w.ollama) {
            wstring mm = w.model.empty() ? L"bge-m3" : w.model;
            size_t cpos = mm.find(L':');
            if (cpos != wstring::npos) mm = mm.substr(0, cpos);
            if (gm.on && !Listening(11434)) {
                c.state = L"off";
                c.text = L"打游戏模式：先关着。她照样聊天，只是不记新的事（以前记住的还在）。";
                c.pill = L"打游戏中";
            } else if (Listening(11434)) {
                bool mok = false;
                std::vector<wstring> models = OllamaModels(&mok);
                bool have = false;
                for (auto& m : models) {
                    wstring base = m;
                    size_t q = base.find(L':');
                    if (q != wstring::npos) base = base.substr(0, q);
                    if (base == mm) have = true;
                }
                if (!mok || have) {
                    c.state = L"ok";
                    c.text = L"开着。" + mcount;
                } else {
                    c.state = L"bad";
                    c.text = L"Ollama 开着，但记忆模型 " + mm + L" 不在，她记不住新的事。交给 Agent 重新下一下。";
                }
            } else {
                bool canfix = !OllamaExe().empty();
                c.state = L"bad";
                c.text = L"Ollama 没开，她记不住新的事（以前记住的还在）。" +
                         wstring(canfix ? L"修复会把它打开。" : L"Ollama 没找到，交给 Agent 装一下。");
                if (canfix) c.fixAct = L"start_ollama", c.fixLbl = L"一键修复";
            }
        } else if (!w.online && w.key.empty()) {
            c.state = L"bad";
            c.text = L"记忆接的是在线服务，但没填密钥，她记不住事。交给 Agent：粘一把密钥，或改成本机记忆。";
        } else {
            c.state = L"ok";
            c.text = L"在线服务，不用开。" + mcount;
        }
        if (w.installed) {
            c.linkLbl = L"看她记住了什么";
            c.linkHref = WebBase() + L"plugin-view/astrbot_plugin_livingmemory/dashboard";
        }
        st.cards.push_back(c);
    }

    // ---- 5 语音
    int vc = Voice();
    {
        Card c;
        c.id = L"voice";
        if (vc == 4) {
            bool breeze = Listening(8137);
            c.name = L"语音 · 本机 Breeze";
            if (gm.on && !breeze) {
                c.state = L"off";
                c.text = L"打游戏模式：先关着，显卡腾给游戏，她现在只打字。";
                c.pill = L"打游戏中";
            } else if (breeze) {
                c.state = L"ok";
                c.text = L"开着，用你的显卡算，不花钱。";
            } else {
                bool canfix = FileExists(JoinPath(BotPath(L"Breeze"), L"start.cmd")) ||
                              FileExists(P(L"breeze-tts\\start-breeze.cmd"));
                c.state = L"bad";
                c.text = L"没在运行，她现在只能打字。" +
                         wstring(canfix ? L"修复会把它重新开起来，大约 20 秒。" : L"找不到 Breeze 的启动文件。");
                if (canfix) c.fixAct = L"start_breeze", c.fixLbl = L"一键修复";
            }
        } else if (vc == 3) {
            c.name = L"语音 · 豆包";
            c.state = L"ok";
            c.text = L"在线服务，不用开。按说话时长扣钱，大约一分钟一块。";
        } else if (vc == 5) {
            c.name = L"语音 · Breeze 在线版";
            c.state = L"ok";
            c.text = L"在线服务，不用在本机开语音程序；按字扣积分。超过 120 字保留文字。";
        } else if (vc == 1) {
            c.name = L"语音 · Edge 免费女声";
            c.state = L"ok";
            c.text = L"在线服务，不用开，不花钱。";
        } else if (vc == 2) {
            c.name = L"语音 · 小米 MiMo";
            c.state = L"ok";
            c.text = L"在线服务，不用开。";
        } else if (Listening(8137)) {
            c.name = L"语音 · Breeze 在跑";
            c.state = L"ok";
            c.pill = L"语音未开";
            c.text = L"Breeze 开着，但语音没启用——她现在只打字。"
                     L"想让她说话，在「维护」页把语音开关打开，或交给 Agent 选个声音。";
        } else {
            c.name = L"语音";
            c.state = L"off";
            c.text = L"没开，她只打字。想要的话去「交给 Agent」。";
        }
        if (vc >= 1) {
            c.linkLbl = L"换模型、语音";
            c.linkHref = WebBase() + L"providers";
        }
        st.cards.push_back(c);
    }

    // ---- 6 看图看视频
    {
        Card c;
        c.id = L"vision";
        c.name = L"看图看视频";
        if (Video() == 1) {
            wstring ff = Answers(L"ffmpeg_path");
            if (ff.empty()) ff = P(L"ffmpeg\\bin\\ffmpeg.exe");
            if (!FileExists(ff)) ff = SidecarFfmpegExe();   // sidecar 里那份也能用
            wstring hear = AsrState();
            if (!FileExists(ff)) {
                c.state = L"bad";
                c.text = L"找不到 ffmpeg，她看不了视频（看图不受影响）。交给 Agent 重新装一下。";
            } else if (hear == L"local" || hear == L"plus") {
                c.state = L"ok";
                c.text = L"能看图、看视频，也听得懂视频里说的话" +
                         wstring(hear == L"plus" ? L"（装了方言、歌词增强版）。" : L"。");
            } else if (hear == L"online") {
                c.state = L"ok";
                c.text = L"能看图、看视频；视频里说的话用在线识别（声音会传给硅基流动）。";
            } else {
                c.state = L"warn";
                c.text = L"能看图、看视频画面，但视频里说的话听不到：" +
                         wstring(hear == L"half" ? L"识别模型只下了一半。" : L"识别模型没装上。") +
                         L"交给 Agent 补装。";
            }
            c.linkLbl = L"截几张、看多长";
            c.linkHref = WebBase() + L"extension?open_config=astrbot_plugin_dafeiyu_video";
        } else {
            c.state = L"ok";
            c.text = L"能看图。看视频没装，想要的话去「交给 Agent」。";
            c.pill = L"能看图";
        }
        st.cards.push_back(c);
    }

    // ---- 7 开机自启
    {
        Card c;
        c.id = L"autostart";
        c.name = L"开机自启";
        std::vector<wstring> lnks = StartupNames();
        auto has = [&](const wstring& n) { return std::find(lnks.begin(), lnks.end(), n) != lnks.end(); };
        std::vector<wstring> miss;
        if (cli && !has(L"大肥鱼-AstrBot.lnk")) miss.push_back(L"大脑");
        if (!has(proto == L"napcat" ? L"大肥鱼-NapCat.lnk" : L"大肥鱼-SnowLuma.lnk")) miss.push_back(pname);
        if ((Memory() == 1 || w.ollama) && !OllamaExe().empty() && !has(L"Ollama.lnk")) miss.push_back(L"Ollama");
        bool breezeLnk = false;
        for (auto& n : lnks)
            if (Lc(n).find(L"breeze") != wstring::npos) breezeLnk = true;
        if (vc == 4 && !breezeLnk) miss.push_back(L"Breeze");
        bool both = has(L"大肥鱼-SnowLuma.lnk") && has(L"大肥鱼-NapCat.lnk");
        wstring lnote = cli ? L"" : L"启动器里要开「开机自启动」「自启动后最小化到托盘」。";
        if (both) {
            c.state = L"warn";
            c.text = L"有重复的登 QQ 启动项，可能抢同一个小号。修复会移走旧入口。";
            c.fixAct = L"autostart_fix";
            c.fixLbl = L"一键修复";
        } else if (!miss.empty()) {
            wstring names;
            for (auto& m : miss) names += (names.empty() ? L"" : L"、") + m;
            c.state = L"warn";
            c.text = L"开机后" + names + L"不会自己起来。点「补上」加进启动项。";
            c.fixAct = L"autostart_fix";
            c.fixLbl = L"补上";
        } else if (!cli) {
            c.state = L"warn";
            c.text = lnote;
        } else {
            c.state = L"ok";
            c.text = L"入口已设。QQ 会隐藏等待网络和大脑，再尝试登录；自动登录失效才打开扫码页。";
        }
        
        st.cards.push_back(c);
    }

    // ---- 8 表情包
    {
        Card c;
        c.id = L"memes";
        c.name = L"表情包";
        MemeInfo mi = MemeState();
        wstring il = ImportLogState(L"memes");
        c.linkLbl = L"看看、上传新的";
        wstring base = L"http://127.0.0.1:" + std::to_wstring(port);
        c.linkHref = base + L"/#/plugin-view/meme_manager/app";
        if (il == L"running") {
            c.state = L"busy";
            c.text = L"正在补装表情包…… 她照常聊天。";
        } else if (mi.installed == 0) {
            c.state = L"warn";
            wstring t = L"还没装上，她先不配图。补装要从 GitHub 下几百 MB，放后台下。";
            if (!il.empty()) t = L"还没装上（上次补装：" + il + L"）。可以再试一次，放后台下。";
            c.text = t;
            c.fixAct = L"import";
            c.fixLbl = L"补装表情包";
        } else if (mi.expected > mi.installed) {
            c.state = L"warn";
            c.text = L"装了 " + std::to_wstring(mi.installed) + L" 套（" + std::to_wstring(mi.pictures) +
                     L" 张），还差 " + std::to_wstring(mi.expected - mi.installed) + L" 套。可以补装，放后台下。";
            c.fixAct = L"import";
            c.fixLbl = L"补装表情包";
        } else {
            c.state = L"ok";
            c.text = L"装了 " + std::to_wstring(mi.installed) + L" 套，共 " + std::to_wstring(mi.pictures) + L" 张。";
        }
        st.cards.push_back(c);
    }

    st.group = GroupReplyMode();
    st.meme = MemeMode();
    st.voice = VoiceMode();
    st.gameOn = gm.on;
    st.gameSince = gm.since;
    // 打游戏模式 = 把本机占显卡/内存的语音、记忆先放下。只要本机真有服务在跑就该能点
    st.gameCan = vc == 4 || Memory() == 1 || Listening(8137) || Listening(11434);
    st.watch = Watch();
    st.vers = Versions();
    if (!st.group.empty()) st.note = L"刚查过 · " + NowLocal(L"%H:%M");
    if (err) err->clear();
    return true;
}

}  // namespace her
