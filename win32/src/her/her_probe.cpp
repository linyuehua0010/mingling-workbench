// 冥零工作台 · 系统层：端口表、进程、HTTP、启动命令、md5
// 这些原来都是 python 里用 psutil / subprocess / urllib 做的，现在直接问 Windows。
#include "her.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <tlhelp32.h>
#include <winhttp.h>

#include <cstdio>
#include <cwchar>
#include <mutex>

#pragma comment(lib, "winhttp.lib")

namespace her {

namespace {

std::wstring Lower(std::wstring s) {
    for (auto& c : s)
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
    return s;
}

std::wstring FileNameOf(const std::wstring& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == std::wstring::npos ? p : p.substr(i + 1);
}

struct ProcEntry {
    DWORD pid = 0, parent = 0;
};

std::vector<ProcEntry> Snapshot() {
    std::vector<ProcEntry> out;
    HANDLE h = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (h == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(h, &pe)) {
        do {
            ProcEntry e;
            e.pid = pe.th32ProcessID;
            e.parent = pe.th32ParentProcessID;
            out.push_back(e);
        } while (Process32NextW(h, &pe));
    }
    CloseHandle(h);
    return out;
}

}  // namespace

// ---------------------------------------------------------------- 端口表
// 端口表要给好几个线程看（看门狗心跳、维护页刷新、更新检查同时可能都在问），
// 所以这里每次都拷一份出去：谁也别拿着别人的 vector 一边读一边被清空。
NetSnap Net() {
    static std::mutex mx;
    static NetSnap snap;
    std::lock_guard<std::mutex> lk(mx);
    DWORD now = GetTickCount();
    if (snap.at && now - snap.at < 2000) return snap;
    snap.listen.clear();
    snap.est.clear();
    snap.at = now;

    DWORD size = 0;
    if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) ==
        ERROR_INSUFFICIENT_BUFFER) {
        std::vector<char> buf(size);
        if (GetExtendedTcpTable(buf.data(), &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) == NO_ERROR) {
            auto* t = (MIB_TCPTABLE_OWNER_PID*)buf.data();
            for (DWORD i = 0; i < t->dwNumEntries; i++)
                snap.listen[(int)ntohs((u_short)t->table[i].dwLocalPort)] = t->table[i].dwOwningPid;
        }
    }
    size = 0;
    if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0) ==
        ERROR_INSUFFICIENT_BUFFER) {
        std::vector<char> buf(size);
        if (GetExtendedTcpTable(buf.data(), &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0) == NO_ERROR) {
            auto* t = (MIB_TCPTABLE_OWNER_PID*)buf.data();
            for (DWORD i = 0; i < t->dwNumEntries; i++) {
                auto& row = t->table[i];
                if (row.dwState != MIB_TCP_STATE_ESTAB) continue;
                Est e;
                e.lport = (int)ntohs((u_short)row.dwLocalPort);
                e.rport = (int)ntohs((u_short)row.dwRemotePort);
                e.pid = row.dwOwningPid;
                snap.est.push_back(e);
            }
        }
    }
    return snap;
}

bool Listening(int port) { return Net().listen.count(port) > 0; }

DWORD ListenPid(int port) {
    NetSnap n = Net();
    auto it = n.listen.find(port);
    return it == n.listen.end() ? 0 : it->second;
}

std::wstring ImagePath(DWORD pid) {
    // 同一个缓存也会被几个线程同时问（维护页刷新、更新检查、掉线看门狗），
    // 锁一下：std::map 并发插入会把堆写坏，表现成乱七八糟的 0xc0000005。
    static std::mutex mx;
    static std::map<DWORD, std::pair<std::wstring, DWORD>> cache;  // pid -> (path, tick)
    DWORD now = GetTickCount();
    {
        std::lock_guard<std::mutex> lk(mx);
        auto it = cache.find(pid);
        if (it != cache.end() && now - it->second.second < 3000) return it->second.first;
    }
    std::wstring path;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h) {
        wchar_t buf[MAX_PATH * 2];
        DWORD n = (DWORD)(sizeof(buf) / sizeof(buf[0]));
        if (QueryFullProcessImageNameW(h, 0, buf, &n)) path = Lower(std::wstring(buf, n));
        CloseHandle(h);
    }
    if (!path.empty()) {
        std::lock_guard<std::mutex> lk(mx);
        cache[pid] = {path, now};
    }
    return path;
}

