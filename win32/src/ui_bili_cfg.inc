// ---------------------------------------------------------------- bili-whale 配置
// 整份配置读进内存，逐行改；点「保存」才落盘：先备份 .bak-<时间>，写完重新解析校验，
// 解析不过就回滚。读进来什么样就写回去什么样——只改界面上这几处，未知键一个都不动。
#include "biliapi.h"

static her::J g_bcfgRoot;
static wstring g_bcfgPath;
static wstring g_bcfgMsg;
static DWORD g_bcfgMsgAt = 0;
static float g_bcfgScroll = 0, g_bcfgContentH = 0, g_bcfgViewH = 0;
static RectF g_rcBcfg;
static HWND g_bcfgEdit = nullptr;
static int g_bcfgEditRow = -1;

static float BcfgRowH(const BiliCfgField& f) { return f.kind == 2 ? S(44) : S(56); }

static float BcfgTotalH() {
    float h = 0;
    for (const BiliCfgField& f : BiliCfgFields()) h += BcfgRowH(f) + S(6);
    return h;
}

static float BcfgTop(const RectF& panel) { return panel.Y + S(76); }

static void BcfgRowRects(const RectF& panel, std::vector<RectF>& out) {
    out.clear();
    float y = BcfgTop(panel) - g_bcfgScroll;
    for (const BiliCfgField& f : BiliCfgFields()) {
        float h = BcfgRowH(f);
        out.push_back(RectF(panel.X + S(18), y, panel.Width - S(36), h));
        y += h + S(6);
    }
}

// ---------------------------------------------------------------- 编辑：借一个原生 EDIT
static void BiliCfgEndEdit(bool apply) {
    if (!g_bcfgEdit) {
        g_bcfgEditRow = -1;
        return;
    }
    wstring text;
    if (apply) {
        int n = GetWindowTextLengthW(g_bcfgEdit);
        text.resize((size_t)n + 1);
        GetWindowTextW(g_bcfgEdit, &text[0], n + 1);
        text.resize((size_t)n);
    }
    DestroyWindow(g_bcfgEdit);
    g_bcfgEdit = nullptr;
    int row = g_bcfgEditRow;
    g_bcfgEditRow = -1;
    if (apply && row >= 0 && row < (int)BiliCfgFields().size()) {
        const BiliCfgField& f = BiliCfgFields()[row];
        wstring err;
        if (!BiliCfgApply(g_bcfgRoot, f, text, &err)) {
            g_bcfgMsg = err;
            g_bcfgMsgAt = GetTickCount();
        }
    }
    SetFocus(g_hwnd);
    UiRequestRepaint();
}

