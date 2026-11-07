#include "core.h"

#include <iphlpapi.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <cstdio>
#include <cstring>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

// ---------------------------------------------------------------- 路径
wstring ExeDir() {
    wchar_t buf[MAX_PATH * 2] = {0};
    GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
    wstring p(buf);
    size_t i = p.find_last_of(L"\\/");
    return i == wstring::npos ? L"." : p.substr(0, i);
}

wstring UserProfile() {
    wchar_t buf[MAX_PATH * 2] = {0};
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", buf, MAX_PATH * 2);
    if (n == 0 || n >= MAX_PATH * 2) {
        const wchar_t* up = _wgetenv(L"USERPROFILE");
        if (up) return wstring(up);
        return L"C:\\Users\\Public";
    }
    return wstring(buf);
}

wstring JoinPath(const wstring& a, const wstring& b) {
    if (a.empty()) return b;
    if (b.empty()) return a;
    wchar_t last = a[a.size() - 1];
    if (last == L'\\' || last == L'/') return a + b;
    return a + L"\\" + b;
}

bool FileExists(const wstring& p) {
    if (p.empty()) return false;
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

bool DirExists(const wstring& p) {
    if (p.empty()) return false;
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

// ---------------------------------------------------------------- 编解码
static bool IsValidUtf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        int extra = 0;
        if (c < 0x80) { i++; continue; }
        else if ((c & 0xE0) == 0xC0) extra = 1;
        else if ((c & 0xF0) == 0xE0) extra = 2;
        else if ((c & 0xF8) == 0xF0) extra = 3;
        else return false;
        if (i + extra >= s.size()) return false;
        for (int k = 1; k <= extra; k++)
            if (((unsigned char)s[i + k] & 0xC0) != 0x80) return false;
        i += extra + 1;
    }
    return true;
}

std::string WToUtf8(const wstring& s) {
    if (s.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return std::string();
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), &out[0], n, nullptr, nullptr);
    return out;
}

wstring Utf8ToW(const std::string& s) {
    if (s.empty()) return wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (n <= 0) return wstring();
    wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &out[0], n);
    return out;
}

// 日志可能是 UTF-8 也可能是 GBK（老 python 日志）：先试 UTF-8，不行按 ANSI 解
static wstring DecodeAuto(const std::string& bytes) {
    if (bytes.empty()) return wstring();
    if (IsValidUtf8(bytes)) return Utf8ToW(bytes);
    int n = MultiByteToWideChar(CP_ACP, 0, bytes.c_str(), (int)bytes.size(), nullptr, 0);
    if (n <= 0) return Utf8ToW(bytes);
    wstring out(n, L'\0');
    MultiByteToWideChar(CP_ACP, 0, bytes.c_str(), (int)bytes.size(), &out[0], n);
    return out;
}

// ---------------------------------------------------------------- 文本
wstring ReadTextFile(const wstring& path, size_t maxBytes) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return wstring();
    LARGE_INTEGER size{};
    GetFileSizeEx(h, &size);
    long long want = size.QuadPart;
    if (maxBytes && want > (long long)maxBytes) {
        LARGE_INTEGER off{};
        off.QuadPart = want - (long long)maxBytes;
        SetFilePointerEx(h, off, nullptr, FILE_BEGIN);
        want = (long long)maxBytes;
    }
    std::string bytes;
    bytes.resize((size_t)want);
    DWORD got = 0;
    if (want > 0) ReadFile(h, &bytes[0], (DWORD)want, &got, nullptr);
    bytes.resize(got);
    CloseHandle(h);
    if (bytes.size() >= 3 && (unsigned char)bytes[0] == 0xEF && (unsigned char)bytes[1] == 0xBB &&
        (unsigned char)bytes[2] == 0xBF)
        bytes.erase(0, 3);
    return DecodeAuto(bytes);
}

bool WriteTextFile(const wstring& path, const wstring& text, bool append) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                           append ? OPEN_ALWAYS : CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    if (append) SetFilePointer(h, 0, nullptr, FILE_END);
    std::string bytes = WToUtf8(text);
    DWORD wrote = 0;
    bool ok = true;
    size_t off = 0;
    while (off < bytes.size()) {
        if (!WriteFile(h, bytes.data() + off, (DWORD)(bytes.size() - off), &wrote, nullptr) || wrote == 0) {
            ok = false;
            break;
        }
        off += wrote;
    }
    CloseHandle(h);
    return ok;
}

wstring Trim(const wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r\n");
    if (a == wstring::npos) return wstring();
    size_t b = s.find_last_not_of(L" \t\r\n");
    return s.substr(a, b - a + 1);
}