std::vector<DWORD> PidsUnder(const std::wstring& rootLower) {
    std::vector<DWORD> out;
    for (auto& e : Snapshot()) {
        if (e.pid == 0 || e.pid == GetCurrentProcessId()) continue;
        std::wstring p = ImagePath(e.pid);
        if (!p.empty() && StartsWith(p, rootLower)) out.push_back(e.pid);
    }
    return out;
}

std::vector<DWORD> PidsNamed(const std::wstring& exeLower) {
    std::vector<DWORD> out;
    for (auto& e : Snapshot()) {
        if (!e.pid) continue;
        std::wstring p = FileNameOf(ImagePath(e.pid));
        if (p == exeLower) out.push_back(e.pid);
    }
    return out;
}

bool ExeUnder(DWORD pid, const std::wstring& rootLower) {
    std::wstring p = ImagePath(pid);
    return !p.empty() && StartsWith(p, rootLower);
}

std::vector<DWORD> ChildrenOf(DWORD pid) {
    std::vector<DWORD> out;
    for (auto& e : Snapshot())
        if (e.parent == pid && e.pid != pid) out.push_back(e.pid);
    return out;
}

bool IsSelf(DWORD pid) {
    if (pid == GetCurrentProcessId()) return true;
    DWORD cur = GetCurrentProcessId();
    for (int depth = 0; depth < 8; depth++) {
        DWORD parent = 0;
        for (auto& e : Snapshot())
            if (e.pid == cur) {
                parent = e.parent;
                break;
            }
        if (!parent || parent == pid) return parent == pid;
        cur = parent;
    }
    return false;
}

bool KillTree(DWORD pid) {
    if (!pid || IsSelf(pid)) return false;
    for (DWORD c : ChildrenOf(pid)) KillTree(c);
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (!h) return false;
    BOOL ok = TerminateProcess(h, 1);
    CloseHandle(h);
    return ok != FALSE;
}

int KillUnder(const std::wstring& rootLower) {
    int n = 0;
    for (DWORD pid : PidsUnder(rootLower))
        if (KillTree(pid)) n++;
    return n;
}

std::vector<DWORD> AstrBotPids() {
    std::vector<DWORD> out;
    auto add = [&](const std::wstring& dir) {
        if (dir.empty()) return;
        for (DWORD pid : PidsUnder(Lower(dir)))
            if (std::find(out.begin(), out.end(), pid) == out.end()) out.push_back(pid);
    };
    add(P(L"uv"));              // 老布局：<Base>\uv
    add(BotPath(L"uv"));        // 新布局：<工作区>\bots\uv
    add(BotPath(L"AstrBot"));   // python 直接跑在组件目录里
    // 端口被占的那个也是它（有时候命令行不是 python 也算）
    int port = BackendPort();
    DWORD pp = ListenPid(port);
    if (pp && std::find(out.begin(), out.end(), pp) == out.end() && !IsSelf(pp)) out.push_back(pp);
    return out;
}

