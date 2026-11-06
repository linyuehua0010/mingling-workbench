// ---------------------------------------------------------------- 维护页
// 把「大肥鱼工作台」那套逻辑自己做了：八张卡、四个频率、十几个按钮，
// 全部由 src\her 里的 C++ 直接查、直接改、直接启停进程。
// 不经过旧网页工作台，也不再需要任何 python 桥。

struct MItem {
    wstring id, state, name, text, fixAct, fixLbl, linkLbl, linkHref, pill;
};

static vector<MItem> g_mItems;
static wstring g_mMsg = L"—", g_mReply = L"—", g_mToken = L"—", g_mMem = L"—";
static wstring g_mGroup = L"", g_mMeme = L"", g_mVoice = L"";
// 打游戏模式的两个状态在 ui.cpp 里定义（总览页也要用，它在 ui_maint 之前 include）
static bool g_mWatchCan = false, g_mWatchOn = false, g_mWatchRun = false;
static wstring g_mWatchNote = L"";
static vector<std::pair<wstring, wstring>> g_mVers;
static wstring g_mNote = L"还没查过";
static bool g_mBusy = false, g_mLoaded = false;
static DWORD g_mAtTick = 0;
static wstring g_mOpName = L"";     // 正在做的动作（按钮上显示「在做…」）
static wstring g_mLastOp = L"";     // 上一件事的结果

static vector<wstring> SplitT(const wstring& s) {
    vector<wstring> out;
    wstring cur;
    for (wchar_t c : s) {
        if (c == L'\t') {
            out.push_back(cur);
            cur.clear();
        } else if (c != L'\r') {
            cur.push_back(c);
        }
    }
    out.push_back(cur);
    return out;
}

// 四位数以上的令牌数折成「x.x 万」，跟以前显示一致
static wstring MaintTokenText(long long t) {
    if (t >= 10000) {
        wchar_t buf[32];
        swprintf(buf, 32, L"%.1f万", t / 10000.0);
        return buf;
    }
    return std::to_wstring(t);
}

// 只在界面线程里跑：把 her::CollectStatus 编好的 TSV 摊到全局
static void ParseStatus(const wstring& raw) {
    g_mItems.clear();
    g_mVers.clear();
    g_mMsg = g_mReply = g_mToken = g_mMem = L"—";
    for (auto& line : SplitLines(raw)) {
        vector<wstring> f = SplitT(line);
        if (f.empty()) continue;
        if (f[0] == L"ITEM" && f.size() >= 10) {
            MItem it;
            it.id = f[1];
            it.state = f[2];
            it.name = f[3];
            it.text = f[4];
            it.fixAct = f[5];
            it.fixLbl = f[6];
            it.linkLbl = f[7];
            it.linkHref = f[8];
            it.pill = f[9];
            g_mItems.push_back(it);
        } else if (f[0] == L"TODAY" && f.size() >= 5) {
            if (!f[1].empty()) g_mMsg = f[1];
            if (!f[2].empty()) g_mReply = f[2];
            if (!f[3].empty()) g_mToken = f[3];
            if (!f[4].empty()) g_mMem = f[4];
        } else if (f[0] == L"FREQ" && f.size() >= 4) {
            g_mGroup = f[1];
            g_mMeme = f[2];
            g_mVoice = f[3];
        } else if (f[0] == L"GAME" && f.size() >= 6) {
            g_mGameOn = f[1] == L"1";
            g_mGameCan = f[5] == L"1";
        } else if (f[0] == L"WATCH" && f.size() >= 6) {
            g_mWatchCan = f[1] == L"1";
            g_mWatchOn = f[2] == L"1";
            g_mWatchRun = f[3] == L"1";
            g_mWatchNote = f[4];
            if (g_mWatchNote.empty()) g_mWatchNote = f[5];
        } else if (f[0] == L"VER" && f.size() >= 3) {
            if (!f[2].empty()) g_mVers.push_back({f[1], f[2]});
        }
    }
}