vector<wstring> SplitLines(const wstring& s) {
    vector<wstring> out;
    wstring cur;
    for (wchar_t c : s) {
        if (c == L'\n') {
            if (!cur.empty() && cur.back() == L'\r') cur.pop_back();
            out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

wstring ReplaceAll(wstring s, const wstring& from, const wstring& to) {
    if (from.empty()) return s;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != wstring::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

bool StartsWith(const wstring& s, const wstring& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}

bool Contains(const wstring& s, const wstring& p) {
    return p.empty() || s.find(p) != wstring::npos;
}

static wstring Lower(wstring s) {
    for (auto& c : s) c = (wchar_t)towlower(c);
    return s;
}

bool IContains(const wstring& s, const wstring& p) {
    if (p.empty()) return true;
    return Lower(s).find(Lower(p)) != wstring::npos;
}

wstring Num(long long v) { return std::to_wstring(v); }

wstring Pad2(int v) {
    wchar_t b[8];
    swprintf(b, 8, L"%02d", v);
    return b;
}

wstring NowStamp() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t b[64];
    swprintf(b, 64, L"%04d-%02d-%02d %02d:%02d:%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
             st.wSecond);
    return b;
}

wstring TodayStr() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t b[32];
    swprintf(b, 32, L"%04d-%02d-%02d", st.wYear, st.wMonth, st.wDay);
    return b;
}

long long NowUnix() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (long long)(u.QuadPart / 10000000ULL) - 11644473600LL;
}

wstring PrettyBytes(double b) {
    wchar_t buf[64];
    const wchar_t* u[] = {L"B", L"KB", L"MB", L"GB", L"TB"};
    int i = 0;
    while (b >= 1024.0 && i < 4) { b /= 1024.0; i++; }
    swprintf(buf, 64, i == 0 ? L"%.0f %s" : L"%.1f %s", b, u[i]);
    return buf;
}

// ---------------------------------------------------------------- 端口
static void WsaInit() {
    static bool done = false;
    if (!done) {
        WSADATA d;
        WSAStartup(MAKEWORD(2, 2), &d);
        done = true;
    }
}

bool PortOpen(int port, int timeoutMs) {
    WsaInit();
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;
    u_long nb = 1;
    ioctlsocket(s, FIONBIO, &nb);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    bool ok = false;
    if (connect(s, (sockaddr*)&a, sizeof(a)) == 0) {
        ok = true;
    } else {
        int err = WSAGetLastError();
        if (err == WSAEWOULDBLOCK) {
            fd_set wf, ef;
            FD_ZERO(&wf);
            FD_ZERO(&ef);
            FD_SET(s, &wf);
            FD_SET(s, &ef);
            timeval tv{};
            tv.tv_sec = timeoutMs / 1000;
            tv.tv_usec = (timeoutMs % 1000) * 1000;
            int r = select(0, nullptr, &wf, &ef, &tv);
            if (r > 0 && FD_ISSET(s, &wf)) {
                int so_err = 0;
                int len = sizeof(so_err);
                getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&so_err, &len);
                ok = (so_err == 0);
            }
        }
    }
    closesocket(s);
    return ok;
}

DWORD PidOnPort(int port) {
    DWORD pid = 0;
    DWORD size = 0;
    if (GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) != ERROR_INSUFFICIENT_BUFFER)
        return 0;
    std::vector<char> buf(size);
    if (GetExtendedTcpTable(buf.data(), &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) != NO_ERROR)
        return 0;
    auto* table = (MIB_TCPTABLE_OWNER_PID*)buf.data();
    for (DWORD i = 0; i < table->dwNumEntries; i++) {
        if ((int)ntohs((u_short)table->table[i].dwLocalPort) == port) {
            pid = table->table[i].dwOwningPid;
            break;
        }
    }
    return pid;
}

