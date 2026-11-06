// ---------------------------------------------------------------- bili-whale 配置
// 整份配置读进内存，逐行改；点「保存」才落盘：先备份 .bak-<时间>，写完重新解析校验，
// 解析不过就回滚。读进来什么样就写回去什么样——只改界面上这几处，未知键一个都不动。
//
// 下面还有一段「对话 API」：那几项不属于 bili-whale 的配置文件，落在 settings.json，
// Key 单独放 secrets\dsh-api-key.txt，不往人家的配置里塞，也不写进 settings。
#include "biliapi.h"

static her::J g_bcfgRoot;
static wstring g_bcfgPath;
static wstring g_bcfgMsg;
static DWORD g_bcfgMsgAt = 0;
static float g_bcfgScroll = 0, g_bcfgContentH = 0, g_bcfgViewH = 0;
static RectF g_rcBcfg;
static HWND g_bcfgEdit = nullptr;
static int g_bcfgEditRow = -1;
static DshApiCfg g_bcfgApi;
static bool g_bcfgTestBusy = false;

// 一张表两段：0=小标题  1=bili-whale 配置项  2=对话 API 配置项
struct CfgRow {
    int src = 1;
    int idx = 0;
};
static std::vector<CfgRow> g_bcfgRows;

struct ApiRowDef {
    const wchar_t* id;
    const wchar_t* label;
    const wchar_t* hint;
    int kind;   // 0 文本 1 数字 2 布尔 5 密钥（画成圆点，编辑框也是密码框）
};
static const ApiRowDef kApiRows[] = {
    {L"enabled", L"启用对话 API", L"关掉的话只是 B 站页不调它，别的功能照旧", 2},
    {L"base", L"Base URL", L"OpenAI 兼容的接口根地址，例如 https://api.deepseek.com/v1", 0},
    {L"path", L"路径", L"默认 /chat/completions（拼在 Base URL 后面）", 0},
    {L"model", L"模型名", L"例如 deepseek-chat", 0},
    {L"timeout", L"超时（秒）", L"5–300，只影响这一路对话，不挡看片", 1},
    {L"key", L"API Key", L"存到 secrets\\dsh-api-key.txt，不写 settings.json", 5},
};
static const int kApiRowCount = (int)(sizeof(kApiRows) / sizeof(kApiRows[0]));

static void BcfgBuildRows() {
    g_bcfgRows.clear();
    g_bcfgRows.push_back({0, 0});
    for (size_t i = 0; i < BiliCfgFields().size(); i++) g_bcfgRows.push_back({1, (int)i});
    g_bcfgRows.push_back({0, 1});
    for (int i = 0; i < kApiRowCount; i++) g_bcfgRows.push_back({2, i});
}

static float BcfgRowH(const CfgRow& row) {
    if (row.src == 0) return S(38);
    int kind = row.src == 1 ? BiliCfgFields()[row.idx].kind : kApiRows[row.idx].kind;
    return kind == 2 ? S(44) : S(56);
}

static float BcfgTotalH() {
    if (g_bcfgRows.empty()) BcfgBuildRows();
    float h = 0;
    for (const CfgRow& r : g_bcfgRows) h += BcfgRowH(r) + S(6);
    return h;
}

static float BcfgTop(const RectF& panel) { return panel.Y + S(76); }

static void BcfgRowRects(const RectF& panel, std::vector<RectF>& out) {
    if (g_bcfgRows.empty()) BcfgBuildRows();
    out.clear();
    float y = BcfgTop(panel) - g_bcfgScroll;
    for (const CfgRow& row : g_bcfgRows) {
        float h = BcfgRowH(row);
        out.push_back(RectF(panel.X + S(18), y, panel.Width - S(36), h));
        y += h + S(6);
    }
}

static wstring BcfgLabel(const CfgRow& row) {
    if (row.src == 0) return row.idx == 0 ? L"bili-whale 的配置" : L"对话 API（可选）";
    if (row.src == 1) return BiliCfgFields()[row.idx].label;
    return kApiRows[row.idx].label;
}

static wstring BcfgHint(const CfgRow& row) {
    if (row.src == 0) return L"";
    if (row.src == 1) return BiliCfgFields()[row.idx].hint;
    return kApiRows[row.idx].hint;
}

static int BcfgKind(const CfgRow& row) {
    if (row.src == 0) return -1;
    if (row.src == 1) return BiliCfgFields()[row.idx].kind;
    return kApiRows[row.idx].kind;
}

