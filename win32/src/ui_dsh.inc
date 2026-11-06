// ---------------------------------------------------------------- 问一句（对话 API）
// 把「刚看完的这条」交给外部对话接口解释一下：只看片的结果，不挡看片的主链路。
// 没配、断网、限流都只在这张浮层里说一句，B 站页别的按钮照旧能用。
static wstring g_dshText;
static wstring g_dshErr;
static bool g_dshBusy = false;
static DWORD g_dshAt = 0;
static float g_dshScroll = 0, g_dshContentH = 0, g_dshViewH = 0;
static RectF g_rcDsh;

// 拿 debrief 的标题、UP 和前几节的要点拼一段背景，别把整份 raw 塞过去
static wstring DshPrompt() {
    wstring p = L"你在帮人理解一条刚看完的 B 站视频。请用中文，三到六句话，直接讲清讲了什么、值不值得看，不要客套。\n";
    if (!g_result.title.empty()) p += L"标题：" + g_result.title + L"\n";
    if (!g_result.up.empty()) p += L"UP：" + g_result.up + L"\n";
    wstring body;
    for (int i = 0; i < 8 && body.size() < 1200; i++) {
        if (g_result.section[i].empty()) continue;
        body += g_result.section[i] + L"\n";
    }
    if (body.empty() && !g_result.raw.empty()) {
        body = g_result.raw.size() > 1200 ? g_result.raw.substr(0, 1200) : g_result.raw;
    }
    if (body.empty()) return p + L"（还没有看片结果，先随便说一句问候。）";
    if (body.size() > 1500) body.resize(1500);
    p += L"她看完记下的要点：\n" + body;
    return p;
}

// 工作线程里问，结果回 TK_DSHTEST(action=1)
static void DshRun() {
    DshApiCfg cfg = DshApiLoad();
    wstring prompt = DshPrompt();
    std::thread([cfg, prompt]() {
        TaskData* d = new TaskData();
        d->kind = TK_DSHTEST;
        d->action = 1;
        wstring reply, err;
        d->ok = DshChat(prompt, cfg, &reply, &err);
        d->text = d->ok ? reply : err;
        PostTask(d);
    }).detach();
}

static void DshAsk() {
    DshApiCfg cfg = DshApiLoad();
    if (!cfg.enabled) {
        UiToast(L"对话 API 还没启用：B 站页 → 配置 → 启用对话 API");
        return;
    }
    if (cfg.base.empty()) {
        UiToast(L"还没填 Base URL：B 站页 → 配置");
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

static void PaintDshAsk(Graphics& g) {
    SolidBrush dim(Color(0x7A, 0x15, 0x20, 0x38));
    g.FillRectangle(&dim, 0, 0, (int)g_w, (int)g_h);

    DshApiCfg cfg = DshApiLoad();
    float pw = std::min(S(760), (float)g_w - S(80));
    float ph = std::min(S(560), (float)g_h - S(80));
    RectF panel(((float)g_w - pw) / 2, ((float)g_h - ph) / 2, pw, ph);
    g_rcDsh = panel;
    Round(g, panel, S(16), C_PANEL, C_LINE);
    Txt(g, L"问一句", RectF(panel.X + S(26), panel.Y + S(14), pw - S(52), S(26)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    wstring sub = cfg.model.empty() ? wstring(L"对话 API") : (L"对话 API · " + cfg.model);
    Txt(g, sub, RectF(panel.X + S(26), panel.Y + S(42), pw - S(52), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0, true);
    HLine(g, panel.X + S(24), panel.Y + S(64), panel.X + panel.Width - S(24), C_LINE2);

    RectF body(panel.X + S(26), panel.Y + S(78), panel.Width - S(52), ph - S(78) - S(60));
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
        Txt(g, g_dshErr, RectF(panel.X + S(26), panel.Y + ph - S(58), pw - S(240), S(18)), Fnt(HINT_SIZE, 1, 0),
            C_ERR, 0, true);

    float by = panel.Y + ph - S(44);
    Button(g, RectF(panel.X + pw - S(300), by, S(84), S(30)), L"复制", "dsh:copy", 0, true, !g_dshBusy);
    Button(g, RectF(panel.X + pw - S(208), by, S(84), S(30)), L"再问一次", "dsh:again", 0, true, !g_dshBusy);
    Button(g, RectF(panel.X + pw - S(116), by, S(90), S(30)), L"收起", "dsh:close", 1, true);
}
