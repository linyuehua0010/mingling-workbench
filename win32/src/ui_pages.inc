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
static RectF g_rcInput;                // 输入框当前占的屏幕位置（右键菜单用）
static wstring ClipboardText();
static void InputPaste();
static void InputCopy();
static void InputCut();
static void InputSelectAll();
// bili-whale 配置浮层（实现在 ui_bili_cfg.inc；帮助页的浮层要一起管 Esc，所以这里先声明）
static bool g_bcfgOpen = false;
static void BiliCfgOpen();
static void BiliCfgClose(bool save);
static void BiliCfgEndEdit(bool apply);
static bool BiliCfgClick(const std::string& id);
static bool BiliCfgWheel(int delta);
static void PaintBiliCfg(Graphics& g);
// 「问一句」浮层（对话 API，实现在 ui_dsh.inc）
static bool g_dshOpen = false;
static void DshAsk();
static void DshClose();
static bool DshClick(const std::string& id);
static bool DshWheel(int delta);
static void PaintDshAsk(Graphics& g);

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
static wstring LogPath(int i) {
    if (i == 0) return JoinPath(JoinPath(BaseDir(), L"SnowLuma"), L"snowluma-run.log");
    return JoinPath(JoinPath(BaseDir(), L"astrbot"), L"run.log");
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
            const wchar_t* cand[] = {L"uv\\bin\\astrbot.exe", L"uv\\Scripts\\astrbot.exe",
                                     L"astrbot\\astrbot.exe"};
            for (const wchar_t* rel : cand) {
                wstring p = JoinPath(BaseDir(), rel);
                if (FileExists(p)) { exe = p; break; }
            }
            if (exe.empty()) {
                wchar_t found[MAX_PATH] = {0};
                if (SearchPathW(nullptr, L"astrbot.exe", nullptr, MAX_PATH, found, nullptr)) exe = found;
            }
            wchar_t pathBuf[8192] = {0};
            GetEnvironmentVariableW(L"PATH", pathBuf, 8192);
            EnvList env;
            env.emplace_back(L"PATH", JoinPath(JoinPath(BaseDir(), L"ffmpeg"), L"bin") + L";" + pathBuf);
            env.emplace_back(L"PYTHONUTF8", L"1");
            DWORD pid = 0;
            if (!exe.empty()) pid = SpawnDetached(exe, L"run", JoinPath(BaseDir(), L"astrbot"), env, LogPath(1));
            d->ok = pid != 0;
            d->text = pid ? L"AstrBot 启动了（pid " + Num(pid) + L"）"
                          : L"没找到 AstrBot：请把 AstrBot 放到 " + JoinPath(BaseDir(), L"uv\\bin") +
                            L" 或用 PATH 里的 astrbot.exe；日志见 astrbot\\run.log";
        } else {
            wstring cwd = JoinPath(BaseDir(), L"SnowLuma");
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
            d->text = pid ? L"SnowLuma 启动了（pid " + Num(pid) + L"）" : L"SnowLuma 起不来，看看 snowluma-run.log";
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

static void StartWatch() {
    if (g_watchBusy) return;
    wstring bv = ExtractBv(g_bvInput);
    if (bv.empty() && g_feedSel >= 0 && g_feedSel < (int)g_feed.size()) bv = g_feed[g_feedSel].bv;
    if (bv.empty()) {
        UiToast(L"先粘个链接，或者点左边一条选题");
        return;
    }
    wstring hint;
    for (auto& f : g_feed)
        if (f.bv == bv) hint = f.title;
    g_watchBusy = true;
    g_watchBv = bv;
    g_watchT0 = NowUnix();
    g_watchPct = 6;
    g_watchStage.clear();
    {
        std::lock_guard<std::mutex> lk(g_progMx);
        g_progPct = 0;
        g_progStage.clear();
    }
    g_watchStatus = L"正在看 " + bv + L" · 起手 · 0s";
    g_hasResult = false;
    g_watchScroll = 0;
    std::thread([bv, hint]() {
        TaskData* d = new TaskData();
        d->kind = TK_WATCH;
        d->bv = bv;
        long long t0 = NowUnix();
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
            r = RunCaptureStream(we.node, L"\"" + we.mjs + L"\" debrief " + bv + L" --grid " + BiliGridSetting(),
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
    wstring p = g_logSrc == 0 ? JoinPath(JoinPath(RootDir(), L"logs"), L"bili-whale.log") : LogPath(g_logSrc - 1);
    if (g_logSrc == 0 && !FileExists(p)) {
        // bili-whale 没有常驻服务：拿最近一次任务的输出
        g_logText = L"bili-whale 是命令行工具，没有常驻日志；最近一次任务见「队列」。";
        return;
    }
    g_logText = TailFile(p, 240, 260000);
    if (g_logText.empty()) g_logText = L"（日志是空的：服务可能还没启动过）";
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
        case 6: {   // 更新：一圈箭头
            g.DrawArc(&p, x + S(0.5f), y + S(0.5f), s2 - S(1), s2 - S(1), 40.0f, 280.0f);
            PointF tip[3] = {{x + s2 - S(2.4f), y + S(0.4f)}, {x + s2 - S(0.2f), y + S(4.6f)}, {x + s2 - S(5.2f), y + S(4.2f)}};
            g.FillPolygon(&b, tip, 3);
            g.DrawLine(&p, x + s2 * 0.5f, y + S(3.5f), x + s2 * 0.5f, y + s2 - S(3.5f));
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
    Txt(g, L"工作台 · " APP_VERSION, RectF(ax + ar * 2 + S(13), ay + S(26), S(120), S(16)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);

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
        Round(g, c, S(14), C_PANEL, C_LINE);
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
        Round(g, c, S(14), C_PANEL, C_LINE);
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
    Round(g, recent, S(14), C_PANEL, C_LINE);
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
    Round(g, quick, S(14), C_PANEL, C_LINE);
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
static void PaintBili(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    float lw = std::min(S(376), std::max(S(260), W * 0.38f));
    RectF left(x0, y0, lw, H);
    Round(g, left, S(14), C_PANEL, C_LINE);
    Txt(g, L"今晚看什么", RectF(left.X + S(22), left.Y + S(16), S(180), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, g_feedBusy ? L"正在捞…" : g_feedNote, RectF(left.X + S(22), left.Y + S(42), left.Width - S(140), S(18)),
        Fnt(HINT_SIZE, 1, 0), C_FAINT, 0);
    Button(g, RectF(left.X + left.Width - S(88), left.Y + S(14), S(66), S(28)), g_feedBusy ? L"…" : L"换一批",
           "btn:feed", 0, true, !g_feedBusy);
    {
        RectF b(left.X + left.Width - S(148), left.Y + S(18), S(52), S(22));
        bool hov = Hov("bfiles");
        Txt(g, L"产物", b, Fnt(MICRO_SIZE, hov ? 0 : 1, 0), hov ? C_ACCENT : C_ACCENT2, 2);
        AddHit(b, "bfiles");
    }
    HLine(g, left.X + S(20), left.Y + S(66), left.X + left.Width - S(20), C_LINE2);

    RectF list(left.X + S(8), left.Y + S(72), left.Width - S(16), left.Height - S(116));
    g_rcFeed = list;
    g.SetClip(list);
    float iy = list.Y - g_feedScroll;
    for (int i = 0; i < (int)g_feed.size(); i++) {
        FeedItem& f = g_feed[i];
        RectF r(list.X + S(6), iy + S(3), list.Width - S(12), S(78));
        std::string id = "feed:" + std::to_string(i);
        bool sel = (g_feedSel == i);
        if (sel) Round(g, r, S(11), C_ACCENT_S, 0x00000000);
        else if (Hov(id)) Round(g, r, S(11), 0xFFF4F8FF, 0x00000000);
        if (sel) Round(g, RectF(r.X + S(2), r.Y + S(18), S(2.6f), S(40)), S(1.3f), C_ACCENT, 0);
        Txt(g, f.title, RectF(r.X + S(16), r.Y + S(12), r.Width - S(96), S(40)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT, 0, true);
        wstring meta = f.up.empty() ? f.bv : (f.up + L"  ·  " + f.bv);
        Txt(g, meta, RectF(r.X + S(16), r.Y + S(52), r.Width - S(28), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
        wstring right;
        if (!f.dur.empty()) {
            int sec = _wtoi(f.dur.c_str());
            right = Num(sec / 60) + L":" + Pad2(sec % 60);
        }
        Txt(g, right, RectF(r.X + r.Width - S(60), r.Y + S(12), S(46), S(18)), Fnt(HINT_SIZE, 1, 0), C_ACCENT2, 2);
        AddHit(r, id);
        iy += S(82);
    }
    g.ResetClip();
    ScrollBar(g, list, g_feedScroll, S(82) * g_feed.size());
    if (g_feed.empty()) {
        Txt(g, g_feedBusy ? L"正在筛…" : L"点右上「换一批」捞选题",
            RectF(list.X, list.Y + S(40), list.Width, S(24)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    }

    // ---- 底部：当前工作区（产物落这里，点一下可以换）
    {
        float wy = left.Y + left.Height - S(38);
        HLine(g, left.X + S(20), wy - S(8), left.X + left.Width - S(20), C_LINE2);
        Txt(g, L"工作区", RectF(left.X + S(20), wy, S(52), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0);
        Txt(g, WorkspaceDir(), RectF(left.X + S(20) + S(50), wy, left.Width - S(150), S(16)), Fnt(MICRO_SIZE, 1, 0),
            C_SUB, 0, true);
        RectF b(left.X + left.Width - S(92), wy - S(5), S(72), S(26));
        bool hov = Hov("ws:pick");
        Round(g, b, S(8), hov ? C_ACCENT_S : 0x00000000, 0x00000000);
        Txt(g, L"换工作区", b, Fnt(MICRO_SIZE, hov ? 0 : 1, 0), hov ? C_ACCENT : C_ACCENT2, 1);
        AddHit(b, "ws:pick");
    }

    float rx = x0 + lw + S(16);
    float rw = (float)g_w - rx - S(24);
    RectF ed(rx, y0, rw - S(122), S(46));
    g_rcInput = ed;
    Round(g, ed, S(12), g_editFocus ? 0xFFFFFFFF : C_PANEL2, g_editFocus ? C_ACCENT2 : C_LINE);
    float txx = ed.X + S(16);
    if (g_bvInput.empty()) {
        Txt(g, L"粘贴 B站 链接或 BV 号…（Ctrl+V / 右键）", RectF(txx, ed.Y, ed.Width - S(24), ed.Height),
            Fnt(SUBTITLE_SIZE, 1, 0), 0xFFAAB5C9, 0);
    } else {
        RectF tr(txx, ed.Y, ed.Width - S(24), ed.Height);
        if (g_inputSelAll) Round(g, RectF(ed.X + S(3), ed.Y + S(3), ed.Width - S(6), ed.Height - S(6)), S(9),
                                 0x2E3E5FBF, 0x00000000);
        Txt(g, g_bvInput, tr, Fnt(SUBTITLE_SIZE, 0, 0), g_inputSelAll ? C_ACCENT : C_TEXT, 0, true);
    }
    AddHit(ed, "edit:bv");
    Button(g, RectF(ed.X + ed.Width + S(12), y0, S(110), S(46)), g_watchBusy ? L"看着呢…" : L"让她看", "btn:watch", 1,
           false, !g_watchBusy);

    wstring status = g_watchBusy ? g_watchStatus : (g_hasResult ? L"看完了 · 结果在下面" : L"读字幕、弹幕、热评，再看几帧画面");
    if (!g_watchStatus.empty() && g_watchBusy) status = g_watchStatus;
    Txt(g, status, RectF(rx, y0 + S(54), rw, S(20)), Fnt(HINT_SIZE, 1, 0), g_watchBusy ? C_ACCENT : C_FAINT, 0, true);
    if (g_watchBusy) {
        RectF bar(rx, y0 + S(76), rw, S(3));
        Round(g, bar, S(1.5f), 0x1A3E5FBF, 0, 0);
        float wd = rw * (g_watchPct / 100.0f);
        if (wd > S(3)) Round(g, RectF(rx, y0 + S(76), wd, S(3)), S(1.5f), C_ACCENT, 0, 0);
    }

    // ---- B 站相关的入口都收在这一条上：配置、诊断（登录/配额/风控/自检）、产物
    {
        float sy = y0 + S(86), bh = S(28), sx = rx;
        Button(g, RectF(sx, sy, S(120), bh), L"bili-whale 配置", "bcfg", 0, true);
        sx += S(128);
        const wchar_t* diag[] = {L"登录", L"配额", L"风控", L"自检"};
        const int dact[] = {0, 2, 3, 4};
        for (int i = 0; i < 4; i++) {
            Button(g, RectF(sx, sy, S(56), bh), diag[i], "bchk:" + std::to_string(dact[i]), 0, true);
            sx += S(62);
        }
        if (sx + S(60) < rx + rw) Button(g, RectF(sx, sy, S(56), bh), L"产物", "bfiles", 0, true);
        sx += S(62);
        if (sx + S(72) < rx + rw) Button(g, RectF(sx, sy, S(72), bh), L"问一句", "bdsh", 0, true);
    }

    RectF res(rx, y0 + S(122), rw, H - S(122));
    Round(g, res, S(14), C_PANEL, C_LINE);

    bool hasArt = g_hasResult && (!g_result.sheet.empty() || !g_result.cover.empty());
    float artW = hasArt ? S(268) : 0;
    RectF textArea(res.X + S(22), res.Y + S(18), res.Width - S(44) - artW, res.Height - S(36));
    g_rcWatch = textArea;
    g_watchViewH = textArea.Height;

    if (!g_hasResult) {
        Image* em = LoadImg(g_artEmpty);
        float ih = std::min(res.Height - S(110), S(300) * g_scale);
        if (em && ih > S(80)) {
            float iw = ih * (float)em->GetWidth() / (float)em->GetHeight();
            DrawImgFill(g, em, RectF(res.X + res.Width / 2 - iw / 2, res.Y + S(46), iw, ih), 0.0f, 0.0f, 1.0f, 1.0f);
        }
        Txt(g, g_watchBusy ? (L"正在看… " + Num((long long)g_watchPct) + L"%") : L"她还没看过视频", RectF(res.X, res.Y + res.Height - S(58), res.Width, S(24)),
            Fnt(TITLE_SIZE, 0, 0), C_SUB, 1);
    } else {
        float total = DrawRich(g, g_result.raw, textArea, g_watchScroll);
        g_watchContentH = total;
        ScrollBar(g, textArea, g_watchScroll, total);
        if (hasArt) {
            float ax = res.X + res.Width - artW + S(6);
            float ay = res.Y + S(20);
            Image* cover = g_result.cover.empty() ? nullptr : LoadImg(g_result.cover);
            if (cover) {
                Round(g, RectF(ax, ay, artW - S(20), S(150)), S(10), C_PANEL2, C_LINE);
                GraphicsPath cp;
                cp.AddArc(ax, ay, S(20), S(20), 180, 90);
                cp.AddArc(ax + artW - S(20) - S(20), ay, S(20), S(20), 270, 90);
                cp.AddArc(ax + artW - S(20) - S(20), ay + S(150) - S(20), S(20), S(20), 0, 90);
                cp.AddArc(ax, ay + S(150) - S(20), S(20), S(20), 90, 90);
                cp.CloseFigure();
                g.SetClip(&cp);
                DrawImgFill(g, cover, RectF(ax, ay, artW - S(20), S(150)), 0, 0, 1, 1);
                g.ResetClip();
                AddHit(RectF(ax, ay, artW - S(20), S(150)), "btn:open_cover");
                ay += S(162);
            }
            Image* sheet = g_result.sheet.empty() ? nullptr : LoadImg(g_result.sheet);
            if (sheet) {
                float sh = artW - S(20);
                float ih2 = sh * (float)sheet->GetHeight() / (float)sheet->GetWidth();
                Round(g, RectF(ax, ay, sh, ih2), S(10), C_PANEL2, C_LINE);
                GraphicsPath sp;
                sp.AddEllipse(-1, -1, 1, 1);
                g.SetClip(RectF(ax, ay, sh, ih2));
                DrawImgFill(g, sheet, RectF(ax, ay, sh, ih2), 0, 0, 1, 1);
                g.ResetClip();
                AddHit(RectF(ax, ay, sh, ih2), "btn:open_sheet");
                ay += ih2 + S(10);
            }
            if (ay + S(64) < res.Y + res.Height) {
                Button(g, RectF(ax, ay, (artW - S(28)) / 2, S(30)), L"打开文件夹", "btn:open_shotdir", 0, true);
                Button(g, RectF(ax + (artW - S(28)) / 2 + S(8), ay, (artW - S(28)) / 2, S(30)), L"复制全文",
                       "btn:copy", 0, true);
            }
        }
    }
    if (g_bcfgOpen) PaintBiliCfg(g);   // 配置浮层最后画，命中区盖在最上面
    if (g_dshOpen) PaintDshAsk(g);
}

// ---------------------------------------------------------------- 队列
static void PaintJobs(Graphics& g) {
    float x0 = S(236), y0 = S(22), W = (float)g_w - x0 - S(24), H = (float)g_h - S(44);
    float th = H * 0.50f;
    RectF table(x0, y0, W, th);
    Round(g, table, S(14), C_PANEL, C_LINE);
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
    Round(g, detail, S(14), C_PANEL, C_LINE);
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
    Round(g, panel, S(14), C_PANEL, C_LINE);
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
    Round(g, panel, S(14), C_PANEL, C_LINE);
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
#include "ui_help.inc"
#include "ui_bili_cfg.inc"
#include "ui_dsh.inc"

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
        case 6: PaintUpdates(g); break;
        case 7: PaintSetup(g); break;
        case 8: PaintAsk(g); break;
        case 9: PaintHelp(g); break;
        default: PaintHelp(g); break;
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
    if (g_dshOpen) {   // 「问一句」浮层开着：点哪儿都先归它
        DshClick(id);
        return;
    }
    if (g_bcfgOpen) {   // 配置浮层开着：点哪儿都先归它，别让下面的页签偷偷响应
        if (id.empty()) BiliCfgEndEdit(true);   // 点空白 = 这一格就这样
        BiliCfgClick(id);
        return;
    }
    if (id.empty()) {
        if (g_askEditor) {   // 点空白等于「就这样」：存下来再收
            CloseAskEditor(true);
            return;
        }
        g_editFocus = 0;
        UiRequestRepaint();
        return;
    }
    vector<std::string> p = SplitId(id, ':');
    if (UiNotifyClick(id)) return;   // 右上角横幅上的按钮
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
        BiliCfgOpen();
        g_editFocus = 0;
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
        DshAsk();
        g_editFocus = 0;
        return;
    }
    if (p[0] == "feed") {
        g_feedSel = std::atoi(p[1].c_str());
        if (g_feedSel >= 0 && g_feedSel < (int)g_feed.size()) {
            g_bvInput = g_feed[g_feedSel].bv;
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
        if (op == L"updates") {   // 「更新检查」把更新页翻出来，别只弹一句话
            g_tab = 6;
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
    if (g_bcfgOpen || g_dshOpen) return;
    if (g_tab != 1) return;
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
                                    id.rfind("askedit:", 0) == 0 || id.rfind("askeditor:", 0) == 0 ||
                                    id.rfind("notify:", 0) == 0);
        SetCursor(LoadCursorW(nullptr, hand ? IDC_HAND : IDC_ARROW));
        UiRequestRepaint();
    }
}

bool UiOnWheel(int x, int y, int delta) {
    if (g_dshOpen) return DshWheel(delta);
    if (g_bcfgOpen) return BiliCfgWheel(delta);
    float step = -delta / 120.0f * S(52);
    auto clampf = [](float v, float content, float view) {
        float maxv = std::max(0.0f, content - view);
        return std::max(0.0f, std::min(v, maxv));
    };
    PointF pt((float)x, (float)y);
    if (g_tab == 1 && g_rcFeed.Contains(pt)) {
        g_feedScroll = clampf(g_feedScroll + step, S(82) * g_feed.size(), g_rcFeed.Height);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 1 && g_rcWatch.Contains(pt)) {
        g_watchScroll = clampf(g_watchScroll + step, g_watchContentH, g_watchViewH);
        UiRequestRepaint();
        return true;
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
    if (g_tab == 7 && g_rcSetup.Contains(pt)) {
        g_setScroll = clampf(g_setScroll + step, g_setContentH, g_setViewH);
        UiRequestRepaint();
        return true;
    }
    if (g_tab == 9 && g_rcHelp.Contains(pt)) {
        g_helpScroll = clampf(g_helpScroll + step, g_helpH, g_rcHelp.Height);
        UiRequestRepaint();
        return true;
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
    if (g_tab == 6 && g_rcUp.Contains(pt)) {
        g_upScroll = clampf(g_upScroll + step, g_upContentH, g_upViewH);
        UiRequestRepaint();
        return true;
    }
    return false;
}

void UiOnChar(unsigned int ch) {
    if (g_askEditor) return;   // 正在输入框里打字
    if (g_bcfgOpen) return;    // 配置浮层：字符归它自己的 EDIT
    if (g_dshOpen) return;     // 「问一句」浮层：不接受输入
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
    if (g_dshOpen) {           // 「问一句」浮层：Esc 关掉，1–9 不切页
        if (vk == VK_ESCAPE) DshClose();
        return;
    }
    if (g_bcfgOpen) {          // 配置浮层：Esc 关掉，1–9 照样不切页
        if (vk == VK_ESCAPE) BiliCfgClose(false);
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
    // 1..9 直接切页签，键盘党不用摸鼠标
    if (!g_editFocus && (vk == '0')) {   // 0 = 最后一个页签（帮助）
        g_tab = 9;
        UiRequestRepaint();
        return;
    }
    if (!g_editFocus && vk >= '1' && vk <= '9') {
        g_tab = vk - '1';
        if (g_tab == 1 && g_feed.empty() && !g_feedBusy) RefreshFeed();
        if (g_tab == 2) LoadJobs();
        if (g_tab == 3) RefreshLogsNow();
        if (g_tab == 5) RefreshStatus(false);
        if (g_tab == 6) RefreshUpdates(false);
        UiRequestRepaint();
        return;
    }
    if (vk == VK_F5) {
        if (g_tab == 1) RefreshFeed();
        if (g_tab == 2) LoadJobs();
        if (g_tab == 3) RefreshLogsNow();
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
            g_result = d->debrief;
            g_hasResult = !d->text.empty();
            g_watchScroll = 0;
            g_watchStatus.clear();
            g_watchPct = 100;
            g_watchStage.clear();
            JobRec j;
            j.t = NowUnix();
            j.bv = d->bv;
            j.title = d->title;
            j.up = d->up;
            j.source = L"console";
            j.chat = L"工作台";
            j.status = d->ok ? L"ok" : L"fail";
            j.seconds = d->seconds;
            wstring dir = JoinPath(JoinPath(RootDir(), L"logs"), L"jobs");
            CreateDirectoryW(dir.c_str(), nullptr);
            j.sink = JoinPath(dir, d->bv + L"-" + Num(j.t) + L".txt");
            WriteTextFile(j.sink, d->text);
            AppendJob(j);
            LoadJobs();
            if (d->ok) UiToast(L"看完啦，记在队列里了");
            else UiToast(L"没看成功，去体检页看看");
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
        case TK_DSHTEST: {   // DSH 对话 API：action 0=测连接（配置浮层） 1=问一句（看片结果）
            wstring text = d->text;
            if (text.size() > 400) text = text.substr(0, 400) + L"…";
            if (d->action == 1) {
                g_dshBusy = false;
                g_dshText = d->ok ? d->text : (L"没问到：" + d->text);
                g_dshAt = GetTickCount();
                if (d->ok) g_dshScroll = 0;
            } else {
                g_bcfgTestBusy = false;
                g_bcfgMsg = d->ok ? (L"连上了：" + text) : (L"没连上：" + text);
                g_bcfgMsgAt = GetTickCount();
            }
            if (!d->ok) UiToast(d->action == 1 ? L"对话 API 没答上来（不影响看片）" : L"对话 API 没连上（不影响看片）");
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
