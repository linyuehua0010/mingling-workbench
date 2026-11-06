// 冥零工作台 · 输入分类 + 通用网页读取
//
// 两个用途：
//   1. 判断用户往输入框里粘的到底是什么：B 站链接/BV、别的网页链接、QQ/微信那种
//      分享文本，还是本地快捷方式。判错的代价很大（拿网页去跑 debrief 会白等），
//      所以规则写得保守：只认真正看得到的证据。
//   2. 「其他链接」的 MVP 读取：一次 GET，跟重定向、限时、限大小，抽 <title> 和
//      去掉标签的正文。不执行 JS、不登录、不绕风控——读不到就老实说读不到。
#include "core.h"

#include <windows.h>
#include <winhttp.h>

#include <algorithm>

// ---------------------------------------------------------------- 文本小工具

static wstring LowerAscii(const wstring& s) {
    wstring r = s;
    for (auto& c : r)
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
    return r;
}

static bool EndsWithNoCase(const wstring& s, const wstring& tail) {
    if (s.size() < tail.size()) return false;
    return LowerAscii(s.substr(s.size() - tail.size())) == LowerAscii(tail);
}

// 链接到这里就该停了：空白、引号、尖括号，以及中文标点（分享文本里常见）
static bool IsUrlStop(wchar_t c) {
    switch (c) {
        case L' ':
        case L'\t':
        case L'\r':
        case L'\n':
        case L'"':
        case L'\'':
        case L'<':
        case L'>':
        case L'（':
        case L'）':
        case L'【':
        case L'】':
        case L'，':
        case L'。':
        case L'、':
        case L'；':
        case L'：':
        case L'！':
        case L'？':
        case L'“':
        case L'”':
        case L'《':
        case L'》': return true;
        default: return false;
    }
}

wstring FirstUrl(const wstring& text) {
    wstring low = LowerAscii(text);
    size_t h = low.find(L"http://");
    size_t s = low.find(L"https://");
    size_t at = wstring::npos;
    if (h == wstring::npos) at = s;
    else if (s == wstring::npos) at = h;
    else at = std::min(h, s);
    if (at == wstring::npos) return L"";

    size_t end = at;
    while (end < text.size() && !IsUrlStop(text[end])) end++;
    wstring url = text.substr(at, end - at);
    // 句末的英文标点也去掉（"看这个 https://a.com/x." 里最后的点是句子的一部分）
    while (!url.empty()) {
        wchar_t c = url.back();
        if (c == L'.' || c == L',' || c == L';' || c == L':' || c == L')' || c == L']' || c == L'}' ||
            c == L'!' || c == L'?')
            url.pop_back();
        else
            break;
    }
    return url;
}

static bool LooksLikeBiliHost(const wstring& url) {
    wstring low = LowerAscii(url);
    return low.find(L"bilibili.com") != wstring::npos || low.find(L"b23.tv") != wstring::npos ||
           low.find(L"bili2233.cn") != wstring::npos || low.find(L"bili22.cn") != wstring::npos;
}

// 手打的 BV 号常常是小写开头（bv1xx…），ExtractBv 只认大写，这里先扶正再找一次。
static wstring BvLoose(const wstring& text) {
    wstring up = text;
    for (size_t i = 0; i + 1 < up.size(); i++)
        if (up[i] == L'b' && up[i + 1] == L'v') {
            up[i] = L'B';
            up[i + 1] = L'V';
        }
    return ExtractBv(up);
}

// 句末标点不算内容：整串「链接 + 句号」仍然算「只粘贴了一个链接」
static wstring TrimEdgePunct(const wstring& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == L' ' || s[b] == L'\t')) b++;
    while (e > b && (s[e - 1] == L' ' || s[e - 1] == L'\t' || IsUrlStop(s[e - 1]) || s[e - 1] == L'.' ||
                     s[e - 1] == L',' || s[e - 1] == L';' || s[e - 1] == L':' || s[e - 1] == L')' ||
                     s[e - 1] == L']' || s[e - 1] == L'}' || s[e - 1] == L'!' || s[e - 1] == L'?'))
        e--;
    return s.substr(b, e - b);
}

