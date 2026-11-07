// ---------------------------------------------------------------- 链接与应用
// 一个面板管两件事：怎么读网页链接、怎么连对话 API（「问一句」用的那个）。
// 以前这两样塞在 bili-whale 配置浮层的下半截，用户找不到；现在单独一页。
//
// 保存规则跟 bili 配置一样：先备份 .bak-<时间> → 改键 → 整份重新解析 → 不对就回滚；
// 没列出来的键原样保留。API Key 只写 secrets\dsh-api-key.txt，不进 settings.json。
#include "biliapi.h"

static LinkCfg g_lcLink;   // g_lcOpen 声明在 ui_pages.inc 顶部
static DshApiCfg g_lcApi;
static wstring g_lcMsg;
static DWORD g_lcMsgAt = 0;
static float g_lcScroll = 0, g_lcContentH = 0, g_lcViewH = 0;
static RectF g_rcLc;
static HWND g_lcEdit = nullptr;
static int g_lcEditRow = -1;
static bool g_lcTestBusy = false;

struct LcRowDef {
    const wchar_t* id;
    const wchar_t* label;
    const wchar_t* hint;
    int kind;   // 0 文本 1 数字 2 布尔 5 密钥
};

static const LcRowDef kLinkRows[] = {
    {L"link_enabled", L"读取网页链接", L"关掉之后粘网页链接只会提示，不去读", 2},
    {L"link_timeout", L"超时（秒）", L"默认 15 秒；上限就是 15 秒，只能调小", 1},
    {L"link_maxkb", L"大小上限（KB）", L"默认 512 KB；上限不放宽，只能调小", 1},
    {L"link_ua", L"User-Agent", L"留空 = 内置那句；填了就用你的（300 字以内）", 0},
};
static const int kLinkRowCount = (int)(sizeof(kLinkRows) / sizeof(kLinkRows[0]));

static const LcRowDef kApiRows[] = {
    {L"enabled", L"启用对话 API", L"关掉只是「问一句」不能用，别的功能照旧", 2},
    {L"base", L"Base URL", L"OpenAI 兼容的接口根地址，例如 https://api.deepseek.com/v1", 0},
    {L"path", L"路径", L"默认 /chat/completions（拼在 Base URL 后面）", 0},
    {L"model", L"模型名", L"例如 deepseek-chat", 0},
    {L"timeout", L"超时（秒）", L"5–300，只影响这一路对话，不挡看片", 1},
    {L"key", L"API Key", L"存到 secrets\\dsh-api-key.txt，不写 settings.json", 5},
};
static const int kApiRowCount = (int)(sizeof(kApiRows) / sizeof(kApiRows[0]));

struct LcRow {
    int src = 1;   // 0=小标题 1=读链接 2=对话 API
    int idx = 0;
};
static std::vector<LcRow> g_lcRows;

static void LcBuildRows() {
    g_lcRows.clear();
    g_lcRows.push_back({0, 0});
    for (int i = 0; i < kLinkRowCount; i++) g_lcRows.push_back({1, i});
    g_lcRows.push_back({0, 1});
    for (int i = 0; i < kApiRowCount; i++) g_lcRows.push_back({2, i});
}

static float LcRowH(const LcRow& row) {
    if (row.src == 0) return S(38);
    int kind = row.src == 1 ? kLinkRows[row.idx].kind : kApiRows[row.idx].kind;
    return kind == 2 ? S(44) : S(56);
}

static float LcTotalH() {
    if (g_lcRows.empty()) LcBuildRows();
    float h = 0;
    for (const LcRow& r : g_lcRows) h += LcRowH(r) + S(6);
    return h;
}

static void LcRowRects(const RectF& panel, std::vector<RectF>& out) {
    if (g_lcRows.empty()) LcBuildRows();
    out.clear();
    float y = panel.Y + S(76) - g_lcScroll;
    for (const LcRow& row : g_lcRows) {
        float h = LcRowH(row);
        out.push_back(RectF(panel.X + S(18), y, panel.Width - S(36), h));
        y += h + S(6);
    }
}

