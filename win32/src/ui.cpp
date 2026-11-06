// 冥零工作台 · UI（Win32 + GDI+ 全自绘）
#include "ui.h"
#include "version.h"
#include "her/her.h"
#include "biliapi.h"

#include <shellapi.h>
#include <shlobj.h>
#include <cmath>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>

using namespace Gdiplus;

// ---------------------------------------------------------------- 配色（冥零：冷白 + 宝石蓝）
static const ARGB C_BG = 0xFFEDF2FA;
static const ARGB C_BG2 = 0xFFE4EBF7;
static const ARGB C_PANEL = 0xFFFFFFFF;
static const ARGB C_PANEL2 = 0xFFF7FAFF;
static const ARGB C_LINE = 0xFFDBE3F1;
static const ARGB C_LINE2 = 0xFFEAF0FA;
static const ARGB C_TEXT = 0xFF1A2130;
static const ARGB C_SUB = 0xFF5C6883;
static const ARGB C_FAINT = 0xFF96A3BC;
static const ARGB C_ACCENT = 0xFF3E5FBF;
static const ARGB C_ACCENT2 = 0xFF8098DA;
static const ARGB C_ACCENT_S = 0xFFEEF2FE;
static const ARGB C_OK = 0xFF3F8F72;
static const ARGB C_WARN = 0xFFB08A3E;
static const ARGB C_ERR = 0xFFB4566A;

// ---------------------------------------------------------------- 字号（四档 + 页面标题）
// 新加文字一律用这几个常量，别再往 Fnt() 里写裸数字；数值都乘 S()，150% 下跟着放大。
static const float PAGE_TITLE_SIZE = 16.5f;  // 维护/求助/帮助 的页面大标题
static const float TITLE_SIZE = 14.5f;       // 卡片、面板标题
static const float SUBTITLE_SIZE = 12.5f;    // 条目标题、输入框、按钮
static const float BODY_SIZE = 11.5f;        // 正文
static const float HINT_SIZE = 10.5f;        // 辅助信息、状态、脚注
static const float MICRO_SIZE = 9.8f;        // 胶囊、版本号这类极小字
static const float NAV_SIZE = 13.0f;         // 侧栏页签
static const float RICH_SIZE = 13.0f;        // 台账/日志富文本

static float g_scale = 1.0f;
static inline float S(float v) { return v * g_scale; }
static inline Color Cc(ARGB a) { return Color(a); }

// ---------------------------------------------------------------- 状态
static HWND g_hwnd = nullptr;
static int g_w = 1200, g_h = 760;
static HBITMAP g_bmp = nullptr;
static HDC g_mem = nullptr;
static int g_bw = 0, g_bh = 0;

static int g_tab = 0;   // 0 总览 1 B站 2 队列 3 日志 4 体检 5 维护 6 更新 7 求助 8 帮助
static const wchar_t* TABS[] = {L"总览", L"B站", L"队列", L"日志", L"体检", L"维护", L"更新", L"功能", L"求助", L"帮助"};

struct SvcDef { const wchar_t* id; const wchar_t* name; const wchar_t* port; const wchar_t* desc; };
static const SvcDef SVCS[2] = {
    {L"snowluma", L"SnowLuma", L"5099", L"挂 QQ 收消息"},
    {L"astrbot", L"AstrBot", L"6199", L"对话 · 插件 · 记忆"},
};
static bool g_svcUp[2] = {false, false};
static DWORD g_svcPid[2] = {0, 0};
static bool g_whaleOk = false;
static wstring g_whaleNote;
static wstring g_clock;

static wstring g_artHero, g_artAvatar, g_artEmpty;

static vector<FeedItem> g_feed;
static bool g_feedBusy = false;
static wstring g_feedNote = L"还没捞选题";
static int g_feedSel = -1;
static float g_feedScroll = 0;