InputAction ClassifyInput(const wstring& in) {
    InputAction a;
    a.text = Trim(in);
    if (a.text.empty()) {
        a.kind = IN_EMPTY;
        return a;
    }

    // 本地路径 / 快捷方式：整串就是一个存在的文件，才认。
    // 只做「打开」——不注入进程、不读屏幕、不抓应用内容。
    wstring t = a.text;
    if (t.size() >= 2 && t.front() == L'"' && t.back() == L'"') t = Trim(t.substr(1, t.size() - 2));
    if (FileExists(t)) {
        wstring low = LowerAscii(t);
        if (EndsWithNoCase(low, L".lnk") || EndsWithNoCase(low, L".exe") || EndsWithNoCase(low, L".url") ||
            (t.size() > 2 && t[1] == L':')) {
            a.kind = IN_PATH;
            a.path = t;
            return a;
        }
    }

    a.url = FirstUrl(a.text);
    a.bv = ExtractBv(a.text);
    if (a.bv.empty()) a.bv = BvLoose(a.text);

    if (LooksLikeBiliHost(a.text)) {
        // B 站链接（含 b23.tv 短链、分享文本）一律走原来的看片链路
        a.kind = IN_BILI;
        return a;
    }
    if (!a.bv.empty()) {
        // 只粘了 BV 号（或者句子里的 BV 号）
        a.kind = IN_BILI;
        return a;
    }
    if (!a.url.empty()) {
        // 整串就是链接 → 普通链接；前后还有话 → 应用分享文本
        a.kind = LowerAscii(TrimEdgePunct(a.text)) == LowerAscii(a.url) ? IN_URL : IN_SHARE;
        return a;
    }
    a.kind = IN_UNKNOWN;
    return a;
}

// ---------------------------------------------------------------- 解码

static bool ValidUtf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        int n = 0;
        if ((c & 0xE0) == 0xC0) n = 1;
        else if ((c & 0xF0) == 0xE0) n = 2;
        else if ((c & 0xF8) == 0xF0) n = 3;
        else return false;
        if (i + n >= s.size()) return false;
        for (int k = 1; k <= n; k++)
            if (((unsigned char)s[i + k] & 0xC0) != 0x80) return false;
        i += n + 1;
    }
    return true;
}

static wstring FromCp(const std::string& s, UINT cp) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), nullptr, 0);
    if (n <= 0) return L"";
    wstring out((size_t)n, L'\0');
    MultiByteToWideChar(cp, 0, s.data(), (int)s.size(), &out[0], n);
    return out;
}

// 网页编码：头里写明了就照它；没写就看字节——先当 UTF-8，不合法再当 GBK。
// 中文站点这两种覆盖了绝大多数，剩下的按 GBK 兜底总比乱码好。
static wstring DecodePage(const std::string& raw, bool gbkHint) {
    if (raw.empty()) return L"";
    if (gbkHint) return FromCp(raw, CP_ACP);
    if (ValidUtf8(raw)) return FromCp(raw, CP_UTF8);
    return FromCp(raw, CP_ACP);
}

// ---------------------------------------------------------------- HTML 抽取