bool QqOnline() {
    J cfg = CmdConfig();
    int ws = 6199;
    const J* plat = cfg.Get(L"platform");
    if (plat && plat->t == J::ARR) {
        for (auto& p : plat->a) {
            if (p.Str(L"type") != L"aiocqhttp") continue;
            ws = (int)p.Int(L"ws_reverse_port", 6199);
            break;
        }
    }
    DWORD listenPid = ListenPid(ws);
    if (!listenPid) return false;
    auto astr = AstrBotPids();
    bool owner = std::find(astr.begin(), astr.end(), listenPid) != astr.end();
    if (!owner) {
        // 端口是它开的，但进程表里没认出来（比如被别的壳包着）也算
        owner = true;
    }
    std::wstring dirs[] = {Lower(P(L"SnowLuma")), Lower(P(L"NapCat")),
                           Lower(BotPath(L"SnowLuma")), Lower(BotPath(L"NapCat"))};
    NetSnap net = Net();
    for (auto& e : net.est) {
        if (e.rport != ws) continue;
        std::wstring p = ImagePath(e.pid);
        if (p.empty()) continue;
        for (auto& d : dirs)
            if (!d.empty() && StartsWith(p, d)) return owner;
    }
    return false;
}

// ---------------------------------------------------------------- HTTP
Http HttpCall(const std::wstring& method, const std::wstring& url, const std::wstring& body,
              const std::vector<std::pair<std::wstring, std::wstring>>& headers, int timeoutMs) {
    Http r;
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[512] = {0}, path[4096] = {0};
    uc.lpszHostName = host;
    uc.dwHostNameLength = 511;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 4095;
    if (!WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &uc)) return r;

    HINTERNET s = WinHttpOpen(L"MinglingWorkbench/2.0", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                              WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) return r;
    WinHttpSetTimeouts(s, timeoutMs, timeoutMs, timeoutMs, timeoutMs);
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) {
        WinHttpCloseHandle(s);
        return r;
    }
    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET q = WinHttpOpenRequest(c, method.c_str(), path, nullptr, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!q) {
        WinHttpCloseHandle(c);
        WinHttpCloseHandle(s);
        return r;
    }
    std::wstring hdr;
    for (auto& kv : headers) hdr += kv.first + L": " + kv.second + L"\r\n";
    if (!body.empty() && hdr.find(L"Content-Type") == std::wstring::npos)
        hdr += L"Content-Type: application/json\r\n";
    std::string bytes = WToUtf8(body);
    BOOL sent = WinHttpSendRequest(q, hdr.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : hdr.c_str(),
                                   hdr.empty() ? 0 : (DWORD)-1L, bytes.empty() ? nullptr : (LPVOID)bytes.data(),
                                   (DWORD)bytes.size(), (DWORD)bytes.size(), 0);
    if (sent && WinHttpReceiveResponse(q, nullptr)) {
        DWORD code = 0, len = sizeof(code);
        if (WinHttpQueryHeaders(q, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX, &code, &len, WINHTTP_NO_HEADER_INDEX)) {
            r.code = (int)code;
            r.ok = true;
        }
        std::string all;
        for (;;) {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(q, &avail) || avail == 0) break;
            std::string chunk;
            chunk.resize(avail);
            DWORD got = 0;
            if (!WinHttpReadData(q, &chunk[0], avail, &got) || got == 0) break;
            chunk.resize(got);
            all += chunk;
            if (all.size() > 8 * 1024 * 1024) break;
        }
        r.body = Utf8ToW(all);
    }
    WinHttpCloseHandle(q);
    WinHttpCloseHandle(c);
    WinHttpCloseHandle(s);
    return r;
}

Http HttpGet(const std::wstring& url, int timeoutMs) { return HttpCall(L"GET", url, L"", {}, timeoutMs); }

Http HttpGetJson(const std::wstring& url, const std::wstring& bearer, int timeoutMs) {
    std::vector<std::pair<std::wstring, std::wstring>> h;
    h.push_back({L"Accept", L"application/json"});
    if (!bearer.empty()) h.push_back({L"Authorization", L"Bearer " + bearer});
    return HttpCall(L"GET", url, L"", h, timeoutMs);
}

Http HttpPostJson(const std::wstring& url, const std::wstring& json, const std::wstring& bearer, int timeoutMs) {
    std::vector<std::pair<std::wstring, std::wstring>> h;
    h.push_back({L"Accept", L"application/json"});
    h.push_back({L"Content-Type", L"application/json"});
    if (!bearer.empty()) h.push_back({L"Authorization", L"Bearer " + bearer});
    return HttpCall(L"POST", url, json, h, timeoutMs);
}