static wstring LcLabel(const LcRow& row) {
    if (row.src == 0) return row.idx == 0 ? L"读链接" : L"对话 API（问一句）";
    return row.src == 1 ? kLinkRows[row.idx].label : kApiRows[row.idx].label;
}

static wstring LcHint(const LcRow& row) {
    if (row.src == 0) return L"";
    return row.src == 1 ? kLinkRows[row.idx].hint : kApiRows[row.idx].hint;
}

static int LcKind(const LcRow& row) {
    if (row.src == 0) return -1;
    return row.src == 1 ? kLinkRows[row.idx].kind : kApiRows[row.idx].kind;
}

static wstring LcShow(const LcRow& row) {
    if (row.src == 1) {
        wstring id = kLinkRows[row.idx].id;
        if (id == L"link_enabled") return g_lcLink.enabled ? L"开" : L"关";
        if (id == L"link_timeout") return Num(g_lcLink.timeoutSec);
        if (id == L"link_maxkb") return Num(g_lcLink.maxKB);
        if (id == L"link_ua") return g_lcLink.ua.empty() ? L"（内置）" : g_lcLink.ua;
        return L"";
    }
    wstring id = kApiRows[row.idx].id;
    if (id == L"enabled") return g_lcApi.enabled ? L"开" : L"关";
    if (id == L"base") return g_lcApi.base;
    if (id == L"path") return g_lcApi.path;
    if (id == L"model") return g_lcApi.model;
    if (id == L"timeout") return Num(g_lcApi.timeoutSec);
    if (id == L"key") return g_lcApi.key.empty() ? L"" : L"已保存（••••）";
    return L"";
}

static bool LcApply(const LcRow& row, const wstring& text, wstring* err) {
    wstring t = Trim(text);
    auto onoff = [&](bool* dst) -> bool {
        bool on = (t == L"开" || t == L"是" || t == L"1" || t == L"true" || t == L"on");
        bool off = (t == L"关" || t == L"否" || t == L"0" || t == L"false" || t == L"off");
        if (!on && !off) {
            if (err) *err = L"只能填 开 / 关";
            return false;
        }
        *dst = on;
        return true;
    };
    auto number = [&](int lo, int hi, int* dst) -> bool {
        wchar_t* end = nullptr;
        double v = wcstod(t.c_str(), &end);
        if (t.empty() || end == nullptr || *end != 0 || !std::isfinite(v) || v < lo || v > hi) {
            if (err) *err = L"要填 " + Num(lo) + L"–" + Num(hi) + L" 之间的数";
            return false;
        }
        *dst = (int)(v + 0.5);
        return true;
    };
    if (row.src == 1) {
        wstring id = kLinkRows[row.idx].id;
        if (id == L"link_enabled") return onoff(&g_lcLink.enabled);
        if (id == L"link_timeout") return number(5, 15, &g_lcLink.timeoutSec);
        if (id == L"link_maxkb") return number(64, 512, &g_lcLink.maxKB);
        if (id == L"link_ua") {
            g_lcLink.ua = (t == L"（内置）") ? wstring() : t;
            return true;
        }
        return true;
    }
    wstring id = kApiRows[row.idx].id;
    if (id == L"enabled") return onoff(&g_lcApi.enabled);
    if (id == L"base") {
        if (!t.empty() && t.compare(0, 7, L"http://") != 0 && t.compare(0, 8, L"https://") != 0) {
            if (err) *err = L"Base URL 要以 http:// 或 https:// 开头";
            return false;
        }
        g_lcApi.base = t;
        return true;
    }
    if (id == L"path") {
        g_lcApi.path = t;
        return true;
    }
    if (id == L"model") {
        g_lcApi.model = t;
        return true;
    }
    if (id == L"timeout") return number(5, 300, &g_lcApi.timeoutSec);
    if (id == L"key") {
        g_lcApi.key = t;
        return true;
    }
    return true;
}