static wstring StripHtml(const wstring& html, wstring* titleOut) {
    wstring title;
    wstring body;
    body.reserve(html.size());

    size_t i = 0;
    const size_t n = html.size();
    // 跳过 <script>/<style> 的整段内容：它们是正文里的噪音
    while (i < n) {
        if (html[i] != L'<') {
            body.push_back(html[i]);
            i++;
            continue;
        }
        // 找出这个标签的名字
        size_t gt = html.find(L'>', i);
        if (gt == wstring::npos) break;
        wstring tag = html.substr(i + 1, gt - i - 1);
        wstring lowTag = LowerAscii(tag);
        bool closing = false;
        size_t k = 0;
        while (k < lowTag.size() && (lowTag[k] == L' ' || lowTag[k] == L'\t' || lowTag[k] == L'\r' || lowTag[k] == L'\n'))
            k++;
        if (k < lowTag.size() && lowTag[k] == L'/') {
            closing = true;
            k++;
        }
        wstring name;
        while (k < lowTag.size() && ((lowTag[k] >= L'a' && lowTag[k] <= L'z') || (lowTag[k] >= L'0' && lowTag[k] <= L'9')))
            name.push_back(lowTag[k++]);

        if (name == L"script" || name == L"style" || name == L"noscript") {
            if (!closing) {
                wstring endTag = L"</" + name;
                size_t e = LowerAscii(html).find(endTag, gt);
                if (e == wstring::npos) {
                    i = n;
                } else {
                    size_t e2 = html.find(L'>', e);
                    i = (e2 == wstring::npos) ? n : e2 + 1;
                }
            } else {
                i = gt + 1;
            }
            continue;
        }
        if (name == L"title" && !closing) {
            size_t e = LowerAscii(html).find(L"</title", gt);
            if (e != wstring::npos) title = Trim(html.substr(gt + 1, e - gt - 1));
            i = gt + 1;
            continue;
        }
        if (name == L"br" || name == L"p" || name == L"div" || name == L"li" || name == L"tr" || name == L"h1" ||
            name == L"h2" || name == L"h3" || name == L"h4" || name == L"section" || name == L"article" ||
            name == L"header" || name == L"footer" || name == L"blockquote") {
            body.push_back(L'\n');
        }
        i = gt + 1;
    }

    // 一行一行收拾：去标签残留、解码实体、压掉多余空白、丢掉空行
    wstring out;
    for (auto& line : SplitLines(body)) {
        wstring s = UnescapeHtml(line);
        wstring cleaned;
        bool lastSpace = true;
        for (wchar_t c : s) {
            if (c == L' ' || c == L'\t' || c == L'\r' || c == 0x3000) {
                if (!lastSpace) cleaned.push_back(L' ');
                lastSpace = true;
            } else {
                cleaned.push_back(c);
                lastSpace = false;
            }
        }
        cleaned = Trim(cleaned);
        if (cleaned.empty()) continue;
        if (!out.empty()) out.push_back(L'\n');
        out += cleaned;
    }
    if (titleOut) *titleOut = UnescapeHtml(title);
    return out;
}

// ---------------------------------------------------------------- 取网页

static wstring ErrFromWinHttp(DWORD e) {
    switch (e) {
        case ERROR_WINHTTP_TIMEOUT: return L"等太久了（超时）";
        case ERROR_WINHTTP_NAME_NOT_RESOLVED: return L"域名解析不了（地址写错或没网）";
        case ERROR_WINHTTP_CANNOT_CONNECT: return L"连不上这个站点";
        case ERROR_WINHTTP_SECURE_FAILURE: return L"对方证书有问题，没敢继续";
        case ERROR_WINHTTP_INVALID_URL: return L"地址格式不对";
        case ERROR_WINHTTP_OPERATION_CANCELLED: return L"读取被取消了";
        default: return L"网络出错（代码 " + Num((long long)e) + L"）";
    }
}