// 对话 API 的值：布尔→开/关，密钥→不把明文画在屏幕上
static wstring BcfgApiShow(const wstring& id) {
    if (id == L"enabled") return g_bcfgApi.enabled ? L"开" : L"关";
    if (id == L"base") return g_bcfgApi.base;
    if (id == L"path") return g_bcfgApi.path;
    if (id == L"model") return g_bcfgApi.model;
    if (id == L"timeout") return Num(g_bcfgApi.timeoutSec);
    if (id == L"key") return g_bcfgApi.key.empty() ? L"" : L"已保存（••••）";
    return L"";
}

static wstring BcfgValue(const CfgRow& row) {
    if (row.src == 1) return BiliCfgShow(g_bcfgRoot, BiliCfgFields()[row.idx]);
    if (row.src == 2) return BcfgApiShow(kApiRows[row.idx].id);
    return L"";
}

// 对话 API 的值写回内存：不落盘，等「保存」
static bool BcfgApiApply(const wstring& id, const wstring& text, wstring* err) {
    wstring t = Trim(text);
    if (id == L"enabled") {
        bool on = (t == L"开" || t == L"是" || t == L"1" || t == L"true" || t == L"TRUE" || t == L"on" || t == L"ON");
        bool off = (t == L"关" || t == L"否" || t == L"0" || t == L"false" || t == L"FALSE" || t == L"off" || t == L"OFF");
        if (!on && !off) {
            if (err) *err = L"只能填 开 / 关";
            return false;
        }
        g_bcfgApi.enabled = on;
        return true;
    }
    if (id == L"base") {
        if (!t.empty() && t.compare(0, 7, L"http://") != 0 && t.compare(0, 8, L"https://") != 0) {
            if (err) *err = L"Base URL 要以 http:// 或 https:// 开头";
            return false;
        }
        g_bcfgApi.base = t;
        return true;
    }
    if (id == L"path") {
        g_bcfgApi.path = t;
        return true;
    }
    if (id == L"model") {
        g_bcfgApi.model = t;
        return true;
    }
    if (id == L"timeout") {
        wchar_t* end = nullptr;
        double sec = wcstod(t.c_str(), &end);
        if (t.empty() || end == nullptr || *end != 0 || !std::isfinite(sec) || sec < 5 || sec > 300) {
            if (err) *err = L"超时要填 5–300 之间的秒数";
            return false;
        }
        g_bcfgApi.timeoutSec = (int)(sec + 0.5);
        return true;
    }
    if (id == L"key") {
        g_bcfgApi.key = t;
        return true;
    }
    return true;
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
    if (apply && row >= 0 && row < (int)g_bcfgRows.size()) {
        const CfgRow& r = g_bcfgRows[row];
        wstring err;
        bool ok = r.src == 1 ? BiliCfgApply(g_bcfgRoot, BiliCfgFields()[r.idx], text, &err)
                             : BcfgApiApply(kApiRows[r.idx].id, text, &err);
        if (!ok) {
            g_bcfgMsg = err;
            g_bcfgMsgAt = GetTickCount();
        } else {
            g_bcfgMsg.clear();
        }
    }
    SetFocus(g_hwnd);
    UiRequestRepaint();
}

