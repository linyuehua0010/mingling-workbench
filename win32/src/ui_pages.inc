// 冥零工作台 · 页面 / 事件 / 后台任务（被 ui.cpp 文本包含）
// 这里直接用 ui.cpp 里的静态状态和绘制助手。

// ---------------------------------------------------------------- 动作声明
static void StartService(int idx);
static void StopService(int idx);
// 掉线提醒的本地心跳（定义在 ui_watch.inc，本文件先用）
static void StartWatchdog();
static void StopWatchdog();
static void MuteWatchdogFor(int seconds);
static void WatchdogWake();
static bool NotifyArmed();
static int NotifyEverySeconds();
// 掉线提醒的横幅 / 点击 / 收尾（定义在 ui_watch.inc）
static void PaintNotifyBanner(Graphics& g);
static void TickNotifyBanner();
static bool UiNotifyClick(const std::string& id);
static void WatchTest();
static void FreeNotifyState();
static void RefreshFeed();
static void StartWatch();
static void RunCheck(int action);
static void OpenPath(const wstring& p);
static void CopyText(const wstring& s);
static void LoadJobs();
static void LoadJobDetail(int idx);
static void RefreshLogsNow();
static void PostTask(TaskData* d) { PostMessageW(g_hwnd, WM_APP_JOB, 0, (LPARAM)d); }
// B 站输入框（自绘的，没有原生 EDIT 的剪贴板能力，得自己接）
static const size_t kInputMax = 600;
static bool g_inputSelAll = false;     // Ctrl+A：再打字/粘贴就整体替换
static bool g_linkMode = false;        // 上一次「让她看」读的是网页还是 B 站
static RectF g_rcInput;                // 输入框当前占的屏幕位置（右键菜单用）
static wstring ClipboardText();
static void InputPaste();
static void InputCopy();
static void InputCut();
static void InputSelectAll();
// B 站页分区：0 选题 / 1 看片与读链接 / 2 结果 / 3 配置（配置里再分 bili-whale 与链接与应用）
static int g_bSec = 1;
static int g_bCfgSub = 0;
// bili-whale 配置（实现在 ui_bili_cfg.inc；进配置分区时装载）
static bool g_bcfgOpen = false;
static void BiliCfgOpen();
static void BiliCfgClose(bool save);
static void BiliCfgEndEdit(bool apply);
static bool BiliCfgClick(const std::string& id);
static bool BiliCfgWheel(int delta);
static void PaintBiliCfg(Graphics& g, const RectF& area);
// 「链接与应用」面板（读链接的设置 + 对话 API，实现在 ui_link_cfg.inc）
static bool g_lcOpen = false;
static void LinkCfgOpen();
static void LinkCfgClosePanel();
static bool LinkCfgClick(const std::string& id);
static bool LinkCfgWheel(int delta);
static void PaintLinkCfg(Graphics& g, const RectF& area);
// 「问一句」面板（对话 API，实现在 ui_dsh.inc；嵌在结果分区右边）
static bool g_dshOpen = false;
static void DshAsk();
static void DshClose();
static bool DshClick(const std::string& id);
static bool DshWheel(int delta);
static void PaintDshAsk(Graphics& g, const RectF& area);

// ---------------------------------------------------------------- 看视频的进度
// debrief 一边跑一边把 ①..⑥ 的分节标题打出来，这里认标题算进度，别的行不管。
static std::mutex g_progMx;
static int g_progPct = 0;
static wstring g_progStage;

static int StageFromLine(const wstring& line, wstring& stage) {
    if (line.find(L"══") == wstring::npos) return -1;
    struct Mark { wchar_t ch; int pct; const wchar_t* say; };
    static const Mark M[] = {
        {0x2460, 6, L"元信息"},    {0x2461, 12, L"封面"},
        {0x2462, 20, L"官方字幕"}, {0x2463, 34, L"弹幕热区"},
        {0x2464, 48, L"热评"},     {0x2465, 68, L"画面和九宫格"},
    };
    for (const Mark& m : M) {
        if (line.find(m.ch) != wstring::npos) {
            stage = wstring(L"正在弄「") + m.say + L"」";
            return m.pct;
        }
    }
    return -1;
}

static void WatchOnLine(const wstring& line, void*) {
    wstring st;
    int pct = StageFromLine(line, st);
    if (pct < 0) return;
    {
        std::lock_guard<std::mutex> lk(g_progMx);
        if (pct <= g_progPct) return;
        g_progPct = pct;
        g_progStage = st;
    }
    if (g_hwnd) PostMessageW(g_hwnd, WM_APP_PROGRESS, 0, 0);
}

