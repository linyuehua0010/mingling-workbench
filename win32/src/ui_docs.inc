// ---------------------------------------------------------------- 内置教程（离线 Markdown）
// 文档随安装包放在 <安装根>\docs\ 下，只读、不联网；图只能是包里的相对路径。
// 渲染只认得教程里真会用的那几种：标题 / 段落 / 列表 / 代码块 / 表格 / 引用 / 分隔线 / 本地图片。
#include "version.h"

struct DocEntry {
    const wchar_t* id;
    const wchar_t* title;
    const wchar_t* file;
    const wchar_t* hint;
};
static const DocEntry DOCS[] = {
    {L"guide", L"使用说明", L"使用说明.md", L"装完到会用，含 FAQ 和排错"},
    {L"bili", L"B 站 / 看视频", L"deploy-bili.md", L"bili-whale、登录、配额"},
    {L"qq", L"QQ 机器人", L"deploy-qq.md", L"QQ 登录端、NapCat、怎么跑起来"},
};
static const int DOC_COUNT = (int)(sizeof(DOCS) / sizeof(DOCS[0]));

static int g_docSel = -1;              // -1 = 没打开
static wstring g_docSrc;               // 展开占位符后的正文
static wstring g_docLoaded;            // 已载入的 id
static float g_docScroll = 0;
static float g_docViewH = 0;

static wstring DocDir() {
    wstring d = JoinPath(ExeDir(), L"docs");
    if (DirExists(d)) return d;
    d = JoinPath(ParentDir(ExeDir()), L"docs");
    if (DirExists(d)) return d;
    return JoinPath(BaseDir(), L"docs");
}

static wstring TabListText() {
    wstring s;
    for (int i = 0; i < (int)(sizeof(TABS) / sizeof(TABS[0])); i++) {
        if (i) s += L" / ";
        s += TABS[i];
    }
    return s;
}

// 文档里会随版本变的东西一律写占位符，这里按 version.h 和页签表填上——
// 免得帮助里写的还是上个版本的号码。
static wstring DocExpand(const wstring& s) {
    wstring o = s;
    o = ReplaceAll(o, L"{{VERSION}}", APP_VERSION);
    o = ReplaceAll(o, L"{{VERSION_TAG}}", APP_VERSION);
    o = ReplaceAll(o, L"{{FILEVERSION}}", APP_VERSION_FULL_W);
    o = ReplaceAll(o, L"{{TABS}}", Num((long long)(sizeof(TABS) / sizeof(TABS[0]))));
    o = ReplaceAll(o, L"{{TABLIST}}", TabListText());
    o = ReplaceAll(o, L"{{HOTKEYS}}", L"1–" + Num((long long)(sizeof(TABS) / sizeof(TABS[0]))) + L" 切左侧页签，F5 刷新当前页，F9 全部启动，F10 全部关闭");
    return o;
}

static bool DocLoad(int idx) {
    if (idx < 0 || idx >= DOC_COUNT) return false;
    if (g_docLoaded == DOCS[idx].id && !g_docSrc.empty()) return true;
    wstring p = JoinPath(DocDir(), DOCS[idx].file);
    if (!FileExists(p)) {
        g_docSrc = L"══════════ 文档不在这里 ══════════\n\n没找到：" + p +
                   L"\n\n安装包里应该带着 docs\\" + wstring(DOCS[idx].file) + L"，重装一次就好。";
        g_docLoaded = DOCS[idx].id;
        return false;
    }
    g_docSrc = DocExpand(ReadTextFile(p));
    g_docLoaded = DOCS[idx].id;
    g_docScroll = 0;
    return true;
}

// 「用系统打开」：把占位符填好的那一份写到临时目录再交给系统，
// 不然用户看到的是 {{VERSION}} 这种生词。
static void DocOpenExternal(int idx) {
    if (idx < 0 || idx >= DOC_COUNT) return;
    DocLoad(idx);
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    wstring p = JoinPath(tmp, L"mingling-doc-" + wstring(DOCS[idx].id) + L".md");
    if (!WriteTextFile(p, g_docSrc)) {
        UiToast(L"临时文件写不出来，打不开");
        return;
    }
    OpenPath(p);
}

