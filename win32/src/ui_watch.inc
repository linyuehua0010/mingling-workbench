// ---------------------------------------------------------------- 掉线提醒（本地心跳）
// 每 NotifyEverySeconds() 秒看一眼 SnowLuma / AstrBot /（本机语音开着时）Breeze 还在不在：
// 端口能连、或者 <工作区>\bots\<目录> 下还有它的进程，都算在。连续两次没见到才认定掉线，
// 免得它自己重启的那两三秒也被当成掉线。发现掉线就 PostMessage(WM_APP_NOTIFY)，
// 由窗口线程弹托盘气泡（可以换成她的头像）+ 右上角滑进来一条横幅。
//
// 文案和头像都在 settings.json 里换，不用改代码：
//   notify_title   标题，默认「冥零 · 掉线提醒」
//   notify_body    正文，默认「哎呀，{name} 掉线了，快重启一下大脑吧~」，{name} {time} 会替换
//   notify_avatar  自定义头像 png（绝对路径；不填就用 art\avatar.png）
//   notify_every   多久查一次，30–600 秒，默认 60
// 关掉提醒还是在 <机器人根>\private\qq-watch-off.txt 放个文件（维护页那个开关写的就是它）。

struct WatchSvc {
    const wchar_t* name;     // 显示名
    const wchar_t* dir;      // <工作区>\bots 下的目录名
    const wchar_t* oldRel;   // 老布局在 <机器人根> 下的相对路径
    int port;                // 它自己监听的端口（0 = 不看端口）
    const wchar_t* act;      // 横幅上「重启一下」按哪个动作
    bool voiceOnly;          // 只有选了本机 Breeze 语音才盯它
};

static const WatchSvc WATCH_SVC[] = {
    {L"QQ", L"SnowLuma", L"SnowLuma", 5099, L"relogin", false},
    {L"AstrBot（大脑）", L"AstrBot", L"astrbot", 6199, L"restart_brain", false},
    {L"Breeze（本机语音）", L"Breeze", L"breeze-tts", 8137, L"start_breeze", true},
};
static const int WATCH_N = (int)(sizeof(WATCH_SVC) / sizeof(WATCH_SVC[0]));

static std::atomic<bool> g_hbStop{false};
static HANDLE g_hbWake = nullptr;
static std::thread g_hbThread;
static int g_hbEvery = 60;
static DWORD g_hbMuteUntil = 0;

static int NotifyEverySeconds() {
    int v = _wtoi(SettingGet(L"notify_every").c_str());
    if (v < 30 || v > 600) v = 60;
    return v;
}

static bool NotifyArmed() {
    return !FileExists(JoinPath(JoinPath(BaseDir(), L"private"), L"qq-watch-off.txt"));
}

// 显示用一个短名字：「AstrBot（大脑）」→「AstrBot」（去掉括号里的补语）
static std::wstring SvcShort(const WatchSvc& s) {
    std::wstring n = s.name;
    size_t p = n.find(L'（');
    if (p == std::wstring::npos) p = n.find(L'(');
    if (p != std::wstring::npos) n = n.substr(0, p);
    return Trim(n);
}

// settings.json 里可以带 {name} / {time}；不配就用默认那句
static std::wstring NotifyTpl(const wchar_t* key, const wchar_t* def, const WatchSvc& s) {
    std::wstring t = SettingGet(key);
    if (Trim(t).empty()) t = def;
    t = ReplaceAll(t, L"{name}", SvcShort(s));
    t = ReplaceAll(t, L"{time}", NowStamp());
    return t;
}

static std::wstring Lc(const std::wstring& s) {
    std::wstring r = s;
    for (auto& c : r)
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
    return r;
}

// 端口通、或者它的目录下还有进程，都算活着
static bool SvcRunning(const WatchSvc& s) {
    if (s.port > 0 && PortOpen(s.port, 250) && PidOnPort(s.port) != 0) return true;
    std::wstring bot = JoinPath(BotRoot(), s.dir);
    if (DirExists(bot) && !her::PidsUnder(Lc(bot)).empty()) return true;
    std::wstring oldp = JoinPath(BaseDir(), s.oldRel);
    if (DirExists(oldp) && !her::PidsUnder(Lc(oldp)).empty()) return true;
    return false;
}

// ---------------------------------------------------------------- 横幅 + 托盘图标
static NotifyReq* g_notify = nullptr;
static DWORD g_notifyAt = 0;

static HICON g_balloonIcon = nullptr;
static std::wstring g_balloonPath;