static void RefreshStatus(bool force) {
    if (g_mBusy) return;
    if (!force && g_mLoaded && GetTickCount() - g_mAtTick < 45000) return;
    g_mBusy = true;
    if (!g_mLoaded) g_mNote = L"正在问她好不好…";
    std::thread([]() {
        TaskData* d = new TaskData();
        d->kind = TK_STATUS;
        her::Status st;
        wstring err;
        bool ok = her::CollectStatus(st, &err);
        wstring out;
        if (ok) {
            const wstring tab(1, L'\t');
            auto add = [&](const wstring& s) {
                out += s;
                out += L'\n';
            };
            add(L"TODAY" + tab + std::to_wstring(st.stat.msgs) + tab + std::to_wstring(st.stat.replies) + tab +
                MaintTokenText(st.stat.tokens) + tab + std::to_wstring(st.stat.mems));
            add(L"FREQ" + tab + st.group + tab + st.meme + tab + st.voice);
            add(L"GAME" + tab + (st.gameOn ? L"1" : L"0") + tab + L"0" + tab + L"0" + tab + L"0" + tab +
                (st.gameCan ? L"1" : L"0"));
            add(L"WATCH" + tab + (st.watch.can ? L"1" : L"0") + tab + (st.watch.on ? L"1" : L"0") + tab +
                (st.watch.running ? L"1" : L"0") + tab + st.watch.state + tab + st.watch.note);
            for (auto& c : st.cards)
                add(L"ITEM" + tab + c.id + tab + c.state + tab + c.name + tab + c.text + tab + c.fixAct + tab +
                    c.fixLbl + tab + c.linkLbl + tab + c.linkHref + tab + c.pill);
            for (auto& v : st.vers) add(L"VER" + tab + v.first + tab + v.second);
        }
        d->ok = ok;
        d->text = ok ? out : (err.empty() ? wstring(L"没查出来") : err);
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

// 动作的中文名：头部「正在做：…」用这个，别把 updates 这种内部名字给用户看
static wstring MaintOpLabel(const wstring& name) {
    struct KV { const wchar_t* k; const wchar_t* v; };
    static const KV tbl[] = {
        {L"restart_brain", L"重启大脑"}, {L"restart_astrbot", L"重启大脑"},
        {L"start_brain", L"开大脑"},     {L"start_astrbot", L"开大脑"},
        {L"relogin", L"重登 QQ"},        {L"restart_qq", L"重启 QQ 程序"},
        {L"start_breeze", L"开语音 Breeze"}, {L"start_ollama", L"开本机 Ollama"},
        {L"backup", L"备份"},
        {L"diag", L"求助信息"},          {L"autostart_fix", L"修开机自启"},
        {L"updates", L"更新检查"},       {L"skill_update", L"更新技能"},
        {L"watch_on", L"开掉线提醒"},    {L"watch_off", L"关掉线提醒"},
        {L"watch_test", L"试一条通知"},  {L"qq_watch", L"掉线提醒"},
        {L"game_on", L"打游戏模式"},     {L"game_off", L"恢复语音记忆"},
        {L"game_off_boot", L"开机恢复"}, {L"group_reply", L"群里回复方式"},
        {L"meme", L"表情包频率"},        {L"voice", L"语音频率"},
        {L"import", L"补装"},
    };
    for (auto& kv : tbl)
        if (name == kv.k) return kv.v;
    return name;
}

// 按钮：名字跟以前一样（ui_pages.inc 里的 fix:/op:/freq: 不用改），真人干活换成 C++
static void RunHerOp(const wstring& name, const wstring& arg) {
    if (g_mBusy) {
        UiToast(L"上一件事还在做，等它一下");
        return;
    }
    g_mBusy = true;
    g_mOpName = MaintOpLabel(name);
    g_mNote = L"正在做：" + g_mOpName;
    std::thread([name, arg]() {
        TaskData* d = new TaskData();
        d->kind = TK_OP;
        d->opName = name;
        d->opArg = arg;
        her::ActionResult r = her::RunAction(name, arg);
        d->ok = r.ok;
        d->text = r.msg;
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

static ARGB StateColor(const wstring& st) {
    if (st == L"ok") return C_OK;
    if (st == L"warn") return C_WARN;
    if (st == L"busy") return C_ACCENT2;
    if (st == L"off" || st == L"unk") return 0xFFB7C2D6;   // 查询失败 ≠ 要修
    return C_ERR;
}

static wstring StateWord(const wstring& st) {
    if (st == L"ok") return L"正常";
    if (st == L"warn") return L"留意";
    if (st == L"busy") return L"在忙";
    if (st == L"off") return L"关着";
    if (st == L"unk") return L"没查到";
    return L"要修";
}

static float g_mScroll = 0;
static float g_mContentH = 0;
static float g_mViewH = 0;
static RectF g_rcMaint;

static void PaintMaint(Graphics& g) {
    float x0 = S(236), y0 = S(20), w = (float)g_w - x0 - S(24);
    float h = (float)g_h - y0 - S(22);

    // 整页高度固定，窗口矮的时候就整页滚动，别把卡片挤扁
    float headH = S(112);
    float gap = S(12);
    float opsH = S(94);
    float freqH = S(86);
    float ch = S(150);
    float fullH = headH + S(14) + ch * 2 + gap + S(14) + freqH + S(14) + opsH;
    g_mContentH = fullH;
    g_mViewH = h;
    g_rcMaint = RectF(x0, y0, w, h);
    float maxScroll = std::max(0.0f, fullH - h);
    if (g_mScroll > maxScroll) g_mScroll = maxScroll;
    bool scrolls = maxScroll > 0.5f;
    if (scrolls) {
        g.SetClip(RectF(x0, y0, w, h));
        g.TranslateTransform(0.0f, -g_mScroll);
        g_drawOffY = -g_mScroll;
    }

    // ---- 头：今天的数据
    RectF head(x0, y0, w, headH);
    Round(g, head, S(14), C_PANEL, C_LINE);
    Txt(g, L"她今天怎么样", RectF(x0 + S(22), y0 + S(16), S(420), S(26)), Fnt(PAGE_TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, g_mBusy ? g_mNote : (g_mLastOp.empty() ? g_mNote : g_mLastOp),
        RectF(x0 + S(22), y0 + S(44), w * 0.40f, S(18)), Fnt(HINT_SIZE, 1, 0), g_mBusy ? C_ACCENT : C_FAINT, 0, true);
    // 版本行
    {
        wstring v;
        for (auto& kv : g_mVers) {
            if (!v.empty()) v += L"   ·   ";
            v += kv.first + L" " + kv.second;
        }
        Txt(g, v.empty() ? L"版本还没取到" : v, RectF(x0 + S(22), y0 + headH - S(30), w * 0.55f, S(18)),
            Fnt(MICRO_SIZE, 1, 0), 0xFFA8B3C8, 0, true);
    }
    Button(g, RectF(x0 + w - S(96), y0 + S(16), S(76), S(28)), g_mBusy ? L"在查…" : L"再查一遍", "mref", 0, true, !g_mBusy);
    // 打游戏模式：开了就把本机语音/记忆先放下，她照样打字
    {
        float gbw = S(146);
        RectF gb(x0 + w - S(104) - gbw, y0 + S(16), gbw, S(28));
        bool can = g_mGameCan || g_mGameOn;
        if (g_mGameOn)
            Button(g, gb, L"打完了，恢复", "op:game_off", 1, true, !g_mBusy);
        else if (can)
            Button(g, gb, L"开打游戏模式", "op:game_on", 0, true, !g_mBusy);
        else
            Button(g, gb, L"打游戏模式", "op:game_hint", 0, true, !g_mBusy, true);   // 灰的但点得动
        if (g_mGameOn)
            Chip(g, RectF(gb.X - S(76), y0 + S(20), S(66), S(20)), L"打游戏中", C_ACCENT, 0x1F3E5FBF);
    }

    // 四格数字：宽够就横排大数字，窄了压成一行，别和右上按钮打架
    if (w < S(1100)) {
        wstring line = L"今天 " + g_mMsg + L"   回复 " + g_mReply + L"   token " + g_mToken + L"   记住 " + g_mMem;
        Txt(g, line, RectF(x0 + S(22), y0 + S(62), w - S(44), S(20)), Fnt(BODY_SIZE, 0, 0), C_SUB, 0, true);
    } else {
        const wchar_t* labels[4] = {L"今天消息", L"她的回复", L"用了 token", L"记住的事"};
        const wstring* vals[4] = {&g_mMsg, &g_mReply, &g_mToken, &g_mMem};
        float statsEnd = x0 + w - S(104) - S(166) - S(16);   // 右边要给「开打游戏模式 / 再查一遍」留位置
        float bx = x0 + w * 0.42f, bw = std::max(S(58), (statsEnd - bx) / 4.0f);
        for (int i = 0; i < 4; i++) {
            float cx = bx + i * bw;
            Txt(g, *vals[i], RectF(cx, y0 + S(30), bw - S(8), S(30)), Fnt(20, 0, 0), i == 3 ? C_ACCENT : C_TEXT, 0);
            Txt(g, labels[i], RectF(cx, y0 + S(62), bw - S(8), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0);
        }
    }

    // ---- 八张检查卡（4×2）
    float cw = (w - gap * 3) / 4.0f;
    float gy = y0 + headH + S(14);
    float bandBot = gy + ch * 2 + gap;   // 虚拟画布下沿，窗口矮时靠滚动露出来
    float gtop = gy;
    if (g_mItems.empty()) {
        RectF box(x0, gy, w, bandBot - gy);
        Round(g, box, S(14), C_PANEL, C_LINE);
        Txt(g, g_mBusy ? L"正在查…" : L"点右上「再查一遍」",
            RectF(x0, gy + (bandBot - gy) / 2 - S(12), w, S(24)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 1);
    } else {
        for (size_t i = 0; i < g_mItems.size() && i < 8; i++) {
            int col = (int)i % 4, row = (int)i / 4;
            RectF c(x0 + col * (cw + gap), gtop + row * (ch + gap), cw, ch);
            Round(g, c, S(14), C_PANEL, C_LINE);
            ARGB sc = StateColor(g_mItems[i].state);
            Dot(g, c.X + S(20), c.Y + S(24), S(4), sc);
            Txt(g, g_mItems[i].name, RectF(c.X + S(34), c.Y + S(14), c.Width - S(100), S(22)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0, true);
            Chip(g, RectF(c.X + c.Width - S(62), c.Y + S(14), S(46), S(20)), StateWord(g_mItems[i].state), sc,
                 (sc & 0x00FFFFFF) | 0x1A000000);
            if (!g_mItems[i].pill.empty())
                Txt(g, g_mItems[i].pill, RectF(c.X + c.Width - S(64), c.Y + S(38), S(54), S(14)), Fnt(MICRO_SIZE, 1, 0), C_ACCENT, 2);
            float tw = c.Width - S(40) - (g_mItems[i].pill.empty() ? 0.0f : S(56));
            {
                // 卡片高度固定，字多了要截住，别压到下面的按钮上
                RectF tr(c.X + S(20), c.Y + S(42), tw, ch - S(80));
                GraphicsState gs = g.Save();
                g.SetClip(tr);
                TxtWrap(g, g_mItems[i].text, tr, Fnt(HINT_SIZE, 1, 0), C_SUB, 0);
                g.Restore(gs);
            }
            float by = c.Y + ch - S(34);
            bool hasFix = !g_mItems[i].fixAct.empty() && g_mItems[i].fixAct != L"import";
            bool hasLnk = !g_mItems[i].linkLbl.empty();
            if (hasFix) {
                Button(g, RectF(c.X + S(16), by, S(104), S(24)), g_mItems[i].fixLbl.empty() ? L"一键修复" : g_mItems[i].fixLbl,
                       "fix:" + WToUtf8(g_mItems[i].fixAct), 1, true, !g_mBusy);
            }
            if (hasLnk) {
                float lw = S(126);
                float lx = hasFix ? c.X + S(16) + S(104) + S(8) : c.X + S(16);
                if (lx + lw > c.X + c.Width - S(12)) lx = c.X + c.Width - S(12) - lw;
                Button(g, RectF(lx, by, lw, S(24)), g_mItems[i].linkLbl,
                       "lnk:" + std::to_string(i), hasFix ? 0 : 0, true, true);
            }
        }
    }

    // ---- 三个频率开关
    float fy = bandBot + S(14);
    RectF fr(x0, fy, w, freqH);
    Round(g, fr, S(14), C_PANEL, C_LINE);
    struct Row { const wchar_t* label; const wchar_t* key; const wchar_t* const* opts; const wchar_t* const* words; int n; wstring cur; };
    static const wchar_t* GRP_OPT[4] = {L"off", L"mention", L"quote", L"both"};
    static const wchar_t* GRP_WORD[4] = {L"不 @", L"@ 对方", L"引用", L"都加"};
    static const wchar_t* LVL_OPT[3] = {L"few", L"mid", L"many"};
    static const wchar_t* LVL_WORD[3] = {L"少", L"适中", L"多"};
    static const wchar_t* WATCH_OPT[2] = {L"on", L"off"};
    static const wchar_t* WATCH_WORD[2] = {L"开", L"关"};
    Row rows[4] = {
        {L"群里回复", L"group", GRP_OPT, GRP_WORD, 4, g_mGroup},
        {L"表情包", L"meme", LVL_OPT, LVL_WORD, 3, g_mMeme},
        {L"语音", L"voice", LVL_OPT, LVL_WORD, 3, g_mVoice},
        {L"掉线提醒", L"watch", WATCH_OPT, WATCH_WORD, 2, g_mWatchOn ? L"on" : L"off"},
    };
    float colW = (w - S(44)) / 4.0f;
    for (int i = 0; i < 4; i++) {
        float cx = x0 + S(22) + i * colW;
        Txt(g, rows[i].label, RectF(cx, fy + S(14), colW - S(16), S(18)), Fnt(BODY_SIZE, 1, 0), C_FAINT, 0);
        float cy = fy + S(36);
        float chipW = S(52);
        if (i == 0) chipW = S(62);
        if (wstring(rows[i].key) == L"watch") chipW = S(46);   // 这一列还要塞间隔和「试一条」
        for (int k = 0; k < rows[i].n; k++) {
            bool sel = rows[i].cur == rows[i].opts[k];
            float px = cx + k * (chipW + S(6));
            if (px + chipW > cx + colW - S(10)) break;
            std::string id = (wstring(rows[i].key) == L"watch")
                                 ? ("op:watch_" + WToUtf8(rows[i].opts[k]))
                                 : (std::string("freq:") + WToUtf8(rows[i].key) + ":" + WToUtf8(rows[i].opts[k]));
            Round(g, RectF(px, cy, chipW, S(28)), S(9), sel ? C_ACCENT : C_PANEL2, sel ? C_ACCENT : C_LINE);
            Txt(g, rows[i].words[k], RectF(px, cy, chipW, S(28)), Fnt(HINT_SIZE, sel ? 0 : 1, 0),
                sel ? 0xFFFFFFFF : C_SUB, 1);
            AddHit(RectF(px, cy, chipW, S(28)), id);
        }
        if (wstring(rows[i].key) == L"watch") {
            {   // 间隔：点一下循环 30 秒 / 1 分 / 5 分
                int ev = _wtoi(SettingGet(L"notify_every").c_str());
                if (ev < 30) ev = 60;
                wstring evw = ev >= 300 ? L"5 分" : (ev >= 60 ? L"1 分" : L"30 秒");
                RectF er(cx + 2 * (chipW + S(6)) + S(4), cy, chipW, S(28));
                Round(g, er, S(9), C_PANEL2, C_LINE);
                Txt(g, evw, er, Fnt(HINT_SIZE, 1, 0), C_SUB, 1);
                AddHit(er, "op:watch_every");
            }
            float px = cx + 3 * (chipW + S(6)) + S(4);
            RectF tr(px, cy, S(60), S(28));
            bool en = !g_mBusy && g_mWatchCan;
            Round(g, tr, S(9), C_PANEL2, C_LINE);
            Txt(g, L"试一条", tr, Fnt(HINT_SIZE, 1, 0), en ? C_SUB : C_FAINT, 1);
            if (en) AddHit(tr, "op:watch_test");
            wstring note = !g_mWatchCan ? L"这一版没放"
                          : (g_mWatchOn ? (g_mWatchRun ? L"开着 · 后台在跑" : L"开着 · 后台没起")
                                        : L"关着 · 掉线不通知");
            Txt(g, note, RectF(cx, cy + S(32), colW - S(14), S(16)), Fnt(MICRO_SIZE, 1, 0),
                g_mWatchOn && g_mWatchRun ? C_OK : C_FAINT, 0, true);
        }
    }

    // ---- 一键操作（两排）
    float oy = y0 + fullH - opsH + S(6);
    struct Btn { const wchar_t* label; const char* id; int kind; };
    Btn rowA[6] = {
        {L"重启大脑", "op:restart_brain", 1},
        {L"重登 QQ", "op:relogin", 0},
        {L"重启 QQ 程序", "op:restart_qq", 0},
        {L"备份到桌面", "op:backup", 0},
        {L"求助信息", "op:diag", 0},
        {L"更新检查", "op:updates", 0},
    };
    Btn rowB[8] = {
        {L"开语音 Breeze", "op:start_breeze", 0},
        {L"开本机 Ollama", "op:start_ollama", 0},
        {L"打开工作区", "doc:base", 0},
        {L"修开机自启", "op:autostart_fix", 0},
        {L"一键自动配置", "op:autosetup", 1},
        {L"导入冥零人设", "op:import_skill", 0},
        {L"更新技能", "op:skill_update", 0},
        {L"打开日志", "doc:logs", 0},
    };
    const int rowN[2] = {6, 8};
    for (int row = 0; row < 2; row++) {
        Btn* btns = row == 0 ? rowA : rowB;
        float bwid = (w - S(10) * (rowN[row] - 1)) / (float)rowN[row];   // 两排按钮数不一样，各算各的宽度
        float bx2 = x0;
        for (int i = 0; i < rowN[row]; i++) {
            Button(g, RectF(bx2, oy + row * S(44), bwid, S(36)), btns[i].label, btns[i].id, btns[i].kind, false, !g_mBusy);
            bx2 += bwid + S(10);
        }
    }

    if (scrolls) {
        g.ResetTransform();
        g.ResetClip();
        ScrollBar(g, RectF(x0, y0, w, h), g_mScroll, fullH);
        g_drawOffY = 0;
    }
}

// ---------------------------------------------------------------- 一键自动配置
// 后台线程只 PostMessage，进度由窗口线程落到 g_mNote（lParam 是 new wstring，这里 delete）
void UiOnAutoCfg(int pct, wstring* step) {
    std::unique_ptr<wstring> hold(step);
    g_mNote = L"自动配置 " + std::to_wstring(pct) + L"% · " + (hold ? *hold : wstring());
    UiRequestRepaint();
}

static void StartAutoSetup() {
    if (g_mBusy) {
        UiToast(L"上一件事还在做，等它一下");
        return;
    }
    g_mBusy = true;
    g_mOpName = L"一键自动配置";
    g_mNote = L"正在看环境…";
    std::thread([]() {
        TaskData* d = new TaskData();
        d->kind = TK_OP;
        d->opName = L"autosetup";
        // 两段各占一半进度：先补齐 Node/ffmpeg/工作区，再把五个组件装进 <工作区>\bots
        her::SetupReport a = her::AutoSetup([](int pct, const std::wstring& s) {
            PostMessageW(g_hwnd, WM_APP_AUTOCFG, (WPARAM)(pct / 2), (LPARAM)new std::wstring(L"补环境：" + s));
        });
        her::SetupReport b = her::BotsSetup([](int pct, const std::wstring& s) {
            PostMessageW(g_hwnd, WM_APP_AUTOCFG, (WPARAM)(50 + pct / 2), (LPARAM)new std::wstring(L"装组件：" + s));
        });
        d->ok = a.ok && b.ok;
        d->text = a.ok ? b.summary : a.summary;
        wstring log = JoinPath(JoinPath(RootDir(), L"logs"), L"setup.log");
        for (auto& s : a.steps)
            WriteTextFile(log, (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail, true);
        for (auto& s : b.steps)
            WriteTextFile(log, (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail, true);
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}