// ---------------------------------------------------------------- 编辑
static void LinkCfgEndEdit(bool apply) {
    if (!g_lcEdit) {
        g_lcEditRow = -1;
        return;
    }
    wstring text;
    if (apply) {
        int n = GetWindowTextLengthW(g_lcEdit);
        text.resize((size_t)n + 1);
        GetWindowTextW(g_lcEdit, &text[0], n + 1);
        text.resize((size_t)n);
    }
    DestroyWindow(g_lcEdit);
    g_lcEdit = nullptr;
    int row = g_lcEditRow;
    g_lcEditRow = -1;
    if (apply && row >= 0 && row < (int)g_lcRows.size()) {
        const LcRow& r = g_lcRows[row];
        wstring err;
        if (!LcApply(r, text, &err)) {
            g_lcMsg = err;
            g_lcMsgAt = GetTickCount();
        } else {
            g_lcMsg.clear();
        }
    }
    SetFocus(g_hwnd);
    UiRequestRepaint();
}

static void LinkCfgBeginEdit(int row) {
    LinkCfgEndEdit(true);
    if (row < 0 || row >= (int)g_lcRows.size()) return;
    std::vector<RectF> rs;
    LcRowRects(g_rcLc, rs);
    if (row >= (int)rs.size()) return;
    RectF r = rs[row];
    const LcRow& ref = g_lcRows[row];
    float bw = S(300), x = r.X + r.Width - bw - S(6), y = r.Y + S(9);
    wstring val = LcShow(ref);
    if (ref.src == 1 && wstring(kLinkRows[ref.idx].id) == L"link_ua" && val == L"（内置）") val.clear();
    if (ref.src == 2 && wstring(kApiRows[ref.idx].id) == L"key") val = g_lcApi.key;
    DWORD style = WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_BORDER;
    if (ref.src == 2 && kApiRows[ref.idx].kind == 5) style |= ES_PASSWORD;
    g_lcEdit = CreateWindowExW(0, L"EDIT", val.c_str(), style, (int)x, (int)y, (int)bw, (int)S(30),
                               g_hwnd, (HMENU)0x9104, GetModuleHandleW(nullptr), nullptr);
    if (!g_lcEdit) return;
    SendMessageW(g_lcEdit, WM_SETFONT, (WPARAM)AskEditorFont(), TRUE);
    SendMessageW(g_lcEdit, EM_SETSEL, 0, -1);
    SetFocus(g_lcEdit);
    g_lcEditRow = row;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 测试连接
static void LinkCfgTest() {
    if (g_lcTestBusy) return;
    LinkCfgEndEdit(true);
    if (g_lcApi.base.empty()) {
        g_lcMsg = L"先填 Base URL，再测";
        g_lcMsgAt = GetTickCount();
        UiRequestRepaint();
        return;
    }
    if (!g_lcApi.enabled) {
        g_lcMsg = L"对话 API 现在是关着的；测完记得打开，不然「问一句」用不了";
        g_lcMsgAt = GetTickCount();
    }
    g_lcTestBusy = true;
    g_lcMsg = L"正在测试连接…";
    g_lcMsgAt = GetTickCount();
    DshApiCfg cfg = g_lcApi;
    cfg.enabled = true;   // 测试就是测「这组参数能不能通」，不看总开关
    std::thread([cfg]() {
        TaskData* d = new TaskData();
        d->kind = TK_DSHTEST;
        d->action = 2;
        wstring reply, err;
        d->ok = DshChat(L"你好，用一句话打个招呼就行。", cfg, &reply, &err);
        d->text = d->ok ? reply : err;
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 开 / 关
// 配置是 B 站页里的一个分区，不再是浮层：进来就重新从盘上读一遍
static void LinkCfgOpen() {
    BiliCfgEndEdit(true);   // 另一个分区可能正开着编辑框
    LcBuildRows();
    g_lcLink = LinkLoad();
    g_lcApi = DshApiLoad();
    g_lcMsg.clear();
    g_lcTestBusy = false;
    g_lcOpen = true;
    g_lcScroll = 0;
    UiRequestRepaint();
}

// 切到 bili-whale 分区时收掉这边的编辑框
static void LinkCfgClosePanel() {
    LinkCfgEndEdit(true);
    g_lcOpen = false;
}

static void LinkCfgClose(bool save) {
    LinkCfgEndEdit(save);
    if (!save) {
        LinkCfgOpen();
        return;
    }
    wstring err;
    if (!LinkSave(g_lcLink, &err)) {
        g_lcMsg = err;
        g_lcMsgAt = GetTickCount();
        UiToast(L"读链接的设置没保存成：" + err);
    } else if (!DshApiSave(g_lcApi, &err)) {
        g_lcMsg = err;
        g_lcMsgAt = GetTickCount();
        UiToast(L"读链接存了，但对话 API 没存成：" + err);
    } else {
        g_lcMsg = L"存好了，旧文件备份成 .bak-时间";
        g_lcMsgAt = GetTickCount();
        UiToast(L"存好了，旧文件备份成 .bak-时间");
    }
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 绘制（画进 B 站页给的那块地方）
static void PaintLinkCfg(Graphics& g, const RectF& panel) {
    const float pw = panel.Width;
    const float ph = panel.Height;
    g_rcLc = panel;
    Card(g, panel, C_PANEL, C_LINE);
    Txt(g, L"链接与应用", RectF(panel.X + S(26), panel.Y + S(14), pw - S(52), S(26)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"读网页链接的规矩，和「问一句」用的对话 API", RectF(panel.X + S(26), panel.Y + S(42), pw - S(52), S(16)),
        Fnt(MICRO_SIZE, 1, 0), C_FAINT, 0, true);
    HLine(g, panel.X + S(24), panel.Y + S(64), panel.X + panel.Width - S(24), C_LINE2);

    RectF view(panel.X + S(8), panel.Y + S(70), panel.Width - S(16), ph - S(70) - S(62));
    g_lcViewH = view.Height;
    float totalH = LcTotalH();
    float maxScroll = std::max(0.0f, totalH - view.Height);
    if (g_lcScroll > maxScroll) g_lcScroll = maxScroll;
    if (g_lcScroll < 0) g_lcScroll = 0;
    g_lcContentH = totalH;

    g.SetClip(view);
    std::vector<RectF> rs;
    LcRowRects(panel, rs);
    for (size_t i = 0; i < g_lcRows.size(); i++) {
        const LcRow& row = g_lcRows[i];
        const RectF& r = rs[i];
        if (r.Y + r.Height < view.Y - S(4) || r.Y > view.Y + view.Height + S(4)) continue;
        if (row.src == 0) {
            Txt(g, LcLabel(row), RectF(r.X + S(12), r.Y + S(8), r.Width - S(24), S(24)), Fnt(SUBTITLE_SIZE, 1, 0),
                C_SUB, 0, true);
            HLine(g, r.X + S(12), r.Y + r.Height - S(4), r.X + r.Width - S(12), C_LINE2);
            continue;
        }
        int kind = LcKind(row);
        std::string id = "lcrow:" + std::to_string(i);
        if (Hov(id)) Round(g, r, S(10), 0xFFF4F8FF, 0x00000000);
        Txt(g, LcLabel(row), RectF(r.X + S(12), r.Y + S(8), r.Width - S(330), S(20)), Fnt(BODY_SIZE, 0, 0), C_TEXT, 0,
            true);
        wstring hint = LcHint(row);
        if (!hint.empty())
            Txt(g, hint, RectF(r.X + S(12), r.Y + S(30), r.Width - S(330), S(18)), Fnt(MICRO_SIZE, 1, 0), C_FAINT,
                0, true);
        wstring val = LcShow(row);
        RectF vb(r.X + r.Width - S(306), r.Y + S(9), S(300), S(30));
        if (kind == 2) {
            RectF chip(vb.X, vb.Y + S(4), S(72), S(22));
            bool on = (val == L"开");
            Round(g, chip, S(11), on ? 0x1F3F8F72 : 0x14000000, 0x00000000);
            Txt(g, val, chip, Fnt(HINT_SIZE, 0, 0), on ? C_OK : C_FAINT, 1);
        } else {
            Round(g, vb, S(9), 0xFFFBFDFF, C_LINE);
            Txt(g, val.empty() ? wstring(L"（空）") : val, RectF(vb.X + S(12), vb.Y, vb.Width - S(24), vb.Height),
                Fnt(HINT_SIZE, 1, 0), val.empty() ? C_FAINT : C_SUB, 0, true);
        }
        AddHit(r, id);
    }
    g.ResetClip();
    ScrollBar(g, view, g_lcScroll, totalH);

    float by = panel.Y + ph - S(46);
    if (!g_lcMsg.empty()) {
        bool bad = g_lcMsg.find(L"没") != wstring::npos || g_lcMsg.find(L"要") != wstring::npos ||
                   g_lcMsg.find(L"不能") != wstring::npos || g_lcMsg.find(L"不对") != wstring::npos;
        Txt(g, g_lcMsg, RectF(panel.X + S(26), by + S(6), pw - S(400), S(20)), Fnt(HINT_SIZE, 1, 0),
            bad ? C_ERR : C_OK, 0, true);
    } else {
        Txt(g, L"改完点保存；Key 只存 secrets\\dsh-api-key.txt。", RectF(panel.X + S(26), by + S(6), pw - S(400), S(20)),
            Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    }
    Button(g, RectF(panel.X + pw - S(322), by, S(96), S(30)), g_lcTestBusy ? L"测试中…" : L"测试连接", "lc:test", 0,
           true, !g_lcTestBusy);
    Button(g, RectF(panel.X + pw - S(214), by, S(96), S(30)), L"保存", "lc:save", 1, true);
    Button(g, RectF(panel.X + pw - S(110), by, S(84), S(30)), L"重新读", "lc:reload", 0, true);
}

// ---------------------------------------------------------------- 点击 / 滚轮
static bool LinkCfgClick(const std::string& id) {
    if (id.empty()) {
        LinkCfgEndEdit(true);
        return true;
    }
    vector<std::string> p = SplitId(id, ':');
    if (p.empty()) return true;
    if (p[0] == "lc") {
        if (p.size() > 1 && p[1] == "save") LinkCfgClose(true);
        else if (p.size() > 1 && p[1] == "cancel") LinkCfgClose(false);
        else if (p.size() > 1 && p[1] == "reload") LinkCfgOpen();
        else if (p.size() > 1 && p[1] == "test") LinkCfgTest();
        return true;
    }
    if (p[0] == "lcrow" && p.size() > 1) {
        int i = std::atoi(p[1].c_str());
        if (i < 0 || i >= (int)g_lcRows.size()) return true;
        const LcRow& row = g_lcRows[i];
        if (row.src == 0) return true;
        if (LcKind(row) == 2) {
            LinkCfgEndEdit(true);
            wstring err;
            wstring nv = (LcShow(row) == L"开") ? L"关" : L"开";
            if (!LcApply(row, nv, &err)) {
                g_lcMsg = err;
                g_lcMsgAt = GetTickCount();
            }
            UiRequestRepaint();
            return true;
        }
        LinkCfgBeginEdit(i);
        return true;
    }
    return true;
}

static bool LinkCfgWheel(int delta) {
    if (!g_lcOpen) return false;
    float maxScroll = std::max(0.0f, LcTotalH() - g_lcViewH);
    g_lcScroll += -delta / 120.0f * S(52);
    if (g_lcScroll < 0) g_lcScroll = 0;
    if (g_lcScroll > maxScroll) g_lcScroll = maxScroll;
    UiRequestRepaint();
    return true;
}