static wstring g_bvInput;
static bool g_watchBusy = false;
static wstring g_watchStatus;
static wstring g_watchBv;      // 正在看的那条
static wstring g_watchStage;   // 进行到哪一步（①..⑥）
static int g_watchPct = 0;     // 0..100
static long long g_watchT0 = 0;
static Debrief g_result;
static bool g_hasResult = false;
static float g_watchScroll = 0, g_watchContentH = 0, g_watchViewH = 0;

static vector<JobRec> g_jobs;
static int g_jobSel = -1;
static float g_jobsScroll = 0;
static wstring g_jobDetail;
static float g_jobDetailScroll = 0, g_jobDetailH = 0, g_jobDetailView = 0;

static int g_logSrc = 0;
static const wchar_t* LOG_NAMES[] = {L"B站 / bili-whale", L"AstrBot", L"SnowLuma"};
static wstring g_logText;
static float g_logScroll = 0, g_logH = 0, g_logView = 0;
static DWORD g_logStamp = 0;

static wstring g_checkText = L"点上面的按钮跑自检。";
static float g_checkScroll = 0, g_checkH = 0, g_checkView = 0;
static bool g_checkBusy = false;
static int g_checkAction = -1;

static wstring g_toast;
static DWORD g_toastAt = 0;

static int g_editFocus = 0;

// ---------------------------------------------------------------- 布局记录（滚动区域）
static RectF g_rcFeed, g_rcWatch, g_rcLog, g_rcCheck, g_rcJobs;

// ---------------------------------------------------------------- 路径
// 工作区契约：产物/台账只看 WorkspaceDir()（见 paths.cpp），不再从 exe 位置猜。
static wstring RootDir() { return WorkspaceDir(); }
static wstring ArtDir() {
    vector<wstring> cands = {JoinPath(ExeDir(), L"art"), JoinPath(ParentDir(ExeDir()), L"art"),
                             JoinPath(SidecarDir(), L"art")};
    for (auto& c : cands) if (DirExists(c)) return c;
    return cands[1];
}
static wstring Asset(const wchar_t* name) { return JoinPath(ArtDir(), name); }
static wstring DiaryPath() { return FindWhale().diary; }

// ---------------------------------------------------------------- 字体
static map<int, Font*> g_fonts;
static Font* Fnt(float px, int weight, int mono) {
    int key = (int)(S(px) * 10) * 100 + weight * 10 + mono;
    auto it = g_fonts.find(key);
    if (it != g_fonts.end()) return it->second;
    const wchar_t* fam = mono ? L"Consolas" : (weight == 1 ? L"Microsoft YaHei UI Light" : L"Microsoft YaHei UI");
    Font* f = new Font(fam, S(px), FontStyleRegular, UnitPixel);
    if (f->GetLastStatus() != Ok) {
        delete f;
        f = new Font(L"Microsoft YaHei UI", S(px), FontStyleRegular, UnitPixel);
    }
    g_fonts[key] = f;
    return f;
}