// ---- 排版：把 Markdown 拍平成一行行，量好高，画的时候只管按 y 往下堆
struct DocLine {
    int kind;          // 0 正文 1 h1 2 h2 3 h3 4 列表 5 代码 6 表格 7 图片 8 分隔 9 引用
    wstring text;
    float h = 0;
    float blockH = 0;   // 代码块第一行记整块高：底色得先画，不然会盖住字
    float indent = 0;
    std::vector<wstring> rows;   // 表格：单元格用 \t 拼过
};

static std::vector<DocLine> g_docLayout;
static wstring g_docLayoutKey;
static float g_docLayoutW = 0;

static std::vector<wstring> WrapByFont(Graphics& g, const wstring& s, Font* f, float width) {
    std::vector<wstring> out;
    if (s.empty()) {
        out.push_back(L"");
        return out;
    }
    wstring cur;
    for (size_t i = 0; i < s.size(); i++) {
        cur.push_back(s[i]);
        if ((cur.size() % 4 == 0 || s[i] == L' ') && Tw(g, cur, f) > width && cur.size() > 1) {
            wchar_t last = cur.back();
            cur.pop_back();
            out.push_back(cur);
            cur = wstring(1, last);
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

static wstring DocInline(const wstring& in) {
    wstring s = in;
    s = ReplaceAll(s, L"**", L"");
    s = ReplaceAll(s, L"__", L"");
    s = ReplaceAll(s, L"`", L"");
    // [文字](链接) → 文字（链接）；纯链接原样留
    wstring o;
    for (size_t i = 0; i < s.size();) {
        if (s[i] == L'[') {
            size_t rb = s.find(L']', i);
            if (rb != wstring::npos && rb + 1 < s.size() && s[rb + 1] == L'(') {
                size_t rp = s.find(L')', rb + 2);
                if (rp != wstring::npos) {
                    wstring label = s.substr(i + 1, rb - i - 1);
                    wstring url = s.substr(rb + 2, rp - rb - 2);
                    if (label == url)
                        o += url;
                    else
                        o += label + L"（" + url + L"）";
                    i = rp + 1;
                    continue;
                }
            }
        }
        o.push_back(s[i]);
        i++;
    }
    return o;
}

static void DocLayout(Graphics& g, float width) {
    wstring key = Num((long long)g_docSel) + L"|" + Num((long long)width) + L"|" +
                  Num((long long)g_docSrc.size() * 137 + (long long)(g_docSrc.empty() ? 0 : g_docSrc[0]));
    if (key == g_docLayoutKey && std::fabs(width - g_docLayoutW) < 0.5f) return;
    g_docLayoutKey = key;
    g_docLayoutW = width;
    g_docLayout.clear();

    Font* body = Fnt(11.5f, 0, 0);
    Font* bold = Fnt(11.5f, 1, 0);
    Font* h1 = Fnt(17.0f, 1, 0);
    Font* h2 = Fnt(14.0f, 1, 0);
    Font* h3 = Fnt(12.5f, 1, 0);
    Font* mono = Fnt(11.0f, 0, 1);

    std::vector<wstring> lines = SplitLines(g_docSrc);
    bool inCode = false;
    std::vector<wstring> codeBuf;
    std::vector<wstring> tableBuf;

    auto flushCode = [&]() {
        if (codeBuf.empty()) return;
        float w = width - S(28);
        for (auto& c : codeBuf) {
            for (auto& wl : WrapByFont(g, c, mono, w)) {
                DocLine d;
                d.kind = 5;
                d.text = wl;
                d.h = S(19);
                d.indent = S(14);
                g_docLayout.push_back(d);
            }
        }
        DocLine pad;
        pad.kind = 5;
        pad.text = L" ";
        pad.h = S(8);
        g_docLayout.push_back(pad);
        codeBuf.clear();
    };

    auto flushTable = [&]() {
        if (tableBuf.empty()) return;
        // 第一行是表头，第二行是 |---|---|
        std::vector<std::vector<wstring>> rows;
        for (size_t r = 0; r < tableBuf.size(); r++) {
            wstring t = Trim(tableBuf[r]);
            if (t.find(L'|') == wstring::npos) continue;
            if (r == 1 && t.find(L"---") != wstring::npos) continue;
            std::vector<wstring> cells;
            wstring cur;
            for (size_t i = 0; i < t.size(); i++) {
                if (t[i] == L'|') {
                    cells.push_back(Trim(cur));
                    cur.clear();
                } else {
                    cur.push_back(t[i]);
                }
            }
            if (!cur.empty()) cells.push_back(Trim(cur));
            if (!cells.empty() && cells.front().empty()) cells.erase(cells.begin());
            if (!cells.empty() && cells.back().empty()) cells.pop_back();
            if (!cells.empty()) rows.push_back(cells);
        }
        tableBuf.clear();
        if (rows.empty()) return;
        size_t cols = 0;
        for (auto& r : rows) cols = std::max(cols, r.size());
        if (cols == 0) return;
        // 列宽按内容估，最后按可用宽度缩放
        std::vector<float> cw(cols, S(40));
        for (auto& r : rows) {
            for (size_t c = 0; c < r.size() && c < cols; c++) {
                float w = Tw(g, r[c], c == 0 ? bold : body) + S(18);
                cw[c] = std::max(cw[c], std::min(w, width * 0.62f));
            }
        }
        float sum = 0;
        for (float w : cw) sum += w;
        float avail = width - S(6);
        if (sum > avail && sum > 0) {
            for (auto& w : cw) w = w * avail / sum;
        }
        for (size_t r = 0; r < rows.size(); r++) {
            DocLine d;
            d.kind = 6;
            d.h = S(26);
            for (size_t c = 0; c < cols; c++) {
                if (c) d.text += L"\t";
                d.text += (c < rows[r].size()) ? DocInline(rows[r][c]) : wstring();
            }
            d.rows.push_back(L"");
            g_docLayout.push_back(d);
        }
        DocLine gap;
        gap.kind = 0;
        gap.text = L"";
        gap.h = S(8);
        g_docLayout.push_back(gap);
    };

    for (auto& raw : lines) {
        wstring line = raw;
        while (!line.empty() && (line.back() == L'\r' || line.back() == L'\n')) line.pop_back();
        wstring t = Trim(line);

        if (StartsWith(t, L"```")) {
            if (inCode) {
                inCode = false;
                flushCode();
            } else {
                flushTable();
                inCode = true;
            }
            continue;
        }
        if (inCode) {
            codeBuf.push_back(line);
            continue;
        }
        if (StartsWith(t, L"|")) {
            tableBuf.push_back(t);
            continue;
        }
        flushTable();

        if (t.empty()) {
            DocLine d;
            d.kind = 0;
            d.text = L"";
            d.h = S(7);
            g_docLayout.push_back(d);
            continue;
        }
        if (StartsWith(t, L"# ")) {
            DocLine d;
            d.kind = 1;
            d.text = DocInline(Trim(t.substr(2)));
            d.h = S(34);
            g_docLayout.push_back(d);
            continue;
        }
        if (StartsWith(t, L"## ")) {
            DocLine d;
            d.kind = 2;
            d.text = DocInline(Trim(t.substr(3)));
            d.h = S(30);
            g_docLayout.push_back(d);
            continue;
        }
        if (StartsWith(t, L"### ")) {
            DocLine d;
            d.kind = 3;
            d.text = DocInline(Trim(t.substr(4)));
            d.h = S(25);
            g_docLayout.push_back(d);
            continue;
        }
        if (t == L"---" || t == L"***" || t == L"___") {
            DocLine d;
            d.kind = 8;
            d.h = S(14);
            g_docLayout.push_back(d);
            continue;
        }
        if (StartsWith(t, L"![")) {
            size_t rb = t.find(L']');
            size_t lp = t.find(L'(', rb == wstring::npos ? 0 : rb);
            size_t rp = lp == wstring::npos ? wstring::npos : t.find(L')', lp);
            if (rb != wstring::npos && lp != wstring::npos && rp != wstring::npos) {
                wstring rel = Trim(t.substr(lp + 1, rp - lp - 1));
                DocLine d;
                d.kind = 7;
                d.text = rel;
                if (!rel.empty() && (rel[0] == L'/' || rel[0] == L'\\' || (rel.size() > 1 && rel[1] == L':')))
                    d.indent = 1;   // 绝对路径：只在本地（不随包），也照画
                Image* im = LoadImg(JoinPath(DocDir(), rel));
                float ih = S(180);
                if (im) ih = (float)im->GetHeight() * (width - S(12)) / (float)im->GetWidth();
                d.h = std::min(ih, S(300)) + S(10);
                g_docLayout.push_back(d);
                continue;
            }
        }
        if (StartsWith(t, L"> ")) {
            for (auto& wl : WrapByFont(g, DocInline(Trim(t.substr(2))), body, width - S(20))) {
                DocLine d;
                d.kind = 9;
                d.text = wl;
                d.h = S(21);
                g_docLayout.push_back(d);
            }
            continue;
        }
        bool bullet = StartsWith(t, L"- ") || StartsWith(t, L"* ") || StartsWith(t, L"+ ");
        int numLen = 0;
        if (!bullet && t.size() > 2) {
            int i = 0;
            while (i < (int)t.size() && t[i] >= L'0' && t[i] <= L'9') i++;
            if (i > 0 && i < (int)t.size() && (t[i] == L'.' || t[i] == L')') && i + 1 < (int)t.size() && t[i + 1] == L' ')
                numLen = i + 1;
        }
        if (bullet || numLen > 0) {
            wstring txt = bullet ? Trim(t.substr(2)) : Trim(t.substr(numLen));
            wstring mark = bullet ? wstring(L"·") : t.substr(0, numLen);
            std::vector<wstring> wl = WrapByFont(g, DocInline(txt), body, width - S(30));
            for (size_t i = 0; i < wl.size(); i++) {
                DocLine d;
                d.kind = 4;
                d.text = (i == 0 ? mark + L" " + wl[i] : wstring(L"   ") + wl[i]);
                d.h = S(21);
                d.indent = S(10);
                g_docLayout.push_back(d);
            }
            continue;
        }
        for (auto& wl : WrapByFont(g, DocInline(t), body, width - S(4))) {
            DocLine d;
            d.kind = 0;
            d.text = wl;
            d.h = S(22);
            g_docLayout.push_back(d);
        }
    }
    if (inCode) flushCode();
    flushTable();

    // 代码块底色要在文字之前画：把每块的总高记在块首行上
    for (size_t i = 0; i < g_docLayout.size();) {
        if (g_docLayout[i].kind != 5) {
            i++;
            continue;
        }
        size_t j = i;
        float hh = 0;
        while (j < g_docLayout.size() && g_docLayout[j].kind == 5) hh += g_docLayout[j].h, j++;
        g_docLayout[i].blockH = hh;
        i = j;
    }
}

// 画整篇文档，返回内容总高
static float DrawDoc(Graphics& g, const RectF& area, float scroll) {
    if (g_docSel < 0 || g_docSel >= DOC_COUNT) return 0;
    Font* body = Fnt(11.5f, 0, 0);
    Font* bold = Fnt(11.5f, 1, 0);
    Font* h1 = Fnt(17.0f, 1, 0);
    Font* h2 = Fnt(14.0f, 1, 0);
    Font* h3 = Fnt(12.5f, 1, 0);
    Font* mono = Fnt(11.0f, 0, 1);

    DocLayout(g, area.Width - S(12));
    g.SetClip(area);
    float y = area.Y - scroll;
    for (size_t i = 0; i < g_docLayout.size(); i++) {
        DocLine& d = g_docLayout[i];
        if (d.blockH > 0) {
            Round(g, RectF(area.X + S(2), y - S(4), area.Width - S(10), d.blockH + S(8)), S(8), C_PANEL2,
                  0x00000000);
        }
        switch (d.kind) {
            case 1:
                Txt(g, d.text, RectF(area.X, y + S(8), area.Width - S(10), S(26)), h1, C_ACCENT, 0);
                HLine(g, area.X, y + d.h - S(2), area.X + area.Width - S(10), C_LINE);
                break;
            case 2: {
                Round(g, RectF(area.X, y + S(6), S(3), S(16)), S(1.5f), C_ACCENT, 0);
                Txt(g, d.text, RectF(area.X + S(10), y + S(4), area.Width - S(20), S(24)), h2, C_TEXT, 0);
                break;
            }
            case 3:
                Txt(g, d.text, RectF(area.X + S(2), y + S(2), area.Width - S(16), S(22)), h3, C_SUB, 0);
                break;
            case 4:
                Txt(g, d.text, RectF(area.X + d.indent, y, area.Width - S(16) - d.indent, d.h), body, C_TEXT, 0);
                break;
            case 5:
                Txt(g, d.text, RectF(area.X + d.indent, y, area.Width - S(20) - d.indent, d.h), mono, C_TEXT, 0);
                break;
            case 6: {
                // 表格：按 \t 切，列宽按最宽单元格
                std::vector<wstring> cells;
                wstring cur;
                for (wchar_t ch : d.text) {
                    if (ch == L'\t') {
                        cells.push_back(cur);
                        cur.clear();
                    } else {
                        cur.push_back(ch);
                    }
                }
                cells.push_back(cur);
                if (cells.empty()) break;
                float totW = area.Width - S(10);
                std::vector<float> w(cells.size(), 1.0f);
                float sum = 0;
                for (size_t c = 0; c < cells.size(); c++) {
                    w[c] = Tw(g, cells[c], c == 0 ? bold : body) + S(18);
                    sum += w[c];
                }
                if (sum > 0) {
                    for (auto& v : w) v = v * totW / sum;
                }
                // 第一行当表头：判断依据是它是第一块表格行的开始（简化：整块第一行）
                bool header = false;
                if (i + 1 < g_docLayout.size() && g_docLayout[i + 1].kind == 6) header = (i == 0 || g_docLayout[i - 1].kind != 6);
                if (header) {
                    Round(g, RectF(area.X, y, totW, d.h), S(4), C_ACCENT_S, 0x00000000);
                }
                float x = area.X;
                for (size_t c = 0; c < cells.size(); c++) {
                    Txt(g, cells[c], RectF(x + S(8), y, w[c] - S(12), d.h), header ? bold : body, C_TEXT, 0, true, 1);
                    x += w[c];
                }
                HLine(g, area.X, y + d.h, area.X + totW, C_LINE2);
                break;
            }
            case 7: {
                wstring p = d.text;
                bool abs = !p.empty() && (p[0] == L'/' || p[0] == L'\\' || (p.size() > 1 && p[1] == L':'));
                Image* im = LoadImg(abs ? p : JoinPath(DocDir(), p));
                float ih = d.h - S(10);
                if (im) {
                    float iw = (float)im->GetWidth(), ihh = (float)im->GetHeight();
                    float k = std::min((area.Width - S(12)) / iw, ih / ihh);
                    float dw = iw * k, dh = ihh * k;
                    g.DrawImage(im, RectF(area.X + S(2), y, dw, dh));
                    Round(g, RectF(area.X + S(2), y, dw, dh), S(6), 0x00000000, C_LINE);
                } else {
                    Round(g, RectF(area.X + S(2), y, area.Width - S(20), S(44)), S(8), C_PANEL2, C_LINE);
                    Txt(g, L"（图不在这里：" + p + L"）", RectF(area.X + S(12), y, area.Width - S(40), S(44)),
                        Fnt(10.5f, 0, 0), C_FAINT, 0, true, 1);
                }
                break;
            }
            case 8:
                HLine(g, area.X + S(2), y + d.h * 0.5f, area.X + area.Width - S(20), C_LINE2);
                break;
            case 9: {
                Round(g, RectF(area.X, y - S(2), S(3), d.h), S(1.5f), C_ACCENT2, 0);
                Txt(g, d.text, RectF(area.X + S(12), y, area.Width - S(28), d.h), body, C_SUB, 0);
                break;
            }
            default:
                Txt(g, d.text, RectF(area.X, y, area.Width - S(12), d.h), body, C_TEXT, 0);
                break;
        }
        y += d.h;
    }
    g.ResetClip();
    return y - (area.Y - scroll);
}

// ---- 教程列表 + 阅读器（帮助中心里用）
static void DocChipRow(Graphics& g, float x, float y, float w) {
    float cx = x;
    for (int i = 0; i < DOC_COUNT; i++) {
        Font* f = Fnt(11.5f, 0, 0);
        float cw = Tw(g, DOCS[i].title, f) + S(28);
        RectF r(cx, y, cw, S(30));
        bool on = (g_docSel == i);
        Round(g, r, S(8), on ? C_ACCENT : C_PANEL2, on ? 0x00000000 : C_LINE);
        Txt(g, DOCS[i].title, r, f, on ? 0xFFFFFFFF : C_TEXT, 1);
        AddHit(r, "doc:" + WToUtf8(DOCS[i].id));
        cx += cw + S(8);
        if (cx > x + w) break;
    }
}