HICON UiBalloonIcon(const std::wstring& png, int size) {
    if (png.empty() || size <= 0 || !FileExists(png)) return nullptr;
    if (g_balloonIcon && g_balloonPath == png) return g_balloonIcon;
    if (g_balloonIcon) {   // 换了头像：旧图标得还回去，不然 GDI 句柄一直涨
        DestroyIcon(g_balloonIcon);
        g_balloonIcon = nullptr;
        g_balloonPath.clear();
    }
    Image* im = LoadImg(png);
    if (!im) return nullptr;
    Bitmap bmp(size, size, PixelFormat32bppARGB);
    {
        Graphics bg(&bmp);
        bg.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        bg.SetPixelOffsetMode(PixelOffsetModeHalf);
        float iw = (float)im->GetWidth(), ih = (float)im->GetHeight();
        float side = std::min(iw, ih);
        bg.DrawImage(im, RectF(0.0f, 0.0f, (float)size, (float)size), (iw - side) / 2, (ih - side) / 2, side, side,
                     UnitPixel);
    }
    HBITMAP hb = nullptr;
    if (bmp.GetHBITMAP(Color(0, 0, 0, 0), &hb) != Ok || !hb) return nullptr;
    ICONINFO ii{};
    ii.fIcon = TRUE;
    ii.hbmColor = hb;
    ii.hbmMask = CreateBitmap(size, size, 1, 1, nullptr);
    HICON ic = CreateIconIndirect(&ii);
    DeleteObject(hb);
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    if (!ic) return nullptr;
    g_balloonIcon = ic;
    g_balloonPath = png;
    return ic;
}

static void FreeNotifyState() {
    if (g_notify) {
        delete g_notify;
        g_notify = nullptr;
    }
    if (g_balloonIcon) {
        DestroyIcon(g_balloonIcon);
        g_balloonIcon = nullptr;
    }
    g_balloonPath.clear();
    g_notifyAt = 0;
}

// 后台线程把每条提醒的指针交过来，这里接管（唯一的所有者）
void UiOnNotify(NotifyReq* r) {
    if (!r) return;
    if (g_notify) delete g_notify;
    g_notify = r;
    g_notifyAt = GetTickCount();
    TickNotifyBanner();
    UiRequestRepaint();
}

static void CloseNotify() {
    if (g_notify) {
        delete g_notify;
        g_notify = nullptr;
    }
    g_notifyAt = 0;
    UiRequestRepaint();
}

// 横幅自己收：放 15 秒 + 收起的 350ms
static void TickNotifyBanner() {
    if (!g_notify) return;
    if (GetTickCount() - g_notifyAt > 15350) CloseNotify();
}

static void PaintNotifyBanner(Graphics& g) {
    if (!g_notify) return;
    const DWORD ANIM_IN = 350, HOLD_MS = 15000, ANIM_OUT = 350;
    DWORD age = GetTickCount() - g_notifyAt;
    float p = 1.0f;
    if (age < ANIM_IN) p = (float)age / (float)ANIM_IN;
    else if (age > HOLD_MS) p = 1.0f - (float)(age - HOLD_MS) / (float)ANIM_OUT;
    if (p <= 0.02f) return;

    float w = S(408), h = S(108);
    float x = (float)g_w - w - S(22) + (1.0f - p) * (w + S(32));
    float y = S(18);
    RectF r(x, y, w, h);

    // 先垫一层淡影子，压在卡片上也看得清
    Round(g, RectF(x + S(2), y + S(5), w, h), S(14), 0x22000000, 0x00000000);
    Round(g, r, S(14), C_PANEL, C_ACCENT);

    float av = S(46);
    RectF ar(x + S(16), y + S(16), av, av);
    Image* im = LoadImg(g_notify->avatar.empty() ? g_artAvatar : g_notify->avatar);
    if (im) {
        GraphicsPath clip;
        clip.AddEllipse(ar);
        GraphicsState st = g.Save();
        g.SetClip(&clip);
        DrawImgFill(g, im, ar, 0.0f, 0.0f, 1.0f, 1.0f);
        g.Restore(st);
    } else {
        Round(g, ar, av / 2, C_ACCENT_S, C_ACCENT);
        Dot(g, ar.X + ar.Width / 2, ar.Y + ar.Height / 2, av * 0.18f, C_ACCENT);
    }

    float tx = ar.X + ar.Width + S(14);
    float tw = w - (tx - x) - S(16);
    Txt(g, g_notify->title, RectF(tx, y + S(14), tw, S(22)), Fnt(SUBTITLE_SIZE, 1, 0), C_TEXT, 0, true);
    TxtWrap(g, g_notify->body, RectF(tx, y + S(40), tw, S(42)), Fnt(HINT_SIZE, 0, 0), C_SUB, 0);

    Button(g, RectF(x + w - S(206), y + h - S(38), S(92), S(26)), L"重启一下", "notify:fix", 1, true, true);
    Button(g, RectF(x + w - S(106), y + h - S(38), S(92), S(26)), L"知道了", "notify:close", 0, true, true);
}