static void BiliCfgBeginEdit(int row) {
    BiliCfgEndEdit(true);
    const auto& fs = BiliCfgFields();
    if (row < 0 || row >= (int)fs.size()) return;
    std::vector<RectF> rs;
    BcfgRowRects(g_rcBcfg, rs);
    if (row >= (int)rs.size()) return;
    RectF r = rs[row];
    // 编辑框只认屏幕坐标：行是在滚动区里画的，这里直接算到位
    float bw = S(300), x = r.X + r.Width - bw - S(6), y = r.Y + S(9);
    wstring val = BiliCfgShow(g_bcfgRoot, fs[row]);
    g_bcfgEdit = CreateWindowExW(0, L"EDIT", val.c_str(), WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_BORDER,
                                 (int)x, (int)y, (int)bw, (int)S(30), g_hwnd, (HMENU)0x9103,
                                 GetModuleHandleW(nullptr), nullptr);
    if (!g_bcfgEdit) return;
    SendMessageW(g_bcfgEdit, WM_SETFONT, (WPARAM)AskEditorFont(), TRUE);
    SendMessageW(g_bcfgEdit, EM_SETSEL, 0, -1);
    SetFocus(g_bcfgEdit);
    g_bcfgEditRow = row;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 开 / 关
static void BiliCfgOpen() {
    if (g_bcfgOpen) {
        UiRequestRepaint();
        return;
    }
    wstring err;
    BiliCfgLoad(g_bcfgRoot, &err);
    g_bcfgPath = BiliCfgPath();
    g_bcfgMsg = err;
    g_bcfgMsgAt = err.empty() ? 0 : GetTickCount();
    g_bcfgOpen = true;
    g_bcfgScroll = 0;
    UiRequestRepaint();
}

static void BiliCfgClose(bool save) {
    BiliCfgEndEdit(save);   // 取消时正在编辑的那格不写进内存
    if (save) {
        wstring err;
        if (BiliCfgSave(g_bcfgRoot, &err)) UiToast(L"配置已保存，旧文件备份成 .bak-时间");
        else UiToast(L"没保存成：" + err);
    }
    g_bcfgOpen = false;
    g_bcfgScroll = 0;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 绘制
static void PaintBiliCfg(Graphics& g) {
    SolidBrush dim(Color(0x7A, 0x15, 0x20, 0x38));
    g.FillRectangle(&dim, 0, 0, (int)g_w, (int)g_h);

    float pw = std::min(S(800), (float)g_w - S(80));
    float ph = std::min(S(660), (float)g_h - S(80));
    RectF panel(((float)g_w - pw) / 2, ((float)g_h - ph) / 2, pw, ph);
    g_rcBcfg = panel;
    Round(g, panel, S(16), C_PANEL, C_LINE);
    Txt(g, L"bili-whale 配置", RectF(panel.X + S(26), panel.Y + S(14), pw - S(52), S(26)), Fnt(TITLE_SIZE, 0, 0),
        C_TEXT, 0);
    Txt(g, g_bcfgPath, RectF(panel.X + S(26), panel.Y + S(42), pw - S(52), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT,
        0, true);
    HLine(g, panel.X + S(24), panel.Y + S(64), panel.X + panel.Width - S(24), C_LINE2);

    // 行：滚动的部分单独裁一块，别画到标题和按钮上
    RectF view(panel.X + S(8), panel.Y + S(70), panel.Width - S(16), ph - S(70) - S(62));
    g_bcfgViewH = view.Height;
    float maxScroll = std::max(0.0f, BcfgTotalH() - view.Height);
    if (g_bcfgScroll > maxScroll) g_bcfgScroll = maxScroll;
    if (g_bcfgScroll < 0) g_bcfgScroll = 0;
    g_bcfgContentH = BcfgTotalH();

    g.SetClip(view);
    std::vector<RectF> rs;
    BcfgRowRects(panel, rs);
    const auto& fs = BiliCfgFields();
    for (size_t i = 0; i < fs.size(); i++) {
        const BiliCfgField& f = fs[i];
        const RectF& r = rs[i];
        if (r.Y + r.Height < view.Y - S(4) || r.Y > view.Y + view.Height + S(4)) continue;
        std::string id = "bcfgrow:" + std::to_string(i);
        bool ro = (f.kind == 4);
        if (!ro && Hov(id)) Round(g, r, S(10), 0xFFF4F8FF, 0x00000000);
        Txt(g, f.label, RectF(r.X + S(12), r.Y + S(8), r.Width - S(330), S(20)), Fnt(BODY_SIZE, 0, 0),
            ro ? C_FAINT : C_TEXT, 0, true);
        if (!f.hint.empty())
            Txt(g, f.hint, RectF(r.X + S(12), r.Y + S(30), r.Width - S(330), S(18)), Fnt(MICRO_SIZE, 1, 0), C_FAINT,
                0, true);
        wstring val = BiliCfgShow(g_bcfgRoot, f);
        RectF vb(r.X + r.Width - S(306), r.Y + S(9), S(300), S(30));
        if (f.kind == 2) {
            RectF chip(vb.X, vb.Y + S(4), S(72), S(22));
            bool on = (val == L"开");
            Round(g, chip, S(11), on ? 0x1F3F8F72 : 0x14000000, 0x00000000);
            Txt(g, val, chip, Fnt(HINT_SIZE, 0, 0), on ? C_OK : C_FAINT, 1);
        } else {
            Round(g, vb, S(9), ro ? C_PANEL2 : 0xFFFBFDFF, ro ? 0x00000000 : C_LINE);
            Txt(g, val.empty() ? (ro ? wstring() : wstring(L"（空）")) : val,
                RectF(vb.X + S(12), vb.Y, vb.Width - S(24), vb.Height), Fnt(HINT_SIZE, 1, 0),
                ro ? C_FAINT : (val.empty() ? C_FAINT : C_SUB), 0, true);
        }
        if (!ro) AddHit(r, id);
    }
    g.ResetClip();
    ScrollBar(g, view, g_bcfgScroll, BcfgTotalH());

    // 底：提示 + 保存 / 取消
    float by = panel.Y + ph - S(46);
    if (!g_bcfgMsg.empty()) {
        bool bad = g_bcfgMsg.find(L"没") != wstring::npos || g_bcfgMsg.find(L"要") != wstring::npos ||
                   g_bcfgMsg.find(L"不能") != wstring::npos;
        Txt(g, g_bcfgMsg, RectF(panel.X + S(26), by + S(6), pw - S(260), S(20)), Fnt(HINT_SIZE, 1, 0),
            bad ? C_ERR : C_OK, 0, true);
    } else {
        Txt(g, L"改完点保存。别的键原样留着，不会丢。", RectF(panel.X + S(26), by + S(6), pw - S(260), S(20)),
            Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    }
    Button(g, RectF(panel.X + pw - S(214), by, S(96), S(30)), L"保存", "bcfg:save", 1, true);
    Button(g, RectF(panel.X + pw - S(110), by, S(84), S(30)), L"取消", "bcfg:cancel", 0, true);
}

// ---------------------------------------------------------------- 点击 / 滚轮 / 按键
static bool BiliCfgClick(const std::string& id) {
    vector<std::string> p = SplitId(id, ':');
    if (p.empty()) return true;
    if (p[0] == "bcfg") {
        if (p.size() > 1 && p[1] == "save") BiliCfgClose(true);
        else if (p.size() > 1 && p[1] == "cancel") BiliCfgClose(false);
        return true;
    }
    if (p[0] == "bcfgrow" && p.size() > 1) {
        int i = std::atoi(p[1].c_str());
        const auto& fs = BiliCfgFields();
        if (i < 0 || i >= (int)fs.size()) return true;
        const BiliCfgField& f = fs[i];
        if (f.kind == 4) {
            g_bcfgMsg = L"这一项结构比较复杂，要改就编辑配置文件";
            g_bcfgMsgAt = GetTickCount();
            UiRequestRepaint();
            return true;
        }
        if (f.kind == 2) {
            BiliCfgEndEdit(true);
            wstring err;
            wstring nv = (BiliCfgShow(g_bcfgRoot, f) == L"开") ? L"关" : L"开";
            if (!BiliCfgApply(g_bcfgRoot, f, nv, &err)) {
                g_bcfgMsg = err;
                g_bcfgMsgAt = GetTickCount();
            }
            UiRequestRepaint();
            return true;
        }
        BiliCfgBeginEdit(i);
        return true;
    }
    return true;   // 浮层开着，别的点击一律吞掉
}

static bool BiliCfgWheel(int delta) {
    if (!g_bcfgOpen) return false;
    float maxScroll = std::max(0.0f, BcfgTotalH() - g_bcfgViewH);
    g_bcfgScroll += -delta / 120.0f * S(52);
    if (g_bcfgScroll < 0) g_bcfgScroll = 0;
    if (g_bcfgScroll > maxScroll) g_bcfgScroll = maxScroll;
    UiRequestRepaint();
    return true;
}
