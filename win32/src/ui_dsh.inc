// ---------------------------------------------------------------- 问一句（对话 API）
// 把「刚看完的这条」交给外部对话接口解释一下：只看片的结果，不挡看片的主链路。
// 没配、断网、限流都只在这张浮层里说一句，B 站页别的按钮照旧能用。
static wstring g_dshText;
static wstring g_dshErr;
static bool g_dshBusy = false;
static DWORD g_dshAt = 0;
static float g_dshScroll = 0, g_dshContentH = 0, g_dshViewH = 0;
static RectF g_rcDsh;

// 拿结果的标题、来源和前几节的要点拼一段背景，别把整份 raw 塞过去。
// 看片和读链接共用这一个入口：链接结果没有分节，就退回正文前 1200 字。
static wstring DshPrompt() {
    wstring p = g_linkMode
                    ? L"你在帮人理解一个刚读到的网页。请用中文，三到六句话，直接讲清这页在说什么、值不值得细看，不要客套。\n"
                    : L"你在帮人理解一条刚看完的 B 站视频。请用中文，三到六句话，直接讲清讲了什么、值不值得看，不要客套。\n";
    if (!g_result.title.empty()) p += L"标题：" + g_result.title + L"\n";
    if (!g_result.up.empty()) p += (g_linkMode ? L"来源：" : L"UP：") + g_result.up + L"\n";
    wstring body;
    for (int i = 0; i < 8 && body.size() < 1200; i++) {
        if (g_result.section[i].empty()) continue;
        body += g_result.section[i] + L"\n";
    }
    if (body.empty() && !g_result.raw.empty()) {
        body = g_result.raw.size() > 1200 ? g_result.raw.substr(0, 1200) : g_result.raw;
    }
    if (body.empty()) return p + L"（还没有结果，先随便说一句问候。）";
    if (body.size() > 1500) body.resize(1500);
    p += (g_linkMode ? L"她读到的正文：\n" : L"她看完记下的要点：\n") + body;
    return p;
}

// 工作线程里问，结果回 TK_DSHTEST(action=1)
static void DshRun() {
    DshApiCfg cfg = DshApiLoad();
    wstring prompt = DshPrompt();
    JobRec memory;
    memory.t = NowUnix(); memory.bv = g_watchBv; memory.title = g_result.title;
    memory.status = g_result.ok ? L"ok" : L"fail"; memory.type = L"api";
    std::thread([cfg, prompt, memory]() {
        TaskData* d = new TaskData();
        d->kind = TK_DSHTEST;
        d->action = 1;
        wstring reply, err;
        d->ok = DshChat(prompt, cfg, &reply, &err);
        d->text = d->ok ? reply : err;
        if (d->ok && memory.status == L"ok" && !QueueJobMemory(memory, prompt + L"\n对话回复：\n" + reply))
            d->text += L"\n（回复成功，但长期记忆排队失败。）";
        PostTask(d);
    }).detach();
}

static void DshAsk() {
    DshApiCfg cfg = DshApiLoad();
    if (!cfg.enabled) {
        UiToast(L"对话 API 还没启用：B 站页 → 链接与应用 → 启用对话 API");
        return;
    }
    if (cfg.base.empty()) {
        UiToast(L"还没填 Base URL：B 站页 → 链接与应用");
        return;
    }
    g_dshOpen = true;
    g_dshBusy = true;
    g_dshText = L"正在问…";
    g_dshErr.clear();
    g_dshScroll = 0;
    g_dshAt = GetTickCount();
    UiRequestRepaint();
    DshRun();
}

static void DshClose() {
    g_dshOpen = false;
    g_dshBusy = false;
    UiRequestRepaint();
}

static bool DshClick(const std::string& id) {
    vector<std::string> p = SplitId(id, ':');
    if (p.size() > 1 && p[0] == "dsh") {
        if (p[1] == "close") {
            DshClose();
            return true;
        }
        if (p[1] == "again") {
            if (!g_dshBusy) {
                g_dshBusy = true;
                g_dshText = L"正在问…";
                g_dshAt = GetTickCount();
                UiRequestRepaint();
                DshRun();
            }
            return true;
        }
        if (p[1] == "copy") {
            CopyText(g_dshText);
            return true;
        }
    }
    if (id.empty() && !g_dshBusy) {
        // 点空白不关：结果可能正看着，关它得点按钮
        return true;
    }
    return true;   // 浮层开着，别的点击一律吞掉
}

static bool DshWheel(int delta) {
    if (!g_dshOpen) return false;
    float maxScroll = std::max(0.0f, g_dshContentH - g_dshViewH);
    g_dshScroll += -delta / 120.0f * S(52);
    if (g_dshScroll < 0) g_dshScroll = 0;
    if (g_dshScroll > maxScroll) g_dshScroll = maxScroll;
    UiRequestRepaint();
    return true;
}

static void PaintDshAsk(Graphics& g, const RectF& panel) {
    DshApiCfg cfg = DshApiLoad();
    const float pw = panel.Width;
    const float ph = panel.Height;
    g_rcDsh = panel;
    Round(g, panel, S(12), C_PANEL2, C_LINE);
    Txt(g, L"问一句", RectF(panel.X + S(20), panel.Y + S(12), pw - S(40), S(24)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT, 0);
    wstring sub = cfg.model.empty() ? wstring(L"对话 API") : (L"对话 API · " + cfg.model);
    Txt(g, sub, RectF(panel.X + S(20), panel.Y + S(38), pw - S(40), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0, true);
    HLine(g, panel.X + S(18), panel.Y + S(58), panel.X + panel.Width - S(18), C_LINE2);

    RectF body(panel.X + S(20), panel.Y + S(70), panel.Width - S(40), ph - S(70) - S(52));
    g_dshViewH = body.Height;
    float total = 0;
    if (g_dshBusy) {
        Txt(g, g_dshText, RectF(body.X, body.Y, body.Width, S(24)), Fnt(BODY_SIZE, 1, 0), C_ACCENT, 0, true);
    } else {
        total = DrawRich(g, g_dshText, body, g_dshScroll);
        g_dshContentH = total;
        ScrollBar(g, body, g_dshScroll, total);
    }
    if (!g_dshErr.empty())
        Txt(g, g_dshErr, RectF(panel.X + S(20), panel.Y + ph - S(50), pw - S(200), S(18)), Fnt(HINT_SIZE, 1, 0),
            C_ERR, 0, true);

    float by = panel.Y + ph - S(40);
    Button(g, RectF(panel.X + pw - S(280), by, S(80), S(28)), L"复制", "dsh:copy", 0, true, !g_dshBusy);
    Button(g, RectF(panel.X + pw - S(192), by, S(88), S(28)), L"再问一次", "dsh:again", 0, true, !g_dshBusy);
    Button(g, RectF(panel.X + pw - S(96), by, S(76), S(28)), L"收起", "dsh:close", 1, true);
}
