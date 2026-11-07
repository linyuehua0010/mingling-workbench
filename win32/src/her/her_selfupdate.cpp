// 覆盖更新：只换冥零工作台自己的程序文件。
//
// 为什么单开一个文件：这段逻辑要同时给 GUI（后台线程 + 分离进程）和命令行（同步演练）用，
// 而且里面有几个容易出事的细节（自己覆盖不了自己、安装失败要回滚），放一起比较好读。
//
// 铁律：
//   1. 只碰 bin / sidecar / tools / pack / plugin / skill / docs / art 这八个程序目录；
//   2. 备份写到 <机器人根>\旧版\，跟工作区同盘，回滚不用跨盘搬；
//   3. 安装器万一失败，把备份原样拷回去，再把她叫起来；
//   4. 真正动手的是「临时目录里的 updater 副本」，不是正在跑的 exe ——
//      安装器要覆盖 bin\MinglingWorkbench.exe，而正在运行的 exe 是删不掉的。
#include "her.h"

#include <tlhelp32.h>
#include <winhttp.h>

namespace her {

std::vector<std::wstring> UpdateProgramDirs() {
    return {L"bin", L"sidecar", L"tools", L"pack", L"plugin", L"skill", L"docs", L"art"};
}

// 正在跑的 exe 的完整路径（安装后是 <安装根>\MinglingWorkbench.exe，开发时是 <仓库>\bin\…exe）
static wstring SelfExePath() {
    wchar_t buf[MAX_PATH * 2] = {0};
    GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
    return wstring(buf);
}

// 程序目录（bin/sidecar/tools/…）所在的那一层。
// 安装包把 exe 直接放在根上，开发目录放在 bin\ 下，两种都得认。
static wstring ProgramRoot() {
    const wstring exeDir = AppDir();
    if (DirExists(JoinPath(exeDir, L"sidecar")) || DirExists(JoinPath(exeDir, L"art")) ||
        DirExists(JoinPath(exeDir, L"skill")))
        return exeDir;
    const wstring up = ParentDir(exeDir);
    if (DirExists(JoinPath(up, L"sidecar")) || DirExists(JoinPath(up, L"art"))) return up;
    return exeDir;
}

static wstring SafeTs() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t buf[32];
    swprintf(buf, 32, L"%04d%02d%02d-%02d%02d%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return buf;
}

static std::wstring GithubTok() {
    const wstring p = SecretFile(L"github-token.txt");
    if (!FileExists(p)) return L"";
    return Trim(ReadTextFile(p));
}

// ---------------------------------------------------------------- SHA-256
// 不引第三方库：只为了核对安装包，一个自带的实现就够。
namespace {
struct Sha256 {
    unsigned int h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    unsigned char buf[64];
    size_t n = 0;
    unsigned long long total = 0;

    static unsigned int RotR(unsigned int x, int c) { return (x >> c) | (x << (32 - c)); }