// ---------------------------------------------------------------- 启动
void LaunchCmd(const std::wstring& batPath, const std::wstring& cwd, bool visible) {
    std::wstring cmd = L"cmd.exe /d /c \"\"" + batPath + L"\"\"";
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = visible ? SW_SHOWNORMAL : SW_SHOWMINNOACTIVE;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    std::wstring dir = cwd.empty() ? Base() : cwd;
    if (CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE,
                       CREATE_NEW_CONSOLE | CREATE_NEW_PROCESS_GROUP, nullptr, dir.c_str(), &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

DWORD LaunchExe(const std::wstring& exe, const std::wstring& args, const std::wstring& cwd, const EnvList& env,
                bool hidden) {
    std::wstring cmd = L"\"" + exe + L"\"";
    if (!args.empty()) cmd += L" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    DWORD flags = hidden ? CREATE_NO_WINDOW : DETACHED_PROCESS;
    // 环境变量：只有启动 Ollama 时要用（OLLAMA_MODELS 等），其它直接继承
    std::wstring envBlock;
    LPVOID envPtr = nullptr;
    if (!env.empty()) {
        wchar_t* cur = GetEnvironmentStringsW();
        if (cur) {
            for (wchar_t* p = cur; *p;) {
                std::wstring line(p);
                p += line.size() + 1;
                if (line.empty()) break;
                size_t eq = line.find(L'=');
                if (eq != std::wstring::npos) {
                    std::wstring key = line.substr(0, eq);
                    bool over = false;
                    for (auto& kv : env)
                        if (_wcsicmp(kv.first.c_str(), key.c_str()) == 0) over = true;
                    if (over) continue;
                }
                envBlock += line;
                envBlock.push_back(0);
            }
            FreeEnvironmentStringsW(cur);
        }
        for (auto& kv : env) {
            envBlock += kv.first + L"=" + kv.second;
            envBlock.push_back(0);
        }
        envBlock.push_back(0);
        envPtr = (LPVOID)envBlock.c_str();
        flags |= CREATE_UNICODE_ENVIRONMENT;
    }
    std::wstring dir = cwd.empty() ? Base() : cwd;
    DWORD pid = 0;
    if (CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, flags, envPtr, dir.c_str(), &si, &pi)) {
        pid = pi.dwProcessId;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    return pid;
}

bool WaitFor(const std::function<bool()>& fn, int seconds, const std::function<void(int)>& tick) {
    for (int i = 0; i < seconds; i++) {
        if (fn()) return true;
        if (tick) tick(i);
        Sleep(1000);
    }
    return fn();
}

// ---------------------------------------------------------------- md5（astrbot 的密码可能存的是 md5）
std::wstring Md5Hex(const std::wstring& s) {
    std::wstring out;
    HCRYPTPROV prov = 0;
    HCRYPTHASH hash = 0;
    if (!CryptAcquireContextW(&prov, nullptr, nullptr, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) return out;
    if (!CryptCreateHash(prov, CALG_MD5, 0, 0, &hash)) {
        CryptReleaseContext(prov, 0);
        return out;
    }
    std::string bytes = WToUtf8(s);
    CryptHashData(hash, (BYTE*)bytes.data(), (DWORD)bytes.size(), 0);
    BYTE buf[16];
    DWORD len = sizeof(buf);
    if (CryptGetHashParam(hash, HP_HASHVAL, buf, &len, 0)) {
        const wchar_t* hex = L"0123456789abcdef";
        for (DWORD i = 0; i < len; i++) {
            out.push_back(hex[buf[i] >> 4]);
            out.push_back(hex[buf[i] & 0xF]);
        }
    }
    CryptDestroyHash(hash);
    CryptReleaseContext(prov, 0);
    return out;
}

}  // namespace her