// 横条上的两个按钮；返回 true 表示这条 id 归它管
static bool UiNotifyClick(const std::string& id) {
    if (id == "notify:close") {
        CloseNotify();
        return true;
    }
    if (id == "notify:fix") {
        std::wstring act = g_notify ? g_notify->act : std::wstring();
        CloseNotify();
        if (!act.empty()) RunHerOp(act, L"");
        return true;
    }
    return false;
}

// 维护页「试一条」：不真的重启，只看看气泡和横条长什么样
static void WatchTest() {
    const WatchSvc& s = WATCH_SVC[0];
    NotifyReq* r = new NotifyReq();
    r->title = NotifyTpl(L"notify_title", L"冥零 · 掉线提醒", s);
    r->body = L"（试一条）" + NotifyTpl(L"notify_body", L"哎呀，{name} 掉线了，快重启一下大脑吧~", s);
    r->avatar = SettingGet(L"notify_avatar");
    r->act = s.act;
    if (g_hwnd) PostMessageW(g_hwnd, WM_APP_NOTIFY, 0, (LPARAM)r);
}

// ---------------------------------------------------------------- 心跳
static void WatchdogTick(bool first) {
    static int miss[WATCH_N] = {0}, seen[WATCH_N] = {0};
    static DWORD lastAt[WATCH_N] = {0};
    DWORD now = GetTickCount();
    for (int i = 0; i < WATCH_N; i++) {
        const WatchSvc& s = WATCH_SVC[i];
        if (s.voiceOnly && her::Voice() != 4) {   // 没在用本机语音，就不该盯它
            miss[i] = 0;
            seen[i] = 0;
            continue;
        }
        if (SvcRunning(s)) {
            miss[i] = 0;
            seen[i] = 1;
            continue;
        }
        if (++miss[i] < 2 || !seen[i]) continue;   // 没见过它活着 / 只断了一下：先不吓人
        if (now < g_hbMuteUntil) continue;
        if (lastAt[i] && now - lastAt[i] < 10 * 60 * 1000) continue;   // 同一条十分钟内只报一次
        lastAt[i] = now;
        miss[i] = 0;
        if (first) continue;

        NotifyReq* r = new NotifyReq();
        r->title = NotifyTpl(L"notify_title", L"冥零 · 掉线提醒", s);
        r->body = NotifyTpl(L"notify_body", L"哎呀，{name} 掉线了，快重启一下大脑吧~", s);
        r->avatar = SettingGet(L"notify_avatar");
        r->act = s.act;
        PostMessageW(g_hwnd, WM_APP_NOTIFY, 0, (LPARAM)r);

        std::wstring logDir = JoinPath(BaseDir(), L"logs");
        if (DirExists(logDir)) {
            std::wstring js = L"{\"at\":" + std::to_wstring((long long)NowUnix()) + L",\"every\":" +
                              std::to_wstring(g_hbEvery) + L",\"what\":\"" + SvcShort(s) + L"\"}";
            WriteTextFile(JoinPath(logDir, L"workbench-watch.json"), js);
        }
    }
}

static void WatchdogLoop() {
    WatchdogTick(true);
    while (!g_hbStop.load()) {
        DWORD r = WaitForSingleObject(g_hbWake, (DWORD)g_hbEvery * 1000);
        if (g_hbStop.load()) break;
        g_hbEvery = NotifyEverySeconds();
        if (r == WAIT_TIMEOUT) WatchdogTick(false);
    }
}

static void WatchdogWake() {
    if (g_hbWake) SetEvent(g_hbWake);
}

static void StopWatchdog() {
    g_hbStop.store(true);
    if (g_hbWake) SetEvent(g_hbWake);
    if (g_hbThread.joinable()) g_hbThread.join();
    if (g_hbWake) {
        CloseHandle(g_hbWake);
        g_hbWake = nullptr;
    }
}

static void StartWatchdog() {
    if (g_hbThread.joinable()) return;
    if (!NotifyArmed()) return;
    g_hbStop.store(false);
    g_hbEvery = NotifyEverySeconds();
    if (!g_hbWake) g_hbWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_hbThread = std::thread(WatchdogLoop);
}

// 打游戏 / 看电影那会儿先别弹
static void MuteWatchdogFor(int seconds) {
    if (seconds < 0) seconds = 0;
    g_hbMuteUntil = GetTickCount() + (DWORD)seconds * 1000;
}
