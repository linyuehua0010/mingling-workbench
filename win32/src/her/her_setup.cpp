// 冥零工作台 · 一键自动配置（纯 C++，跑在 RunHerOp 的工作线程里）
// 环境那摊子（Node、ffmpeg、五个组件、写配置）全交给 tools\bootstrap.ps1；
// C++ 只做本机步骤：工作区、密钥目录、settings、附带脚本，外加协议翻译。
#include "her.h"

#include <cstdio>
#include <cwchar>
#include <cstdlib>

namespace her {
namespace {

// ---------------------------------------------------------------- 工具协议
// bootstrap.ps1 / self-setup.ps1 都用同一套 ##STEP / ##OK / ##FAIL / ##RESULT。
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

std::wstring PowerShellExe() {
    wchar_t sysroot[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH * 2);
    std::wstring win = sysroot[0] ? std::wstring(sysroot) : std::wstring(L"C:\\Windows");
    return JoinPath(JoinPath(JoinPath(win, L"System32"), L"WindowsPowerShell"), L"v1.0\\powershell.exe");
}

// 传给 PowerShell 的路径参数：末尾的 \ 会吃掉自己的收尾引号（"F:\x\" → 参数变成 F:\x"），
// 所以统一削掉尾部分隔符再按需要补成对的反斜杠；盘符根（F:\）单独照顾。
std::wstring ArgPath(const std::wstring& s) {
    std::wstring t = s;
    while (t.size() > 2 && (t.back() == L'\\' || t.back() == L'/')) t.pop_back();
    if (t.size() == 2 && t[1] == L':') t += L'\\';     // "F:" → "F:\"
    if (!t.empty() && t.back() == L'\\') t += L'\\';   // "F:\" → "F:\\"（命令行里 \\" 才是字面反斜杠）
    return t;
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
        if (w != std::wstring::npos && c->rep) {
            std::wstring v = Trim(line.substr(w + 4));
            size_t n = v.find(L" next=");   // why=… next=… 只留 why 那一段
            c->rep->summary = n == std::wstring::npos ? v : Trim(v.substr(0, n));
        }
    }
}

// 拉起 tools\bootstrap.ps1（不带 -Check，只跑 extra 里 -Component 点名的组件），把协议翻成进度和报告。
// who 是这个脚本在报告里显示的名字；pctFrom..pctTo 是它在总进度条里占的区间。
// 判断只看 ##RESULT ok=1 且没有 ##FAIL：bootstrap 的退出码 0/1/2 都可能出现，
// 真正的缺项都在 ##FAIL 里，不能拿进程退出码当结论。
bool RunSetupScript(const wchar_t* who, SetupReport& rep, const wchar_t* extra,
                    const std::function<void(int, const std::wstring&)>& onStep, int pctFrom, int pctTo) {
    auto add = [&](const wchar_t* name, bool ok, const std::wstring& detail) {
        SetupStep s;
        s.name = name;
        s.ok = ok;
        s.detail = detail;
        rep.steps.push_back(s);
    };
    std::wstring script = JoinPath(JoinPath(Root(), L"tools"), L"bootstrap.ps1");
    if (!FileExists(script)) {
        add(who, false, L"没找到 " + script + L"（这一版没带 bootstrap.ps1）");
        rep.summary = L"没找到环境脚本，先把工作台更新到带 tools\\bootstrap.ps1 的版本。";
        return false;
    }
    std::wstring ps = PowerShellExe();
    if (!FileExists(ps)) {
        add(who, false, L"找不到 PowerShell：" + ps);
        rep.summary = L"这台机器缺 PowerShell，环境装不了。";
        return false;
    }

    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -Base \"" +
                        ArgPath(Base()) + L"\" -Workspace \"" + ArgPath(WorkspaceDir()) + L"\" -Bots \"" +
                        ArgPath(BotRoot()) + L"\"";
    if (extra && *extra) args += std::wstring(L" ") + extra;   // 形如 " -Component node,ffmpeg"
    // 脚本里的 0..100% 只占本阶段 pctFrom..pctTo 这一段。
    std::function<void(int, const std::wstring&)> scaled = [&](int pct, const std::wstring& text) {
        if (!onStep) return;
        onStep(pctFrom + pct * (pctTo - pctFrom) / 100, text);
    };
    BotsCtx ctx;
    ctx.rep = &rep;
    ctx.onStep = &scaled;
    if (onStep) onStep(pctFrom, L"拉起环境脚本（缺什么补什么，第一次要下载，可能十几分钟）");
    CmdResult r = RunCaptureStream(ps, args, Root(), EnvList(), 45 * 60 * 1000, OnBotsLine, &ctx);

    if (r.timeout) {
        add(who, false, L"跑了 45 分钟还没结束，先停了（网络慢就再试一次）");
        return false;
    }
    if (!ctx.sawResult) {
        std::wstring tail = Trim(r.out);
        if (tail.size() > 600) tail = tail.substr(tail.size() - 600);
        add(who, false, L"脚本没给出结果（退出码 " + std::to_wstring(r.code) + L"）：" + tail);
        return false;
    }
    int bad = 0;
    for (auto& s : rep.steps)
        if (!s.ok) bad++;
    return ctx.resultOk && bad == 0;
}

}  // namespace

