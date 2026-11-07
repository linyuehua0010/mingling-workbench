// ---------------------------------------------------------------- 帮助中心
// 原来「更新 / 求助 / 帮助」三页并成一页：上面是标题和三颗胶囊，下面三段各自滚动。
// 三段都还是同一批代码（更新页的 UpRow、求助的十一张卡、帮助的 FAQ + 教程），
// 只是坐标由这里给，所以点开的动作、--her-op 的路径、改字浮层全都没变。

static int g_hSec = 0;   // 0 更新 / 1 求助 / 2 帮助

static void PaintHChips(Graphics& g, float x, float y) {
    static const wchar_t* names[3] = {L"更新", L"求助", L"帮助"};
    float cw = S(76), gap = S(8);
    for (int i = 0; i < 3; i++) {
        RectF r(x + i * (cw + gap), y, cw, S(32));
        std::string id = "hsec:" + std::to_string(i);
        bool sel = (g_hSec == i);
        bool hov = Hov(id.c_str());
        Round(g, r, S(10), sel ? C_ACCENT : (hov ? C_ACCENT_S : C_PANEL2), sel ? C_ACCENT : C_LINE);
        Txt(g, names[i], r, Fnt(SUBTITLE_SIZE, sel ? 0 : 1, 0), sel ? 0xFFFFFFFF : C_SUB, 1);
        AddHit(r, id.c_str());
    }
}

static void PaintHelpCenter(Graphics& g) {
    float x0 = S(236), y0 = S(20), w = (float)g_w - x0 - S(24);
    float h = (float)g_h - y0 - S(22);
    float headH = S(64);

    RectF head(x0, y0, w, headH);
    Card(g, head, C_PANEL, C_LINE);
    Txt(g, L"帮助中心", RectF(x0 + S(22), y0 + S(14), S(220), S(28)), Fnt(PAGE_TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"更新、求助、帮助都在这儿；出问题先看这里。", RectF(x0 + S(150), y0 + S(20), S(360), S(18)),
        Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    PaintHChips(g, x0 + w - S(268), y0 + S(16));

    RectF body(x0, y0 + headH + S(12), w, (y0 + h) - (y0 + headH + S(12)));
    if (g_hSec == 0) PaintUpdatesBody(g, body);
    else if (g_hSec == 1) PaintAskBody(g, body);
    else PaintHelpBody(g, body);
}