// ---------------------------------------------------------------- 图片缓存
static map<wstring, Image*> g_imgs;
// 大图（九宫格、立绘）解码后按长边缩到这个尺寸再缓存：屏幕上最多也就画这么大，
// 留着原图只是白占内存。1400 足够九宫格里看清小字。
static const float IMG_MAX_SIDE = 1400.0f;
static Image* LoadImg(const wstring& path) {
    auto it = g_imgs.find(path);
    if (it != g_imgs.end()) return it->second;
    Image* im = nullptr;
    if (FileExists(path)) {
        Bitmap* src = Bitmap::FromFile(path.c_str(), FALSE);
        if (src && src->GetLastStatus() == Ok) {
            UINT w = src->GetWidth(), h = src->GetHeight();
            float k = 1.0f;
            if (w > IMG_MAX_SIDE || h > IMG_MAX_SIDE)
                k = IMG_MAX_SIDE / (float)(w > h ? w : h);
            if (k < 1.0f) {
                UINT nw = (UINT)(w * k + 0.5f), nh = (UINT)(h * k + 0.5f);
                Bitmap* dst = new Bitmap(nw, nh, PixelFormat32bppPARGB);
                if (dst->GetLastStatus() == Ok) {
                    Graphics g(dst);
                    g.SetCompositingMode(CompositingModeSourceCopy);
                    g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
                    g.SetPixelOffsetMode(PixelOffsetModeHighQuality);
                    g.DrawImage(src, RectF(0.0f, 0.0f, (float)nw, (float)nh), 0.0f, 0.0f,
                                (float)w, (float)h, UnitPixel);
                    im = dst;
                } else {
                    delete dst;
                }
            }
            if (!im) im = src;
            else delete src;
        } else if (src) {
            delete src;
        }
    }
    g_imgs[path] = im;
    return im;
}
// 把不再显示的大图拿走（换视频、关窗口时用），下次用到再解码
static void DropImg(const wstring& path) {
    auto it = g_imgs.find(path);
    if (it == g_imgs.end()) return;
    if (it->second) delete it->second;
    g_imgs.erase(it);
}

static void DrawImgFill(Graphics& g, Image* im, const RectF& dst, float sx /*0..1*/, float sy, float sw, float sh) {
    if (!im) return;
    float iw = (float)im->GetWidth(), ih = (float)im->GetHeight();
    g.DrawImage(im, dst, iw * sx, ih * sy, iw * sw, ih * sh, UnitPixel);
}

// ---------------------------------------------------------------- 命中 / 悬停
struct Hit { RectF r; std::string id; };
static vector<Hit> g_hits;
static std::string g_hover;
static float g_drawOffY = 0;   // 整页滚动时，命中区跟着画的偏移走
static void AddHit(const RectF& r, const std::string& id) {
    RectF rr = r;
    rr.Y += g_drawOffY;
    if (rr.Y + rr.Height < 0 || rr.Y > (float)g_h) return;   // 滚出视口的不接点击
    g_hits.push_back({rr, id});
}
static bool Hov(const std::string& id) { return g_hover == id; }
static std::string HitAt(int x, int y) {
    for (auto it = g_hits.rbegin(); it != g_hits.rend(); ++it)
        if (it->r.Contains((float)x, (float)y)) return it->id;
    return std::string();
}

// ---------------------------------------------------------------- 基础绘制
static void Round(Graphics& g, const RectF& r, float rad, ARGB fill, ARGB line, float lw = 1.0f) {
    if (r.Width <= 0 || r.Height <= 0) return;
    GraphicsPath p;
    float d = std::min(rad * 2, std::min(r.Width, r.Height));
    if (d <= 0.5f) {
        SolidBrush b(Cc(fill));
        g.FillRectangle(&b, r);
        if (line & 0xFF000000) {
            Pen pen(Cc(line), lw);
            g.DrawRectangle(&pen, r);
        }
        return;
    }
    p.AddArc(r.X, r.Y, d, d, 180, 90);
    p.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
    p.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
    p.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
    p.CloseFigure();
    SolidBrush b(Cc(fill));
    g.FillPath(&b, &p);
    if ((line & 0xFF000000) != 0) {
        Pen pen(Cc(line), lw);
        g.DrawPath(&pen, &p);
    }
}

static float Tw(Graphics& g, const wstring& s, Font* f) {
    if (s.empty()) return 0;
    RectF b;
    g.MeasureString(s.c_str(), (INT)s.size(), f, PointF(0, 0), &b);
    return b.Width;
}