// ---------------------------------------------------------------- 环境（自动配置）
// Node / ffmpeg / Python（还有 WebView2）交给 tools\bootstrap.ps1（幂等：装好了就跳过），
// C++ 不再自己下载任何东西；这里只留工作台自己的本机步骤：
// 工作区、密钥目录、写 settings、附带脚本。
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

    // ---- 工作区 / 密钥目录
    step(3, L"准备工作区与密钥目录");
    EnsureWorkspaceLayout(WorkspaceDir());
    EnsureSecrets();
    add(L"工作区", true, WorkspaceDir());
    add(L"密钥目录", true, SecretsDir());

    // ---- 配置
    step(7, L"写配置");
    if (SettingGet(L"workspace").empty()) SettingSet(L"workspace", WorkspaceDir());
    if (SettingGet(L"base").empty()) SettingSet(L"base", BaseDir());

    // ---- 环境（WebView2 / Node / ffmpeg / Python）交给 bootstrap.ps1；五个组件归 --bots-setup
    bool scriptOk = RunSetupScript(L"环境脚本", rep, L" -Component webview2,node,ffmpeg,python", onStep, 10, 92);

    // ---- 附带脚本
    step(96, L"检查附带脚本");
    {
        struct Want { const wchar_t* rel; const wchar_t* file; };
        const Want want[] = {{L"tools\\qq_watch.py", L"qq_watch.py"}, {L"tools\\qq-toast.ps1", L"qq-toast.ps1"}};
        // base 可能指向全新工作区，连 tools\ 都还没有：先把目标目录补出来再复制，
        // 否则 CopyFileW 只会因为「路径不存在」失败，看着像机器人根不可写。
        auto ensureDir = [](const std::wstring& path) {
            for (size_t i = 1; i < path.size(); i++)
                if (path[i] == L'\\') CreateDirectoryW(path.substr(0, i).c_str(), nullptr);
            CreateDirectoryW(path.c_str(), nullptr);
        };
        ensureDir(JoinPath(Base(), L"tools"));
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
    rep.ok = scriptOk && bad == 0;
    // 脚本自己失败（没给结果 / ok=0 却没有红项）时也要说「还差 1 项」，不能报成 0 项。
    int n = bad != 0 ? bad : 1;
    rep.summary = rep.ok ? std::wstring(L"环境齐了：Node、ffmpeg、工作区、密钥目录都在位，可以开始用了。")
                         : (std::wstring(L"还差 ") + std::to_wstring(n) + L" 项，看报告里的红字。");
    return rep;
}

