// ---------------------------------------------------------------- 更新页
// 更新页：AstrBot / SnowLuma / 安装 Skill 和工作台，
// 每行给出版本、状态和下一步；Skill 有新版能一键换，别的复制一句话交给 Agent。
// 数据来自 her::CheckUpdates()，缓存是工作台自己的 logs\cache.json。

static her::UpdatesInfo g_up;
static bool g_upBusy = false, g_upLoaded = false;
static DWORD g_upTick = 0;
static float g_upScroll = 0, g_upContentH = 0, g_upViewH = 0;
static RectF g_rcUp;

static wstring UpStamp(long long at) {
    if (at <= 0) return L"还没查过";
    time_t t = (time_t)at;
    struct tm lt;
    localtime_s(&lt, &t);
    wchar_t buf[32];
    wcsftime(buf, 32, lt.tm_year == 0 ? L"" : L"%m-%d %H:%M", &lt);
    return buf;
}

static void RefreshUpdates(bool force) {
    if (g_upBusy) return;
    if (!force && g_upLoaded) return;
    g_upBusy = true;
    std::thread([force]() {
        TaskData* d = new TaskData();
        d->kind = TK_UPDATES;
        her::UpdatesInfo* info = new her::UpdatesInfo(her::CheckUpdates(force));
        d->ptr = info;
        d->ok = true;
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

static const her::UpdateItem* UpItem(const wstring& id) {
    for (auto& it : g_up.items)
        if (it.id == id) return &it;
    return nullptr;
}

static wstring UpAskText(const her::UpdateItem& it) {
    return L"用冥零的安装 Skill（mingling-install），帮我把 " + it.name + L" 从 " + it.local + L" 更新到 " + it.latest +
           L"：先备份，只换程序，我的设置、记忆和登录都别动。";
}

// 在查哪个仓库：快照通道（settings.json 的 repo_snapshot）。没配就是空字符串，
// 界面据此说「还没配」，而不是假装在查一个不存在的仓库。
static wstring UpWbRepo() { return g_up.wbRepo; }
static wstring g_upMsg;          // 一键更新的进度 / 结果（一行话）
static long long g_upMsgAt = 0;
static int g_upProg = -1;        // 下载百分比；-1 = 没在下载

static wstring UpStateWord(const her::UpdateItem& it) {
    const wstring& st = it.state;
    if (st == L"new") return L"有新版";
    if (st == L"latest") return L"最新";
    if (st == L"unknown") return L"查不到";
    if (st == L"missing") return L"没找到";
    // 工作台自己：没配 repo_snapshot、断网、限流、仓库还没发 snapshot release，都归到这一种说法，
    // 别让人以为是工作台装坏了
    if (it.id == L"wb") return L"本机 / 没查到";
    return L"本机";
}

static ARGB UpStateColor(const wstring& st) {
    if (st == L"new") return C_ACCENT;
    if (st == L"latest") return C_OK;
    if (st == L"unknown" || st == L"missing") return C_WARN;
    return C_FAINT;
}

static bool UpSkillNotes(const her::UpdateItem& it) { return it.id == L"skill" && it.state == L"new" && !it.notes.empty(); }

static float UpRowH(const her::UpdateItem& it) {
    float h = S(92);
    if (UpSkillNotes(it)) h += (float)std::min<size_t>(it.notes.size(), 4) * S(17);
    return h;
}

static void PaintUpRow(Graphics& g, const her::UpdateItem& it, const RectF& c) {
    Card(g, c, C_PANEL, C_LINE);
    Font* nf = Fnt(TITLE_SIZE, 0, 0);
    Txt(g, it.name, RectF(c.X + S(20), c.Y + S(13), S(340), S(22)), nf, C_TEXT, 0, true);
    float nw = Tw(g, it.name, nf) + S(12);
    // 工作台那行的状态词是「本机 / 没查到」，比别的长，chip 得放宽
    float chipW = it.id == L"wb" ? S(96) : S(52);
    Chip(g, RectF(c.X + S(20) + nw, c.Y + S(14), chipW, S(19)), UpStateWord(it), UpStateColor(it.state),
         (UpStateColor(it.state) & 0x00FFFFFF) | 0x1A000000);

    // 右边：版本 + 下一步
    float rightW = S(236);
    float rx = c.X + c.Width - rightW - S(18);
    if (it.state == L"new")
        Txt(g, it.local + L"  →  " + it.latest, RectF(rx, c.Y + S(12), rightW, S(22)), Fnt(SUBTITLE_SIZE, 0, 1), C_ACCENT, 2);
    else
        Txt(g, it.local, RectF(rx, c.Y + S(12), rightW, S(22)), Fnt(SUBTITLE_SIZE, 1, 0), C_SUB, 2, true);

    if (it.state == L"new") {
        if (it.id == L"skill")
            Button(g, RectF(rx + rightW - S(104), c.Y + S(44), S(104), S(28)), g_mBusy ? L"在做…" : L"一键更新",
                   "upact:skill", 1, true, !g_mBusy);
        else if (it.id == L"wb") {
            // 工作台自己能覆盖自己：下载 → 校验 → 备份 → 静默安装 → 重启
            Button(g, RectF(rx + rightW - S(136), c.Y + S(44), S(136), S(28)),
                   g_upProg >= 0 ? (L"下载 " + Num(g_upProg) + L"%") : L"一键更新", "up:wbgo", 1, true,
                   g_upProg < 0);
            RectF rl(rx + rightW - S(136), c.Y + S(76), S(136), S(16));
            Txt(g, L"也可以去 Releases 手动下", rl, Fnt(MICRO_SIZE, Hov("up:wbdl") ? 0 : 1, 0),
                Hov("up:wbdl") ? C_ACCENT : C_FAINT, 2);
            AddHit(rl, "up:wbdl");
        }
        else
            Button(g, RectF(rx + rightW - S(136), c.Y + S(44), S(136), S(28)), L"复制给 Agent 的话", "upact:" + WToUtf8(it.id),
                   0, true, true);
    }

    // 左边：说明。新版说明按情况写，别只甩一句「有新版本」
    wstring desc = it.what;
    if (it.state == L"new" && it.id == L"skill")
        desc = L"有新版，点一下就换上，大约半分钟，她照常聊天。" + wstring(UpSkillNotes(it) ? L"这一版改了：" : L"");
    else if (it.state == L"new" && it.id == L"wb")
        desc = L"GitHub 上（" + UpWbRepo() +
               L"）有新版本了。点「一键更新」：先把她自己的程序文件备份到 <机器人根>\\旧版\\，"
               L"再静默装上新版，装完自己开回来。bots、out、logs、secrets 和你的设置都不动。";
    else if (it.id == L"wb" && it.state == L"latest")
        desc = L"已经是最新（" + UpWbRepo() + L"）。换机器时从 Releases 页面下载安装包覆盖安装就行。";
    else if (it.id == L"wb" && UpWbRepo().empty())
        desc = L"更新页还没配更新源：现在显示的是本机版本，不影响任何功能。正式版装了就会去查正式仓库的 release。";
    else if (it.id == L"wb")
        desc = L"本机就是最新一版，或者这会儿没查到 " + UpWbRepo() +
               L" 的 release——断网、被限流、仓库还没发版都会这样。查到会变成「有新版」。";
    else if (it.state == L"new")
        desc = it.what + L"有新版。升级前 Agent 会先备份，升级时她会下线一两分钟。";
    else if (it.state == L"latest")
        desc = it.what + L"已经是最新。";
    else if (it.id == L"skill" && it.state == L"local")
        desc = it.what + L"GitHub 上还没发这一版（releases 里要有 mingling-install.zip），本机是 " + it.local +
               L"；发布之后这里会变成「有新版」。";
    else if (it.state == L"missing" && it.id == L"skill")
        desc = it.what + L"这台机器上还没装这份 Skill，让 Agent 装一次就行，装完这里会显示版本号。";
    else if (it.state == L"missing")
        desc = it.what + L"这台机器上没找到它的安装目录。机器人根设置对不对、有没有装过，都能在这里看出来。";
    else if (it.state == L"unknown")
        desc = it.what + L"这会儿查不到最新版（网络不通），过会儿再看。";
    float tw = c.Width - rightW - S(60);
    TxtWrap(g, desc, RectF(c.X + S(20), c.Y + S(42), tw, S(38)), Fnt(HINT_SIZE, 1, 0), C_SUB, 0);

    if (UpSkillNotes(it)) {
        float ny = c.Y + S(42) + S(20) * 1.0f;
        size_t n = std::min<size_t>(it.notes.size(), 4);
        for (size_t i = 0; i < n; i++) {
            Txt(g, L"· " + it.notes[i], RectF(c.X + S(26), ny + i * S(17), tw, S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0,
                true);
        }
    }
}

// 侧栏「更新」上的数字：有新版的数量 + QQ 升级提醒
static int UpBadgeCount() {
    if (!g_upLoaded) return 0;
    int n = g_up.qqUpgrade ? 1 : 0;
    for (auto& it : g_up.items)
        if (it.state == L"new") n++;
    return n;
}

// 第一次画侧栏就悄悄查一轮（有 6 小时缓存，不慢），好让角标早点出来
static void UpMaybeRefresh() {
    if (!g_upLoaded && !g_upBusy) RefreshUpdates(false);
}

// 画在「帮助中心 → 更新」这一块里：坐标和尺寸由外面给
static void PaintUpdatesBody(Graphics& g, const RectF& area) {
    if (!g_upLoaded && !g_upBusy) RefreshUpdates(false);

    float x0 = area.X, y0 = area.Y, w = area.Width, h = area.Height;
    float headH = S(64), gap = S(10);

    float qqH = g_up.qqUpgrade ? S(116) : 0;
    float fullH = headH + S(6);
    if (g_up.qqUpgrade) fullH += qqH + gap;
    if (g_up.items.empty())
        fullH += S(120);
    else
        for (auto& it : g_up.items) fullH += UpRowH(it) + gap;
    fullH += S(30);
    if (!g_upMsg.empty()) fullH += S(22);

    g_upContentH = fullH;
    g_upViewH = h;
    g_rcUp = RectF(x0, y0, w, h);
    float maxScroll = std::max(0.0f, fullH - h);
    if (g_upScroll > maxScroll) g_upScroll = maxScroll;
    bool scrolls = maxScroll > 0.5f;
    if (scrolls) {
        g.SetClip(RectF(x0, y0, w, h));
        g.TranslateTransform(0.0f, -g_upScroll);
        g_drawOffY = -g_upScroll;
    }

    Txt(g, L"更新", RectF(x0, y0 + S(2), S(200), S(28)), Fnt(PAGE_TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"安装 Skill 和工作台点一下就能换；别的复制一句话交给 Agent",
        RectF(x0, y0 + S(34), w - S(240), S(18)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    Button(g, RectF(x0 + w - S(96), y0 + S(4), S(96), S(30)), g_upBusy ? L"正在查…" : L"再查一遍", "up:refresh", 0, true,
           !g_upBusy);
    Txt(g, g_up.at > 0 ? (L"上次查：" + UpStamp(g_up.at) + L" · 每 6 小时查一次") : L"正在查……",
        RectF(x0 + w - S(300), y0 + S(38), S(300), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 2, true);

    float y = y0 + headH + S(6);

    // ---- QQ 升级提醒
    if (g_up.qqUpgrade) {
        RectF q(x0, y, w, qqH);
        Round(g, q, S(14), 0xFFFFF9EC, 0xFFEAD9B4);
        Txt(g, L"桌面 QQ 像是自动升级了，登录端还没跟上", RectF(q.X + S(20), q.Y + S(14), w - S(40), S(22)),
            Fnt(SUBTITLE_SIZE, 0, 0), 0xFF8A6A22, 0);
        const her::UpdateItem* sl = UpItem(L"snowluma");
        wstring tail = (sl && sl->state == L"new")
                           ? (L"新版 " + sl->latest + L" 已经出了，复制一句话让 Agent 换上（只换程序，登录和设置都留着）。")
                           : wstring(L"它一般更新很勤，出了新版这里会提醒你，再复制一句话交给 Agent 换上。");
        TxtWrap(g, L"登录端是跟着 QQ 版本做的，QQ 自己升级以后可能挂不上。她现在要是还在线，先不用管；"
                    L"掉线后登不回来的话：" +
                       tail,
                RectF(q.X + S(20), q.Y + S(40), w - S(40), S(40)), Fnt(HINT_SIZE, 1, 0), 0xFF7A6533, 0);
        Button(g, RectF(q.X + S(20), q.Y + qqH - S(40), S(152), S(28)),
               (sl && sl->state == L"new") ? L"等登录端新版" : L"好，先等等", "up:qqsl", 0, true, true);
        y += qqH + gap;
    }

    // ---- 版本行
    if (g_up.items.empty()) {
        RectF box(x0, y, w, S(120));
        Card(g, box, C_PANEL, C_LINE);
        Txt(g, g_upBusy ? L"正在查新版本……" : L"还没查到版本，点右上「再查一遍」",
            RectF(x0, y + S(42), w, S(24)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
        Txt(g, L"第一次查要问 PyPI 和 GitHub，十几秒，不影响别的。", RectF(x0, y + S(70), w, S(18)),
            Fnt(MICRO_SIZE, 1, 0), C_FAINT, 1);
    } else {
        for (auto& it : g_up.items) {
            float rh = UpRowH(it);
            PaintUpRow(g, it, RectF(x0, y, w, rh));
            y += rh + gap;
        }
    }

    // ---- 页脚
    Txt(g, g_up.ok ? L"都查到了。" : L"有几项没查到最新版（多半是网络不通），过会儿再点「再查一遍」。",
        RectF(x0, y + S(2), w, S(18)), Fnt(MICRO_SIZE, 1, 0), g_up.ok ? C_FAINT : C_WARN, 0, true);
    if (!g_upMsg.empty()) {
        wstring line = g_upMsg;
        if (g_upProg >= 0) line += L"  " + Num(g_upProg) + L"%";
        Txt(g, line, RectF(x0, y + S(24), w, S(18)), Fnt(MICRO_SIZE, 0, 0), C_ACCENT, 0, true);
    }

    if (scrolls) {
        g.ResetTransform();
        g.ResetClip();
        ScrollBar(g, RectF(x0, y0, w, h), g_upScroll, fullH);
        g_drawOffY = 0;
    }
}

// ---------------------------------------------------------------- 工作台一键更新
// 只换程序：下载 → 校验 → 备份到 <机器人根>\旧版\ → 静默安装 → 重启。
// bots、out、logs、private、secrets 和 settings 一律不碰。
static void UpMsgSet(const wstring& s) {
    g_upMsg = s;
    g_upMsgAt = NowUnix();
    UiRequestRepaint();
}

static bool OtherWorkbenchRunning() {
    // 自己算一个；还有别的（比如命令行 --her-op 正在跑）就先别动，免得文件被占
    auto pids = her::PidsNamed(L"minglingworkbench.exe");
    return pids.size() > 1;
}

static void SelfUpdateWorker(her::SetupAsset a) {
    TaskData* d = new TaskData();
    d->kind = TK_SELFUPD;
    her::UpdatePlan* plan = new her::UpdatePlan();
    wstring err;

    wstring dir = JoinPath(StateDir(), L"updates");
    CreateDirectoryW(StateDir().c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);
    wstring dest = JoinPath(dir, a.name);

    UpMsgSet(L"正在下载 " + a.name);
    g_upProg = 0;
    unsigned long long got = 0;
    bool ok = her::DownloadFile(a.url, dest, &got, &err, [](int p) {
        g_upProg = p;
        UiRequestRepaint();
    });
    g_upProg = -1;
    if (!ok) {
        d->ok = false;
        d->text = L"下载没成：" + (err.empty() ? wstring(L"网络问题") : err);
        delete plan;
        PostTask(d);
        return;
    }
    // 大小对不上就不装：宁可说「没成」，也别装半个包
    if (a.size > 0 && got != a.size) {
        d->ok = false;
        d->text = L"下载的大小对不上（要 " + Num((long long)a.size) + L"，拿到 " + Num((long long)got) + L"），没装";
        delete plan;
        PostTask(d);
        return;
    }
    // release 上挂了 .sha256 就核对；没挂就只能信大小
    if (!a.shaUrl.empty()) {
        wstring shaPath = dest + L".sha256";
        unsigned long long sgot = 0;
        wstring serr;
        if (her::DownloadFile(a.shaUrl, shaPath, &sgot, &serr, nullptr)) {
            wstring want = Trim(ReadTextFile(shaPath));
            size_t sp = want.find_first_of(L" \t\r\n");
            if (sp != wstring::npos) want = want.substr(0, sp);
            wstring have = her::Sha256File(dest, nullptr);
            if (!want.empty() && !have.empty() && !IContains(want, have)) {
                d->ok = false;
                d->text = L"校验没通过（哈希对不上），已经放弃安装";
                delete plan;
                PostTask(d);
                return;
            }
        }
    }

    UpMsgSet(L"正在备份程序文件到 <机器人根>\\旧版\\");
    *plan = her::PlanUpdate(dest, a.tag);
    if (!plan->ok) {
        d->ok = false;
        d->text = L"备份没成：" + plan->err;
        delete plan;
        PostTask(d);
        return;
    }
    d->ok = true;
    d->text = plan->backupDir;
    d->ptr = plan;   // 交给 UiOnTask 消费
    PostTask(d);
}

static void StartSelfUpdate() {
    if (g_upProg >= 0) return;
    const her::UpdateItem* wb = UpItem(L"wb");
    if (!wb) return;
    if (wb->state != L"new" || wb->latest.empty()) {
        UiToast(L"还没查到新版：先点「再查一遍」");
        return;
    }
    if (UpWbRepo().empty()) {
        UiToast(L"还没配更新源（repo_snapshot），不知道去哪儿下");
        return;
    }
    if (OtherWorkbenchRunning()) {
        MessageBoxW(g_hwnd, L"还有一份工作台在跑（可能是命令行自检）。\n先把它关掉，再点一键更新。",
                    L"冥零工作台 · 更新", MB_OK | MB_ICONWARNING);
        return;
    }
    wstring bak = JoinPath(BotRoot(), L"旧版");
    wstring ask = L"把工作台从 " + wb->local + L" 换到 " + wb->latest + L"？\n\n" +
                  L"· 只会换她自己的程序文件（bin / sidecar / tools / pack / plugin / skill / docs / art）\n" +
                  L"· 换之前先备份到 " + bak + L"\n" +
                  L"· bots、out、logs、secrets 和你的设置都不动\n" +
                  L"· 装的时候窗口会自己关掉，装完自己开回来\n\n" +
                  L"现在开始？";
    if (MessageBoxW(g_hwnd, ask.c_str(), L"冥零工作台 · 更新", MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return;

    UpMsgSet(L"正在问 GitHub 要安装包地址");
    wstring repo = UpWbRepo();
    wstring ver = wb->latest;
    std::thread([repo, ver]() {
        her::SetupAsset a = her::FindSetupAsset(repo, ver);
        if (!a.ok) {
            TaskData* d = new TaskData();
            d->kind = TK_SELFUPD;
            d->ok = false;
            d->text = a.err;
            PostTask(d);
            return;
        }
        SelfUpdateWorker(a);
    }).detach();
}