// align: 0 左 1 中 2 右；ellipsis 单行裁剪
// 字体里没有的字（对勾、警告、emoji）换成能画的字符，免得出现豆腐块
static wstring GlyphFix(const wstring& s) {
    wstring o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size(); i++) {
        wchar_t c = s[i];
        if (c >= 0xD800 && c <= 0xDBFF) {  // 代理对：整对丢掉（emoji）
            if (i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) i++;
            continue;
        }
        if (c >= 0xDC00 && c <= 0xDFFF) continue;
        switch (c) {
            case 0x2713: case 0x2714: case 0x2705: o += L'\u221A'; continue;   // ✓ ✔ ✅ -> √
            case 0x2717: case 0x2718: case 0x2715: case 0x274C: o += L'\u00D7'; continue;  // ✗ ✘ ❌ -> ×
            case 0x26A0: case 0x2757: o += L'\uFF01'; continue;                // ⚠ ❗ -> ！
            case 0x1F525: o += L'\u203A'; continue;                            // 🔥 -> ›
            case 0xFE0F: case 0x200D: case 0x20E3: continue;                   // 变体选择符
            default: break;
        }
        if (c < 0x20 && c != L'\t') continue;
        o += c;
    }
    return o;
}

static void Txt(Graphics& g, const wstring& s, const RectF& r, Font* f, ARGB c, int align = 0, bool ellipsis = false,
                int valign = 1) {
    if (s.empty()) return;
    StringFormat fmt;
    fmt.SetAlignment(align == 0 ? StringAlignmentNear : (align == 1 ? StringAlignmentCenter : StringAlignmentFar));
    fmt.SetLineAlignment(valign == 1 ? StringAlignmentCenter : (valign == 0 ? StringAlignmentNear : StringAlignmentFar));
    if (ellipsis) {
        fmt.SetTrimming(StringTrimmingEllipsisCharacter);
        fmt.SetFormatFlags(StringFormatFlagsNoWrap);
    } else {
        fmt.SetFormatFlags(StringFormatFlagsNoWrap);
    }
    SolidBrush b(Cc(c));
    wstring fx = GlyphFix(s);
    if (fx.empty()) return;
    g.DrawString(fx.c_str(), (INT)fx.size(), f, r, &fmt, &b);
}

static void TxtWrap(Graphics& g, const wstring& s, const RectF& r, Font* f, ARGB c, int valign = 0) {
    if (s.empty()) return;
    StringFormat fmt;
    fmt.SetAlignment(StringAlignmentNear);
    fmt.SetLineAlignment(valign == 0 ? StringAlignmentNear : StringAlignmentCenter);
    SolidBrush b(Cc(c));
    wstring fx = GlyphFix(s);
    if (fx.empty()) return;
    g.DrawString(fx.c_str(), (INT)fx.size(), f, r, &fmt, &b);
}

static void HLine(Graphics& g, float x1, float y, float x2, ARGB c) {
    Pen p(Cc(c), 1.0f);
    g.DrawLine(&p, x1, y, x2, y);
}

static void Dot(Graphics& g, float cx, float cy, float r, ARGB c) {
    SolidBrush ring(Cc((c & 0x00FFFFFF) | 0x33000000));
    g.FillEllipse(&ring, cx - r * 2.2f, cy - r * 2.2f, r * 4.4f, r * 4.4f);
    SolidBrush b(Cc(c));
    g.FillEllipse(&b, cx - r, cy - r, r * 2, r * 2);
}

