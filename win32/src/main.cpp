// 冥零工作台 · Win32 入口
// 一个可执行文件，没有浏览器内核、没有 HTTP 服务：界面全部 GDI+ 自绘，
// B站 部分直接调 dsh-bili-whale 的命令行。
#include "ui.h"
#include "version.h"
#include "her/her.h"

#include <objidl.h>
#include <shellapi.h>
#include <gdiplus.h>
#include <cstdio>
#include <cwchar>
#include <memory>

using namespace Gdiplus;

// shell32 的导出，不在 shellapi.h 里，手写声明省得引入 shobjidl。
extern "C" HRESULT WINAPI SetCurrentProcessExplicitAppUserModelID(PCWSTR appID);

#if APP_SNAPSHOT
// 快照版单独一条线：窗口类名、AppUserModelID 都和正式版分开，
// 于是两个版本可以同时开着，「只留一份」也不会把正式版顶掉。
static const wchar_t* CLS_NAME = L"MinglingWorkbench.snapshot";
static const wchar_t* APP_USER_MODEL_ID = L"Mingling.Workbench.snapshot";
#else
static const wchar_t* CLS_NAME = L"MinglingWorkbench";
static const wchar_t* APP_USER_MODEL_ID = L"Mingling.Workbench.2";
#endif
static const wchar_t* WIN_TITLE = L"冥零工作台 " APP_VERSION;

static FILE* g_out = nullptr;

static void AttachConsoleIfAsked() {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool want = false;
    if (argv) {
        for (int i = 1; i < argc; i++)
            if (wcscmp(argv[i], L"--console") == 0 || wcscmp(argv[i], L"--her-status") == 0 ||
                wcscmp(argv[i], L"--her-op") == 0 || wcscmp(argv[i], L"--paths") == 0 ||
                wcscmp(argv[i], L"--feed") == 0 || wcscmp(argv[i], L"--debrief") == 0 ||
                wcscmp(argv[i], L"--bili") == 0 || wcscmp(argv[i], L"--autosetup") == 0 ||
                wcscmp(argv[i], L"--bots-setup") == 0 ||
                wcscmp(argv[i], L"--selfsetup") == 0 ||
                wcscmp(argv[i], L"--version") == 0) want = true;
        LocalFree(argv);
    }
    if (!want) return;
    if (!AllocConsole()) return;
    FILE* f = nullptr;
    _wfreopen_s(&f, L"CONOUT$", L"w", stdout);
    _wfreopen_s(&f, L"CONOUT$", L"w", stderr);
    g_out = stdout;
    if (g_out) wprintf(L"[冥零工作台] 调试控制台已开\n");
}

#define WM_APP_TRAY (WM_APP + 5)

static NOTIFYICONDATAW g_nid{};
static bool g_trayOk = false;

static void TrayAdd(HWND h) {
    g_nid = {};
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = h;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON,
                                    GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    if (!g_nid.hIcon) g_nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(g_nid.szTip, L"冥零工作台", ARRAYSIZE(g_nid.szTip));
    g_trayOk = Shell_NotifyIconW(NIM_ADD, &g_nid) != FALSE;
}

static void TrayRemove() {
    if (g_trayOk) Shell_NotifyIconW(NIM_DELETE, &g_nid);
    g_trayOk = false;
}