// ---------------------------------------------------------------- 五个组件（bots 布局）
// 同一份 tools\bootstrap.ps1（幂等）：只补五个组件与启动脚本（-Component 点名），环境那几项归 AutoSetup。
// 这里只负责把它拉起来，把 ##STEP / ##OK / ##FAIL / ##RESULT 翻译成进度和报告。
SetupReport BotsSetup(const std::function<void(int, const std::wstring&)>& onStep) {
    SetupReport rep;
    bool ok = RunSetupScript(L"安装脚本", rep, L" -Component uv,astrbot,snowluma,breeze,ollama,bili-whale,bots-launchers",
                             onStep, 0, 100);
    if (rep.summary.empty()) {
        int bad = 0;
        for (auto& s : rep.steps)
            if (!s.ok) bad++;
        rep.ok = ok && bad == 0;
        rep.summary = rep.ok
                          ? std::wstring(L"组件齐了：AstrBot、SnowLuma、Breeze、Ollama、bili-whale 都在 " +
                                         BotRoot() + L" 下。")
                          : (std::wstring(L"还有 ") + std::to_wstring(bad != 0 ? bad : 1) +
                             L" 项没成，看报告里的红字。");
    } else {
        rep.ok = ok;   // 脚本没落盘 / 没 PowerShell：summary 已经写清原因
    }
    return rep;
}

// ---------------------------------------------------------------- 自设定（冥零配置包）

// 拿 pack\mingling-pack\pack.json，把 DeepSeek、QQ 平台、聊天设置、插件、记忆、语音、人设都配成冥零。
// 真正的活在 tools\self-setup.ps1（provider / platform / chat / plugins / memory / voice / persona / verify 八块），
// 这里只拉起它，把 ##STEP / ##OK / ##FAIL / ##RESULT 翻译成进度和报告。
SetupReport Configure(const std::function<void(int, const std::wstring&)>& onStep, bool dryRun) {
    SetupReport rep;
    auto add = [&](const wchar_t* name, bool ok, const std::wstring& detail) {
        SetupStep s;
        s.name = name;
        s.ok = ok;
        s.detail = detail;
        rep.steps.push_back(s);
    };
    std::wstring script = JoinPath(JoinPath(Root(), L"tools"), L"self-setup.ps1");
    if (!FileExists(script)) {
        add(L"自设定脚本", false, L"找不到自设定脚本：" + script);
        rep.summary = L"自设定脚本缺失，请修复安装，补齐 tools 和 pack 后再试。";
        return rep;
    }
    std::wstring ps = PowerShellExe();
    if (!FileExists(ps)) {
        add(L"自设定脚本", false, L"找不到 PowerShell：" + ps);
        rep.summary = L"这台机器缺 PowerShell，自设定跑不了。";
        return rep;
    }

    std::wstring args =
        L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -Base \"" + ArgPath(Base()) + L"\"";
    if (dryRun) args += L" -DryRun";
    BotsCtx ctx;
    ctx.rep = &rep;
    ctx.onStep = &onStep;
    if (onStep) onStep(1, L"读配置包（pack\\mingling-pack\\pack.json）");
    CmdResult r = RunCaptureStream(ps, args, Root(), EnvList(), 15 * 60 * 1000, OnBotsLine, &ctx);

    if (r.timeout) {
        add(L"自设定脚本", false, L"跑了 15 分钟还没结束，先停了（后台卡住就先重启大脑再试）");
    } else if (!ctx.sawResult) {
        std::wstring tail = Trim(r.out);
        if (tail.size() > 600) tail = tail.substr(tail.size() - 600);
        add(L"自设定脚本", false, L"脚本没给出结果（退出码 " + std::to_wstring(r.code) + L"）：" + tail);
    } else {
        add(L"自设定脚本", ctx.resultOk,
            ctx.resultOk ? L"跑完了：DeepSeek、QQ 平台、聊天设置、插件、记忆、语音、人设都按配置包对过一遍"
                         : L"有块没成，看上面的红字（改完 key 或 QQ 再点一次就行）");
    }

    int bad = 0;
    for (auto& s : rep.steps)
        if (!s.ok) bad++;
    rep.ok = ctx.sawResult && ctx.resultOk && bad == 0;
    if (rep.summary.empty() || !rep.ok) {
        if (rep.ok) {
            rep.summary = L"自设定完成：DeepSeek、QQ 平台、聊天设置、插件、记忆、语音、人设都配好了，可以私聊她了。";
        } else if (rep.summary.empty()) {
            rep.summary = std::wstring(L"还差 ") + std::to_wstring(bad == 0 ? 1 : bad) +
                          L" 项没配好，看报告里的红字。";
        }
    }
    return rep;
}

}  // namespace her
