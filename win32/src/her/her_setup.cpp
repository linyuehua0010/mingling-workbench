// 冥零工作台 · 一键自动配置（纯 C++，跑在 RunHerOp 的工作线程里）
// 只补「缺了就一定用不了」的东西：Node、ffmpeg、工作区、密钥目录。
// Ollama 体积大，只提示不静默装；Python 可选，装不上不影响主流程。
#include "her.h"

#include <winhttp.h>

#include <cstdio>
#include <cwchar>
#include <cstdlib>

namespace her {
namespace {

// 下载源集中在这里，换镜像走 settings.json 的 mirror_node，不在代码里散落版本号
const wchar_t* kNodeZip = L"https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip";
const wchar_t* kFfmpegZip =
    L"https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip";

std::wstring UrlFor(const wchar_t* key, const wchar_t* def) {
    std::wstring v = SettingGet(key);
    return v.empty() ? def : v;
}

void MakeDirs(const std::wstring& dir) {
    std::wstring cur;
    for (size_t i = 0; i < dir.size(); i++) {
        cur += dir[i];
        if (dir[i] == L"\\"[0] || dir[i] == L"/"[0]) {
            if (cur.size() > 3) CreateDirectoryW(cur.c_str(), nullptr);
        }
    }
    CreateDirectoryW(dir.c_str(), nullptr);
}

// WinHTTP 流式落盘：node/ffmpeg 都是几十 MB 的包，不能整个读进内存
bool DownloadTo(const std::wstring& url, const std::wstring& dst, long long* total = nullptr) {
    long long got_bytes = 0;
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t host[512] = {0}, path[4096] = {0};
    uc.lpszHostName = host;
    uc.dwHostNameLength = 511;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 4095;
    if (!WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &uc)) return false;

    FILE* f = nullptr;
    _wfopen_s(&f, dst.c_str(), L"wb");
    if (!f) return false;