static void TrayBalloon(const std::wstring& text, const std::wstring& title = L"冥零工作台 · 掉线提醒",
                        const std::wstring& avatar = L"") {
    if (!g_trayOk) return;
    // 有自定义头像就用 NIIF_USER 换成她自己的脸；没图（或读不出来）退回系统信息图标
    HICON ic = avatar.empty() ? nullptr : UiBalloonIcon(avatar, 32);
    g_nid.uFlags = NIF_INFO;
    if (ic) {
        g_nid.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
        g_nid.hBalloonIcon = ic;
    } else {
        g_nid.dwInfoFlags = NIIF_INFO;
        g_nid.hBalloonIcon = nullptr;
    }
    g_nid.uTimeout = 10000;
    lstrcpynW(g_nid.szInfoTitle, title.c_str(), ARRAYSIZE(g_nid.szInfoTitle));
    lstrcpynW(g_nid.szInfo, text.c_str(), ARRAYSIZE(g_nid.szInfo));
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    // 专注助手会把气泡压掉，闪一下任务栏兜底
    FLASHWINFO fw{sizeof(fw), FindWindowW(CLS_NAME, nullptr), FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0};
    if (fw.hwnd) FlashWindowEx(&fw);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_CREATE:
            UiInit(hwnd);
            TrayAdd(hwnd);
            SetTimer(hwnd, 1, 1000, nullptr);
            return 0;

        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(hwnd, &ps);
            RECT rc;
            GetClientRect(hwnd, &rc);
            UiPaint(dc, rc.right - rc.left, rc.bottom - rc.top);
            EndPaint(hwnd, &ps);
            return 0;
        }

        case WM_PRINTCLIENT: {
            // 给截图/打印用：把客户区画到外部 DC（PrintWindow 会发这条）
            RECT rc;
            GetClientRect(hwnd, &rc);
            UiPaint((HDC)wp, rc.right - rc.left, rc.bottom - rc.top);
            return 0;
        }

        case WM_ERASEBKGND:
            return 1;

        case WM_SIZE:
            // 最小化就把工作集还给系统，任务管理器里看着也小；恢复时按需再取回来
            if (wp == SIZE_MINIMIZED)
                SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
            InvalidateRect(hwnd, nullptr, FALSE);
            return 0;

        case WM_TIMER:
            if (wp == 1) UiTick();
            return 0;

        case WM_MOUSEMOVE:
            UiOnMove(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
            return 0;

        case WM_LBUTTONDOWN:
            SetFocus(hwnd);
            UiOnClick(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
            return 0;

        case WM_RBUTTONUP:   // 输入框上的右键菜单：粘贴 / 复制 / 剪切 / 全选
            UiOnRClick(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
            return 0;

        case WM_MOUSEWHEEL: {
            POINT pt = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            ScreenToClient(hwnd, &pt);
            UiOnWheel(pt.x, pt.y, GET_WHEEL_DELTA_WPARAM(wp));
            return 0;
        }

        case WM_CHAR:
            UiOnChar((unsigned int)wp);
            return 0;

        case WM_KEYDOWN:
            UiOnKeyDown((int)wp);
            return 0;

        case WM_SETCURSOR:
            if (LOWORD(lp) == HTCLIENT) {
                SetCursor(LoadCursorW(nullptr, IDC_ARROW));
                return TRUE;
            }
            break;

        case WM_APP_JOB:
            UiOnTask((TaskData*)lp);
            return 0;

        case WM_APP_PROGRESS:
            UiOnProgress();
            return 0;

        case WM_APP_AUTOCFG:   // 自动配置的进度：lParam 是 new wstring，由窗口线程接管
            UiOnAutoCfg((int)wp, (std::wstring*)lp);
            return 0;

        case WM_APP_TOAST: {   // 后台线程想弹托盘气泡（掉线提醒走这里）
            std::unique_ptr<std::wstring> s((std::wstring*)lp);
            if (s) TrayBalloon(*s);
            return 0;
        }
        case WM_APP_NOTIFY: {   // 后台心跳报掉线：先弹托盘气泡，再交给界面画顶部横幅
            std::unique_ptr<NotifyReq> r((NotifyReq*)lp);
            if (r) {
                TrayBalloon(r->body, r->title, r->avatar);
                UiOnNotify(r.release());
            }
            return 0;
        }

        case WM_CTLCOLOREDIT: {   // 改卡片的输入框要深色，别一块白
            HDC dc = (HDC)wp;
            SetTextColor(dc, RGB(228, 234, 244));
            SetBkColor(dc, RGB(22, 26, 34));
            static HBRUSH editBr = CreateSolidBrush(RGB(22, 26, 34));
            return (LRESULT)editBr;
        }


        case WM_APP_TRAY:
            if (LOWORD(lp) == NIN_BALLOONUSERCLICK || LOWORD(lp) == WM_LBUTTONUP) {
                ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
                UiToast(L"我在。");
            }
            return 0;

        case WM_GETMINMAXINFO: {
            MINMAXINFO* mm = (MINMAXINFO*)lp;
            float sc = 1.0f;
            if (HDC mdc = GetDC(GetDesktopWindow())) {
                sc = GetDeviceCaps(mdc, LOGPIXELSX) / 96.0f;
                ReleaseDC(GetDesktopWindow(), mdc);
            }
            if (sc < 0.85f) sc = 0.85f;
            if (sc > 2.0f) sc = 2.0f;
            mm->ptMinTrackSize.x = (LONG)(1000 * sc);
            mm->ptMinTrackSize.y = (LONG)(700 * sc);
            return 0;
        }

        case WM_DESTROY:
            KillTimer(hwnd, 1);
            TrayRemove();
            UiShutdown();
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// 命令行自检：--paths 打路径契约，--feed 拉选题，--debrief <BV> 走一遍看视频，
// --bili <args> 原样转发给内置 sidecar（排障用）。全部只读/只写工作区，不弹窗。
// GUI 子系统进程的 stdout 在重定向时不可靠：同时写 MINGLING_CLI_OUT 指定的文件，
// 验收脚本靠它留证据（不设就只打控制台）。
static void Out(const wstring& line) {
    wprintf(L"%s\n", line.c_str());
    wchar_t path[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"MINGLING_CLI_OUT", path, MAX_PATH * 2) && path[0])
        WriteTextFile(path, line + L"\r\n", true);
}

static int BiliCli(const std::vector<std::wstring>& args, int from) {
    auto has = [&](const wchar_t* k) { return from < (int)args.size() && args[from] == k; };
    if (has(L"--version")) {
        Out(std::wstring(APP_NAME) + L" " + APP_VERSION);
        Out(std::wstring(L"  文件版本 ") + APP_VERSION_FULL_W);
        return 0;
    }
    if (has(L"--paths")) {
        Out(std::wstring(L"版本     : ") + APP_VERSION + L"（" + APP_VERSION_FULL_W + L"）");
        WhaleEnv e = FindWhale();
        Out(L"工作区   : " + WorkspaceDir());
        Out(L"机器人根 : " + BaseDir());
        Out(L"组件根   : " + BotRoot());
        Out(L"AstrBot  : " + her::BotPath(L"AstrBot"));
        Out(L"SnowLuma : " + her::BotPath(L"SnowLuma"));
        Out(L"Breeze   : " + her::BotPath(L"Breeze"));
        Out(L"Ollama   : " + her::BotPath(L"Ollama"));
        Out(L"状态目录 : " + StateDir());
        Out(L"sidecar  : " + SidecarWhaleDir());
        Out(L"node     : " + e.node);
        Out(L"ffmpeg   : " + SidecarFfmpegExe());
        Out(L"配置     : " + e.config);
        Out(L"凭据     : " + e.creds + (FileExists(e.creds) ? L"（存在）" : L"（缺失）"));
        Out(L"日记     : " + e.diary);
        Out(L"台账     : " + JobsFile());
        Out(L"密钥目录 : " + SecretsDir());
        return e.ok ? 0 : 2;
    }
    if (has(L"--feed")) {
        CmdResult r = RunWhale(L"feed --n 6", 180000);
        Out(r.out);
        return r.code;
    }
    if (has(L"--debrief") && from + 1 < (int)args.size()) {
        wstring bv = args[from + 1];
        CmdResult r = RunWhale(L"debrief " + bv + L" --grid 3x3", 900000);
        Out(r.out);
        if (r.code != 0) return r.code;
        Debrief d = ParseDebrief(r.out);
        Out(L"[自检] " + wstring(d.ok ? L"OK" : L"FAIL") + L" | " + d.title + L" | 九宫格 " + d.sheet);
        return d.ok ? 0 : 3;
    }
    if (has(L"--watch") && from + 1 < (int)args.size()) {
        long long t0 = NowUnix();
        wstring bv = ExtractBv(args[from + 1]);
        if (bv.empty()) { Out(L"认不出 BV 号：" + args[from + 1]); return 4; }
        CmdResult r = RunWhale(L"debrief " + bv + L" --grid 3x3", 900000);
        Debrief d = ParseDebrief(r.out);
        wstring sink;
        EnsureWorkspaceLayout(WorkspaceDir());
        if (!r.out.empty()) {
            sink = JoinPath(JoinPath(JoinPath(WorkspaceDir(), L"logs"), L"jobs"),
                            bv + L"-" + std::to_wstring(NowUnix()) + L".txt");
            WriteTextFile(sink, r.out);
        }
        JobRec j;
        j.t = NowUnix();
        j.bv = bv;
        j.title = d.title;
        j.up = d.up;
        j.source = L"console";
        j.chat = L"工作台";
        j.status = (r.code == 0 && d.ok) ? L"ok" : L"fail";
        j.sink = sink;
        j.seconds = std::to_wstring((long long)(NowUnix() - t0)) + L"s";
        AppendJob(j);
        Out(L"[台账] 已写 " + JobsFile() + L"（source=console）");
        Out(L"[自检] " + wstring(d.ok ? L"OK" : L"FAIL") + L" | " + d.title + L" | 九宫格 " + d.sheet + L" | 正文 " + sink);
        return d.ok ? 0 : 3;
    }
    if (has(L"--bili")) {
        wstring rest;
        for (int i = from + 1; i < (int)args.size(); i++) rest += L" " + args[i];
        CmdResult r = RunWhale(rest, 180000);
        Out(r.out);
        return r.code;
    }
    if (has(L"--bots-setup")) {
        // 只装五个组件（不碰 Node/ffmpeg 那一套）：脚本在 tools\auto-setup.ps1
        Out(L"[装组件] 开始（第一次要下载，可能十几分钟）…");
        her::SetupReport rep = her::BotsSetup([](int pct, const std::wstring& s) {
            Out(L"[" + std::to_wstring(pct) + L"%] " + s);
        });
        for (auto& s : rep.steps)
            Out(wstring(L"  ") + (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail);
        Out(rep.summary);
        return rep.ok ? 0 : 2;
    }

    if (has(L"--autosetup")) {
        // 一键自动配置（计划 4.x）：UI 里是维护页按钮，这里给验收脚本一条命令行入口
        Out(L"[自动配置] 开始检查环境（要下 Node 与 ffmpeg，可能几分钟）…");
        her::SetupReport rep = her::AutoSetup([](int pct, const std::wstring& name) {
            Out(L"[" + std::to_wstring(pct) + L"%] " + name);
        });
        for (auto& s : rep.steps)
            Out(wstring(L"  ") + (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail);
        Out(rep.summary);
        return rep.ok ? 0 : 2;
    }

    if (has(L"--selfsetup")) {
        // 自设定：拿 pack\mingling-pack\pack.json 把 DeepSeek、QQ 平台、聊天设置、人设配成冥零
        bool dry = false;
        for (size_t i = 0; i + 1 < args.size(); ++i)
            if (args[i] == L"--selfsetup" && args[i + 1] == L"--dry") dry = true;
        Out(dry ? L"[自设定] 干跑（只看不说，什么都不改）…"
                : L"[自设定] 开始（要连后台，缺 key 或缺 QQ 平台会告诉你）…");
        her::SetupReport rep = her::Configure([](int pct, const std::wstring& s) {
            Out(L"[" + std::to_wstring(pct) + L"%] " + s);
        }, dry);
        for (auto& s : rep.steps)
            Out(wstring(L"  ") + (s.ok ? L"[ok] " : L"[!!] ") + s.name + L"  " + s.detail);
        Out(rep.summary);
        return rep.ok ? 0 : 2;
    }
    return 1;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE, LPSTR, int show) {
    AttachConsoleIfAsked();

    // 命令行模式：--her-status（查一遍给脚本/我自检用）、--game-off（开机自动恢复那一条）
    {
        int argc = 0;
        LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        std::vector<std::wstring> args;
        bool cli = false;
        if (argv) {
            for (int i = 1; i < argc; i++) {
                args.push_back(argv[i]);
                if (wcscmp(argv[i], L"--her-status") == 0 || wcscmp(argv[i], L"--game-off") == 0 ||
                    wcscmp(argv[i], L"--her-op") == 0 || wcscmp(argv[i], L"--paths") == 0 ||
                    wcscmp(argv[i], L"--feed") == 0 || wcscmp(argv[i], L"--debrief") == 0 ||
                    wcscmp(argv[i], L"--watch") == 0 || wcscmp(argv[i], L"--bili") == 0 ||
                    wcscmp(argv[i], L"--autosetup") == 0 || wcscmp(argv[i], L"--bots-setup") == 0 ||
                    wcscmp(argv[i], L"--selfsetup") == 0 ||
                    wcscmp(argv[i], L"--version") == 0) cli = true;
            }
            LocalFree(argv);
        }
        if (cli) {
            for (int i = 0; i < (int)args.size(); i++) {
                if (args[i] == L"--version" || args[i] == L"--paths" || args[i] == L"--feed" || args[i] == L"--debrief" ||
                    args[i] == L"--watch" || args[i] == L"--bili" || args[i] == L"--autosetup" ||
                    args[i] == L"--bots-setup" || args[i] == L"--selfsetup")
                    return BiliCli(args, i);
            }
            return her::CliMain(args);
        }
    }

    // 只留一份：已经有窗口就把它叫到前面
    HWND old = FindWindowW(CLS_NAME, nullptr);
    if (old) {
        ShowWindow(old, SW_RESTORE);
        SetForegroundWindow(old);
        return 0;
    }

    // 高 DPI 交给系统缩放，坐标我们自己算
    typedef BOOL(WINAPI * PFN_SETDPICTX)(HANDLE);
    if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
        auto p = (PFN_SETDPICTX)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (p) p((HANDLE)-4);   // PER_MONITOR_AWARE_V2
    }

    GdiplusStartupInput gi;
    ULONG_PTR token = 0;
    // 关掉扩展点注入（SetWindowsHookEx / AppInit）：既少一类被第三方输入层/加速器注入
    // 干扰的崩溃面，也让启动环境更干净。自绘窗口不用钩子，不影响功能。
    {
        PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY pol{};
        pol.DisableExtensionPoints = 1;
        SetProcessMitigationPolicy(ProcessExtensionPointDisablePolicy, &pol, sizeof(pol));
    }

    if (GdiplusStartup(&token, &gi, nullptr) != Ok) return 1;

    // 子进程会从启动它的宿主继承 AppUserModelID；不显式指定的话，任务栏会把本窗口归到
    // 宿主那一组、用宿主的图标（常常解析成通用文件图标）。给自己一个独立 ID。
    SetCurrentProcessExplicitAppUserModelID(APP_USER_MODEL_ID);

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = CLS_NAME;
    wc.hIcon = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                 GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    if (!wc.hIcon) wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    if (!RegisterClassExW(&wc)) return 1;

    // 按屏幕 DPI 给个像样的初始大小，别在 150% 缩放的小屏上挤成一团
    float dsc = 1.0f;
    if (HDC sdc = GetDC(nullptr)) {
        dsc = GetDeviceCaps(sdc, LOGPIXELSX) / 96.0f;
        ReleaseDC(nullptr, sdc);
    }
    if (dsc < 0.85f) dsc = 0.85f;
    if (dsc > 2.0f) dsc = 2.0f;
    const int swScreen = GetSystemMetrics(SM_CXSCREEN), shScreen = GetSystemMetrics(SM_CYSCREEN);
    int w = (int)(1400 * dsc), h = (int)(900 * dsc);
    if (w > (int)(swScreen * 0.90f)) w = (int)(swScreen * 0.90f);
    if (h > (int)(shScreen * 0.86f)) h = (int)(shScreen * 0.86f);
    RECT want = {0, 0, w, h};
    AdjustWindowRectEx(&want, WS_OVERLAPPEDWINDOW, FALSE, 0);
    int ww = want.right - want.left, wh = want.bottom - want.top;
    int sx = (GetSystemMetrics(SM_CXSCREEN) - ww) / 2;
    int sy = (GetSystemMetrics(SM_CYSCREEN) - wh) / 2 - 20;
    if (sy < 0) sy = 0;

    HWND hwnd = CreateWindowExW(0, CLS_NAME, WIN_TITLE, WS_OVERLAPPEDWINDOW, sx, sy, ww, wh, nullptr, nullptr, inst,
                                nullptr);
    if (!hwnd) {
        GdiplusShutdown(token);
        return 1;
    }
    // 任务栏和 Alt-Tab 读的是窗口自己的图标（WM_GETICON），只设类图标时有的系统版本会退回
    // 通用文件图标，所以这里再显式设一遍。
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)wc.hIcon);
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)wc.hIconSm);
    ShowWindow(hwnd, show == 0 ? SW_SHOWNORMAL : show);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // 编辑卡片文字时 Esc 不切页签，直接退出编辑（输入框自己吃掉其余按键）
        if (msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE && UiAskEditorBusy()) {
            UiAskEditorClose(false);
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    GdiplusShutdown(token);
    return 0;
}