static void BiliCfgBeginEdit(int row) {
    BiliCfgEndEdit(true);
    if (row < 0 || row >= (int)g_bcfgRows.size()) return;
    std::vector<RectF> rs;
    BcfgRowRects(g_rcBcfg, rs);
    if (row >= (int)rs.size()) return;
    RectF r = rs[row];
    const CfgRow& rowRef = g_bcfgRows[row];
    // 编辑框只认屏幕坐标：行是在滚动区里画的，这里直接算到位
    float bw = S(300), x = r.X + r.Width - bw - S(6), y = r.Y + S(9);
    wstring val = BcfgValue(rowRef);
    if (rowRef.src == 2 && wstring(kApiRows[rowRef.idx].id) == L"key") {
        val = g_bcfgApi.key;   // 画的是圆点，编辑时给真值
    }
    DWORD style = WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_BORDER;
    if (rowRef.src == 2 && kApiRows[rowRef.idx].kind == 5) style |= ES_PASSWORD;
    g_bcfgEdit = CreateWindowExW(0, L"EDIT", val.c_str(), style, (int)x, (int)y, (int)bw, (int)S(30), g_hwnd,
                                 (HMENU)0x9103, GetModuleHandleW(nullptr), nullptr);
    if (!g_bcfgEdit) return;
    SendMessageW(g_bcfgEdit, WM_SETFONT, (WPARAM)AskEditorFont(), TRUE);
    SendMessageW(g_bcfgEdit, EM_SETSEL, 0, -1);
    SetFocus(g_bcfgEdit);
    g_bcfgEditRow = row;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 测试连接（工作线程 + PostMessage）
static void BcfgTestConnection() {
    if (g_bcfgTestBusy) return;
    BiliCfgEndEdit(true);
    if (g_bcfgApi.base.empty()) {
        g_bcfgMsg = L"先填 Base URL，再测";
        g_bcfgMsgAt = GetTickCount();
        UiRequestRepaint();
        return;
    }
    g_bcfgTestBusy = true;
    g_bcfgMsg = L"正在测试连接…";
    g_bcfgMsgAt = GetTickCount();
    DshApiCfg cfg = g_bcfgApi;
    std::thread([cfg]() {
        TaskData* d = new TaskData();
        d->kind = TK_DSHTEST;
        d->action = 0;
        wstring reply, err;
        d->ok = DshChat(L"你好，用一句话打个招呼就行。", cfg, &reply, &err);
        d->text = d->ok ? reply : err;
        PostTask(d);
    }).detach();
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 开 / 关
static void BiliCfgOpen() {
    if (g_bcfgOpen) {
        UiRequestRepaint();
        return;
    }
    wstring err;
    BcfgBuildRows();
    BiliCfgLoad(g_bcfgRoot, &err);
    g_bcfgApi = DshApiLoad();
    g_bcfgPath = BiliCfgPath();
    g_bcfgMsg = err;
    g_bcfgMsgAt = err.empty() ? 0 : GetTickCount();
    g_bcfgTestBusy = false;
    g_bcfgOpen = true;
    g_bcfgScroll = 0;
    UiRequestRepaint();
}

static void BiliCfgClose(bool save) {
    BiliCfgEndEdit(save);   // 取消时正在编辑的那格不写进内存
    if (save) {
        wstring err;
        if (!BiliCfgSave(g_bcfgRoot, &err)) {
            UiToast(L"没保存成：" + err);
        } else if (!DshApiSave(g_bcfgApi, &err)) {
            UiToast(L"bili 配置存了，但对话 API 没存成：" + err);
        } else {
            UiToast(L"配置已保存，旧文件备份成 .bak-时间");
        }
    }
    g_bcfgOpen = false;
    g_bcfgScroll = 0;
    UiRequestRepaint();
}

// ---------------------------------------------------------------- 绘制
static void PaintBiliCfg(Graphics& g) {
    SolidBrush dim(Color(0x7A, 0x15, 0x20, 0x38));
    g.FillRectangle(&dim, 0, 0, (int)g_w, (int)g_h);

    float pw = std::min(S(820), (float)g_w - S(80));
    float ph = std::min(S(680), (float)g_h - S(80));
    RectF panel(((float)g_w - pw) / 2, ((float)g_h - ph) / 2, pw, ph);
    g_rcBcfg = panel;
    Round(g, panel, S(16), C_PANEL, C_LINE);
    Txt(g, L"配置", RectF(panel.X + S(26), panel.Y + S(14), pw - S(52), S(26)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, g_bcfgPath, RectF(panel.X + S(26), panel.Y + S(42), pw - S(52), S(16)), Fnt(MICRO_SIZE, 1, 0), C_FAINT,
        0, true);
    HLine(g, panel.X + S(24), panel.Y + S(64), panel.X + panel.Width - S(24), C_LINE2);

    // 行：滚动的部分单独裁一块，别画到标题和按钮上
    RectF view(panel.X + S(8), panel.Y + S(70), panel.Width - S(16), ph - S(70) - S(62));
    g_bcfgViewH = view.Height;
    float totalH = BcfgTotalH();
    float maxScroll = std::max(0.0f, totalH - view.Height);
    if (g_bcfgScroll > maxScroll) g_bcfgScroll = maxScroll;
    if (g_bcfgScroll < 0) g_bcfgScroll = 0;
    g_bcfgContentH = totalH;

    g.SetClip(view);
    std::vector<RectF> rs;
    BcfgRowRects(panel, rs);
    for (size_t i = 0; i < g_bcfgRows.size(); i++) {
        const CfgRow& row = g_bcfgRows[i];
        const RectF& r = rs[i];
        if (r.Y + r.Height < view.Y - S(4) || r.Y > view.Y + view.Height + S(4)) continue;
        if (row.src == 0) {
            Txt(g, BcfgLabel(row), RectF(r.X + S(12), r.Y + S(8), r.Width - S(24), S(24)), Fnt(SUBTITLE_SIZE, 1, 0),
                C_SUB, 0, true);
            HLine(g, r.X + S(12), r.Y + r.Height - S(4), r.X + r.Width - S(12), C_LINE2);
            continue;
        }
        int kind = BcfgKind(row);
        std::string id = "bcfgrow:" + std::to_string(i);
        bool ro = (kind == 4);
        if (!ro && Hov(id)) Round(g, r, S(10), 0xFFF4F8FF, 0x00000000);
        Txt(g, BcfgLabel(row), RectF(r.X + S(12), r.Y + S(8), r.Width - S(330), S(20)), Fnt(BODY_SIZE, 0, 0),
            ro ? C_FAINT : C_TEXT, 0, true);
        wstring hint = BcfgHint(row);
        if (!hint.empty())
            Txt(g, hint, RectF(r.X + S(12), r.Y + S(30), r.Width - S(330), S(18)), Fnt(MICRO_SIZE, 1, 0), C_FAINT,
                0, true);
        wstring val = BcfgValue(row);
        RectF vb(r.X + r.Width - S(306), r.Y + S(9), S(300), S(30));
        if (kind == 2) {
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
    ScrollBar(g, view, g_bcfgScroll, totalH);

    // 底：提示 + 测试连接 / 保存 / 取消
    float by = panel.Y + ph - S(46);
    if (!g_bcfgMsg.empty()) {
        bool bad = g_bcfgMsg.find(L"没") != wstring::npos || g_bcfgMsg.find(L"要") != wstring::npos ||
                   g_bcfgMsg.find(L"不能") != wstring::npos || g_bcfgMsg.find(L"不对") != wstring::npos;
        Txt(g, g_bcfgMsg, RectF(panel.X + S(26), by + S(6), pw - S(360), S(20)), Fnt(HINT_SIZE, 1, 0),
            bad ? C_ERR : C_OK, 0, true);
    } else {
        Txt(g, L"改完点保存。别的键原样留着，不会丢。", RectF(panel.X + S(26), by + S(6), pw - S(360), S(20)),
            Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    }
    Button(g, RectF(panel.X + pw - S(322), by, S(96), S(30)), g_bcfgTestBusy ? L"测试中…" : L"测试连接",
           "bcfg:test", 0, true, !g_bcfgTestBusy);
    Button(g, RectF(panel.X + pw - S(214), by, S(96), S(30)), L"保存", "bcfg:save", 1, true);
    Button(g, RectF(panel.X + pw - S(110), by, S(84), S(30)), L"取消", "bcfg:cancel", 0, true);
}

// ---------------------------------------------------------------- 点击 / 滚轮 / 按键
static bool BiliCfgClick(const std::string& id) {
    if (id.empty()) {
        BiliCfgEndEdit(true);
        return true;
    }
    vector<std::string> p = SplitId(id, ':');
    if (p.empty()) return true;
    if (p[0] == "bcfg") {
        if (p.size() > 1 && p[1] == "save") BiliCfgClose(true);
        else if (p.size() > 1 && p[1] == "cancel") BiliCfgClose(false);
        else if (p.size() > 1 && p[1] == "test") BcfgTestConnection();
        return true;
    }
    if (p[0] == "bcfgrow" && p.size() > 1) {
        int i = std::atoi(p[1].c_str());
        if (i < 0 || i >= (int)g_bcfgRows.size()) return true;
        const CfgRow& row = g_bcfgRows[i];
        if (row.src == 0) return true;
        int kind = BcfgKind(row);
        if (kind == 4) {
            g_bcfgMsg = L"这一项结构比较复杂，要改就编辑配置文件";
            g_bcfgMsgAt = GetTickCount();
            UiRequestRepaint();
            return true;
        }
        if (kind == 2) {
            BiliCfgEndEdit(true);
            wstring err;
            wstring cur = BcfgValue(row);
            wstring nv = (cur == L"开") ? L"关" : L"开";
            bool ok = row.src == 1 ? BiliCfgApply(g_bcfgRoot, BiliCfgFields()[row.idx], nv, &err)
                                   : BcfgApiApply(kApiRows[row.idx].id, nv, &err);
            if (!ok) {
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