    void Block(const unsigned char* p) {
        static const unsigned int K[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        unsigned int w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((unsigned int)p[i * 4] << 24) | ((unsigned int)p[i * 4 + 1] << 16) |
                   ((unsigned int)p[i * 4 + 2] << 8) | (unsigned int)p[i * 4 + 3];
        for (int i = 16; i < 64; i++) {
            unsigned int s0 = RotR(w[i - 15], 7) ^ RotR(w[i - 15], 18) ^ (w[i - 15] >> 3);
            unsigned int s1 = RotR(w[i - 2], 17) ^ RotR(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        unsigned int a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            unsigned int S1 = RotR(e, 6) ^ RotR(e, 11) ^ RotR(e, 25);
            unsigned int ch = (e & f) ^ ((~e) & g);
            unsigned int t1 = hh + S1 + ch + K[i] + w[i];
            unsigned int S0 = RotR(a, 2) ^ RotR(a, 13) ^ RotR(a, 22);
            unsigned int mj = (a & b) ^ (a & c) ^ (b & c);
            unsigned int t2 = S0 + mj;
            hh = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

    void Feed(const unsigned char* p, size_t len) {
        total += len;
        while (len > 0) {
            size_t take = 64 - n;
            if (take > len) take = len;
            memcpy(buf + n, p, take);
            n += take;
            p += take;
            len -= take;
            if (n == 64) {
                Block(buf);
                n = 0;
            }
        }
    }

    std::wstring Done() {
        unsigned long long bits = total * 8;
        unsigned char pad = 0x80;
        Feed(&pad, 1);
        unsigned char z = 0;
        while (n != 56) Feed(&z, 1);
        unsigned char len[8];
        for (int i = 0; i < 8; i++) len[i] = (unsigned char)((bits >> (56 - i * 8)) & 0xFF);
        Feed(len, 8);
        wchar_t out[65];
        for (int i = 0; i < 8; i++) swprintf(out + i * 8, 9, L"%08x", h[i]);
        out[64] = 0;
        return out;
    }
};
}  // namespace

std::wstring Sha256File(const std::wstring& path, std::wstring* err) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        if (err) *err = L"打不开文件：" + path;
        return L"";
    }
    Sha256 s;
    std::vector<unsigned char> buf(1 << 16);
    DWORD got = 0;
    while (ReadFile(f, buf.data(), (DWORD)buf.size(), &got, nullptr) && got > 0) s.Feed(buf.data(), got);
    CloseHandle(f);
    return s.Done();
}

// ---------------------------------------------------------------- HTTP
static std::wstring UrlHost(const std::wstring& url) {
    wchar_t host[256] = {0};
    URL_COMPONENTS uc = {};
    uc.dwStructSize = sizeof(uc);
    uc.lpszHostName = host;
    uc.dwHostNameLength = 255;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return L"";
    std::wstring h(host);
    for (wchar_t& ch : h) ch = (wchar_t)towlower(ch);
    return h;
}

static bool IsGithubHost(const std::wstring& host) {
    return host == L"github.com" || host == L"api.github.com" ||
           (host.size() > 11 && host.compare(host.size() - 11, 11, L".github.com") == 0);
}

// 从原始响应头里抠一行。Location 没有「按名字取」的稳妥写法，统一走 RAW_HEADERS。
static std::wstring HeaderLine(HINTERNET r, const std::wstring& name) {
    // Location 有专门的查询号，先走它，省得自己去啃原始头
    if (_wcsicmp(name.c_str(), L"Location") == 0) {
        DWORD sz = 0;
        if (!WinHttpQueryHeaders(r, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER, &sz,
                                 WINHTTP_NO_HEADER_INDEX) &&
            GetLastError() == ERROR_INSUFFICIENT_BUFFER && sz > 0) {
            std::vector<wchar_t> b(sz / sizeof(wchar_t) + 2, 0);
            if (WinHttpQueryHeaders(r, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX, b.data(), &sz,
                                    WINHTTP_NO_HEADER_INDEX))
                return Trim(std::wstring(b.data()));
        }
    }
    DWORD sz = 0;
    if (!WinHttpQueryHeaders(r, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER,
                             &sz, WINHTTP_NO_HEADER_INDEX) &&
        GetLastError() != ERROR_INSUFFICIENT_BUFFER)
        return L"";
    if (sz == 0) return L"";
    std::vector<wchar_t> buf(sz / sizeof(wchar_t) + 2, 0);
    if (!WinHttpQueryHeaders(r, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, buf.data(), &sz,
                             WINHTTP_NO_HEADER_INDEX))
        return L"";
    std::wstring raw(buf.data());
    std::wstring want = name + L":";
    for (wchar_t& ch : want) ch = (wchar_t)towlower(ch);
    size_t pos = 0;
    while (pos < raw.size()) {
        size_t eol = raw.find(L"\r\n", pos);
        if (eol == std::wstring::npos) eol = raw.size();
        std::wstring line = raw.substr(pos, eol - pos);
        if (line.size() > want.size()) {
            std::wstring head = line.substr(0, want.size());
            for (wchar_t& ch : head) ch = (wchar_t)towlower(ch);
            if (head == want) return Trim(line.substr(want.size()));
        }
        pos = eol + 2;
    }
    return L"";
}

// 私有仓库的资产要先带 token 请求，GitHub 再 302 到 objects.githubusercontent.com 的签名地址；
// 那一跳不能再带 Authorization（S3 会嫌「两种认证并存」），所以跳转自己走，换主机就摘掉 token。
static bool HttpGetBinary(const std::wstring& url, const std::wstring& path, unsigned long long* got,
                          std::wstring* err, const std::function<void(int)>& prog, int timeoutMs) {
    if (got) *got = 0;
    const std::wstring tok = GithubTok();
    std::wstring cur = url;
    bool ok = false;
    for (int hop = 0; hop < 6 && !ok; ++hop) {
        wchar_t host[256] = {0}, obj[2048] = {0}, ext[2048] = {0};
        URL_COMPONENTS uc = {};
        uc.dwStructSize = sizeof(uc);
        uc.lpszHostName = host;
        uc.dwHostNameLength = 255;
        uc.lpszUrlPath = obj;
        uc.dwUrlPathLength = 2047; uc.lpszExtraInfo = ext; uc.dwExtraInfoLength = 2047;
        if (!WinHttpCrackUrl(cur.c_str(), 0, 0, &uc)) {
            if (err) *err = L"下载地址不对：" + cur;
            return false;
        }
        const std::wstring hostS(host); const std::wstring reqPath = std::wstring(obj) + ext;
        const bool https = uc.nScheme == INTERNET_SCHEME_HTTPS;
        HINTERNET s = WinHttpOpen(L"MinglingWorkbench/updater", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                  WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!s) {
            if (err) *err = L"网络没起来（WinHTTP 初始化失败）";
            return false;
        }
        DWORD t = (DWORD)timeoutMs;
        WinHttpSetTimeouts(s, t, t, t, t);
        HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
        if (!c) {
            WinHttpCloseHandle(s);
            if (err) *err = L"连不上这个地址（域名解析或网络问题）";
            return false;
        }
        DWORD flags = https ? WINHTTP_FLAG_SECURE : 0;
        HINTERNET r = WinHttpOpenRequest(c, L"GET", reqPath.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
        if (!r) {
            WinHttpCloseHandle(c);
            WinHttpCloseHandle(s);
            if (err) *err = L"请求没发出去";
            return false;
        }
        DWORD pol = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        WinHttpSetOption(r, WINHTTP_OPTION_REDIRECT_POLICY, &pol, sizeof(pol));
        DWORD decomp = WINHTTP_DECOMPRESSION_FLAG_ALL;
        WinHttpSetOption(r, WINHTTP_OPTION_DECOMPRESSION, &decomp, sizeof(decomp));
        if (!tok.empty() && IsGithubHost(hostS)) {
            std::wstring auth = L"Authorization: token " + tok;
            WinHttpAddRequestHeaders(r, auth.c_str(), (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD);
        }
        WinHttpAddRequestHeaders(r, L"Accept: application/octet-stream", (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD);

        std::wstring next;
        do {
            if (!WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) break;
            if (!WinHttpReceiveResponse(r, nullptr)) break;
            DWORD code = 0, clen = sizeof(code);
            WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &code, &clen, WINHTTP_NO_HEADER_INDEX);
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                std::wstring loc = HeaderLine(r, L"Location");
                if (loc.empty()) {
                    if (err) *err = L"跳转没给出地址（HTTP " + Num((long long)code) + L"）";
                    break;
                }
                if (loc.size() > 1 && loc[0] == L'/') {
                    next = (https ? L"https://" : L"http://") + hostS + loc;
                } else {
                    next = loc;
                }
                break;
            }
            if (code != 200) {
                if (err) *err = L"下载被拒（HTTP " + Num((long long)code) + L"）";
                break;
            }
            unsigned long long totalAll = 0;
            {
                wchar_t cl[64];
                DWORD csz = sizeof(cl);
                if (WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_HEADER_NAME_BY_INDEX, cl, &csz,
                                        WINHTTP_NO_HEADER_INDEX)) {
                    totalAll = (unsigned long long)_wtoi64(cl);
                }
            }
            HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (f == INVALID_HANDLE_VALUE) {
                if (err) *err = L"下载不下来：写不进 " + path;
                break;
            }
            bool wrOk = true;
            for (;;) {
                DWORD avail = 0;
                if (!WinHttpQueryDataAvailable(r, &avail)) {
                    wrOk = false;
                    break;
                }
                if (avail == 0) break;
                std::vector<char> chunk(avail);
                DWORD read = 0;
                if (!WinHttpReadData(r, chunk.data(), avail, &read) || read == 0) {
                    wrOk = false;
                    break;
                }
                DWORD written = 0;
                if (!WriteFile(f, chunk.data(), read, &written, nullptr) || written != read) {
                    wrOk = false;
                    break;
                }
                if (got) *got += read;
                if (prog && totalAll > 0) prog((int)((*got) * 100 / totalAll));
            }
            CloseHandle(f);
            if (!wrOk) {
                if (err) *err = L"下载到一半断了（网络不稳）";
                break;
            }
            ok = true;
        } while (false);

        WinHttpCloseHandle(r);
        WinHttpCloseHandle(c);
        WinHttpCloseHandle(s);
        if (!next.empty()) {
            cur = next;
            continue;
        }
    }
    if (!ok && err && err->empty()) *err = L"下载没成（跳转太多，或者地址一直在换）";
    return ok;
}

bool DownloadFile(const std::wstring& url, const std::wstring& path, unsigned long long* got, std::wstring* err,
                  const std::function<void(int)>& prog) {
    return HttpGetBinary(url, path, got, err, prog, 60000);
}

// ---------------------------------------------------------------- 找安装包
static bool GetRelJson(const std::wstring& url, J* out) {
    const wstring tok = GithubTok();
    Http h = tok.empty() ? HttpGet(url, 8000) : HttpGetJson(url, tok, 8000);
    if (!h.ok || h.code >= 400) {
        // 没 token 时 api.github.com 容易限流，换成网页兜底没必要：这里只要资产清单
        return false;
    }
    bool ok = false;
    J j = J::Parse(h.body, &ok);
    if (!ok) return false;
    *out = j;
    return true;
}

SetupAsset FindSetupAsset(const std::wstring& repo, const std::wstring& version) {
    SetupAsset a;
    const wstring tok = GithubTok();
    if (repo.empty()) {
        a.err = L"还没配更新源（repo_snapshot），不知道去哪儿找安装包";
        return a;
    }
    wstring want = version;
    if (!want.empty() && (want[0] == L'v' || want[0] == L'V')) want = want.substr(1);
    if (want.empty()) {
        a.err = L"还不知道最新版是多少：先点「再查一遍」";
        return a;
    }
    J list;
    if (!GetRelJson(L"https://api.github.com/repos/" + repo + L"/releases?per_page=100", &list) || !list.Arr()) {
        a.err = L"查不到 release 列表（网络不通，或者 GitHub 限流了）";
        return a;
    }
    const J* pick = nullptr;
    for (const J& rel : list.a) {
        wstring tag = rel.Str(L"tag_name");
        wstring v = tag;
        if (!v.empty() && (v[0] == L'v' || v[0] == L'V')) v = v.substr(1);
        if (v == want) {
            pick = &rel;
            break;
        }
    }
    if (!pick) {
        a.err = L"这个版本在 GitHub 上没找到 release（" + want + L"）";
        return a;
    }
    a.tag = pick->Str(L"tag_name");
    const J* assets = pick->Get(L"assets");
    if (!assets || !assets->Arr()) {
        a.err = L"这个 release 还没挂安装包";
        return a;
    }
    for (const J& it : assets->a) {
        wstring nm = it.Str(L"name");
        wstring low = nm;
        for (auto& c : low) c = (wchar_t)towlower(c);
        if (low.size() > 4 && low.substr(low.size() - 4) == L".exe" && IContains(low, L"setup")) {
            if (!a.url.empty()) continue;   // 有多个时留第一个
            a.name = nm;
            const long long aid = it.Int(L"id", 0);
            a.url = (tok.empty() || aid <= 0)
                        ? it.Str(L"browser_download_url")
                        : (L"https://api.github.com/repos/" + repo + L"/releases/assets/" + Num(aid));
            a.size = (unsigned long long)it.Int(L"size", 0);
            if (a.size == 0) {
                const J* sz = it.Get(L"size");
                if (sz && sz->t == J::NUM) a.size = (unsigned long long)sz->num;
            }
        }
    }
    if (a.url.empty()) {
        a.err = L"release 里没找到 setup 安装包";
        return a;
    }
    for (const J& it : assets->a) {
        wstring nm = it.Str(L"name");
        if (nm == a.name + L".sha256" || nm == a.name + L".sha256.txt") {
            const long long sid = it.Int(L"id", 0);
            a.shaUrl = (tok.empty() || sid <= 0)
                           ? it.Str(L"browser_download_url")
                           : (L"https://api.github.com/repos/" + repo + L"/releases/assets/" + Num(sid));
            break;
        }
    }
    a.ok = true;
    return a;
}

// ---------------------------------------------------------------- 备份 / 计划
static bool CopyProgramOut(const std::wstring& destRoot, std::wstring* err,
                           const std::function<void(int)>& prog) {
    const wstring app = ProgramRoot();
    std::vector<std::wstring> dirs = UpdateProgramDirs();
    int i = 0;
    for (auto& d : dirs) {
        wstring from = JoinPath(app, d);
        wstring to = JoinPath(destRoot, d);
        if (!DirExists(from)) continue;
        if (!CopyDirTree(from, to)) {
            if (err) *err = L"备份失败：" + from;
            return false;
        }
        i++;
        if (prog) prog(i * 100 / (int)dirs.size());
    }
    // exe 自己不在任何白名单目录里，单独留一份；回滚时按原位置放回去
    const wstring self = SelfExePath();
    if (FileExists(self)) {
        wstring keep = JoinPath(destRoot, L"_self");
        CreateDirectoryW(keep.c_str(), nullptr);
        if (!CopyFileW(self.c_str(), JoinPath(keep, L"MinglingWorkbench.exe").c_str(), FALSE)) {
            if (err) *err = L"备份工作台主程序失败：" + self;
            return false;
        }
        const wstring loader = JoinPath(ParentDir(self), L"WebView2Loader.dll");
        if (FileExists(loader) && !CopyFileW(loader.c_str(), JoinPath(keep, L"WebView2Loader.dll").c_str(), FALSE)) {
            if (err) *err = L"备份界面加载器失败：" + loader;
            return false;
        }
    }
    return true;
}

static bool CopyProgramBack(const std::wstring& bakRoot, std::wstring* err) {
    const wstring app = ProgramRoot();
    for (auto& d : UpdateProgramDirs()) {
        wstring from = JoinPath(bakRoot, d);
        if (!DirExists(from)) continue;
        if (!CopyDirTree(from, JoinPath(app, d))) {
            if (err) *err = L"回滚失败：" + from;
            return false;
        }
    }
    wstring selfBak = JoinPath(JoinPath(bakRoot, L"_self"), L"MinglingWorkbench.exe");
    if (FileExists(selfBak)) {
        const wstring self = SelfExePath();
        CopyFileW(selfBak.c_str(), self.c_str(), FALSE);   // 正被占用时由 helper 之后的重启兜底
    }
    const wstring loaderBak = JoinPath(JoinPath(bakRoot, L"_self"), L"WebView2Loader.dll");
    if (FileExists(loaderBak) && !CopyFileW(loaderBak.c_str(), JoinPath(ParentDir(SelfExePath()), L"WebView2Loader.dll").c_str(), FALSE)) {
        if (err) *err = L"回滚界面加载器失败";
        return false;
    }
    return true;
}

UpdatePlan PlanUpdate(const std::wstring& setupPath, const std::wstring& tag) {
    UpdatePlan p;
    p.setup = setupPath;
    if (!FileExists(setupPath)) {
        p.err = L"安装包不在：" + setupPath;
        return p;
    }
    p.exePath = SelfExePath();
    wstring tagSafe = tag.empty() ? wstring(L"update") : tag;
    for (auto& c : tagSafe) {
        if (c == L'/' || c == L'\\' || c == L':' || c == L'*' || c == L'?' || c == L'"' || c == L'<' || c == L'>' ||
            c == L'|' || c == L' ')
            c = L'-';
    }
    wstring wbRoot = WorkspaceDir();
    if (wbRoot.empty()) wbRoot = ProgramRoot();   // 机器人根 = 工作区，机器人组件在 bots\ 下，别往里写
    p.backupDir = JoinPath(JoinPath(JoinPath(wbRoot, L"旧版"), L"workbench-" + tagSafe + L"-" + SafeTs()), L"");
    if (!p.backupDir.empty() && (p.backupDir.back() == L'\\' || p.backupDir.back() == L'/')) p.backupDir.pop_back();
    if (!CopyProgramOut(p.backupDir, &p.err, nullptr)) {
        if (p.err.empty()) p.err = L"备份程序文件时出错了";
        return p;
    }
    p.log = JoinPath(p.backupDir, L"install.log");
    // 自己的副本：安装器要覆盖 bin 里的 exe，正在跑的那个删不掉
    wchar_t tmp[MAX_PATH];
    GetTempPathW(MAX_PATH, tmp);
    p.helper = JoinPath(tmp, L"mingling-updater-" + SafeTs() + L".exe");
    if (!CopyFileW(p.exePath.c_str(), p.helper.c_str(), FALSE)) {
        p.err = L"没法把自己复制到临时目录（可能被安全软件拦了）";
        return p;
    }
    p.ok = true;
    return p;
}

static bool RunInstaller(const std::wstring& setup, const std::wstring& logPath, int* code, std::wstring* err) {
    if (code) *code = -1;
    wstring cmd = L"\"" + setup + L"\" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS";
    if (!logPath.empty()) cmd += L" /LOG=\"" + logPath + L"\"";
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        if (err) *err = L"安装器起不来（可能被杀毒软件拦了）";
        return false;
    }
    WaitForSingleObject(pi.hProcess, 10 * 60 * 1000);
    DWORD ec = 1;
    GetExitCodeProcess(pi.hProcess, &ec);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (code) *code = (int)ec;
    return true;
}

bool ApplyUpdateSync(const UpdatePlan& p, int* code, std::wstring* err) {
    if (!p.ok) {
        if (err) *err = p.err.empty() ? wstring(L"更新计划没准备好") : p.err;
        return false;
    }
    int ec = -1;
    if (!RunInstaller(p.setup, p.log, &ec, err)) return false;
    if (code) *code = ec;
    if (ec != 0) {
        wstring rerr;
        if (!CopyProgramBack(p.backupDir, &rerr)) {
            if (err) *err = L"安装器退出码 " + Num(ec) + L"，回滚也没成：" + rerr;
            return false;
        }
        if (err) *err = L"安装器退出码 " + Num(ec) + L"，已经回滚到备份";
        return false;
    }
    return true;
}

bool LaunchUpdateDetached(const UpdatePlan& p, std::wstring* err) {
    if (!p.ok) {
        if (err) *err = p.err.empty() ? wstring(L"更新计划没准备好") : p.err;
        return false;
    }
    wstring cmd = L"\"" + p.helper + L"\" --wb-update-run \"" + p.backupDir + L"\" \"" + p.setup + L"\" \"" + p.log +
                  L"\" " + Num((long long)GetCurrentProcessId()) + L" \"" + p.exePath + L"\"";
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                        nullptr, nullptr, &si, &pi)) {
        if (err) *err = L"升级程序起不来（可能被杀毒软件拦了）";
        return false;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}

int RunUpdateHelper(const std::wstring& backupDir, const std::wstring& setup, const std::wstring& logPath,
                    unsigned long parentPid, const std::wstring& exePath) {
    // 1. 等老的那个退出：它不退，bin 里的 exe 就换不掉
    HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)parentPid);
    if (parent) {
        WaitForSingleObject(parent, 120 * 1000);
        CloseHandle(parent);
    }
    Sleep(600);

    auto relaunch = [&]() {
        if (exePath.empty() || !FileExists(exePath)) return;
        wstring c = L"\"" + exePath + L"\"";
        std::vector<wchar_t> b(c.begin(), c.end());
        b.push_back(0);
        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi = {};
        CreateProcessW(nullptr, b.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    };

    wstring err;
    int code = -1;
    if (!RunInstaller(setup, logPath, &code, &err)) {
        WriteTextFile(logPath, L"[更新] 安装器没起来：" + err + L"\r\n", true);
        relaunch();
        return 2;
    }
    if (code != 0) {
        wstring rerr;
        bool rolled = CopyProgramBack(backupDir, &rerr);
        WriteTextFile(logPath, L"[更新] 安装器退出码 " + Num(code) + L"，" +
                                   (rolled ? wstring(L"已经回滚到 ") : wstring(L"回滚失败 ")) +
                                   (rolled ? backupDir : rerr) + L"\r\n", true);
        relaunch();
        return 1;
    }
    WriteTextFile(logPath, L"[更新] 装好了，正在重启。\r\n", true);
    relaunch();
    return 0;
}

}  // namespace her