    bool ok = false;
    HINTERNET s = WinHttpOpen(L"MinglingWorkbench/2.0", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                              WINHTTP_NO_PROXY_BYPASS, 0);
    if (s) {
        WinHttpSetTimeouts(s, 20000, 20000, 20000, 60000);
        HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
        if (c) {
            DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
            HINTERNET q = WinHttpOpenRequest(c, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                             WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
            if (q) {
                // GitHub 的 release 下载会 302 到 objects.githubusercontent.com，必须跟随
                DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
                WinHttpSetOption(q, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
                if (WinHttpSendRequest(q, WINHTTP_NO_ADDITIONAL_HEADERS, 0, nullptr, 0, 0, 0) &&
                    WinHttpReceiveResponse(q, nullptr)) {
                    DWORD code = 0, len = sizeof(code);
                    WinHttpQueryHeaders(q, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                        WINHTTP_HEADER_NAME_BY_INDEX, &code, &len, WINHTTP_NO_HEADER_INDEX);
                    if (code == 200) {
                        ok = true;
                        for (;;) {
                            DWORD avail = 0;
                            if (!WinHttpQueryDataAvailable(q, &avail) || avail == 0) break;
                            std::string chunk;
                            chunk.resize(avail);
                            DWORD got = 0;
                            if (!WinHttpReadData(q, &chunk[0], avail, &got) || got == 0) {
                                ok = false;
                                break;
                            }
                            got_bytes += got;
                            if (fwrite(chunk.data(), 1, got, f) != got) {
                                ok = false;
                                break;
                            }
                        }
                    }
                }
                WinHttpCloseHandle(q);
            }
            WinHttpCloseHandle(c);
        }
        WinHttpCloseHandle(s);
    }
    fclose(f);
    if (!ok) DeleteFileW(dst.c_str());
    if (total) *total = got_bytes;
    return ok;
}

// Win10 1809+ 自带 bsdtar，能直接解 zip，不引第三方库
bool Unzip(const std::wstring& zip, const std::wstring& dest) {
    MakeDirs(dest);
    CmdResult r = RunCapture(L"tar.exe", L"-xf \"" + zip + L"\" -C \"" + dest + L"\"", L"", EnvList(), 300000);
    if (r.code == 0) return true;
    CmdResult r2 = RunCapture(L"powershell.exe",
                              L"-NoProfile -ExecutionPolicy Bypass -Command \"Expand-Archive -LiteralPath '" +
                                  zip + L"' -DestinationPath '" + dest + L"' -Force\"",
                              L"", EnvList(), 300000);
    return r2.code == 0;
}

bool FindFileRec(const std::wstring& dir, const wchar_t* name, int depth, std::wstring& out) {
    if (depth < 0) return false;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(JoinPath(dir, L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::vector<std::wstring> subs;
    bool found = false;
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L"..") continue;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            subs.push_back(JoinPath(dir, n));
        } else if (_wcsicmp(n.c_str(), name) == 0) {
            out = JoinPath(dir, n);
            found = true;
            break;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (found) return true;
    for (auto& d : subs)
        if (FindFileRec(d, name, depth - 1, out)) return true;
    return false;
}

void MoveTree(const std::wstring& srcDir, const std::wstring& dstDir) {
    MakeDirs(dstDir);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(JoinPath(srcDir, L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        std::wstring n = fd.cFileName;
        if (n == L"." || n == L"..") continue;
        std::wstring a = JoinPath(srcDir, n), b = JoinPath(dstDir, n);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            MoveTree(a, b);
        else
            // 状态目录在 C:、sidecar 可能装在别的盘：不加 COPY_ALLOWED 会 ERROR_NOT_SAME_DEVICE，
            // 表现是「目录建了、程序没搬过去」，解压全成功却报告没搞到。
            MoveFileExW(a.c_str(), b.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

void RemoveTree(const std::wstring& dir) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(JoinPath(dir, L"*").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring n = fd.cFileName;
            if (n == L"." || n == L"..") continue;
            std::wstring sub = JoinPath(dir, n);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) RemoveTree(sub);
            else DeleteFileW(sub.c_str());
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir.c_str());
}

// 解压后通常多一层 node-vXX-win-x64\，把那层的内容搬到目标目录。
// 返回空串表示成功，否则是「哪一步没成」，好让报告说清楚而不是只写没搞到。
std::wstring InstallZip(const std::wstring& url, const wchar_t* exeName, const std::wstring& work,
                        const std::wstring& destDir) {
    std::wstring zip = work + L".zip";
    std::wstring err;
    long long got = 0;
    if (!DownloadTo(url, zip, &got)) {
        err = L"下载失败，只收到 " + std::to_wstring(got >> 20) + L"MB（" + url + L"）";
    } else if (!Unzip(zip, work)) {
        err = L"解压失败（" + std::to_wstring(got >> 20) + L"MB 已下完）";
    } else {
        std::wstring exe;
        if (!FindFileRec(work, exeName, 5, exe)) err = L"包里找不到 " + std::wstring(exeName);
        else MoveTree(ParentDir(exe), destDir);
    }
    // 包是 30MB~200MB 级：成功失败都清干净，别把状态目录塞满
    DeleteFileW(zip.c_str());
    RemoveTree(work);
    return err;
}

bool HavePython() {
    return FileExists(JoinPath(JoinPath(Base(), L"tools\\python"), L"pythonw.exe")) ||
           FileExists(JoinPath(JoinPath(Base(), L"python"), L"pythonw.exe")) ||
           FileExists(JoinPath(JoinPath(SidecarDir(), L"python"), L"pythonw.exe"));
}

}  // namespace
SetupReport AutoSetup(const std::function<void(int, const std::wstring&)>& onStep) {
    SetupReport rep;
    auto step = [&](int pct, const wchar_t* name) {
        if (onStep) onStep(pct, name);
    };
    auto add = [&](const wchar_t* name, bool ok, const std::wstring& detail) {
        SetupStep s;
        s.name = name;
        s.ok = ok;
        s.detail = detail;
        rep.steps.push_back(s);
    };

    std::wstring tmp = JoinPath(StateDir(), L"tmp");
    MakeDirs(tmp);

    // ---- Node
    step(5, L"检查 Node 运行时");
    std::wstring node = SidecarNodeExe(), nodeErr;
    if (node.empty()) {
        nodeErr = InstallZip(UrlFor(L"mirror_node", kNodeZip), L"node.exe", JoinPath(tmp, L"node-setup"),
                             JoinPath(SidecarDir(), L"node"));
        if (nodeErr.empty()) {
            node = SidecarNodeExe();
            if (!node.empty()) rep.fixed++;
        }
    }
    add(L"Node 运行时", !node.empty(),
        node.empty() ? L"没搞到：" + nodeErr + L"（检查网络，或用 settings.json 的 mirror_node 换源）" : node);

    // ---- ffmpeg
    step(35, L"检查 ffmpeg");
    std::wstring ff = SidecarFfmpegExe(), ffErr;
    if (ff.empty()) {
        ffErr = InstallZip(UrlFor(L"mirror_ffmpeg", kFfmpegZip), L"ffmpeg.exe",
                           JoinPath(tmp, L"ffmpeg-setup"),
                           JoinPath(JoinPath(SidecarDir(), L"ffmpeg"), L"bin"));
        if (ffErr.empty()) {
            ff = SidecarFfmpegExe();
            if (!ff.empty()) rep.fixed++;
        }
    }
    add(L"ffmpeg", !ff.empty(),
        ff.empty() ? L"没搞到：" + ffErr + L"（检查网络，或用 settings.json 的 mirror_ffmpeg 换源）" : ff);

    // ---- Python（可选，缺了不影响主流程）
    step(55, L"检查 Python（可缺）");
    if (HavePython()) {
        add(L"Python", true, L"已有，用本机的");
    } else {
        CmdResult r = RunCapture(L"winget.exe",
                                 L"install -e --id Python.Python.3.12 --scope user --silent "
                                 L"--accept-package-agreements --accept-source-agreements",
                                 L"", EnvList(), 600000);
        if (r.code == 0 && HavePython()) {
            rep.fixed++;
            add(L"Python", true, L"用 winget 装好了");
        } else {
            add(L"Python", true, L"没装（可选：只有少数技能要用；想装就自己跑 winget install Python.Python.3.12）");
        }
    }

    // ---- Ollama：体积大，只提示不静默装
    step(65, L"检查 Ollama");
    {
        bool have = !OllamaExe().empty();
        bool up = Listening(11434);
        std::wstring d = have ? (up ? std::wstring(L"装着，正在跑")
                                     : std::wstring(L"装着，没在跑（要用本机记忆再点「开本机 Ollama」）"))
                              : std::wstring(L"没装。它体积大，工作台不静默装——要本机记忆时再去 ollama.com/download");
        add(L"Ollama", true, d);
    }

    // ---- 工作区 / 密钥目录
    step(75, L"检查工作区与密钥目录");
    EnsureWorkspaceLayout(WorkspaceDir());
    EnsureSecrets();
    add(L"工作区", true, WorkspaceDir());
    add(L"密钥目录", true, SecretsDir());

    // ---- 配置
    step(88, L"写配置");
    if (SettingGet(L"workspace").empty()) SettingSet(L"workspace", WorkspaceDir());
    if (SettingGet(L"base").empty()) SettingSet(L"base", BaseDir());

    // ---- 附带脚本
    step(94, L"检查附带脚本");
    {
        struct Want { const wchar_t* rel; const wchar_t* file; };
        const Want want[] = {{L"tools\\qq_watch.py", L"qq_watch.py"}, {L"tools\\qq-toast.ps1", L"qq-toast.ps1"}};
        int missing = 0;      // 源文件在、但没复制过去（<Base> 不可写之类）
        int notShipped = 0;   // 这一版根本没带这个脚本：不是环境问题，不该刷红
        for (auto& w : want) {
            std::wstring dst = JoinPath(Base(), w.rel);
            if (FileExists(dst)) continue;
            std::vector<std::wstring> cand = {JoinPath(JoinPath(Root(), L"tools"), w.file),
                                              JoinPath(JoinPath(Root(), L"sidecar"), w.file)};
            bool haveSrc = false, copied = false;
            for (auto& c : cand) {
                if (!FileExists(c)) continue;
                haveSrc = true;
                if (CopyFileW(c.c_str(), dst.c_str(), FALSE)) {
                    copied = true;
                    break;
                }
            }
            if (copied) continue;
            if (haveSrc) missing++; else notShipped++;
        }
        add(L"附带脚本", missing == 0,
            missing != 0
                ? std::wstring(L"有 ") + std::to_wstring(missing) + L" 个复制失败（检查机器人根是否可写）"
                : (notShipped > 0
                       ? std::wstring(L"这一版没带这 ") + std::to_wstring(notShipped) +
                             L" 个脚本；掉线提醒改用工作台自己的心跳，不影响用"
                       : std::wstring(L"掉线提醒用的脚本在位")));
    }

    step(100, L"完成");
    int bad = 0;
    for (auto& s : rep.steps)
        if (!s.ok) bad++;
    rep.ok = (bad == 0);
    rep.summary = rep.ok ? std::wstring(L"环境齐了：Node、ffmpeg、工作区、密钥目录都在位，可以开始用了。")
                         : (std::wstring(L"还差 ") + std::to_wstring(bad) + L" 项，看报告里的红字。");
    return rep;
}

// ---------------------------------------------------------------- 五个组件（bots 布局）
// 真正的下载/解压/写配置在 tools\auto-setup.ps1 里：脚本自己判断「装好了就跳过」，
// 这里只负责把它拉起来，把 ##STEP / ##OK / ##FAIL / ##RESULT 翻译成进度和报告。
namespace {

struct BotsCtx {
    SetupReport* rep = nullptr;
    const std::function<void(int, const std::wstring&)>* onStep = nullptr;
    bool sawResult = false;
    bool resultOk = false;
};

std::wstring AfterBar(const std::wstring& line) {
    size_t p = line.find(L'|');
    return p == std::wstring::npos ? std::wstring() : Trim(line.substr(p + 1));
}

void OnBotsLine(const std::wstring& raw, void* user) {
    BotsCtx* c = (BotsCtx*)user;
    std::wstring line = Trim(raw);
    if (StartsWith(line, L"##STEP ")) {
        int pct = _wtoi(line.c_str() + 7);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        if (c->onStep && *c->onStep) (*c->onStep)(pct, AfterBar(line));
        return;
    }
    if (StartsWith(line, L"##OK ") || StartsWith(line, L"##FAIL ")) {
        bool ok = line[3] == L'K';        // ##OK / ##FAIL 的第 4 个字符就能分辨
        std::wstring body = Trim(line.substr(ok ? 5 : 7));
        size_t bar = body.find(L'|');
        SetupStep s;
        s.name = Trim(bar == std::wstring::npos ? body : body.substr(0, bar));
        s.detail = bar == std::wstring::npos ? std::wstring() : Trim(body.substr(bar + 1));
        s.ok = ok;
        if (c->rep) c->rep->steps.push_back(s);
        return;
    }
    if (StartsWith(line, L"##RESULT ")) {
        c->sawResult = true;
        c->resultOk = IContains(line, L"ok=1");
        size_t f = line.find(L"fixed=");
        if (f != std::wstring::npos && c->rep) c->rep->fixed = _wtoi(line.c_str() + f + 6);
        size_t w = line.find(L"why=");
        if (w != std::wstring::npos && c->rep) c->rep->summary = Trim(line.substr(w + 4));
    }
}

}  // namespace

SetupReport BotsSetup(const std::function<void(int, const std::wstring&)>& onStep) {
    SetupReport rep;
    auto add = [&](const wchar_t* name, bool ok, const std::wstring& detail) {
        SetupStep s;
        s.name = name;
        s.ok = ok;
        s.detail = detail;
        rep.steps.push_back(s);
    };
    std::wstring script = JoinPath(JoinPath(Root(), L"tools"), L"auto-setup.ps1");
    if (!FileExists(script)) {
        add(L"安装脚本", false, L"没找到 " + script + L"（这一版没带 auto-setup.ps1）");
        rep.summary = L"没找到安装脚本，先把工作台更新到带 auto-setup.ps1 的版本。";
        return rep;
    }
    wchar_t sysroot[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH * 2);
    std::wstring win = sysroot[0] ? std::wstring(sysroot) : std::wstring(L"C:\\Windows");
    std::wstring ps =
        JoinPath(JoinPath(JoinPath(win, L"System32"), L"WindowsPowerShell"), L"v1.0\\powershell.exe");
    if (!FileExists(ps)) {
        add(L"安装脚本", false, L"找不到 PowerShell：" + ps);
        rep.summary = L"这台机器缺 PowerShell，组件装不了。";
        return rep;
    }

    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -Workspace \"" +
                        WorkspaceDir() + L"\" -Bots \"" + BotRoot() + L"\" -Base \"" + Base() + L"\"";
    BotsCtx ctx;
    ctx.rep = &rep;
    ctx.onStep = &onStep;
    if (onStep) onStep(1, L"准备安装包（第一次要下载几百 MB）");
    CmdResult r = RunCaptureStream(ps, args, Root(), EnvList(), 45 * 60 * 1000, OnBotsLine, &ctx);

    if (r.timeout) {
        add(L"安装脚本", false, L"跑了 45 分钟还没结束，先停了（网络慢就再试一次）");
    } else if (!ctx.sawResult) {
        std::wstring tail = Trim(r.out);
        if (tail.size() > 600) tail = tail.substr(tail.size() - 600);
        add(L"安装脚本", false, L"脚本没给出结果（退出码 " + std::to_wstring(r.code) + L"）：" + tail);
    } else {
        add(L"安装脚本", ctx.resultOk,
            ctx.resultOk ? L"跑完了，五个组件都检查过一遍。" : L"有步骤没成，看上面的红字。");
    }
    if (rep.summary.empty()) {
        int bad = 0;
        for (auto& s : rep.steps)
            if (!s.ok) bad++;
        rep.ok = (bad == 0);
        rep.summary = rep.ok
                          ? std::wstring(L"组件齐了：AstrBot、SnowLuma、Breeze、Ollama、bili-whale 都在 " +
                                         BotRoot() + L" 下。")
                          : (std::wstring(L"还有 ") + std::to_wstring(bad) + L" 项没成，看报告里的红字。");
    } else {
        rep.ok = ctx.resultOk;
    }
    return rep;
}

}  // namespace her