// 冥零的蝶：极细线条，半透明
static void Butterfly(Graphics& g, float cx, float cy, float s, ARGB c) {
    Pen pen(Cc(c), std::max(0.8f, S(0.9f)));
    GraphicsPath w1;
    w1.AddBezier(cx, cy, cx - s * 0.30f, cy - s * 0.95f, cx - s * 1.05f, cy - s * 0.75f, cx - s * 0.55f, cy - s * 0.10f);
    w1.AddBezier(cx - s * 0.55f, cy - s * 0.10f, cx - s * 1.00f, cy + s * 0.45f, cx - s * 0.42f, cy + s * 0.72f, cx,
                 cy + s * 0.06f);
    g.DrawPath(&pen, &w1);
    GraphicsPath w2;
    w2.AddBezier(cx, cy, cx + s * 0.30f, cy - s * 0.95f, cx + s * 1.05f, cy - s * 0.75f, cx + s * 0.55f, cy - s * 0.10f);
    w2.AddBezier(cx + s * 0.55f, cy - s * 0.10f, cx + s * 1.00f, cy + s * 0.45f, cx + s * 0.42f, cy + s * 0.72f, cx,
                 cy + s * 0.06f);
    g.DrawPath(&pen, &w2);
    g.DrawLine(&pen, cx, cy - s * 0.28f, cx, cy + s * 0.44f);
    Pen thin(Cc(c), std::max(0.6f, S(0.6f)));
    g.DrawLine(&thin, cx, cy - s * 0.26f, cx - s * 0.28f, cy - s * 0.52f);
    g.DrawLine(&thin, cx, cy - s * 0.26f, cx + s * 0.28f, cy - s * 0.52f);
}

static void Button(Graphics& g, const RectF& r, const wstring& label, const std::string& id, int kind = 0,
                   bool small = false, bool enabled = true, bool hitWhenDisabled = false) {
    bool hov = Hov(id) && enabled;
    ARGB fill, line, text;
    if (kind == 1) {                         // 主按钮
        fill = hov ? 0xFF4C6ED0 : C_ACCENT;
        line = fill;
        text = 0xFFFFFFFF;
    } else if (kind == 2) {                  // 危险/次要
        fill = hov ? 0xFFFDEEF1 : 0x00FFFFFF;
        line = 0xFFE7C6CE;
        text = C_ERR;
    } else {                                 // 幽灵
        fill = hov ? 0xFFEFF4FE : C_PANEL2;
        line = hov ? C_ACCENT2 : C_LINE;
        text = hov ? C_ACCENT : C_SUB;
    }
    if (!enabled) {
        fill = C_PANEL2;
        line = C_LINE2;
        text = C_FAINT;
    }
    Round(g, r, S(9), fill, line);
    Font* f = Fnt(small ? BODY_SIZE : SUBTITLE_SIZE, 0, 0);
    Txt(g, label, r, f, text, 1);
    // 灰的也可以点：有些按钮关着是为了点进去问「为什么不能用」（op:game_hint）
    if (enabled || (hitWhenDisabled && !id.empty())) AddHit(r, id);
}

// ---------------------------------------------------------------- 富文本排版（缓存）
struct RichLine { wstring text; int style; };
static vector<RichLine> g_rich;
static wstring g_richKey;
static float g_richWidth = 0;

static wstring StripHeading(const wstring& line) {
    wstring t = line;
    size_t a = 0, b = t.size();
    while (a < b && (t[a] == L'═' || t[a] == L' ')) a++;
    while (b > a && (t[b - 1] == L'═' || t[b - 1] == L' ' || t[b - 1] == L'\r')) b--;
    return t.substr(a, b - a);
}