bool KillPid(DWORD pid) {
    if (!pid) return false;
    wstring cmd = L"/PID " + Num((long long)pid) + L" /T /F";
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    wstring line = L"taskkill.exe " + cmd;
    std::vector<wchar_t> cmdline(line.begin(), line.end());
    cmdline.push_back(0);
    if (!CreateProcessW(nullptr, cmdline.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
        return false;
    WaitForSingleObject(pi.hProcess, 8000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}

vector<int> ListPidsOf(const wstring& exeLower) {
    vector<int> out;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (Lower(pe.szExeFile) == exeLower) out.push_back((int)pe.th32ProcessID);
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return out;
}

// ---------------------------------------------------------------- 进程
static wstring BuildEnvBlock(const EnvList& overrides) {
    wstring block;
    map<wstring, size_t> index;
    vector<std::pair<wstring, wstring>> items;   // key(原样), value
    LPWCH raw = GetEnvironmentStringsW();
    if (raw) {
        for (const wchar_t* p = raw; *p; p += wcslen(p) + 1) {
            wstring entry(p);
            if (entry.empty() || entry[0] == L'=') continue;
            size_t eq = entry.find(L'=');
            if (eq == wstring::npos) continue;
            wstring k = entry.substr(0, eq), v = entry.substr(eq + 1);
            index[Lower(k)] = items.size();
            items.emplace_back(k, v);
        }
        FreeEnvironmentStringsW(raw);
    }
    for (auto& o : overrides) {
        auto it = index.find(Lower(o.first));
        if (it != index.end()) {
            items[it->second].second = o.second;
        } else {
            index[Lower(o.first)] = items.size();
            items.emplace_back(o.first, o.second);
        }
    }
    block.reserve(32768);
    for (auto& kv : items) {
        block += kv.first;
        block += L'=';
        block += kv.second;
        block += L'\0';
    }
    block += L'\0';
    return block;
}

// 只给名字（比如 powershell.exe）也能跑：先在 PATH 里找一遍
static wstring ResolveExe(const wstring& exe) {
    if (FileExists(exe)) return exe;
    wchar_t buf[MAX_PATH * 2];
    DWORD n = SearchPathW(nullptr, exe.c_str(), L".exe", MAX_PATH * 2, buf, nullptr);
    if (n > 0 && n < MAX_PATH * 2) return wstring(buf, n);
    return wstring();
}

CmdResult RunCapture(const wstring& exe, const wstring& args, const wstring& cwd, const EnvList& env,
                     int timeoutMs) {
    CmdResult r;
    wstring exeReal = ResolveExe(exe);
    if (exeReal.empty()) {
        r.out = L"找不到程序：" + exe;
        return r;
    }
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    // 暂存文件优先放在状态目录的 run\ 下（不依赖系统 TEMP，跑完即删）
    wstring scratch = JoinPath(StateDir(), L"run");
    CreateDirectoryW(scratch.c_str(), nullptr);
    wstring stamp = Num((long long)GetCurrentProcessId()) + L"-" + Num((long long)GetTickCount64()) + L".log";
    wstring outPath = JoinPath(scratch, L"run-" + stamp);
    HANDLE h = CreateFileW(outPath.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        wchar_t tmp[MAX_PATH] = {0};
        GetTempPathW(MAX_PATH, tmp);
        outPath = wstring(tmp) + L"mingling-" + stamp;
        h = CreateFileW(outPath.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    }
    if (h == INVALID_HANDLE_VALUE) {
        r.out = L"建不了临时文件（错误码 " + Num((long long)GetLastError()) + L"）：" + outPath;
        return r;
    }
    wstring cmdline = L"\"" + exeReal + L"\"";
    if (!args.empty()) cmdline += L" " + args;
    std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
    cmd.push_back(0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = h;
    si.hStdError = h;
    si.hStdInput = INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION pi{};
    wstring envBlock = BuildEnvBlock(env);
    wstring dir = cwd.empty() ? ExeDir() : cwd;
    DWORD flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
    BOOL ok = CreateProcessW(exeReal.c_str(), cmd.data(), nullptr, nullptr, TRUE, flags, (void*)envBlock.c_str(),
                             dir.empty() ? nullptr : dir.c_str(), &si, &pi);
    if (!ok) {
        CloseHandle(h);
        DeleteFileW(outPath.c_str());
        r.out = L"启动失败（错误码 " + Num((long long)GetLastError()) + L"）：" + exe;
        return r;
    }
    r.started = true;
    DWORD wait = WaitForSingleObject(pi.hProcess, (DWORD)timeoutMs);
    if (wait == WAIT_TIMEOUT) {
        r.timeout = true;
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 3000);
    }
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    r.code = (int)code;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    r.out = ReadTextFile(outPath, 4 * 1024 * 1024);
    CloseHandle(h);
    DeleteFileW(outPath.c_str());
    if (r.timeout) r.out += L"\n（超时被中止）";
    return r;
}

CmdResult RunCaptureStream(const wstring& exe, const wstring& args, const wstring& cwd, const EnvList& env,
                             int timeoutMs, StreamCb cb, void* user) {
    CmdResult r;
    wstring exeReal = ResolveExe(exe);
    if (exeReal.empty()) {
        r.out = L"找不到程序：" + exe;
        return r;
    }
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE rd = nullptr, wr = nullptr;
    if (!CreatePipe(&rd, &wr, &sa, 0)) {
        r.out = L"建不了管道";
        return r;
    }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    wstring cmdline = L"\"" + exeReal + L"\"";
    if (!args.empty()) cmdline += L" " + args;
    std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
    cmd.push_back(0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = wr;
    si.hStdError = wr;
    si.hStdInput = INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION pi{};
    wstring envBlock = BuildEnvBlock(env);
    wstring dir = cwd.empty() ? ExeDir() : cwd;
    DWORD flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
    BOOL ok = CreateProcessW(exeReal.c_str(), cmd.data(), nullptr, nullptr, TRUE, flags, (void*)envBlock.c_str(),
                             dir.empty() ? nullptr : dir.c_str(), &si, &pi);
    CloseHandle(wr);
    if (!ok) {
        CloseHandle(rd);
        r.out = L"启动失败（错误码 " + Num((long long)GetLastError()) + L"）：" + exe;
        return r;
    }
    r.started = true;

    auto flushLine = [&](std::string& line) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        wstring wl = Utf8ToW(line);
        r.out += wl;
        r.out += L"\n";
        if (cb) cb(wl, user);
    };

    std::string buf;
    std::vector<char> tmp(8192);
    DWORD t0 = GetTickCount();
    bool done = false;
    while (!done) {
        DWORD avail = 0;
        if (!PeekNamedPipe(rd, nullptr, 0, nullptr, &avail, nullptr)) break;
        if (avail > 0) {
            DWORD got = 0;
            DWORD want = avail < (DWORD)tmp.size() ? avail : (DWORD)tmp.size();
            if (!ReadFile(rd, tmp.data(), want, &got, nullptr) || got == 0) break;
            buf.append(tmp.data(), got);
            for (;;) {
                size_t nl = buf.find('\n');
                if (nl == std::string::npos) break;
                std::string line = buf.substr(0, nl);
                buf.erase(0, nl + 1);
                flushLine(line);
            }
        } else {
            if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
                DWORD got = 0;
                while (ReadFile(rd, tmp.data(), (DWORD)tmp.size(), &got, nullptr) && got > 0) buf.append(tmp.data(), got);
                done = true;
                break;
            }
            if ((int)(GetTickCount() - t0) > timeoutMs) {
                r.timeout = true;
                TerminateProcess(pi.hProcess, 1);
                WaitForSingleObject(pi.hProcess, 3000);
                break;
            }
            Sleep(20);
        }
    }
    if (!buf.empty()) flushLine(buf);

    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    r.code = (int)code;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(rd);
    if (r.timeout) r.out += L"\n（超时被中止）";
    return r;
}

DWORD SpawnDetached(const wstring& exe, const wstring& args, const wstring& cwd, const EnvList& env,
                    const wstring& logPath) {
    wstring exeReal = ResolveExe(exe);
    if (exeReal.empty()) return 0;
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE h = CreateFileW(logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    wstring cmdline = L"\"" + exeReal + L"\"";
    if (!args.empty()) cmdline += L" " + args;
    std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
    cmd.push_back(0);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    if (h != INVALID_HANDLE_VALUE) {
        si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        si.hStdOutput = h;
        si.hStdError = h;
        si.hStdInput = INVALID_HANDLE_VALUE;
    } else {
        si.dwFlags = STARTF_USESHOWWINDOW;
    }
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    wstring envBlock = BuildEnvBlock(env);
    DWORD flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT;
    BOOL ok = CreateProcessW(exeReal.c_str(), cmd.data(), nullptr, nullptr, TRUE, flags, (void*)envBlock.c_str(),
                             cwd.c_str(), &si, &pi);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (!ok) return 0;
    DWORD pid = pi.dwProcessId;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return pid;
}

wstring TailFile(const wstring& path, int lines, size_t maxBytes) {
    wstring text = ReadTextFile(path, maxBytes);
    if (text.empty()) return text;
    vector<wstring> all = SplitLines(text);
    if ((int)all.size() <= lines) {
        wstring out;
        for (auto& l : all) { out += l; out += L"\n"; }
        return out;
    }
    wstring out;
    for (int i = (int)all.size() - lines; i < (int)all.size(); i++) {
        out += all[i];
        out += L"\n";
    }
    return out;
}

wstring UnescapeHtml(const wstring& in) {
    wstring s = in;
    s = ReplaceAll(s, L"&amp;", L"&");
    s = ReplaceAll(s, L"&lt;", L"<");
    s = ReplaceAll(s, L"&gt;", L">");
    s = ReplaceAll(s, L"&quot;", L"\"");
    s = ReplaceAll(s, L"&#39;", L"'");
    s = ReplaceAll(s, L"&apos;", L"'");
    s = ReplaceAll(s, L"&nbsp;", L" ");
    return s;
}