// UI 线程：把后台攒下的进度搬到界面上
void UiOnProgress() {
    int pct;
    wstring st;
    {
        std::lock_guard<std::mutex> lk(g_progMx);
        pct = g_progPct;
        st = g_progStage;
    }
    if (!g_watchBusy) return;
    if (pct > g_watchPct) g_watchPct = pct;   // 只涨不落：时间爬升可能已经超过分节
    g_watchStage = st;
    long long el = NowUnix() - g_watchT0;
    if (el < 0) el = 0;
    g_watchStatus = L"正在看 " + g_watchBv + L" · " + (st.empty() ? wstring(L"起手") : st) + L" · " + Num(el) + L"s";
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 小工具
static vector<std::string> SplitId(const std::string& s, char sep) {
    vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == sep) {
            out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    out.push_back(cur);
    return out;
}

static wstring Hhmm(long long t) {
    time_t tt = (time_t)t;
    tm local{};
    localtime_s(&local, &tt);
    wchar_t b[16];
    swprintf(b, 16, L"%02d:%02d", local.tm_hour, local.tm_min);
    return b;
}

static int CountToday() {
    long long since = NowUnix() - 24 * 3600;
    int n = 0;
    for (auto& j : g_jobs)
        if (j.t >= since) n++;
    return n;
}

static void OpenPath(const wstring& p) {
    ShellExecuteW(nullptr, L"open", p.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

static void CopyText(const wstring& s) {
    if (!OpenClipboard(g_hwnd)) return;
    EmptyClipboard();
    size_t bytes = (s.size() + 1) * sizeof(wchar_t);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (h) {
        void* dst = GlobalLock(h);
        memcpy(dst, s.c_str(), bytes);
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h);
    }
    CloseClipboard();
    UiToast(L"已复制");
}

// ---------------------------------------------------------------- 输入框的剪贴板
// 自绘输入框没有原生 EDIT 的那套键盘处理，Ctrl+V/C/X/A、Shift+Insert 和右键菜单
// 都得自己接上。读剪贴板一律 CF_UNICODETEXT：BV 号、完整 URL、QQ/微信的分享文本
// 都是纯文本，不需要别的格式。
static wstring ClipboardText() {
    wstring out;
    if (!OpenClipboard(g_hwnd)) return out;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t* p = (const wchar_t*)GlobalLock(h);
        if (p) {
            out = p;
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    // 单行化：分享文本常带换行，压成空格；首尾空白剪掉，粘进来就能直接识别
    for (wchar_t& c : out) {
        if (c == L'\r' || c == L'\n' || c == L'\t' || c == 0x2028 || c == 0x2029) c = L' ';
    }
    return Trim(out);
}

static void InputPaste() {
    wstring t = ClipboardText();
    if (t.empty()) {
        UiToast(L"剪贴板里没有文字");
        return;
    }
    if (g_inputSelAll) {
        g_bvInput.clear();
        g_inputSelAll = false;
    }
    size_t room = g_bvInput.size() < kInputMax ? kInputMax - g_bvInput.size() : 0;
    if (room == 0) {
        UiToast(L"输入框满了，先删一点");
        return;
    }
    if (t.size() > room) {
        t.resize(room);
        UiToast(L"太长了，只取了前面一段");
    }
    g_bvInput += t;
    g_editFocus = 1;
    UiRequestRepaint();
}

static void InputCopy() {
    if (g_bvInput.empty()) return;
    CopyText(g_bvInput);
}

static void InputCut() {
    if (g_bvInput.empty()) return;
    CopyText(g_bvInput);
    g_bvInput.clear();
    g_inputSelAll = false;
    UiRequestRepaint();
}

static void InputSelectAll() {
    g_inputSelAll = true;
    g_editFocus = 1;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 服务 / 任务
// 组件目录：新布局在 <工作区>\bots\<名字> 下，老机器散在 <Base>\<名字> 下。
// 页面上所有「找组件」的地方都走这里，别再各自拼 BaseDir()——拼错那一年就是这么来的。
static wstring CompDir(const wchar_t* name) {
    wstring n = BotDir(name);
    if (DirExists(n)) return n;
    wstring o = JoinPath(BaseDir(), name);
    if (DirExists(o)) return o;
    return n;
}

static wstring LogPath(int i) {
    if (i == 0) return JoinPath(CompDir(L"SnowLuma"), L"snowluma-run.log");
    return JoinPath(CompDir(L"AstrBot"), L"run.log");
}

// 看日志时读哪个：规范位置没有就退回老位置（老机器升级上来的日志还在 <Base> 下）
static wstring ReadLogPath(int i) {
    wstring p = LogPath(i);
    if (FileExists(p)) return p;
    const wchar_t* file = i == 0 ? L"snowluma-run.log" : L"run.log";
    wstring legacy = JoinPath(JoinPath(BaseDir(), i == 0 ? L"SnowLuma" : L"AstrBot"), file);
    if (FileExists(legacy)) return legacy;
    return p;
}

// B站那条标签背后是 bili-whale 命令行工具（现在一条消息一个子进程，没有常驻服务）。
// 老版本留过 logs\bili-service.log，有就拿来给用户看一眼——真看到内容总比一句空话强。
static wstring BiliLogPath() {
    wstring d = JoinPath(RootDir(), L"logs");
    const wchar_t* names[] = {L"bili-whale.log", L"bili-service.log"};
    for (const wchar_t* n : names) {
        wstring p = JoinPath(d, n);
        if (FileExists(p)) return p;
    }
    return JoinPath(d, L"bili-whale.log");
}

// 文件最后写进去是多少秒前；读不到返回 -1
static long long SecondsSinceWrite(const wstring& p) {
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &fad)) return -1;
    ULARGE_INTEGER w, n;
    w.LowPart = fad.ftLastWriteTime.dwLowDateTime;
    w.HighPart = fad.ftLastWriteTime.dwHighDateTime;
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    n.LowPart = now.dwLowDateTime;
    n.HighPart = now.dwHighDateTime;
    if (n.QuadPart <= w.QuadPart) return 0;
    return (long long)((n.QuadPart - w.QuadPart) / 10000000ULL);
}

static void StartService(int idx) {
    if (idx < 0 || idx > 1) return;
    if (g_svcUp[idx]) {
        UiToast(L"已经在跑了");
        return;
    }
    std::thread([idx]() {
        TaskData* d = new TaskData();
        d->kind = TK_START;
        d->action = idx;
        if (idx == 1) {
            // AstrBot 的启动器可能在不同布局里：uv 工具目录用 bin，venv 用 Scripts，
            // 也接受用户把 astrbot.exe 放进 PATH。挨个找，找不到就把提示写清楚。
            wstring exe;
            const wchar_t* cand[] = {L"uv\\bin\\astrbot.exe", L"uv\\tools\\astrbot\\Scripts\\astrbot.exe",
                                     L"uv\\Scripts\\astrbot.exe", L"astrbot\\astrbot.exe"};
            for (const wchar_t* rel : cand) {
                wstring p = JoinPath(BotRoot(), rel);
                if (FileExists(p)) { exe = p; break; }
            }
            for (const wchar_t* rel : cand) {
                if (!exe.empty()) break;
                wstring p = JoinPath(BaseDir(), rel);
                if (FileExists(p)) exe = p;
            }
            if (exe.empty()) {
                wchar_t found[MAX_PATH] = {0};
                if (SearchPathW(nullptr, L"astrbot.exe", nullptr, MAX_PATH, found, nullptr)) exe = found;
            }
            wchar_t pathBuf[8192] = {0};
            GetEnvironmentVariableW(L"PATH", pathBuf, 8192);
            EnvList env;
            env.emplace_back(L"PATH", JoinPath(CompDir(L"ffmpeg"), L"bin") + L";" + pathBuf);
            env.emplace_back(L"PYTHONUTF8", L"1");
            DWORD pid = 0;
            if (!exe.empty()) pid = SpawnDetached(exe, L"run", CompDir(L"AstrBot"), env, LogPath(1));
            d->ok = pid != 0;
            d->text = pid ? L"AstrBot 启动了（pid " + Num(pid) + L"）"
                          : L"没找到 AstrBot：请把 AstrBot 放到 " + JoinPath(BotRoot(), L"uv\\bin") +
                            L" 或用 PATH 里的 astrbot.exe；日志见 " + LogPath(1);
        } else {
            wstring cwd = CompDir(L"SnowLuma");
            wstring exe = JoinPath(cwd, L"node.exe");
            EnvList env;
            env.emplace_back(L"SNOWLUMA_HOOK_AUTOLOAD", L"1");
            env.emplace_back(L"SNOWLUMA_ACCEPT_EULA", L"1");
            env.emplace_back(L"SNOWLUMA_ACCEPT_PRIVACY", L"1");
            wstring pwFile = SecretFile(L"snowluma-webui.txt");
            wstring pw = Trim(ReadTextFile(pwFile));
            if (!pw.empty()) env.emplace_back(L"SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD", pw);
            DWORD pid = SpawnDetached(exe, L"index.mjs", cwd, env, LogPath(0));
            d->ok = pid != 0;
            d->text = pid ? L"SnowLuma 启动了（pid " + Num(pid) + L"）" : L"SnowLuma 起不来，看看 " + LogPath(0);
        }
        PostTask(d);
    }).detach();
    UiToast(L"正在启动…");
}

static void StopService(int idx) {
    if (idx < 0 || idx > 1) return;
    int port = idx == 0 ? 5099 : 6199;
    DWORD pid = g_svcPid[idx] ? g_svcPid[idx] : PidOnPort(port);
    if (!pid) {
        UiToast(L"它本来就没开");
        return;
    }
    MuteWatchdogFor(600);   // 用户自己关掉的不算掉线，10 分钟内不报
    std::thread([idx, pid]() {
        KillPid(pid);
        TaskData* d = new TaskData();
        d->kind = TK_STOP;
        d->action = idx;
        d->ok = true;
        d->text = (idx == 0 ? wstring(L"SnowLuma") : wstring(L"AstrBot")) + L" 已关";
        PostTask(d);
    }).detach();
}

static void RefreshFeed() {
    if (g_feedBusy) return;
    g_feedBusy = true;
    g_feedNote = L"正在捞选题…";
    std::thread([]() {
        TaskData* d = new TaskData();
        d->kind = TK_FEED;
        CmdResult r = RunWhale(L"feed --n 8", 180000);
        d->feed = ParseFeed(r.out);
        d->ok = !d->feed.empty();
        d->text = r.out;
        if (!d->ok) d->title = Trim(r.out.size() > 300 ? r.out.substr(0, 300) : r.out);
        PostTask(d);
    }).detach();
}

// 只看域名，够用了：状态行和台账里写这个比写整条长 URL 好读
static wstring UrlHost(const wstring& url) {
    wstring u = url;
    size_t p = u.find(L"://");
    if (p != wstring::npos) u = u.substr(p + 3);
    size_t e = u.find_first_of(L"/?#");
    if (e != wstring::npos) u = u.substr(0, e);
    return u;
}

// 把一次网页读取的结果拼成结果区能画的文本（DrawRich 认 ══════ 标题行）。
// 标题 / 来源 / 耗时 / 摘要四样都在头部，复制出去也能直接看懂。
static wstring LinkReport(const wstring& url, const wstring& title, const WebPage& p, const wstring& secs) {
    wstring s;
    s += L"══════════ 读到的链接 ══════════\n";
    s += L"标题: " + title + L"\n";
    s += L"来源: " + UrlHost(p.url.empty() ? url : p.url) + L"\n";
    s += L"地址: " + (p.url.empty() ? url : p.url) + L"\n";
    if (!secs.empty()) s += L"耗时: " + secs + L"\n";
    if (p.code > 0) s += L"状态: HTTP " + Num(p.code) + L" · 读到 " + PrettyBytes(p.bytes) + L"\n";
    if (!p.note.empty()) s += L"注意: " + p.note + L"\n";
    if (p.ok) {
        if (!p.desc.empty()) s += L"\n══════════ 摘要 ══════════\n" + p.desc + L"\n";
        s += L"\n══════════ 正文摘要 ══════════\n";
        s += p.text;
    } else {
        s += L"\n══════════ 没读成 ══════════\n";
        s += L"  " + (p.err.empty() ? wstring(L"原因不明") : p.err) + L"\n";
        s += L"\n只做了这一件事：一次 GET。不跑脚本、不登录、不绕风控，读不到就是读不到。\n";
    }
    return s;
}

static void StartWatch() {
    if (g_watchBusy) return;

    // 先判断用户到底粘了什么：B 站、别的网页、分享文本、还是本地快捷方式
    InputAction act = ClassifyInput(g_bvInput);
    if (act.kind == IN_EMPTY && g_feedSel >= 0 && g_feedSel < (int)g_feed.size()) {
        act.kind = IN_BILI;
        act.bv = g_feed[g_feedSel].bv;
    }
    if (act.kind == IN_EMPTY) {
        UiToast(L"先粘个链接，或者点左边一条选题");
        return;
    }
    if (act.kind == IN_PATH) {
        OpenPath(act.path);
        UiToast(L"帮你打开了（只打开，不读里面的内容）");
        return;
    }
    if (act.kind == IN_UNKNOWN) {
        UiToast(L"看不出这是什么：B 站链接/BV、网页链接、分享文本都行");
        return;
    }
    if (act.kind == IN_SHARE) UiToast(L"从分享文本里认出链接了，这就去读");

    const bool isLink = (act.kind == IN_URL || act.kind == IN_SHARE);
    g_linkMode = isLink;
    wstring bv = act.bv;
    wstring url = act.url;
    if (act.kind == IN_BILI && bv.empty()) bv = ExtractBv(url);
    wstring hint;
    for (auto& f : g_feed)
        if (!bv.empty() && f.bv == bv) hint = f.title;

    g_watchBusy = true;
    g_watchBv = isLink ? url : bv;
    g_watchT0 = NowUnix();
    g_watchPct = isLink ? 10 : 6;
    g_watchStage.clear();
    {
        std::lock_guard<std::mutex> lk(g_progMx);
        g_progPct = 0;
        g_progStage.clear();
    }
    g_watchStatus = isLink ? (L"正在读 " + url) : (L"正在看 " + bv + L" · 起手 · 0s");
    g_hasResult = false;
    g_watchScroll = 0;

    if (isLink) {
        LinkCfg lc = LinkLoad();
        if (!lc.enabled) {
            UiToast(L"读链接是关着的：B 站页 → 配置 → 链接与应用 → 打开「读取网页链接」");
            return;
        }
        // 一次 GET，超时和大小上限都按「链接与应用」里的设置走（上限本身不可放宽）。
        const int ms = lc.timeoutSec * 1000;
        const size_t cap = (size_t)lc.maxKB * 1024;
        const wstring ua = lc.ua;
        std::thread([url, ms, cap, ua]() {
            TaskData* d = new TaskData();
            d->kind = TK_WATCH;
            d->type = L"link";
            long long t0 = NowUnix();
            WebPage p = FetchWebPage(url, ms, cap, ua);
            long long secs = NowUnix() - t0;
            d->bv = url;
            d->up = UrlHost(p.url.empty() ? url : p.url);
            d->ok = p.ok;
            d->title = p.ok ? p.title : L"没读到";
            d->text = LinkReport(url, p.ok ? p.title : wstring(L"（没读到）"), p, Num(secs) + L"s");
            d->seconds = Num(secs) + L"s";
            PostTask(d);
        }).detach();
        UiRequestRepaint();
        return;
    }

    // B 站：原链路，一个字节都不改（短链缺 BV 时先在后台跟一次重定向）
    g_watchStatus = bv.empty() ? (L"正在跟短链 " + url) : (L"正在看 " + bv + L" · 起手 · 0s");
    std::thread([bv, url, hint]() {
        TaskData* d = new TaskData();
        d->kind = TK_WATCH;
        wstring id = bv;
        long long t0 = NowUnix();
        if (id.empty() && !url.empty()) {
            // b23.tv 这类短链里没有 BV，跟一次重定向，从落地地址里找
            WebPage p = FetchWebPage(url, 8000, 64 * 1024);
            id = ExtractBv(p.url);
            if (id.empty()) id = ExtractBv(p.text);
            if (id.empty()) {
                d->ok = false;
                d->bv = url;
                d->title = L"短链里没找到 BV";
                d->text = L"跟过去也没找到 BV 号。\n从浏览器地址栏里把 BV 开头的那一段复制过来就行。\n\n（" +
                          (p.err.empty() ? wstring(L"落地地址是 ") + p.url : p.err) + L"）";
                d->seconds = Num((long long)(NowUnix() - t0)) + L"s";
                PostTask(d);
                return;
            }
        }
        d->bv = id;
        WhaleEnv we = FindWhale();
        CmdResult r;
        if (!we.ok) {
            r.out = L"没找到 bili-whale：" + we.err;
        } else {
            EnvList env;
            env.emplace_back(L"BILI_ROOT", RootDir());
            env.emplace_back(L"BILI_OUT_ROOT", JoinPath(RootDir(), L"out"));
            env.emplace_back(L"BILI_TMP_ROOT", JoinPath(RootDir(), L"tmp"));
            env.emplace_back(L"BILI_LOGS_ROOT", JoinPath(RootDir(), L"logs"));
            env.emplace_back(L"BILI_WHALE_CONFIG", we.config);
            r = RunCaptureStream(we.node, L"\"" + we.mjs + L"\" debrief " + id + L" --grid " + BiliGridSetting(),
                                 RootDir(), env, (DWORD)BiliTimeoutSec() * 1000, WatchOnLine, nullptr);
        }
        d->debrief = ParseDebrief(r.out);
        d->text = r.out;
        d->ok = d->debrief.ok;
        d->title = d->debrief.title.empty() ? hint : d->debrief.title;
        d->up = d->debrief.up;
        d->seconds = Num((long long)(NowUnix() - t0)) + L"s";
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

static void RunCheck(int action) {
    if (g_checkBusy) return;
    static const wchar_t* CMD[] = {L"session", L"deps", L"quota status", L"traffic status", L"selftest"};
    static const wchar_t* NAME[] = {L"会话", L"依赖", L"限额", L"风控", L"自检"};
    if (action < 0 || action > 4) return;
    g_checkBusy = true;
    g_checkAction = action;
    g_checkText = wstring(L"正在跑 ") + NAME[action] + L" …";
    g_checkScroll = 0;
    std::thread([action]() {
        TaskData* d = new TaskData();
        d->kind = TK_CHECK;
        d->action = action;
        CmdResult r = RunWhale(CMD[action], 180000);
        d->text = wstring(L"» bili-whale ") + CMD[action] + L"   （退出码 " + Num(r.code) + L"）\n\n" + r.out;
        d->ok = r.code == 0;
        PostTask(d);
    }).detach();
}

static void LoadJobs() {
    g_jobs = ReadJobs(120);
    if (g_jobSel >= (int)g_jobs.size()) g_jobSel = (int)g_jobs.size() - 1;
    // 一进队列就把最新那条摊开，省得用户先点一下
    if (g_jobSel < 0 && !g_jobs.empty()) {
        g_jobSel = 0;
        LoadJobDetail(0);
    }
}

static void LoadJobDetail(int idx) {
    g_jobDetail.clear();
    g_jobDetailScroll = 0;
    if (idx < 0 || idx >= (int)g_jobs.size()) return;
    JobRec& j = g_jobs[idx];
    wstring head = j.title + L"\n" + j.bv;
    if (!j.up.empty()) head += L"   @" + j.up;
    head += L"\n" + j.source + L"  ·  " + j.status + L"  ·  " + j.seconds + L"\n\n";
    wstring body;
    if (!j.sink.empty() && FileExists(j.sink)) body = ReadTextFile(j.sink, 400000);
    else body = L"（这次任务没留下正文：可能是失败，或者输出已经清理）";
    g_jobDetail = head + body;
}

static void RefreshLogsNow() {
    // 标签顺序是 B站 / AstrBot / SnowLuma，而 LogPath(0)=SnowLuma、LogPath(1)=AstrBot。
    if (g_logSrc == 0) {
        wstring p = BiliLogPath();
        if (!FileExists(p)) {
            // bili-whale 没有常驻服务：拿最近一次任务的输出
            g_logText = L"bili-whale 是命令行工具，没有常驻日志；最近一次任务见「队列」。";
            g_logStamp = GetTickCount();
            return;
        }
        g_logText = TailFile(p, 240, 260000);
        if (g_logText.empty()) g_logText = L"（" + p + L" 还是空的：它还没写过东西）";
        else if (p.size() > 16 && p.substr(p.size() - 16) == L"bili-service.log") {
            long long age = SecondsSinceWrite(p);
            if (age >= 86400)
                g_logText = L"（这是旧版服务留下的 logs\\bili-service.log，已经 " + Num((int)(age / 86400)) +
                            L" 天没动过；bili-whale 现在一条消息一个子进程，不写常驻日志。下面只是历史内容）\n\n" +
                            g_logText;
        }
    } else {
        wstring p = ReadLogPath(g_logSrc == 1 ? 1 : 0);
        g_logText = TailFile(p, 240, 260000);
        if (g_logText.empty())
            g_logText = FileExists(p) ? L"（" + p + L" 还是空的：服务刚起来，或者还没写过东西）"
                                      : L"（日志是空的：服务可能还没启动过。找不到 " + p + L"）";
    }
    g_logStamp = GetTickCount();
}

// ---------------------------------------------------------------- 侧栏
static void TabIcon(Graphics& g, float x, float y, int idx, ARGB c) {
    SolidBrush b(Cc(c));
    Pen p(Cc(c), S(1.3f));
    float u = S(6), s2 = S(13);
    switch (idx) {
        case 0:
            g.FillRectangle(&b, x, y, u, u);
            g.FillRectangle(&b, x + u + S(2), y, u, u);
            g.FillRectangle(&b, x, y + u + S(2), u, u);
            g.FillRectangle(&b, x + u + S(2), y + u + S(2), u, u);
            break;
        case 1: {
            PointF pts[3] = {{x + S(1), y}, {x + s2, y + s2 * 0.5f}, {x + S(1), y + s2}};
            g.FillPolygon(&b, pts, 3);
            break;
        }
        case 2:
            for (int i = 0; i < 3; i++) g.FillRectangle(&b, x, y + i * S(5), s2 - (i == 2 ? S(4) : 0), S(1.6f));
            break;
        case 3:
            g.DrawRectangle(&p, x, y, s2 - S(2), s2 - S(1));
            for (int i = 0; i < 3; i++) g.DrawLine(&p, x + S(2.5f), y + S(3.5f) + i * S(3), x + s2 - S(4.5f), y + S(3.5f) + i * S(3));
            break;
        case 4:
            g.DrawEllipse(&p, x, y, s2 - S(1), s2 - S(1));
            g.DrawLine(&p, x + S(3), y + S(6.5f), x + S(5.5f), y + S(9));
            g.DrawLine(&p, x + S(5.5f), y + S(9), x + s2 - S(3.4f), y + S(3.4f));
            break;
        case 5: {   // 维护：三条滑块
            float yy[3] = {y + S(1.5f), y + S(6), y + S(10.5f)};
            float kx[3] = {x + S(8), x + S(4), x + S(9.5f)};
            for (int i = 0; i < 3; i++) {
                g.DrawLine(&p, x, yy[i], x + s2, yy[i]);
                g.FillRectangle(&b, kx[i] - S(1.5f), yy[i] - S(1.8f), S(3), S(3.6f));
            }
            break;
        }
        case 6: {   // 帮助中心：一本书
            g.DrawRectangle(&p, x + S(1), y + S(1), s2 - S(3), s2 - S(2));
            for (int i = 0; i < 3; i++) g.DrawLine(&p, x + S(3), y + S(4) + i * S(3), x + s2 - S(4), y + S(4) + i * S(3));
            break;
        }
        case 8: {   // 问号
            g.DrawEllipse(&p, x + S(1), y, s2 - S(3), s2 - S(4));
            g.DrawLine(&p, x + S(4), y + S(7.6f), x + S(5.2f), y + S(9.4f));
            g.DrawLine(&p, x + S(5.2f), y + S(9.4f), x + S(7), y + S(9.4f));
            g.DrawLine(&p, x + S(7), y + S(9.4f), x + S(7.4f), y + S(11.4f));
            g.FillRectangle(&b, x + S(6.3f), y + S(12.6f), S(2.2f), S(2.2f));
            break;
        }
        case 9: {   // 书
            g.DrawRectangle(&p, x + S(1), y + S(1), s2 - S(3), s2 - S(2));
            for (int i = 0; i < 3; i++) g.DrawLine(&p, x + S(3), y + S(4) + i * S(3), x + s2 - S(4), y + S(4) + i * S(3));
            break;
        }
        default: {
            float yy[3] = {y + S(1.5f), y + S(6), y + S(10.5f)};
            float kx[3] = {x + S(8), x + S(4), x + S(9.5f)};
            for (int i = 0; i < 3; i++) {
                g.DrawLine(&p, x, yy[i], x + s2, yy[i]);
                g.FillRectangle(&b, kx[i] - S(1.5f), yy[i] - S(1.8f), S(3), S(3.6f));
            }
            break;
        }
    }
}

// 更新页在 include 的后半段，这里先声明两个入口：侧栏角标要用
static void UpMaybeRefresh();
static int UpBadgeCount();

static void PaintSidebar(Graphics& g) {
    UpMaybeRefresh();
    float W = S(226);
    SolidBrush bg(Cc(0xFFF9FBFF));
    g.FillRectangle(&bg, RectF(0, 0, W, (float)g_h));
    Pen edge(Cc(C_LINE), 1.0f);
    g.DrawLine(&edge, W - 0.5f, 0.0f, W - 0.5f, (float)g_h);

    float ax = S(26), ay = S(24), ar = S(28);
    Image* av = LoadImg(g_artAvatar);
    GraphicsPath clip;
    clip.AddEllipse(ax, ay, ar * 2, ar * 2);
    g.SetClip(&clip);
    if (av) DrawImgFill(g, av, RectF(ax, ay, ar * 2, ar * 2), 0.08f, 0.02f, 0.84f, 0.84f);
    else Round(g, RectF(ax, ay, ar * 2, ar * 2), ar, C_ACCENT_S, 0);
    g.ResetClip();
    Pen ring(Cc(C_ACCENT2), S(1.1f));
    g.DrawEllipse(&ring, ax, ay, ar * 2, ar * 2);

    Txt(g, L"冥零", RectF(ax + ar * 2 + S(13), ay + S(2), S(120), S(24)), Fnt(17, 0, 0), C_TEXT, 0);
    {
        // 版本号后面带不带 -snapshot 都放得下：塞不下就先去掉「工作台 · 」再缩一号字，
        // 不靠省略号，免得把渠道后缀吃掉。
        Font* vf = Fnt(HINT_SIZE, 1, 0);
        wstring s = L"工作台 · " APP_VERSION;
        float left = ax + ar * 2 + S(13);
        float avail = S(236) - S(10) - left;
        if (Tw(g, s, vf) > avail) vf = Fnt(MICRO_SIZE, 1, 0);
        if (Tw(g, s, vf) > avail) s = APP_VERSION;
        Txt(g, s, RectF(left, ay + S(26), avail, S(16)), vf, C_FAINT, 0);
    }

    float y = S(96);
    int ntab = (int)(sizeof(TABS) / sizeof(TABS[0]));
    // 页多了、窗口矮了就压一压行距，别压到底部「服务」那一块
    float tabStep = S(44);
    if (S(96) + ntab * tabStep > (float)g_h - S(196))
        tabStep = std::max(S(34), ((float)g_h - S(96) - S(196)) / (float)ntab);
    for (int i = 0; i < ntab; i++) {
        RectF r(S(12), y, W - S(24), std::min(S(42), tabStep - S(2)));
        std::string id = "tab:" + std::to_string(i);
        bool sel = (g_tab == i);
        if (sel) Round(g, r, S(11), C_ACCENT_S, 0x00000000);
        else if (Hov(id)) Round(g, r, S(11), 0xFFF1F5FD, 0x00000000);
        TabIcon(g, r.X + S(16), r.Y + (r.Height - S(13)) / 2, i, sel ? C_ACCENT : C_FAINT);
        Txt(g, TABS[i], RectF(r.X + S(42), r.Y, r.Width - S(50), r.Height), Fnt(NAV_SIZE, 0, 0), sel ? C_ACCENT : C_SUB, 0);
        if (sel) Round(g, RectF(r.X + S(1), r.Y + S(12), S(2.6f), S(18)), S(1.3f), C_ACCENT, 0);
        if (i == 6) {   // 「更新」有新版时挂个数字，别让人非得点进去才知道
            int bn = UpBadgeCount();
            if (bn > 0)
                Chip(g, RectF(r.X + r.Width - S(30), r.Y + S(13), S(20), S(16)), std::to_wstring(bn), 0xFFFFFFFF,
                     C_ACCENT);
        }
        AddHit(r, id);
        y += tabStep;
    }

    float fy = (float)g_h - S(176);
    HLine(g, S(24), fy, W - S(24), C_LINE2);
    Txt(g, L"服务", RectF(S(26), fy + S(12), S(90), S(16)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    fy += S(34);
    for (int i = 0; i < 2; i++) {
        Dot(g, S(32), fy + S(7), S(3.2f), g_svcUp[i] ? C_OK : 0xFFC3CCDE);
        Txt(g, SVCS[i].name, RectF(S(44), fy - S(2), S(110), S(18)), Fnt(BODY_SIZE, 0, 0), C_SUB, 0);
        Txt(g, g_svcUp[i] ? L"在线" : L"离线", RectF(W - S(74), fy - S(2), S(50), S(18)), Fnt(HINT_SIZE, 1, 0),
            g_svcUp[i] ? C_OK : C_FAINT, 2);
        fy += S(22);
    }
    Dot(g, S(32), fy + S(7), S(3.2f), g_whaleOk ? C_ACCENT : 0xFFC3CCDE);
    Txt(g, L"bili-whale", RectF(S(44), fy - S(2), S(110), S(18)), Fnt(BODY_SIZE, 0, 0), C_SUB, 0);
    Txt(g, g_whaleOk ? L"就绪" : L"缺失", RectF(W - S(74), fy - S(2), S(50), S(18)), Fnt(HINT_SIZE, 1, 0),
        g_whaleOk ? C_ACCENT : C_ERR, 2);
}

// ---------------------------------------------------------------- 总览
static void DrawHero(Graphics& g, const RectF& r) {
    Round(g, r, S(16), C_PANEL, C_LINE);
    GraphicsPath clip;
    clip.AddArc(r.X, r.Y, S(32), S(32), 180, 90);
    clip.AddArc(r.X + r.Width - S(32), r.Y, S(32), S(32), 270, 90);
    clip.AddArc(r.X + r.Width - S(32), r.Y + r.Height - S(32), S(32), S(32), 0, 90);
    clip.AddArc(r.X, r.Y + r.Height - S(32), S(32), S(32), 90, 90);
    clip.CloseFigure();
    g.SetClip(&clip);

    Image* im = LoadImg(g_artHero);
    float iw = r.Width * 0.62f;
    if (im) {
        float srcW = r.Height / (float)im->GetHeight() * (float)im->GetWidth();
        float iwPx = srcW;
        RectF dst(r.X + r.Width - iw, r.Y, iw + S(2), r.Height);
        float aspect = (float)im->GetWidth() / (float)im->GetHeight();
        float needW = r.Height * aspect;
        dst.X = r.X + r.Width - std::min(needW, r.Width * 0.78f);
        dst.Width = std::min(needW, r.Width * 0.78f);
        g.DrawImage(im, dst, 0.0f, 0.0f, (float)im->GetWidth(), (float)im->GetHeight(), UnitPixel);
        (void)iwPx;
        // 左侧渐隐到白：逐列叠白，避开 GDI+ 线性渐变的直边
        int cols = (int)(dst.Width * 0.58f);
        if (cols > 0) {
            for (int i = 0; i < cols; i += 2) {
                float t = (float)i / (float)cols;
                float k = 1.0f - t;
                int a = (int)(255.0f * k * k * k);
                if (a <= 0) break;
                SolidBrush wb((ARGB)(((unsigned)a << 24) | 0x00FFFFFFu));
                RectF strip(dst.X + (float)i - 1.0f, r.Y, 2.0f, r.Height);
                g.FillRectangle(&wb, strip);
            }
        }
        // 底部薄雾
        LinearGradientBrush mist(PointF(r.X, r.Y + r.Height - S(40)), PointF(r.X, r.Y + r.Height), 0x00FFFFFF,
                                 0xAAFFFFFF);
        g.FillRectangle(&mist, RectF(r.X, r.Y + r.Height - S(40), r.Width, S(40)));
    }
    g.ResetClip();

    float tx = r.X + S(30);
    SYSTEMTIME st;
    GetLocalTime(&st);
    int hh = st.wHour;
    const wchar_t* greet = hh < 5 ? L"凌晨了。" : (hh < 11 ? L"早上好。" : (hh < 14 ? L"中午好。" : (hh < 18 ? L"下午好。" : L"晚上好。")));
    Txt(g, greet, RectF(tx, r.Y + S(30), r.Width * 0.6f, S(44)), Fnt(30, 1, 0), C_TEXT, 0);
    wstring sub = wstring(L"现在 ") + g_clock;
    Txt(g, sub, RectF(tx, r.Y + S(76), r.Width * 0.62f, S(20)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 0);

    static const wchar_t* QUOTES[] = {L"知道了知道了，我这就去看。", L"真拿你没办法……那就看一条吧。",
                                      L"这个封面看着还行，勉为其难。", L"又熬夜？看完就睡。"};
    int qi = (int)(st.wDay) % 4;
    RectF q(tx, r.Y + S(98), r.Width * 0.52f, S(24));
    Butterfly(g, q.X + S(6), q.Y + S(11), S(9), 0x663E5FBF);
    Txt(g, QUOTES[qi], RectF(q.X + S(22), q.Y, q.Width - S(22), S(22)), Fnt(SUBTITLE_SIZE, 1, 0), C_SUB, 0);

    Button(g, RectF(tx, r.Y + r.Height - S(52), S(116), S(34)), L"让她看视频", "btn:goto_bili", 1, false);
    Button(g, RectF(tx + S(126), r.Y + r.Height - S(52), S(104), S(34)), L"打开日记", "btn:diary", 0, false);
}

static void PaintOverview(Graphics& g) {
    float x0 = S(236), y0 = S(22), w = (float)g_w - x0 - S(24), h = (float)g_h - S(44);
    RectF hero(x0, y0, w, S(200));
    DrawHero(g, hero);

    float gap = S(14);
    float cy = hero.Y + hero.Height + gap;
    float cw = (w - gap * 3) / 4.0f;
    float ch = S(112);

    for (int i = 0; i < 3; i++) {
        RectF c(x0 + i * (cw + gap), cy, cw, ch);
        Card(g, c, C_PANEL, C_LINE);
        bool up = i < 2 ? g_svcUp[i] : g_whaleOk;
        const wchar_t* name = i < 2 ? SVCS[i].name : L"bili-whale";
        const wchar_t* desc = i < 2 ? SVCS[i].desc : L"看视频";
        wstring port = i < 2 ? SVCS[i].port : L"CLI";
        Dot(g, c.X + S(20), c.Y + S(26), S(4), up ? C_OK : 0xFFC3CCDE);
        Txt(g, name, RectF(c.X + S(34), c.Y + S(14), c.Width - S(44), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
        Txt(g, desc, RectF(c.X + S(20), c.Y + S(42), c.Width - S(36), S(18)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 0);
        if (i < 2) {
            wstring st = up ? L"在线 · 端口 " + wstring(port) : L"离线 · 端口 " + wstring(port);
            if (up && g_svcPid[i]) {
                wstring withPid = st + L" · pid " + Num(g_svcPid[i]);
                if (Tw(g, withPid, Fnt(HINT_SIZE, 0, 0)) <= c.Width - S(36)) st = withPid;
            }
            Txt(g, st, RectF(c.X + S(20), c.Y + S(58), c.Width - S(36), S(16)), Fnt(HINT_SIZE, 0, 0),
                up ? C_SUB : C_FAINT, 0, true);
            std::string a = "svc:" + std::to_string(i) + (up ? ":stop" : ":start");
            Button(g, RectF(c.X + S(16), c.Y + ch - S(36), c.Width - S(32), S(26)), up ? L"关闭" : L"启动", a,
                   up ? 2 : 1, true);
        } else {
            Txt(g, g_whaleOk ? L"就绪" : L"没找到插件",
                RectF(c.X + S(20), c.Y + S(58), c.Width - S(36), S(16)), Fnt(HINT_SIZE, 0, 0),
                g_whaleOk ? C_SUB : C_ERR, 0, true);
            Button(g, RectF(c.X + S(16), c.Y + ch - S(36), c.Width - S(32), S(26)), L"去体检", "btn:goto_check", 0,
                   true);
        }
    }

    // 第四格：机器
    {
        RectF c(x0 + 3 * (cw + gap), cy, cw, ch);
        Card(g, c, C_PANEL, C_LINE);
        Txt(g, L"今天", RectF(c.X + S(20), c.Y + S(16), c.Width - S(36), S(20)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 0);
        int n = CountToday();
        Txt(g, Num(n), RectF(c.X + S(18), c.Y + S(36), S(60), S(34)), Fnt(24, 1, 0), C_ACCENT, 0);
        Txt(g, L"条视频", RectF(c.X + S(18) + Tw(g, Num(n), Fnt(24, 1, 0)) + S(6), c.Y + S(48), S(70), S(20)),
            Fnt(BODY_SIZE, 1, 0), C_SUB, 0);
        wchar_t freeBuf[64] = {0};
        ULARGE_INTEGER fbytes;
        if (GetDiskFreeSpaceExW(RootDir().substr(0, 2).c_str(), &fbytes, nullptr, nullptr))
            Txt(g, PrettyBytes((double)fbytes.QuadPart) + L" 可用", RectF(c.X + S(20), c.Y + S(80), c.Width - S(36), S(18)),
                Fnt(HINT_SIZE, 0, 0), C_FAINT, 0);
        (void)freeBuf;
    }

    float by = cy + ch + gap;
    float bh = y0 + h - by;
    float rw = S(292);
    RectF recent(x0, by, w - rw - gap, bh);
    Card(g, recent, C_PANEL, C_LINE);
    Txt(g, L"最近任务", RectF(recent.X + S(22), recent.Y + S(18), S(160), S(22)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Button(g, RectF(recent.X + recent.Width - S(104), recent.Y + S(14), S(84), S(28)), L"看全部", "btn:goto_jobs",
           0, true);
    HLine(g, recent.X + S(20), recent.Y + S(52), recent.X + recent.Width - S(20), C_LINE2);

    if (g_jobs.empty()) {
        Image* em = LoadImg(g_artEmpty);
        float capH = S(26);
        float ih = std::min(recent.Height - S(70) - capH, S(300));
        if (em && ih > S(60)) {
            float iw = ih * (float)em->GetWidth() / (float)em->GetHeight();
            DrawImgFill(g, em, RectF(recent.X + recent.Width / 2 - iw / 2, recent.Y + S(62), iw, ih), 0, 0, 1, 1);
        }
        Txt(g, L"还没有任务，去 B站 页挑一条。", RectF(recent.X, recent.Y + recent.Height - S(34), recent.Width, S(24)),
            Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    } else {
        float ry = recent.Y + S(62);
        int shown = 0;
        for (auto& j : g_jobs) {
            if (shown >= 4) break;
            if (ry + S(44) > recent.Y + recent.Height) break;
            Txt(g, Hhmm(j.t), RectF(recent.X + S(22), ry, S(48), S(20)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
            Txt(g, j.title.empty() ? j.bv : j.title, RectF(recent.X + S(76), ry, recent.Width - S(180), S(20)),
                Fnt(BODY_SIZE, 0, 0), C_TEXT, 0, true);
            Txt(g, j.source == L"qq" ? L"群" : L"本机", RectF(recent.X + recent.Width - S(96), ry, S(34), S(20)),
                Fnt(HINT_SIZE, 1, 0), C_FAINT, 2);
            Txt(g, j.status == L"ok" ? L"完成" : (j.status == L"fail" ? L"失败" : j.status),
                RectF(recent.X + recent.Width - S(58), ry, S(38), S(20)), Fnt(HINT_SIZE, 1, 0),
                j.status == L"ok" ? C_OK : C_ERR, 2);
            HLine(g, recent.X + S(20), ry + S(28), recent.X + recent.Width - S(20), C_LINE2);
            ry += S(34);
            shown++;
        }
    }

    RectF quick(x0 + w - rw, by, rw, bh);
    Card(g, quick, C_PANEL, C_LINE);
    Txt(g, L"快捷", RectF(quick.X + S(22), quick.Y + S(18), S(120), S(22)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    float qy = quick.Y + S(54);
    float bw2 = (quick.Width - S(44) - S(10)) / 2.0f;
    float bot = quick.Y + quick.Height - S(12);
    auto fits = [&](float y) { return y + S(34) <= bot; };
    if (fits(qy)) {
        Button(g, RectF(quick.X + S(22), qy, bw2, S(34)), L"全部启动", "btn:allstart", 1, true);
        Button(g, RectF(quick.X + S(32) + bw2, qy, bw2, S(34)), L"全部关闭", "btn:allstop", 2, true);
        qy += S(44);
    }
    if (fits(qy)) {
        Button(g, RectF(quick.X + S(22), qy, bw2, S(34)), L"打开日记", "btn:diary", 0, true);
        Button(g, RectF(quick.X + S(32) + bw2, qy, bw2, S(34)), L"日志目录", "btn:logdir", 0, true);
        qy += S(44);
    }
    if (fits(qy)) {
        Button(g, RectF(quick.X + S(22), qy, quick.Width - S(44), S(34)), L"打开 B站 看视频", "btn:goto_bili", 0, true);
        qy += S(44);
    }
    if (fits(qy)) {
        Button(g, RectF(quick.X + S(22), qy, bw2, S(34)), L"ComfyUI", "btn:comfy", 0, true);
        Button(g, RectF(quick.X + S(32) + bw2, qy, bw2, S(34)), L"B站首页", "btn:bilihome", 0, true);
        qy += S(44);
    }
    if (bot - qy > S(20)) {
        Txt(g, L"凭证 " + (g_whaleOk ? wstring(L"已登录") : wstring(L"未就绪")),
            RectF(quick.X + S(22), bot - S(20), quick.Width - S(44), S(18)), Fnt(HINT_SIZE, 0, 0), C_FAINT, 0, true);
    }
}

// ---------------------------------------------------------------- B站
// ---------------------------------------------------------------- B 站：选题 / 看片与读链接 / 结果 / 配置
// 一整页，四个分区。原来两个浮层（bili-whale 配置、问一句）并进来之后，
// 这个页签自己就装得下全部事：挑选题、粘链接、看结果、改配置。
static const wchar_t* kBiliSecName[4] = {L"选题", L"看片与读链接", L"结果", L"配置"};

static void PaintBiliChips(Graphics& g, float x, float y) {
    float cx = x;
    for (int i = 0; i < 4; i++) {
        const wchar_t* nm = kBiliSecName[i];
        float cw = S(88) + S(8) * (float)wcslen(nm) / 4.0f;
        if (i == 1) cw = S(132);
        if (i == 0 || i == 2 || i == 3) cw = S(84);
        RectF r(cx, y, cw, S(32));
        std::string id = "bsec:" + std::to_string(i);
        bool sel = (g_bSec == i);
        Round(g, r, S(9), sel ? C_ACCENT_S : (Hov(id) ? 0xFFF4F8FF : C_PANEL), sel ? 0x00000000 : C_LINE);
        Txt(g, nm, r, Fnt(SUBTITLE_SIZE, sel ? 0 : 1, 0), sel ? C_ACCENT : C_SUB, 1);
        AddHit(r, id);
        cx += cw + S(7);
    }
}

// ---- 分区一：选题
static void PaintBiliFeed(Graphics& g, const RectF& body) {
    Card(g, body, C_PANEL, C_LINE);
    Txt(g, L"今晚看什么", RectF(body.X + S(22), body.Y + S(16), S(200), S(26)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    wstring note = g_feedBusy ? wstring(L"正在捞…") : (g_feedNote.empty() ? wstring(L"她按你的口味挑的") : g_feedNote);
    Txt(g, note, RectF(body.X + S(22), body.Y + S(46), body.Width - S(260), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    Button(g, RectF(body.X + body.Width - S(112), body.Y + S(14), S(88), S(30)), g_feedBusy ? L"…" : L"换一批",
           "btn:feed", 0, true, !g_feedBusy);

    const float gap = S(12);
    const float cw = (body.Width - S(40) - gap) / 2;
    const float ch = S(94);
    RectF list(body.X + S(10), body.Y + S(72), body.Width - S(20), body.Height - S(72) - S(52));
    g_rcFeed = list;
    int rows = ((int)g_feed.size() + 1) / 2;
    float totalH = rows > 0 ? rows * (ch + gap) : 0;
    float maxScroll = std::max(0.0f, totalH - list.Height);
    if (g_feedScroll > maxScroll) g_feedScroll = maxScroll;
    if (g_feedScroll < 0) g_feedScroll = 0;

    g.SetClip(list);
    for (int i = 0; i < (int)g_feed.size(); i++) {
        FeedItem& f = g_feed[i];
        float cx = list.X + S(10) + (i % 2) * (cw + gap);
        float cy = list.Y + S(3) + (i / 2) * (ch + gap) - g_feedScroll;
        RectF r(cx, cy, cw, ch);
        if (r.Y + r.Height < list.Y - S(4) || r.Y > list.Y + list.Height + S(4)) continue;
        std::string id = "feed:" + std::to_string(i);
        bool sel = (g_feedSel == i);
        Round(g, r, S(11), sel ? C_ACCENT_S : (Hov(id) ? 0xFFF7FAFF : C_PANEL2), sel ? C_ACCENT2 : C_LINE2);
        TxtWrap(g, f.title, RectF(r.X + S(14), r.Y + S(12), r.Width - S(84), S(38)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT);
        if (!f.dur.empty()) {
            int sec = _wtoi(f.dur.c_str());
            wstring dur = Num(sec / 60) + L":" + Pad2(sec % 60);
            RectF db(r.X + r.Width - S(58), r.Y + S(10), S(46), S(18));
            Round(g, db, S(9), 0x22000000, 0x00000000);
            Txt(g, dur, db, Fnt(MICRO_SIZE, 0, 0), C_SUB, 1);
        }
        wstring meta = f.up;
        if (!f.play.empty()) meta += (meta.empty() ? L"" : L"  ·  ") + f.play + L"播放";
        if (!f.dm.empty()) meta += L"  ·  " + f.dm + L"弹幕";
        if (meta.empty()) meta = f.bv;
        Txt(g, meta, RectF(r.X + S(14), r.Y + S(56), r.Width - S(28), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
        Txt(g, f.bv, RectF(r.X + S(14), r.Y + r.Height - S(20), r.Width - S(28), S(14)), Fnt(MICRO_SIZE, 1, 1), C_FAINT, 0, true);
        AddHit(r, id);
    }
    g.ResetClip();
    ScrollBar(g, list, g_feedScroll, totalH);

    if (g_feed.empty()) {
        Image* em = LoadImg(g_artEmpty);
        float ih = std::min(list.Height - S(80), S(220) * g_scale);
        if (em && ih > S(70)) {
            float iw = ih * (float)em->GetWidth() / (float)em->GetHeight();
            DrawImgFill(g, em, RectF(list.X + list.Width / 2 - iw / 2, list.Y + S(10), iw, ih), 0, 0, 1, 1);
        }
        Txt(g, g_feedBusy ? L"正在筛…" : L"点右上「换一批」捞选题", RectF(list.X, list.Y + list.Height - S(46), list.Width, S(24)),
            Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    }

    // 底部：当前工作区（产物落这里，点一下可以换）
    float wy = body.Y + body.Height - S(34);
    HLine(g, body.X + S(20), wy - S(10), body.X + body.Width - S(20), C_LINE2);
    Txt(g, L"工作区", RectF(body.X + S(20), wy, S(52), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0);
    Txt(g, WorkspaceDir(), RectF(body.X + S(20) + S(50), wy, body.Width - S(190), S(16)), Fnt(MICRO_SIZE, 1, 0), C_SUB, 0,
        true);
    RectF b(body.X + body.Width - S(96), wy - S(5), S(76), S(26));
    bool hov = Hov("ws:pick");
    Round(g, b, S(8), hov ? C_ACCENT_S : 0x00000000, 0x00000000);
    Txt(g, L"换工作区", b, Fnt(MICRO_SIZE, hov ? 0 : 1, 0), hov ? C_ACCENT : C_ACCENT2, 1);
    AddHit(b, "ws:pick");
    Button(g, RectF(body.X + body.Width - S(196), wy - S(5), S(88), S(26)), L"打开产物", "bfiles", 0, true);
}

// ---- 分区二：看片与读链接
static void PaintBiliWork(Graphics& g, const RectF& body) {
    RectF top(body.X, body.Y, body.Width, S(152));
    Card(g, top, C_PANEL, C_LINE);
    Txt(g, L"看片与读链接", RectF(top.X + S(22), top.Y + S(14), S(200), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"粘 B 站 链接 / BV、普通网页链接或分享文本，回车就开跑", RectF(top.X + S(130), top.Y + S(20), top.Width - S(160), S(18)),
        Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);

    RectF ed(top.X + S(22), top.Y + S(48), top.Width - S(22) * 2 - S(128), S(52));
    g_rcInput = ed;
    Round(g, ed, S(11), g_editFocus ? 0xFFFFFFFF : C_PANEL2, g_editFocus ? C_ACCENT2 : C_LINE);
    float txx = ed.X + S(16);
    if (g_bvInput.empty()) {
        Txt(g, L"粘 B站 链接 / BV，或者别的网页链接、分享文本…（Ctrl+V / 右键）", RectF(txx, ed.Y, ed.Width - S(24), ed.Height),
            Fnt(SUBTITLE_SIZE, 1, 0), 0xFFAAB5C9, 0, true);
    } else {
        RectF tr(txx, ed.Y, ed.Width - S(24), ed.Height);
        if (g_inputSelAll)
            Round(g, RectF(ed.X + S(3), ed.Y + S(3), ed.Width - S(6), ed.Height - S(6)), S(9), 0x2E3E5FBF, 0x00000000);
        Txt(g, g_bvInput, tr, Fnt(SUBTITLE_SIZE, 0, 0), g_inputSelAll ? C_ACCENT : C_TEXT, 0, true);
    }
    AddHit(ed, "edit:bv");
    Button(g, RectF(ed.X + ed.Width + S(12), ed.Y, S(116), S(52)), g_watchBusy ? L"看着呢…" : L"让她看", "btn:watch", 1,
           false, !g_watchBusy);

    wstring status = g_watchBusy ? g_watchStatus
                                 : (g_hasResult ? (g_linkMode ? L"读完了 · 结果在「结果」分区" : L"看完了 · 结果在「结果」分区")
                                                : (g_linkMode ? L"读标题和正文摘要；B 站链接照旧走看片" : L"读字幕、弹幕、热评，再看几帧画面"));
    Txt(g, status, RectF(top.X + S(22), top.Y + S(108), top.Width - S(44), S(18)), Fnt(HINT_SIZE, 1, 0),
        g_watchBusy ? C_ACCENT : C_FAINT, 0, true);
    if (g_watchBusy) {
        RectF bar(top.X + S(22), top.Y + S(132), top.Width - S(44), S(3));
        Round(g, bar, S(1.5f), 0x1A3E5FBF, 0, 0);
        float wd = (top.Width - S(44)) * (g_watchPct / 100.0f);
        if (wd > S(3)) Round(g, RectF(bar.X, bar.Y, wd, S(3)), S(1.5f), C_ACCENT, 0, 0);
    } else {
        HLine(g, top.X + S(22), top.Y + S(133), top.X + top.Width - S(22), C_LINE2);
    }

    // 最近一次（结果分区是全文，这里只给一眼）
    float ly = top.Y + top.Height + S(14);
    RectF last(body.X, ly, body.Width, body.Height - (ly - body.Y) - S(66));
    Card(g, last, C_PANEL, C_LINE);
    Txt(g, L"最近一次", RectF(last.X + S(22), last.Y + S(14), S(160), S(22)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT, 0);
    if (!g_hasResult) {
        Image* em = LoadImg(g_artEmpty);
        float ih = std::min(last.Height - S(130), S(190) * g_scale);
        float blockH = ih + S(46);
        float iy = last.Y + S(40) + std::max(0.0f, (last.Height - S(140) - blockH) / 2.0f);
        if (em && ih > S(64)) {
            float iw = ih * (float)em->GetWidth() / (float)em->GetHeight();
            DrawImgFill(g, em, RectF(last.X + last.Width / 2 - iw / 2, iy, iw, ih), 0, 0, 1, 1);
        }
        wstring word = g_linkMode ? wstring(L"她还没读过网页") : wstring(L"她还没看过视频");
        Txt(g, word, RectF(last.X, iy + ih + S(10), last.Width, S(22)), Fnt(BODY_SIZE, 0, 0), C_SUB, 1);
        Txt(g, L"上面粘一条，或者去「选题」里挑一个", RectF(last.X, iy + ih + S(34), last.Width, S(18)), Fnt(MICRO_SIZE, 1, 0),
            C_FAINT, 1);
    } else {
        wstring kind = g_linkMode ? L"读链接" : L"看视频";
        Chip(g, RectF(last.X + S(100), last.Y + S(16), S(58), S(20)), kind, C_ACCENT, C_ACCENT_S);
        Txt(g, g_result.title.empty() ? L"（无标题）" : g_result.title,
            RectF(last.X + S(22), last.Y + S(46), last.Width - S(44), S(26)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0, true);
        wstring meta = g_result.up;
        if (g_result.seconds > 0) meta += (meta.empty() ? L"" : L"  ·  ") + Num((long long)g_result.seconds) + L" 秒";
        Txt(g, meta, RectF(last.X + S(22), last.Y + S(76), last.Width - S(44), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
        // 摘要：优先用站点写的 description，没有就取正文前两行
        wstring brief;
        for (auto& ln : SplitLines(g_result.raw)) {
            if (ln.find(L"══════") != wstring::npos) continue;
            if (ln.rfind(L"标题:", 0) == 0 || ln.rfind(L"来源:", 0) == 0 || ln.rfind(L"地址:", 0) == 0 ||
                ln.rfind(L"状态:", 0) == 0 || ln.rfind(L"耗时:", 0) == 0 || ln.rfind(L"注意:", 0) == 0)
                continue;
            if (Trim(ln).empty()) continue;
            brief = Trim(ln);
            break;
        }
        if (brief.size() > 160) brief = brief.substr(0, 160) + L"…";
        TxtWrap(g, brief, RectF(last.X + S(22), last.Y + S(102), last.Width - S(44), std::min(S(60), last.Height - S(150))),
                Fnt(BODY_SIZE, 1, 0), C_SUB);
        Button(g, RectF(last.X + last.Width - S(112), last.Y + S(46), S(90), S(30)), L"看全文", "bsec:2", 0, true);
        Button(g, RectF(last.X + last.Width - S(112), last.Y + S(82), S(90), S(30)), L"复制全文", "btn:copy", 0, true);
        Button(g, RectF(last.X + last.Width - S(112), last.Y + S(118), S(90), S(30)), L"打开文件夹", "btn:open_shotdir", 0,
               true);
    }

    // 一键入口：配置两个、诊断四个、产物
    float qy = body.Y + body.Height - S(54);
    float sx = body.X;
    Button(g, RectF(sx, qy, S(120), S(32)), L"bili-whale 配置", "bcfg", 0, true);
    sx += S(128);
    Button(g, RectF(sx, qy, S(104), S(32)), L"链接与应用", "lcfg", 0, true);
    sx += S(112);
    const wchar_t* diag[] = {L"登录", L"配额", L"风控", L"自检"};
    const int dact[] = {0, 2, 3, 4};
    for (int i = 0; i < 4; i++) {
        Button(g, RectF(sx, qy, S(58), S(32)), diag[i], "bchk:" + std::to_string(dact[i]), 0, true);
        sx += S(64);
    }
    if (sx + S(64) < body.X + body.Width) Button(g, RectF(sx, qy, S(60), S(32)), L"产物", "bfiles", 0, true);
}

// ---- 分区三：结果（「问一句」现在也长在这里，不再是浮层）
static void PaintBiliResult(Graphics& g, const RectF& body) {
    Card(g, body, C_PANEL, C_LINE);
    wstring kind = g_linkMode ? L"读链接" : L"看视频";
    Txt(g, L"结果", RectF(body.X + S(22), body.Y + S(12), S(80), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    if (g_hasResult) Chip(g, RectF(body.X + S(76), body.Y + S(15), S(58), S(20)), kind, C_ACCENT, C_ACCENT_S);

    float bx = body.X + body.Width;
    Button(g, RectF(bx - S(98), body.Y + S(10), S(84), S(28)), L"问一句", "bdsh", 0, true, g_hasResult || g_dshOpen);
    Button(g, RectF(bx - S(190), body.Y + S(10), S(84), S(28)), L"复制全文", "btn:copy", 0, true, g_hasResult);
    Button(g, RectF(bx - S(290), body.Y + S(10), S(92), S(28)), L"打开文件夹", "btn:open_shotdir", 0, true, g_hasResult);
    HLine(g, body.X + S(20), body.Y + S(48), bx - S(20), C_LINE2);

    RectF area(body.X + S(10), body.Y + S(54), body.Width - S(20), body.Height - S(54) - S(10));
    float askW = g_dshOpen ? std::min(S(400), area.Width * 0.42f) : 0;
    RectF textArea = area;
    if (askW > 0) textArea.Width = area.Width - askW - S(14);
    g_rcWatch = textArea;
    g_watchViewH = textArea.Height;

    if (!g_hasResult) {
        Image* em = LoadImg(g_artEmpty);
        float ih = std::min(area.Height - S(190), S(210) * g_scale);
        float blockH = ih + S(96);
        float iy = area.Y + std::max(S(12), (area.Height - blockH) / 2.0f);
        if (em && ih > S(80)) {
            float iw = ih * (float)em->GetWidth() / (float)em->GetHeight();
            DrawImgFill(g, em, RectF(area.X + area.Width / 2 - iw / 2, iy, iw, ih), 0, 0, 1, 1);
        }
        wstring emptyWord = g_linkMode ? (g_watchBusy ? L"正在读… " : L"她还没读过网页")
                                       : (g_watchBusy ? L"正在看… " : L"她还没看过视频");
        if (g_watchBusy) emptyWord += Num((long long)g_watchPct) + L"%";
        Txt(g, emptyWord, RectF(area.X, iy + ih + S(12), area.Width, S(24)), Fnt(TITLE_SIZE, 0, 0), C_SUB, 1);
        Button(g, RectF(area.X + area.Width / 2 - S(60), iy + ih + S(46), S(120), S(32)), L"去粘一条",
               "bsec:1", 1, true);
    } else {
        float total = DrawRich(g, g_result.raw, textArea, g_watchScroll);
        g_watchContentH = total;
        ScrollBar(g, textArea, g_watchScroll, total);
        if (askW <= 0) {
            bool hasArt = (!g_result.sheet.empty() || !g_result.cover.empty());
            if (hasArt) {
                float artW = std::min(S(260), area.Width * 0.3f);
                float ax = area.X + area.Width - artW;
                float ay = area.Y;
                Image* cover = g_result.cover.empty() ? nullptr : LoadImg(g_result.cover);
                if (cover) {
                    float cw = artW, chh = cw * 0.5625f;
                    Round(g, RectF(ax, ay, cw, chh), S(10), C_PANEL2, C_LINE);
                    GraphicsPath cp;
                    cp.AddArc(ax, ay, S(20), S(20), 180, 90);
                    cp.AddArc(ax + cw - S(20), ay, S(20), S(20), 270, 90);
                    cp.AddArc(ax + cw - S(20), ay + chh - S(20), S(20), S(20), 0, 90);
                    cp.AddArc(ax, ay + chh - S(20), S(20), S(20), 90, 90);
                    cp.CloseFigure();
                    g.SetClip(&cp);
                    DrawImgFill(g, cover, RectF(ax, ay, cw, chh), 0, 0, 1, 1);
                    g.ResetClip();
                    AddHit(RectF(ax, ay, cw, chh), "btn:open_cover");
                    ay += chh + S(10);
                }
                Image* sheet = g_result.sheet.empty() ? nullptr : LoadImg(g_result.sheet);
                if (sheet) {
                    float sh = artW;
                    float ih2 = sh * (float)sheet->GetHeight() / (float)sheet->GetWidth();
                    if (ay + ih2 > area.Y + area.Height) ih2 = std::max(S(80), area.Y + area.Height - ay);
                    Round(g, RectF(ax, ay, sh, ih2), S(10), C_PANEL2, C_LINE);
                    g.SetClip(RectF(ax, ay, sh, ih2));
                    DrawImgFill(g, sheet, RectF(ax, ay, sh, ih2), 0, 0, 1, 1);
                    g.ResetClip();
                    AddHit(RectF(ax, ay, sh, ih2), "btn:open_sheet");
                }
            }
        }
    }
    if (askW > 0) {
        RectF ask(area.X + area.Width - askW, area.Y, askW, area.Height);
        PaintDshAsk(g, ask);
    }
}

// ---- 分区四：配置（bili-whale / 链接与应用）
static void PaintBiliCfgArea(Graphics& g, const RectF& body) {
    const wchar_t* nm[2] = {L"bili-whale", L"链接与应用"};
    float cx = body.X;
    for (int i = 0; i < 2; i++) {
        float cw = i == 0 ? S(112) : S(104);
        RectF r(cx, body.Y, cw, S(30));
        std::string id = "bcfgsub:" + std::to_string(i);
        bool sel = (g_bCfgSub == i);
        Round(g, r, S(9), sel ? C_ACCENT_S : (Hov(id) ? 0xFFF4F8FF : C_PANEL), sel ? 0x00000000 : C_LINE);
        Txt(g, nm[i], r, Fnt(HINT_SIZE, sel ? 0 : 1, 0), sel ? C_ACCENT : C_SUB, 1);
        AddHit(r, id);
        cx += cw + S(8);
    }
    Txt(g, L"改完点保存；旧配置备份成 .bak-时间", RectF(body.X + S(240), body.Y + S(6), body.Width - S(240), S(18)),
        Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0, true);
    RectF card(body.X, body.Y + S(38), body.Width, body.Height - S(38));
    if (g_bCfgSub == 0) PaintBiliCfg(g, card);
    else PaintLinkCfg(g, card);
}

static void PaintBili(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    g_rcFeed = RectF();
    g_rcInput = RectF();
    g_rcWatch = RectF();

    PaintBiliChips(g, x0, y0);
    {
        wstring right = g_watchBusy ? (g_watchStatus.empty() ? wstring(L"正在跑…") : g_watchStatus)
                                    : (g_hasResult ? (g_linkMode ? wstring(L"刚读完一条链接") : wstring(L"刚看完一条视频"))
                                                   : wstring(L"粘链接、挑选题，都从这一页开始"));
        Txt(g, right, RectF(x0 + S(390), y0 + S(7), W - S(390), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 2, true);
    }
    RectF body(x0, y0 + S(42), W, H - S(42));
    switch (g_bSec) {
        case 0: PaintBiliFeed(g, body); break;
        case 2: PaintBiliResult(g, body); break;
        case 3: PaintBiliCfgArea(g, body); break;
        default: PaintBiliWork(g, body); break;
    }
}

// ---------------------------------------------------------------- 队列
static void PaintJobs(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    float th = H * 0.50f;
    RectF table(x0, y0, W, th);
    Card(g, table, C_PANEL, C_LINE);
    Txt(g, L"任务队列", RectF(table.X + S(22), table.Y + S(16), S(160), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, Num((long long)g_jobs.size()) + L" 条", RectF(table.X + S(104), table.Y + S(18), S(80), S(20)),
        Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    Button(g, RectF(table.X + table.Width - S(96), table.Y + S(14), S(74), S(28)), L"刷新", "btn:jobs_refresh", 0, true);
    HLine(g, table.X + S(20), table.Y + S(54), table.X + table.Width - S(20), C_LINE2);

    float col1 = S(78), col2 = S(72), col3 = S(112), col5 = S(70);
    float hx = table.X + S(22);
    Txt(g, L"时间", RectF(hx, table.Y + S(58), col1, S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    Txt(g, L"来源", RectF(hx + col1, table.Y + S(58), col2, S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    Txt(g, L"BV", RectF(hx + col1 + col2, table.Y + S(58), col3, S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    float titleW = table.Width - (col1 + col2 + col3 + col5) - S(44);
    Txt(g, L"标题", RectF(hx + col1 + col2 + col3, table.Y + S(58), titleW, S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    Txt(g, L"状态", RectF(hx + col1 + col2 + col3 + titleW, table.Y + S(58), col5, S(18)), Fnt(HINT_SIZE, 1, 0),
        C_FAINT, 0);

    RectF rows(table.X + S(10), table.Y + S(80), table.Width - S(20), table.Height - S(92));
    g_rcJobs = rows;
    g.SetClip(rows);
    float ry = rows.Y - g_jobsScroll;
    for (int i = 0; i < (int)g_jobs.size(); i++) {
        JobRec& j = g_jobs[i];
        RectF r(rows.X + S(8), ry, rows.Width - S(16), S(36));
        std::string id = "job:" + std::to_string(i);
        if (g_jobSel == i) Round(g, r, S(9), C_ACCENT_S, 0x00000000);
        else if (Hov(id)) Round(g, r, S(9), 0xFFF4F8FF, 0x00000000);
        float ty = ry + S(9);
        Txt(g, Hhmm(j.t), RectF(r.X + S(6), ty, col1, S(18)), Fnt(BODY_SIZE, 0, 1), C_SUB, 0);
        Txt(g, j.source == L"qq" ? L"群" : L"本机", RectF(r.X + S(6) + col1, ty, col2, S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT,
            0);
        Txt(g, j.bv, RectF(r.X + S(6) + col1 + col2, ty, col3, S(18)), Fnt(HINT_SIZE, 0, 1), C_ACCENT2, 0);
        Txt(g, j.title.empty() ? L"（无标题）" : j.title,
            RectF(r.X + S(6) + col1 + col2 + col3, ty, titleW, S(18)), Fnt(BODY_SIZE, 0, 0), C_TEXT, 0, true);
        Txt(g, j.status == L"ok" ? L"完成" : (j.status == L"fail" ? L"失败" : j.status),
            RectF(r.X + S(4) + col1 + col2 + col3 + titleW, ty, col5, S(18)), Fnt(HINT_SIZE, 1, 0),
            j.status == L"ok" ? C_OK : C_ERR, 2);
        AddHit(r, id);
        ry += S(38);
    }
    g.ResetClip();
    ScrollBar(g, rows, g_jobsScroll, S(38) * g_jobs.size());

    if (g_jobs.empty()) {
        Txt(g, L"队列是空的：看完一条视频就会记在这里。",
            RectF(rows.X, rows.Y + S(30), rows.Width, S(22)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    }

    RectF detail(x0, y0 + th + S(14), W, H - th - S(14));
    Card(g, detail, C_PANEL, C_LINE);
    Txt(g, L"任务详情", RectF(detail.X + S(22), detail.Y + S(14), detail.Width - S(200), S(24)),
        Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    if (g_jobSel >= 0 && g_jobSel < (int)g_jobs.size()) {
        JobRec& j = g_jobs[g_jobSel];
        Button(g, RectF(detail.X + detail.Width - S(88), detail.Y + S(12), S(66), S(26)), L"文件夹", "btn:open_shotdir",
               0, true);
        Button(g, RectF(detail.X + detail.Width - S(164), detail.Y + S(12), S(66), S(26)), L"复制", "btn:copy_job", 0,
               true);
        (void)j;
    }
    HLine(g, detail.X + S(20), detail.Y + S(48), detail.X + detail.Width - S(20), C_LINE2);
    RectF dtext(detail.X + S(22), detail.Y + S(58), detail.Width - S(44), detail.Height - S(72));
    g_rcWatch = dtext;
    if (!g_jobDetail.empty()) {
        float total = DrawRich(g, g_jobDetail, dtext, g_jobDetailScroll);
        g_jobDetailH = total;
        g_jobDetailView = dtext.Height;
        ScrollBar(g, dtext, g_jobDetailScroll, total);
    } else {
        Txt(g, L"点上面一行看详情", RectF(dtext.X, dtext.Y + S(16), dtext.Width, S(24)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    }
}

// ---------------------------------------------------------------- 日志
static void PaintLogs(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    float cx = x0;
    for (int i = 0; i < 3; i++) {
        float w = S(i == 0 ? 132 : 92);
        RectF r(cx, y0, w, S(30));
        std::string id = "logsrc:" + std::to_string(i);
        bool sel = (g_logSrc == i);
        Round(g, r, S(15), sel ? C_ACCENT : C_PANEL, sel ? C_ACCENT : C_LINE);
        Txt(g, LOG_NAMES[i], r, Fnt(BODY_SIZE, 0, 0), sel ? 0xFFFFFFFF : C_SUB, 1);
        AddHit(r, id);
        cx += w + S(8);
    }
    Button(g, RectF(cx, y0, S(74), S(30)), L"刷新", "btn:log_refresh", 0, true);
    Button(g, RectF(cx + S(82), y0, S(104), S(30)), L"日志目录", "btn:logdir", 0, true);

    RectF panel(x0, y0 + S(42), W, H - S(42));
    Card(g, panel, C_PANEL, C_LINE);
    RectF text(panel.X + S(20), panel.Y + S(16), panel.Width - S(40), panel.Height - S(32));
    g_rcLog = text;
    g_logView = text.Height;
    float total = DrawRich(g, g_logText.empty() ? L"（没有日志）" : g_logText, text, g_logScroll);
    g_logH = total;
    ScrollBar(g, text, g_logScroll, total);
}

// ---------------------------------------------------------------- 体检
static void PaintCheck(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    static const wchar_t* BTN[] = {L"会话", L"依赖", L"限额", L"风控", L"自检"};
    float cx = x0;
    for (int i = 0; i < 5; i++) {
        float w = S(i == 2 || i == 3 ? 108 : 112);
        std::string id = "check:" + std::to_string(i);
        Button(g, RectF(cx, y0, w, S(32)), g_checkBusy && g_checkAction == i ? L"跑着呢…" : BTN[i], id,
               g_checkAction == i ? 1 : 0, true, !g_checkBusy);
        cx += w + S(8);
    }
    RectF panel(x0, y0 + S(44), W, H - S(44));
    Card(g, panel, C_PANEL, C_LINE);
    RectF text(panel.X + S(20), panel.Y + S(16), panel.Width - S(40), panel.Height - S(32));
    g_rcCheck = text;
    g_checkView = text.Height;
    float total = DrawRich(g, g_checkText, text, g_checkScroll);
    g_checkH = total;
    ScrollBar(g, text, g_checkScroll, total);
}

// ---------------------------------------------------------------- 绘制入口
#include "ui_maint.inc"
#include "ui_setup.inc"
#include "ui_update.inc"
#include "ui_docs.inc"
#include "ui_help.inc"
#include "ui_bili_cfg.inc"
#include "ui_link_cfg.inc"
#include "ui_dsh.inc"
#include "ui_center.inc"

void UiPaint(HDC hdc, int w, int h) {
    if (!g_bmp || w != g_bw || h != g_bh) {
        if (g_bmp) DeleteObject(g_bmp);
        if (g_mem) DeleteDC(g_mem);
        HDC screen = GetDC(g_hwnd);
        g_mem = CreateCompatibleDC(screen);
        g_bmp = CreateCompatibleBitmap(screen, w, h);
        ReleaseDC(g_hwnd, screen);
        SelectObject(g_mem, g_bmp);
        g_bw = w;
        g_bh = h;
    }
    g_w = w;
    g_h = h;
    g_hits.clear();

    Graphics g(g_mem);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetTextRenderingHint(TextRenderingHintClearTypeGridFit);
    g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    g.SetPixelOffsetMode(PixelOffsetModeHalf);

    RectF full(0, 0, (float)w, (float)h);
    LinearGradientBrush bg(PointF(0, 0), PointF((float)w * 0.6f, (float)h), C_BG, C_BG2);
    g.FillRectangle(&bg, full);

    Butterfly(g, (float)w - S(70), S(56), S(30), 0x1E3E5FBF);
    Butterfly(g, (float)w - S(30), S(120), S(16), 0x143E5FBF);
    Butterfly(g, S(250), (float)h - S(40), S(20), 0x123E5FBF);

    PaintSidebar(g);

    switch (g_tab) {
        case 0: PaintOverview(g); break;
        case 1: PaintBili(g); break;
        case 2: PaintJobs(g); break;
        case 3: PaintLogs(g); break;
        case 4: PaintCheck(g); break;
        case 5: PaintMaint(g); break;
        case 6: PaintHelpCenter(g); break;
        default: PaintHelpCenter(g); break;
    }

    PaintNotifyBanner(g);   // 右上角滑进来那条：托盘气泡被压掉时也看得见

    if (!g_toast.empty() && GetTickCount() - g_toastAt < 4000) {
        Font* f = Fnt(BODY_SIZE, 0, 0);
        float tw = Tw(g, g_toast, f) + S(36);
        RectF r((float)w / 2 - tw / 2, (float)h - S(64), tw, S(36));
        Round(g, r, S(18), 0xF21A2130, 0x00000000);
        Txt(g, g_toast, r, f, 0xFFFFFFFF, 1);
    }

    BitBlt(hdc, 0, 0, w, h, g_mem, 0, 0, SRCCOPY);
}

// ---------------------------------------------------------------- 交互
void UiRequestRepaint() {
    if (g_hwnd) InvalidateRect(g_hwnd, nullptr, FALSE);
}

void UiToast(const wstring& msg) {
    g_toast = msg;
    g_toastAt = GetTickCount();
    UiRequestRepaint();
}

// 换工作区：先选目录，再问要不要把旧的 out/logs 搬过去；搬是复制，不删旧数据。
static void SwitchWorkspace() {
    wstring old = WorkspaceDir();
    wstring pick = PickFolder(g_hwnd, L"选择冥零工作区（out、tmp、logs 会建在这里）", old);
    if (pick.empty()) return;
    if (pick == old) { UiToast(L"还是当前工作区"); return; }
    bool move = false;
    if (DirExists(JoinPath(old, L"out")) || DirExists(JoinPath(old, L"logs"))) {
        int r = MessageBoxW(g_hwnd,
                            wstring(L"要把当前工作区的 out / tmp / logs 复制到新位置吗？\n\n旧文件不会被删除，可以之后再手动清理。").c_str(),
                            L"换工作区", MB_YESNO | MB_ICONQUESTION);
        move = (r == IDYES);
    }
    SetWorkspaceDir(pick);
    EnsureWorkspaceLayout(WorkspaceDir());
    RegisterUninstallEntry();
    if (move) MigrateWorkspaceData(old, pick);
    g_feed.clear();
    g_feedSel = -1;
    g_result = Debrief();
    g_hasResult = false;
    g_jobSel = -1;
    LoadJobs();
    RefreshFeed();
    UiToast(move ? L"已换到新工作区，旧文件已复制过去" : L"已换到新工作区");
    UiRequestRepaint();
}

void UiOnClick(int x, int y) {
    std::string id = HitAt(x, y);
    if (id.empty()) {
        if (g_askEditor) {   // 点空白等于「就这样」：存下来再收
            CloseAskEditor(true);
            return;
        }
        if (g_tab == 1 && g_bSec == 3) {   // 配置分区：点空白 = 这一格就这样
            if (g_bCfgSub == 0) BiliCfgEndEdit(true);
            else LinkCfgEndEdit(true);
        }
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    vector<std::string> p = SplitId(id, ':');
    if (UiNotifyClick(id)) return;   // 右上角横幅上的按钮

    // ---- B 站页自己的分区切换与配置归属
    if (p[0] == "bsec" && p.size() > 1) {
        int sec = std::atoi(p[1].c_str());
        if (sec < 0 || sec > 3) return;
        if (g_tab == 1 && g_bSec == 3 && sec != 3) {   // 离开配置前把正在编辑的格子收进内存
            if (g_bCfgSub == 0) BiliCfgEndEdit(true);
            else LinkCfgEndEdit(true);
        }
        g_bSec = sec;
        if (g_bSec == 3) {
            if (g_bCfgSub == 0) BiliCfgOpen();
            else LinkCfgOpen();
        }
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "bcfgsub" && p.size() > 1) {
        int sub = std::atoi(p[1].c_str());
        if (sub == g_bCfgSub) return;
        if (g_bCfgSub == 0) BiliCfgEndEdit(true);
        else LinkCfgEndEdit(true);
        g_bCfgSub = sub ? 1 : 0;
        if (g_bCfgSub == 0) BiliCfgOpen();
        else LinkCfgOpen();
        UiRequestRepaint();
        return;
    }
    // ---- 侧栏页签和帮助中心的分段：任何时候都认，配置分区里也得能走人
    if (p[0] == "tab") {
        g_tab = std::atoi(p[1].c_str());
        if (g_tab == 1 && g_feed.empty() && !g_feedBusy) RefreshFeed();
        if (g_tab == 2) LoadJobs();
        if (g_tab == 3) RefreshLogsNow();
        if (g_tab == 5) RefreshStatus(false);
        if (g_tab == 6) RefreshUpdates(false);
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "hsec" && p.size() > 1) {
        g_hSec = std::atoi(p[1].c_str());
        if (g_hSec == 0) RefreshUpdates(false);
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (g_tab == 1 && g_bSec == 3) {   // 配置分区里，行和按钮都归配置自己
        if (g_bCfgSub == 0) BiliCfgClick(id);
        else LinkCfgClick(id);
        return;
    }
    if (g_tab == 1 && g_bSec == 2 && p[0] == "dsh") {   // 「问一句」长在结果分区里
        DshClick(id);
        return;
    }

    if (p[0] == "svc") {
        int idx = std::atoi(p[1].c_str());
        if (p.size() > 2 && p[2] == "start") StartService(idx);
        else StopService(idx);
        return;
    }
    if (p[0] == "edit") {
        g_editFocus = 1;
        g_inputSelAll = false;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "maint" && p.size() > 1 && p[1] == "bili") {
        g_tab = 1;
        if (g_feed.empty() && !g_feedBusy) RefreshFeed();
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "bcfg") {
        g_tab = 1;
        g_bSec = 3;
        g_bCfgSub = 0;
        BiliCfgOpen();
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "lcfg") {
        g_tab = 1;
        g_bSec = 3;
        g_bCfgSub = 1;
        LinkCfgOpen();
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "bchk" && p.size() > 1) {
        // 诊断还是体检页那几条命令，只是入口挪到 B 站页上；跑完跳过去看结果
        g_editFocus = 0;
        RunCheck(std::atoi(p[1].c_str()));
        g_tab = 4;
        UiRequestRepaint();
        UiToast(L"自检在跑，结果在体检页");
        return;
    }
    if (p[0] == "bfiles") {
        OpenPath(JoinPath(RootDir(), L"out"));
        return;
    }
    if (p[0] == "bdsh") {
        if (g_dshOpen) {
            DshClose();
        } else {
            g_bSec = 2;
            DshAsk();
        }
        g_editFocus = 0;
        return;
    }
    if (p[0] == "feed") {
        g_feedSel = std::atoi(p[1].c_str());
        if (g_feedSel >= 0 && g_feedSel < (int)g_feed.size()) {
            g_bvInput = g_feed[g_feedSel].bv;
            g_bSec = 1;   // 挑好了就去看片那个分区，直接点「让她看」
            g_editFocus = 0;
        }
        UiRequestRepaint();
        return;
    }
    if (p[0] == "job") {
        g_jobSel = std::atoi(p[1].c_str());
        LoadJobDetail(g_jobSel);
        g_jobDetailScroll = 0;
        UiRequestRepaint();
        return;
    }
    if (p[0] == "logsrc") {
        g_logSrc = std::atoi(p[1].c_str());
        g_logScroll = 0;
        RefreshLogsNow();
        UiRequestRepaint();
        return;
    }
    if (p[0] == "check") {
        RunCheck(std::atoi(p[1].c_str()));
        return;
    }
    // ---- 维护页：重查 / 修复动作 / 外链 / 频率开关 / 一键操作
    if (id == "mref") { RefreshStatus(true); return; }
    // ---- 更新页：重查 / 一键换 Skill / 复制给 Agent / QQ 升级那两条路
    if (p[0] == "up" && p.size() >= 2) {
        wstring k = Utf8ToW(p[1]);
        if (k == L"refresh") { RefreshUpdates(true); return; }
        if (k == L"wbgo") { StartSelfUpdate(); return; }
        if (k == L"wbdl") {
            // 优先点这一轮查到的 release 网页（可能是具体某个 tag）；
            // 没查到就退回快照通道仓库的 releases 列表，再不行才提示去配 repo_snapshot。
            wstring url = g_up.wbUrl;
            wstring repo = g_up.wbRepo.empty() ? Trim(SettingGet(L"repo_snapshot")) : g_up.wbRepo;
            if (url.empty() && !repo.empty()) url = L"https://github.com/" + repo + L"/releases";
            if (url.empty()) {
                UiToast(L"快照通道还没配：在 settings.json 里写 repo_snapshot（owner/name）后再试");
            } else {
                OpenPath(url);
                UiToast(L"已打开 GitHub 发布页");
            }
            return;
        }
        if (k == L"qqsl") {
            const her::UpdateItem* sl = UpItem(L"snowluma");
            if (sl && sl->state == L"new") {
                CopyText(UpAskText(*sl));
                UiToast(L"已复制，粘到 DeepSeek Harness 里发出去");
            } else {
                UiToast(L"好，出了新版这里会提醒你");
            }
            return;
        }
        return;
    }
    if (p[0] == "upact" && p.size() >= 2) {
        wstring k = Utf8ToW(p[1]);
        if (k == L"skill") { RunHerOp(L"skill_update", L""); return; }
        if (const her::UpdateItem* it = UpItem(k)) {
            CopyText(UpAskText(*it));
            UiToast(L"已复制，粘到 DeepSeek Harness 里发出去");
        }
        return;
    }
    if (p[0] == "ask" && p.size() >= 2) {
        int i = std::atoi(p[1].c_str());
        int n = (int)(sizeof(ASKS) / sizeof(ASKS[0]));
        if (i >= 0 && i < n) {
            CopyText(AskBody(i));
            g_askNote = L"复制好了：「" + AskTitle(i) + L"」，粘到 DeepSeek Harness 里发出去。";
            g_askNoteAt = GetTickCount();
            UiToast(L"已复制，粘到 DeepSeek Harness 里");
        }
        return;
    }
    if (p[0] == "askedit" && p.size() >= 2) {
        OpenAskEditor(std::atoi(p[1].c_str()));
        return;
    }
    if (id == "askeditor:save") { CloseAskEditor(true); return; }
    if (id == "askeditor:cancel") { CloseAskEditor(false); return; }

    if (p[0] == "ws" && p.size() >= 2 && p[1] == "pick") { SwitchWorkspace(); return; }
    if (p[0] == "doc") {
        wstring k = Utf8ToW(p[1]);
        for (int i = 0; i < DOC_COUNT; i++) {
            if (k == DOCS[i].id) {
                g_docSel = i;
                g_docScroll = 0;
                DocLoad(i);
                UiRequestRepaint();
                return;
            }
        }
        if (k == L"readme") {
            wstring r = JoinPath(AppDir(), L"README.md");
            if (!FileExists(r)) r = JoinPath(RootDir(), L"README.md");
            if (FileExists(r)) OpenPath(r);
            else OpenPath(JoinPath(AppDir(), L"docs"));
        } else if (k == L"base") OpenPath(WorkspaceDir());
        else if (k == L"logs") OpenPath(JoinPath(RootDir(), L"logs"));
        else if (k == L"jobs") OpenPath(JobsFile());
        else if (k == L"art") OpenPath(JoinPath(RootDir(), L"art"));
        else if (k == L"bots") OpenPath(BotRoot());
        else if (k == L"shots") OpenPath(JoinPath(JoinPath(RootDir(), L"win32"), L"shots"));
        return;
    }
    if (id == "docback") { g_docSel = -1; g_docScroll = 0; UiRequestRepaint(); return; }
    if (id == "docopen") { DocOpenExternal(g_docSel); return; }
    if (p[0] == "fix") { RunHerOp(Utf8ToW(p[1]), L""); return; }
    if (p[0] == "lnk") {
        int i = std::atoi(p[1].c_str());
        if (i >= 0 && i < (int)g_mItems.size() && !g_mItems[i].linkHref.empty()) {
            std::wstring href = g_mItems[i].linkHref;
            if (href.rfind(L"http", 0) == 0) ShellExecuteW(nullptr, L"open", href.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            else OpenPath(href);
        }
        return;
    }
    if (p[0] == "freq" && p.size() >= 3) {
        wstring key = Utf8ToW(p[1]), val = Utf8ToW(p[2]);
        if (key == L"group") RunHerOp(L"group_reply", val);
        else if (key == L"meme") RunHerOp(L"meme", val);
        else if (key == L"voice") RunHerOp(L"voice", val);
        return;
    }
    if (p[0] == "op") {
        wstring op = Utf8ToW(p[1]);
        if (op == L"updates") {   // 「更新检查」把帮助中心翻到「更新」那一格，别只弹一句话
            g_tab = 6;
            g_hSec = 0;
            RefreshUpdates(true);
            UiRequestRepaint();
            return;
        }
        if (op == L"game_hint") {   // 灰的但点得动：点它就解释为什么没得打
            RefreshStatus(false);
            UiToast(g_mLoaded ? L"语音和记忆用的都是在线服务，不占这台电脑——打游戏不用关她。"
                              : L"还在查她的状态，等一秒再点。");
            return;
        }
        if (op == L"autosetup") { StartAutoSetup(); return; }
        if (op == L"feat" && p.size() >= 3) { StartFeature(Utf8ToW(p[2])); return; }
        if (op == L"watch_test") { WatchTest(); return; }
        if (op == L"watch_on") StartWatchdog();      // 本地心跳；开关文件仍然由 RunHerOp 落盘
        if (op == L"watch_off") StopWatchdog();
        if (op == L"watch_every") {
            int v = NotifyEverySeconds();
            v = (v == 30) ? 60 : (v == 60 ? 300 : 30);
            SettingSet(L"notify_every", std::to_wstring(v));
            WatchdogWake();
            RefreshStatus(true);
            UiToast(L"掉线提醒改成每 " + std::to_wstring(v) + L" 秒查一次。");
            return;
        }
        RunHerOp(op, L"");
        return;
    }
    if (id == "btn:watch") { StartWatch(); return; }
    if (id == "btn:feed") { RefreshFeed(); return; }
    if (id == "btn:goto_bili") { g_tab = 1; if (g_feed.empty() && !g_feedBusy) RefreshFeed(); UiRequestRepaint(); return; }
    if (id == "btn:goto_jobs") { g_tab = 2; LoadJobs(); UiRequestRepaint(); return; }
    if (id == "btn:goto_check") { g_tab = 4; UiRequestRepaint(); return; }
    if (id == "btn:diary") {
        if (FileExists(DiaryPath())) OpenPath(DiaryPath());
        else UiToast(L"没找到日记文件");
        return;
    }
    if (id == "btn:logdir") { OpenPath(JoinPath(RootDir(), L"logs")); return; }
    if (id == "btn:comfy") { ShellExecuteW(nullptr, L"open", L"http://127.0.0.1:8188", nullptr, nullptr, SW_SHOWNORMAL); return; }
    if (id == "btn:bilihome") { ShellExecuteW(nullptr, L"open", L"https://www.bilibili.com", nullptr, nullptr, SW_SHOWNORMAL); return; }
    if (id == "btn:allstart") {
        if (!g_svcUp[0]) StartService(0);
        if (!g_svcUp[1]) StartService(1);
        return;
    }
    if (id == "btn:allstop") {
        StopService(0);
        StopService(1);
        return;
    }
    if (id == "btn:open_sheet" && !g_result.sheet.empty()) { OpenPath(g_result.sheet); return; }
    if (id == "btn:open_cover" && !g_result.cover.empty()) { OpenPath(g_result.cover); return; }
    if (id == "btn:open_shotdir") {
        wstring p2 = g_result.sheet;
        if (!p2.empty()) {
            size_t i = p2.find_last_of(L"\\/");
            if (i != wstring::npos) { OpenPath(p2.substr(0, i)); return; }
        }
        wstring bv = g_watchBv;
        if (bv.empty() && g_jobSel >= 0 && g_jobSel < (int)g_jobs.size()) bv = g_jobs[g_jobSel].bv;
        wstring dir = bv.empty() ? JoinPath(WorkspaceDir(), L"out") : JoinPath(JoinPath(WorkspaceDir(), L"out"), bv);
        OpenPath(DirExists(dir) ? dir : JoinPath(WorkspaceDir(), L"out"));
        return;
    }
    if (id == "btn:copy") { CopyText(g_result.raw); return; }
    if (id == "btn:copy_job") { CopyText(g_jobDetail); return; }
    if (id == "btn:log_refresh") { RefreshLogsNow(); g_logScroll = 0; UiRequestRepaint(); return; }
    if (id == "btn:jobs_refresh") { LoadJobs(); UiRequestRepaint(); return; }
}

// 输入框上的右键菜单。自绘输入框没有原生 EDIT 的默认菜单，这里补一个：
// 粘贴 / 复制 / 剪切 / 全选，快捷键提示直接写在菜单项里。
void UiOnRClick(int x, int y) {
    if (g_tab != 1) return;
    if (g_bSec == 3) return;   // 配置分区的格子有自己的原生编辑框
    if (!g_rcInput.Contains(PointF((float)x, (float)y))) return;

    HMENU m = CreatePopupMenu();
    if (!m) return;
    bool has = !g_bvInput.empty();
    UINT copyFlag = MF_STRING | (has ? 0 : MF_GRAYED);
    AppendMenuW(m, MF_STRING, 1, L"粘贴\tCtrl+V");
    AppendMenuW(m, MF_STRING, 2, L"粘贴（Shift+Insert）\tShift+Insert");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, copyFlag, 3, L"复制\tCtrl+C");
    AppendMenuW(m, copyFlag, 4, L"剪切\tCtrl+X");
    AppendMenuW(m, MF_STRING, 5, L"全选\tCtrl+A");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, 6, L"清空");

    POINT pt{x, y};
    ClientToScreen(g_hwnd, &pt);
    SetForegroundWindow(g_hwnd);
    int cmd = (int)TrackPopupMenu(m, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, 0, g_hwnd,
                                  nullptr);
    DestroyMenu(m);
    switch (cmd) {
        case 1:
        case 2: InputPaste(); break;
        case 3: InputCopy(); break;
        case 4: InputCut(); break;
        case 5: InputSelectAll(); break;
        case 6:
            g_bvInput.clear();
            g_inputSelAll = false;
            UiRequestRepaint();
            break;
        default: break;
    }
}

void UiOnMove(int x, int y) {
    std::string id = HitAt(x, y);
    if (id != g_hover) {
        g_hover = id;
        bool hand = !id.empty() && (id.rfind("tab:", 0) == 0 || id.rfind("btn:", 0) == 0 || id.rfind("svc:", 0) == 0 ||
                                    id.rfind("feed:", 0) == 0 || id.rfind("job:", 0) == 0 ||
                                    id.rfind("check:", 0) == 0 || id.rfind("logsrc:", 0) == 0 ||
                                    id.rfind("ask:", 0) == 0 || id.rfind("doc:", 0) == 0 ||
                                    id.rfind("op:", 0) == 0 || id.rfind("freq:", 0) == 0 ||
                                    id.rfind("fix:", 0) == 0 || id.rfind("lnk:", 0) == 0 ||
                                    id.rfind("up:", 0) == 0 || id.rfind("upact:", 0) == 0 ||
                                    id.rfind("bcfg", 0) == 0 || id.rfind("bfiles", 0) == 0 ||
                                    id.rfind("bcfgrow:", 0) == 0 || id.rfind("bdsh", 0) == 0 ||
                                    id.rfind("bsec:", 0) == 0 ||
                                    id.rfind("lc:", 0) == 0 || id.rfind("lcrow:", 0) == 0 ||
                                    id.rfind("askedit:", 0) == 0 || id.rfind("askeditor:", 0) == 0 ||
                                    id.rfind("notify:", 0) == 0);
        SetCursor(LoadCursorW(nullptr, hand ? IDC_HAND : IDC_ARROW));
        UiRequestRepaint();
    }
}

bool UiOnWheel(int x, int y, int delta) {
    float step = -delta / 120.0f * S(52);
    auto clampf = [](float v, float content, float view) {
        float maxv = std::max(0.0f, content - view);
        return std::max(0.0f, std::min(v, maxv));
    };
    PointF pt((float)x, (float)y);
    if (g_tab == 1) {
        if (g_bSec == 0 && g_rcFeed.Contains(pt)) {
            g_feedScroll = clampf(g_feedScroll + step, S(102) * ((g_feed.size() + 1) / 2), g_rcFeed.Height);
            UiRequestRepaint();
            return true;
        }
        if (g_bSec == 2) {
            if (g_dshOpen && g_rcDsh.Contains(pt)) return DshWheel(delta);
            if (g_rcWatch.Contains(pt)) {
                g_watchScroll = clampf(g_watchScroll + step, g_watchContentH, g_watchViewH);
                UiRequestRepaint();
                return true;
            }
        }
        if (g_bSec == 3) return g_bCfgSub == 0 ? BiliCfgWheel(delta) : LinkCfgWheel(delta);
        return false;
    }
    if (g_tab == 2 && g_rcJobs.Contains(pt)) {
        g_jobsScroll = clampf(g_jobsScroll + step, S(38) * g_jobs.size(), g_rcJobs.Height);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 2 && g_rcWatch.Contains(pt)) {
        g_jobDetailScroll = clampf(g_jobDetailScroll + step, g_jobDetailH, g_jobDetailView);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 6) {
        // 帮助中心：三段各自滚自己的
        if (g_hSec == 0 && g_rcUp.Contains(pt)) {
            g_upScroll = clampf(g_upScroll + step, g_upContentH, g_upViewH);
            UiRequestRepaint();
            return true;
        }
        if (g_hSec == 2 && g_rcHelp.Contains(pt)) {
            if (g_docSel >= 0) g_docScroll = clampf(g_docScroll + step, g_helpH, g_rcHelp.Height);
            else g_helpScroll = clampf(g_helpScroll + step, g_helpH, g_rcHelp.Height);
            UiRequestRepaint();
            return true;
        }
        return false;
    }
    if (g_tab == 3 && g_rcLog.Contains(pt)) {
        g_logScroll = clampf(g_logScroll + step, g_logH, g_logView);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 4 && g_rcCheck.Contains(pt)) {
        g_checkScroll = clampf(g_checkScroll + step, g_checkH, g_checkView);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 5 && g_rcMaint.Contains(pt)) {
        g_mScroll = clampf(g_mScroll + step, g_mContentH, g_mViewH);
        UiRequestRepaint();
        return true;
    }
    return false;
}

void UiOnChar(unsigned int ch) {
    if (g_askEditor) return;   // 正在输入框里打字
    if (g_tab == 1 && g_bSec == 3) return;   // 配置分区：字符归它自己的 EDIT
    if (g_tab == 1 && g_bSec == 2 && g_dshOpen) return;   // 「问一句」面板不接受输入
    if (!g_editFocus) return;
    if (ch == 8) {
        if (g_inputSelAll) {
            g_bvInput.clear();
            g_inputSelAll = false;
        } else if (!g_bvInput.empty()) {
            g_bvInput.pop_back();
        }
        UiRequestRepaint();
        return;
    }
    if (ch == 13) {
        StartWatch();
        return;
    }
    if (ch >= 32 && ch != 127) {
        if (g_inputSelAll) {
            g_bvInput.clear();
            g_inputSelAll = false;
        }
        if (g_bvInput.size() < kInputMax) {
            g_bvInput.push_back((wchar_t)ch);
            UiRequestRepaint();
        }
    }
}

void UiOnKeyDown(int vk) {
    if (g_askEditor) return;   // 编辑卡片时按键归输入框
    if (g_tab == 1 && g_bSec == 3) {
        // 配置分区：Esc 回看片那边；正在编辑的格子先落进内存
        if (vk == VK_ESCAPE) {
            if (g_bCfgSub == 0) BiliCfgEndEdit(true);
            else LinkCfgEndEdit(true);
            g_bSec = 1;
            UiRequestRepaint();
        }
        return;
    }
    if (g_tab == 1 && g_bSec == 2 && g_dshOpen) {   // 「问一句」开着：Esc 收起
        if (vk == VK_ESCAPE) DshClose();
        return;
    }
    if (g_editFocus) {
        // 自绘输入框：编辑按键一律喂给输入框，别被「1–9 切页」「Esc」抢走
        bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (ctrl && vk == 'V') {
            InputPaste();
            return;
        }
        if (ctrl && vk == 'C') {
            InputCopy();
            return;
        }
        if (ctrl && vk == 'X') {
            InputCut();
            return;
        }
        if (ctrl && vk == 'A') {
            InputSelectAll();
            return;
        }
        if (shift && vk == VK_INSERT) {
            InputPaste();
            return;
        }
        if (vk == VK_RETURN) {
            StartWatch();
            return;
        }
    }
    if (vk == VK_ESCAPE) {
        g_editFocus = 0;
        g_inputSelAll = false;
    }
    // 1..7 直接切页签，键盘党不用摸鼠标；0 跳最后一个（帮助中心）
    int ntab = (int)(sizeof(TABS) / sizeof(TABS[0]));
    if (!g_editFocus && vk == '0') {
        g_tab = ntab - 1;
        g_hSec = 2;
        UiRequestRepaint();
        return;
    }
    if (!g_editFocus && vk >= '1' && vk <= '9') {
        int want = vk - '1';
        if (want >= ntab) want = ntab - 1;
        g_tab = want;
        if (g_tab == 1 && g_feed.empty() && !g_feedBusy) RefreshFeed();
        if (g_tab == 2) LoadJobs();
        if (g_tab == 3) RefreshLogsNow();
        if (g_tab == 5) RefreshStatus(false);
        if (g_tab == 6) {
            g_hSec = 0;
            RefreshUpdates(false);
        }
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    if (vk == VK_F5) {
        if (g_tab == 1) RefreshFeed();
        if (g_tab == 2) LoadJobs();
        if (g_tab == 3) RefreshLogsNow();
        if (g_tab == 4) {
            int a = g_checkAction;
            RunCheck(a < 0 ? 0 : a);
        }
        if (g_tab == 5) RefreshStatus(true);
        if (g_tab == 6) {
            if (g_hSec == 0) RefreshUpdates(true);
            else if (g_hSec == 1) LoadAskTexts();
            else if (g_docSel >= 0) DocLoad(g_docSel);
        }
        UiRequestRepaint();
    }
    // F9 全起 / F10 全停，跟快捷卡上那两个按钮一件事
    if (vk == VK_F9 || vk == VK_F10) {
        if (!g_svcUp[0] && vk == VK_F9) StartService(0);
        if (!g_svcUp[1] && vk == VK_F9) StartService(1);
        if (vk == VK_F10) {
            StopService(0);
            StopService(1);
        }
        UiRequestRepaint();
    }
}

void UiOnTask(TaskData* d) {
    switch (d->kind) {
        case TK_START:
        case TK_STOP:
            UiToast(d->text);
            break;
        case TK_FEED:
            g_feedBusy = false;
            g_feed = d->feed;
            g_feedScroll = 0;
            if (g_feed.empty()) {
                g_feedNote = L"没捞到候选";
                if (d->text.find(L"已看过") != wstring::npos) g_feedNote = L"候选都被看过啦";
            } else {
                g_feedNote = L"按日记口味捞的 · " + Num((long long)g_feed.size()) + L" 条";
            }
            break;
        case TK_WATCH: {
            g_watchBusy = false;
            // 换一条视频就把上一条的封面/九宫格从内存里放掉，别越攒越多
            if (!g_result.cover.empty()) DropImg(g_result.cover);
            if (!g_result.sheet.empty()) DropImg(g_result.sheet);
            if (!g_result.subs.empty()) DropImg(g_result.subs);
            const bool isLink = (d->type == L"link");
            g_linkMode = isLink;
            if (isLink) {
                // 网页没有分节、没有图，整段报告当正文画
                Debrief db;
                db.ok = d->ok;
                db.raw = d->text;
                db.title = d->title;
                db.up = d->up;
                g_result = db;
            } else {
                g_result = d->debrief;
            }
            g_hasResult = !d->text.empty();
            g_watchScroll = 0;
            g_watchStatus.clear();
            g_watchPct = 100;
            g_watchStage.clear();
            if (g_hasResult && g_tab == 1) {
                g_bSec = 2;      // 跑完就把结果推到眼前，不用自己点分区
                g_dshOpen = false;
            }
            JobRec j;
            j.t = NowUnix();
            j.bv = d->bv;
            j.title = d->title;
            j.up = d->up;
            j.source = L"console";
            j.chat = L"工作台";
            j.status = d->ok ? L"ok" : L"fail";
            j.seconds = d->seconds;
            j.type = d->type;
            wstring dir = JoinPath(JoinPath(RootDir(), L"logs"), L"jobs");
            CreateDirectoryW(dir.c_str(), nullptr);
            // 看片用 BV 命名；读网页没有 BV，就用 link-时间，老解析照旧认
            wstring baseName = isLink ? (L"link-" + Num(j.t)) : (d->bv + L"-" + Num(j.t));
            j.sink = JoinPath(dir, baseName + L".txt");
            WriteTextFile(j.sink, d->text);
            AppendJob(j);
            LoadJobs();
            if (isLink) {
                if (d->ok) UiToast(L"读完了，记在队列里了");
                else UiToast(L"没读成，原因在结果里");
            } else if (d->ok) {
                UiToast(L"看完啦，记在队列里了");
            } else {
                UiToast(L"没看成功，去体检页看看");
            }
            break;
        }
        case TK_CHECK:
            g_checkBusy = false;
            g_checkText = d->text;
            g_checkScroll = 0;
            break;
        case TK_STATUS:
            g_mBusy = false;
            g_mLoaded = d->ok;
            g_mAtTick = GetTickCount();
            if (d->ok) {
                ParseStatus(d->text);
                g_mNote = L"刚查过 · " + NowStamp();
            } else {
                g_mNote = d->text.empty() ? L"没查出来，点「求助信息」把情况发我" : L"没查出来：" + d->text;
            }
            break;
        case TK_UPDATES: {
            g_upBusy = false;
            if (d->ptr) {
                g_up = *(her::UpdatesInfo*)d->ptr;
                delete (her::UpdatesInfo*)d->ptr;
                d->ptr = nullptr;
                g_upLoaded = true;
                g_upTick = GetTickCount();
                g_upScroll = 0;
                if (!g_up.err.empty()) UiToast(g_up.err);
            }
            break;
        }
        case TK_DSHTEST: {   // 对话 API：action 1=问一句（结果浮层） 2=测试连接（链接与应用）
            wstring text = d->text;
            if (text.size() > 400) text = text.substr(0, 400) + L"…";
            if (d->action == 1) {
                g_dshBusy = false;
                g_dshText = d->ok ? d->text : (L"没问到：" + d->text);
                g_dshAt = GetTickCount();
                if (d->ok) g_dshScroll = 0;
            } else if (d->action == 2) {
                g_lcTestBusy = false;
                g_lcMsg = d->ok ? (L"连上了：" + text) : (L"没连上：" + text);
                g_lcMsgAt = GetTickCount();
                UiRequestRepaint();
            }
            if (!d->ok) UiToast(d->action == 1 ? L"对话 API 没答上来（不影响看片）" : L"对话 API 没连上（不影响看片）");
            UiRequestRepaint();
            break;
        }
        case TK_SELFUPD: {   // 工作台一键更新：安装包备好后最后确认一次，再自己关掉
            her::UpdatePlan* plan = (her::UpdatePlan*)d->ptr;
            g_upProg = -1;
            if (!d->ok || !plan) {
                g_upMsg = d->text.empty() ? wstring(L"更新没成") : d->text;
                g_upMsgAt = NowUnix();
                UiToast(g_upMsg);
            } else {
                wstring msg = L"安装包已经下好、校验过，程序文件也备份到了：\n" + plan->backupDir +
                              L"\n\n点确定就关掉工作台开始装，装完它自己会开回来。";
                if (MessageBoxW(g_hwnd, msg.c_str(), L"冥零工作台 · 更新", MB_OKCANCEL | MB_ICONINFORMATION) == IDOK) {
                    wstring err;
                    if (her::LaunchUpdateDetached(*plan, &err)) {
                        DestroyWindow(g_hwnd);
                    } else {
                        g_upMsg = L"升级程序起不来：" + err;
                        g_upMsgAt = NowUnix();
                        UiToast(g_upMsg);
                    }
                } else {
                    g_upMsg = L"先不装：安装包留在 " + plan->setup;
                    g_upMsgAt = NowUnix();
                }
            }
            delete plan;
            d->ptr = nullptr;
            UiRequestRepaint();
            break;
        }
        case TK_OP: {
            g_mBusy = false;
            bool wasUpdates = d->opName == L"updates";
            g_mOpName.clear();
            // 动作现在直接返回一句话（不再走 python 的 RESULT 行）；多行压成一行
            wstring msg;
            for (wchar_t ch : d->text) {
                if (ch == L'\n' || ch == L'\r') {
                    if (!msg.empty() && msg.back() != L' ') msg += L"  ·  ";
                } else {
                    msg += ch;
                }
            }
            if (wasUpdates) {
                if (!d->ok && msg.empty()) msg = L"查更新没成，过会儿再试";
                g_mLastOp = msg;
                UiToast(msg);
                break;
            }
            if (msg.empty()) msg = d->ok ? L"做完了" : L"没做成，点「求助信息」交给 Agent 看看";
            g_mLastOp = msg;
            UiToast(msg);
            g_mAtTick = 0;              // 动作改过东西，回来立刻重查
            RefreshStatus(true);
            break;
        }
        default: break;
    }
    delete d;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 生命周期
void UiInit(HWND hwnd) {
    g_hwnd = hwnd;
    // 首次启动：确认工作区（B站产物、日志、台账都放这里）
    if (!FileExists(SettingsFile())) {
        wstring def = DefaultWorkspaceDir();
        wstring msg = L"冥零工作台需要一个工作区，用来放 B 站产物、日志和台账。\n\n默认：" + def +
                      L"\n\n现在就选别的文件夹吗？以后也能在「B站」页右下角换。";
        if (MessageBoxW(hwnd, msg.c_str(), L"选择工作区", MB_YESNO | MB_ICONQUESTION) == IDYES) {
            wstring p = PickFolder(hwnd, L"选择冥零工作区", def);
            if (!p.empty()) SetWorkspaceDir(p);
        }
        EnsureWorkspaceLayout(WorkspaceDir());
    }
    EnsureWorkspaceLayout(WorkspaceDir());
    EnsureSecrets();   // <Base>\secrets 建出来 + README（幂等，只在缺的时候写）
    her::EnsureBundledSkill();   // 安装包自带的那份安装 Skill 铺到 %USERPROFILE%\.agents\skills（幂等）
    // 安装版（同目录有 unins000.exe）自己登记卸载项：安装器的进程写这条键会被系统拒，
    // 改由应用首次启动时补上，控制面板/设置的「应用」里就能看到并卸载。
    RegisterUninstallEntry();
    // DPI：96 为 1.0，限制在 0.8~1.75，免得布局挤爆
    {
        UINT dpi = 96;
        HMODULE u = GetModuleHandleW(L"user32.dll");
        if (u) {
            typedef UINT(WINAPI * PFN_GETDPI)(HWND);
            auto p = (PFN_GETDPI)GetProcAddress(u, "GetDpiForWindow");
            if (p) {
                UINT d = p(hwnd);
                if (d >= 72) dpi = d;
            }
        }
        g_scale = (float)dpi / 96.0f;
        if (g_scale < 0.8f) g_scale = 0.8f;
        if (g_scale > 1.75f) g_scale = 1.75f;
    }
    wstring art = JoinPath(RootDir(), L"art");
    g_artHero = JoinPath(art, L"hero.png");
    g_artAvatar = JoinPath(art, L"avatar.png");
    g_artEmpty = JoinPath(art, L"empty.png");
    LoadAskTexts();   // 求助页卡片文字：settings.json 的 custom_help_texts
    WhaleEnv we = FindWhale();
    g_whaleOk = we.ok;
    g_whaleNote = we.err;
    LoadJobs();
    g_clock = NowStamp();
    for (int i = 0; i < 2; i++) {
        int port = i == 0 ? 5099 : 6199;
        g_svcUp[i] = PortOpen(port, 80);
        g_svcPid[i] = g_svcUp[i] ? PidOnPort(port) : 0;
    }
    if (g_feed.empty()) RefreshFeed();
    if (NotifyArmed()) StartWatchdog();   // 开关开着就把本地心跳跑起来
}

void UiTick() {
    wstring c = NowStamp();
    bool dirty = (c != g_clock);
    TickNotifyBanner();
    g_clock = c;
    for (int i = 0; i < 2; i++) {
        int port = i == 0 ? 5099 : 6199;
        bool up = PortOpen(port, 60);
        DWORD pid = up ? PidOnPort(port) : 0;
        if (up != g_svcUp[i] || pid != g_svcPid[i]) {
            g_svcUp[i] = up;
            g_svcPid[i] = pid;
            dirty = true;
        }
    }
    if (g_tab == 3 && GetTickCount() - g_logStamp > 2500) {
        RefreshLogsNow();
        dirty = true;
    }
    if (g_tab == 2 && (GetTickCount() / 1000) % 3 == 0) {
        size_t before = g_jobs.size();
        LoadJobs();
        if (g_jobs.size() != before) dirty = true;
    }
    if (g_watchBusy) {
        long long el = NowUnix() - g_watchT0;
        if (el < 0) el = 0;
        wstring st = g_watchStage.empty() ? wstring(L"起手") : g_watchStage;
        wstring ns = L"正在看 " + g_watchBv + L" · " + st + L" · " + Num(el) + L"s";
        if (ns != g_watchStatus) {
            g_watchStatus = ns;
            dirty = true;
        }
        // 抽帧那一段慢，光看分节标题会一直停在 68%；按时间给个下限（10% + 1.5%/秒，封顶 95），
        // 分节标题一旦比它还快就以标题为准，这样既不会早早冲到 96，也不会看着像死了。
        int byTime = 10 + (int)(el * 1.5);
        if (byTime > 95) byTime = 95;
        if (byTime > g_watchPct) {
            g_watchPct = byTime;
            dirty = true;
        }
    }
    // 总览页 / 维护页都要看她的状态（45 秒缓存 + busy 短路，不会反复查）
    if (g_tab == 0 || g_tab == 5) RefreshStatus(false);
    if (dirty) UiRequestRepaint();
}

void UiShutdown() {
    StopWatchdog();   // 必须在 PostQuitMessage 之前 join
    FreeNotifyState();   // 横幅、自定义头像图标、编辑浮层
    CloseAskEditor(false);
    for (auto& kv : g_fonts) delete kv.second;
    g_fonts.clear();
    for (auto& kv : g_imgs)
        if (kv.second) delete kv.second;
    g_imgs.clear();
    if (g_bmp) DeleteObject(g_bmp);
    if (g_mem) DeleteDC(g_mem);
    g_bmp = nullptr;
    g_mem = nullptr;
}