static void LayoutRich(Graphics& g, const wstring& src, float width, Font* body) {
    wstring key = Num((long long)width) + L"|" + Num((long long)src.size()) + L"|" + Num((long long)src.size() * 131 +
                                                                                          (long long)(src.empty() ? 0 : src[0]));
    if (key == g_richKey && std::fabs(width - g_richWidth) < 0.5f) return;
    g_richKey = key;
    g_richWidth = width;
    g_rich.clear();
    vector<wstring> lines = SplitLines(src);
    for (auto& rawline : lines) {
        // 材料里的图片路径行不画（右边已经把封面/九宫格贴出来了），星的粗体记号也去掉
        wstring raw = ReplaceAll(rawline, L"**", L"");
        wstring t = Trim(raw);
        bool pathOnly = StartsWith(t, L"SHEET:") || StartsWith(t, L"SUBS:") ||
                        StartsWith(t, L"封面:") || StartsWith(t, L"②封面") ||
                        t == L"② 封面" || t == L"②封面";
        if (pathOnly) continue;
        if (t.size() > 3 && t[1] == L':' && t[2] == (wchar_t)92 &&
            (t.find(L".jpg") != wstring::npos || t.find(L".png") != wstring::npos))
            continue;
        if (raw.find(L"══════════") != wstring::npos) {
            g_rich.push_back({StripHeading(raw), 1});
            continue;
        }
        int style = 0;
        if (raw.size() >= 2 && raw[0] == L' ' && raw[1] == L' ') style = 2;
        if (raw.find(L"⚠️") != wstring::npos || raw.find(L"✗") != wstring::npos) style = 3;
        if (raw.empty()) {
            g_rich.push_back({L"", 0});
            continue;
        }
        wstring cur;
        for (size_t i = 0; i < raw.size(); i++) {
            cur.push_back(raw[i]);
            if (cur.size() % 3 == 0 && Tw(g, cur, body) > width) {
                wchar_t last = cur.back();
                cur.pop_back();
                g_rich.push_back({cur, style});
                cur = wstring(1, last);
            }
        }
        if (!cur.empty()) g_rich.push_back({cur, style});
    }
}

// 返回内容总高
static float DrawRich(Graphics& g, const wstring& src, const RectF& area, float scroll) {
    Font* body = Fnt(RICH_SIZE, 0, 0);
    Font* head = Fnt(RICH_SIZE, 0, 0);
    Font* mono = Fnt(12.0f, 0, 1);
    LayoutRich(g, src, area.Width - S(8), mono);
    g.SetClip(area);
    float lh = S(21);
    float y = area.Y - scroll;
    float total = 0;
    for (auto& l : g_rich) {
        if (l.style == 1) {
            y += S(10);
            total += S(10);
            Txt(g, l.text, RectF(area.X, y, area.Width, S(22)), head, C_ACCENT, 0);
            y += lh;
            total += lh;
            HLine(g, area.X, y - S(6), area.X + area.Width, C_LINE2);
        } else if (l.style == 3) {
            Txt(g, l.text, RectF(area.X, y, area.Width, lh), body, C_ERR, 0);
            y += lh;
            total += lh;
        } else if (l.style == 2) {
            Txt(g, l.text, RectF(area.X, y, area.Width, lh), mono, C_SUB, 0);
            y += lh;
            total += lh;
        } else {
            Txt(g, l.text, RectF(area.X, y, area.Width, lh), mono, C_TEXT, 0);
            y += lh;
            total += lh;
        }
    }
    g.ResetClip();
    return total + scroll * 0;
}

// ---------------------------------------------------------------- 小部件
static void Chip(Graphics& g, const RectF& r, const wstring& label, ARGB fg, ARGB bg) {
    Round(g, r, r.Height * 0.5f, bg, 0x00000000);
    Txt(g, label, r, Fnt(HINT_SIZE, 0, 0), fg, 1);
}

static void ScrollBar(Graphics& g, const RectF& area, float scroll, float contentH) {
    if (contentH <= area.Height + 1) return;
    float track = area.Height - S(4);
    float h = std::max(S(28), track * area.Height / contentH);
    float maxScroll = contentH - area.Height;
    float t = maxScroll > 0 ? scroll / maxScroll : 0;
    float y = area.Y + S(2) + t * (track - h);
    Round(g, RectF(area.X + area.Width - S(4), y, S(4), h), S(2), 0x335F6B85, 0);
}

// 打游戏模式：维护页要用，所以在 include 之前定义
static bool g_mGameOn = false, g_mGameCan = false;

// 页面与事件在 ui_pages.inc 里（同一个编译单元，共用上面的状态和绘制助手）
#include "ui_pages.inc"
// 掉线提醒的本地心跳：MuteWatchdogFor / StartWatchdog 由前面的页面代码调用，所以放最后
#include "ui_watch.inc"