WebPage FetchWebPage(const wstring& url, int timeoutMs, size_t maxBytes) {
    WebPage p;
    p.url = url;
    if (url.empty()) {
        p.err = L"没有链接";
        return p;
    }
    if (maxBytes == 0) maxBytes = 512 * 1024;
    if (timeoutMs < 1000) timeoutMs = 1000;

    URL_COMPONENTS uc = {};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[512] = {0};
    wchar_t path[4096] = {0};
    wchar_t extra[4096] = {0};
    uc.lpszHostName = host;
    uc.dwHostNameLength = 511;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 4095;
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = 4095;
    if (!WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &uc) || host[0] == 0) {
        p.err = L"这不是一个完整链接（要 http:// 或 https:// 开头）";
        return p;
    }
    wstring target = wstring(path);
    if (extra[0]) target += extra;

    HINTERNET s = WinHttpOpen(L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) MinglingWorkbench/3.0",
                              WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) {
        p.err = ErrFromWinHttp(GetLastError());
        return p;
    }
    // 跟随重定向是需求；默认策略在 WinHTTP 里不一定跟到底，这里显式设成「一直跟」
    DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(s, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
    WinHttpSetTimeouts(s, timeoutMs, timeoutMs, timeoutMs, timeoutMs);

    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) {
        p.err = ErrFromWinHttp(GetLastError());
        WinHttpCloseHandle(s);
        return p;
    }
    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET r = WinHttpOpenRequest(c, L"GET", target.c_str(), nullptr, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!r) {
        p.err = ErrFromWinHttp(GetLastError());
        WinHttpCloseHandle(c);
        WinHttpCloseHandle(s);
        return p;
    }

    const wchar_t* headers =
        L"Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.8\r\n"
        L"Accept-Language: zh-CN,zh;q=0.9,en;q=0.6\r\n";
    BOOL ok = WinHttpSendRequest(r, headers, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
              WinHttpReceiveResponse(r, nullptr);
    if (!ok) {
        p.err = ErrFromWinHttp(GetLastError());
        WinHttpCloseHandle(r);
        WinHttpCloseHandle(c);
        WinHttpCloseHandle(s);
        return p;
    }

    DWORD code = 0, len = sizeof(code);
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code,
                        &len, WINHTTP_NO_HEADER_INDEX);
    p.code = (int)code;

    // 实际地址（跟完重定向之后的）
    wchar_t finalUrl[4096] = {0};
    DWORD fuLen = sizeof(finalUrl);
    if (WinHttpQueryOption(r, WINHTTP_OPTION_URL, finalUrl, &fuLen) && finalUrl[0]) p.url = finalUrl;

    // Content-Type：不是为了挑剔，是要知道编码、也要判断「这压根不是网页」
    wchar_t ctype[512] = {0};
    DWORD ctLen = sizeof(ctype);
    WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX, ctype, &ctLen,
                        WINHTTP_NO_HEADER_INDEX);
    wstring ctypeW = LowerAscii(ctype);
    bool gbkHint = ctypeW.find(L"gbk") != wstring::npos || ctypeW.find(L"gb2312") != wstring::npos ||
                   ctypeW.find(L"gb18030") != wstring::npos;
    bool htmlType = ctypeW.find(L"text/html") != wstring::npos || ctypeW.find(L"application/xhtml") != wstring::npos ||
                    ctypeW.find(L"text/plain") != wstring::npos;

    std::string all;
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(r, &avail)) {
            p.err = ErrFromWinHttp(GetLastError());
            break;
        }
        if (avail == 0) break;
        std::string buf(avail, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(r, &buf[0], avail, &read) || read == 0) break;
        all.append(buf.data(), read);
        if (all.size() >= maxBytes) {
            all.resize(maxBytes);
            break;
        }
    }
    WinHttpCloseHandle(r);
    WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);

    p.bytes = all.size();
    if (!p.err.empty()) return p;
    if (p.code >= 400) {
        p.err = L"对方拒绝了（HTTP " + Num(p.code) + L"）";
        return p;
    }
    if (all.empty()) {
        p.err = L"这个地址没返回内容";
        return p;
    }

    wstring html = DecodePage(all, gbkHint);
    bool looksHtml = html.find(L'<') != wstring::npos;
    if (!htmlType && !looksHtml) {
        p.err = L"这个地址不是网页（像图片、文件或接口返回）";
        return p;
    }

    wstring title;
    wstring text = StripHtml(html, &title);
    if (text.size() > 8000) text = text.substr(0, 8000) + L"\n…（后面还有，先看这些）";
    p.title = title.empty() ? L"（无标题）" : title;
    p.text = text;
    if (text.empty()) {
        p.err = L"网页里没抽到能读的正文（可能要登录，或者整页是脚本画的）";
        return p;
    }
    p.ok = true;
    return p;
}
