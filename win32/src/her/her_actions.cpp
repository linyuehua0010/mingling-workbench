// 冥零工作台 · 维护页上那些按钮真正干的事（原生版 act_*）
// 以前是 python 跑 server.py 里的动作；现在 C++ 自己来：
//   启停进程用 CreateProcess + 等端口，改开关走 AstrBot 接口或直接改配置，
//   备份 / 求助信息 / 开机自启 / 补装这些东西本来就有 ps1 脚本，直接调脚本，不再经 python。
#include "her.h"
#include "../version.h"   // 工作台版本只有这一个出处（更新页要比的 local 就是它）

#include <shlobj.h>
#include <shellapi.h>
#include <time.h>

#include <cstdio>

namespace her {

namespace {

ActionResult Ok(wstring m) { return {true, m}; }
ActionResult Bad(wstring m) { return {false, m}; }

void SleepMs(int ms) { Sleep((DWORD)ms); }

wstring StartupDir() {
    wchar_t buf[MAX_PATH];
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_STARTUP, nullptr, 0, buf))) return L"";
    return buf;
}

bool WriteText(const wstring& path, const wstring& text) { return WriteTextFile(path, text, false); }

wstring B64(const std::vector<unsigned char>& b) {
    static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string o;
    size_t i = 0;
    while (i + 2 < b.size()) {
        unsigned v = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
        o.push_back(t[v >> 18]);
        o.push_back(t[(v >> 12) & 63]);
        o.push_back(t[(v >> 6) & 63]);
        o.push_back(t[v & 63]);
        i += 3;
    }
    if (i + 1 == b.size()) {
        unsigned v = b[i] << 16;
        o.push_back(t[v >> 18]);
        o.push_back(t[(v >> 12) & 63]);
        o.push_back('=');
        o.push_back('=');
    } else if (i + 2 == b.size()) {
        unsigned v = (b[i] << 16) | (b[i + 1] << 8);
        o.push_back(t[v >> 18]);
        o.push_back(t[(v >> 12) & 63]);
        o.push_back(t[(v >> 6) & 63]);
        o.push_back('=');
    }
    return Utf8ToW(o);
}

// PowerShell 用 -EncodedCommand 跑：整段脚本走参数，不碰引号和中文
CmdResult PsEncoded(const wstring& ps, const EnvList& env, int timeoutMs) {
    std::vector<unsigned char> u16;
    std::string s = WToUtf8(ps);
    // 先把 UTF-8 转回 UTF-16LE
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::vector<wchar_t> w(n + 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), w.data(), n);
    u16.resize((size_t)n * 2);
    memcpy(u16.data(), w.data(), u16.size());
    wstring enc = B64(u16);
    return RunCapture(L"powershell.exe", L"-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + enc, Base(), env, timeoutMs);
}

CmdResult PsFile(const wstring& script, const wstring& args, int timeoutMs, const EnvList& env = {}) {
    return RunCapture(L"powershell.exe",
                      L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" " + args, Base(), env,
                      timeoutMs);
}

wstring TailText(const wstring& s, size_t n) {
    return s.size() > n ? s.substr(s.size() - n) : s;
}

std::vector<DWORD> OllamaPids() {
    std::vector<DWORD> out;
    for (const wchar_t* n : {L"ollama.exe", L"ollama app.exe", L"ollama_llama_server.exe"}) {
        std::vector<DWORD> v = PidsNamed(n);
        out.insert(out.end(), v.begin(), v.end());
    }
    return out;
}

// 打游戏模式在启动文件夹放的那个「打完恢复」快捷方式：指向我们自己（--game-off）
bool GameBootHook(bool on) {
    wstring lnk = JoinPath(StartupDir(), L"大肥鱼-打完游戏恢复.lnk");
    if (!on) {
        DeleteFileW(lnk.c_str());
        return true;
    }
    wstring exe = JoinPath(ExeDir(), L"MinglingWorkbench.exe");
    EnvList env;
    env.push_back({L"DFY_LNK", lnk});
    env.push_back({L"DFY_EXE", exe});
    env.push_back({L"DFY_ARGS", L"--game-off"});
    wstring ps =
        L"$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:DFY_LNK);"
        L"$s.TargetPath=$env:DFY_EXE;$s.Arguments=$env:DFY_ARGS;$s.WorkingDirectory=$env:TEMP;$s.WindowStyle=7;"
        L"$s.Description='开机把大肥鱼的语音和记忆开回来，开完自己删掉';$s.Save()";
    return PsEncoded(ps, env, 30000).code == 0;
}

// ---------------------------------------------------------------- 每个人一个动作
ActionResult StartBrain(bool restart) {
    if (!IsCli()) return Bad(L"这不是命令行版安装，得用 AstrBot 启动器开。");
    int port = BackendPort();
    if (!restart && Listening(port)) return Ok(L"大脑本来就开着。");
    if (restart) {
        std::vector<DWORD> pids = AstrBotPids();
        for (DWORD pid : pids) KillTree(pid);
        WaitFor([&] { return !Listening(port); }, 25);
        SleepMs(2000);
    }
    wstring cmd = ComponentStartCmd(L"AstrBot", L"start-astrbot.cmd");
    if (cmd.empty()) return Bad(L"找不到 AstrBot 的启动脚本（bots\\AstrBot\\start.cmd）。");
    LaunchCmd(cmd, ParentDir(cmd), false);
    if (!WaitFor([&] { return Listening(port); }, 150))
        return Bad(L"两分半了后台还没起来。看看 AstrBot 那个窗口里说什么，或者点「求助信息」。");
    WaitFor([] { return QqOnline(); }, 40);
    return Ok(restart ? L"大脑重启好了。" : L"大脑开好了。");
}

ActionResult Relogin() {
    if (QqOnline()) return Ok(L"小号本来就在线，不用重登。");
    wstring cmd = JoinPath(JoinPath(Base(), L"tools"), L"relogin.cmd");
    if (!FileExists(cmd)) {
        // 没有一键重登脚本（新装机器默认没有）：退回到「打开登 QQ 的后台自己扫码」，
        // 不再把用户堵在「没找到工具」这句死路上。
        bool nap = Protocol() == L"napcat";
        int port = nap ? 6099 : 5099;
        if (!Listening(port)) {
            wstring start = ComponentStartCmd(nap ? L"NapCat" : L"SnowLuma",
                                             nap ? L"start-napcat.cmd" : L"start-snowluma.cmd");
            if (!start.empty()) {
                LaunchCmd(start, ParentDir(start), false);
                WaitFor([&] { return Listening(port); }, 60);
            }
        }
        if (!Listening(port))
            return Bad(nap ? L"登 QQ 的程序没起来，也没找到一键重登脚本。先点「重启 QQ 程序」。" 
                           : L"登 QQ 的程序没起来，也没找到一键重登脚本。先点「重启 QQ 程序」。");
        ShellExecuteW(nullptr, L"open", nap ? L"http://127.0.0.1:6099/webui" : L"http://127.0.0.1:5099",
                      nullptr, nullptr, SW_SHOWNORMAL);
        return Ok(L"已打开登 QQ 的后台：在网页里重新扫码登录小号。");
    }
    LaunchCmd(cmd, Base(), true);
    if (!WaitFor([] { return QqOnline(); }, 620))
        return Bad(L"等十分多钟小号还没登上。照那个黑色窗口里说的再做一遍。");
    return Ok(L"小号登上来了。");
}

ActionResult RestartQQ() {
    bool nap = Protocol() == L"napcat";
    wstring root = BotPath(nap ? L"NapCat" : L"SnowLuma");
    wstring cmd = ComponentStartCmd(nap ? L"NapCat" : L"SnowLuma",
                                    nap ? L"start-napcat.cmd" : L"start-snowluma.cmd");
    if (cmd.empty()) return Bad(L"找不到 " + (nap ? wstring(L"start-napcat.cmd") : wstring(L"start-snowluma.cmd")) + L"。");
    KillUnder(root);
    WaitFor([&] { return PidsUnder(root).empty(); }, 15);
    SleepMs(2000);
    LaunchCmd(cmd, ParentDir(cmd), false);
    if (!WaitFor([] { return QqOnline(); }, 75)) return Bad(L"重开了，但小号 75 秒没登上来。点「重登 QQ」扫一下码。");
    return Ok(L"登 QQ 的程序重开好了，小号在线。");
}

ActionResult StartBreeze() {
    if (Listening(8137)) return Ok(L"Breeze 本来就开着。");
    wstring cmd = ComponentStartCmd(L"Breeze", L"breeze-tts\\start-breeze.cmd");
    if (cmd.empty()) return Bad(L"找不到 Breeze 的启动文件（bots\\Breeze\\start.cmd）。");
    LaunchCmd(cmd, ParentDir(cmd), false);
    if (!WaitFor([] { return Listening(8137); }, 90))
        return Bad(L"一分半了 Breeze 还没开。它在加载声音模型，再等等；还不行就点「求助信息」。");
    return Ok(L"Breeze 开好了。");
}

ActionResult StartOllama() {
    if (Listening(11434)) return Ok(L"Ollama 本来就开着。");
    if (OllamaExe().empty()) return Bad(L"找不到 ollama.exe。交给 Agent 装一下。");
    LaunchOllama();
    if (!WaitFor([] { return Listening(11434); }, 60)) return Bad(L"一分钟了 Ollama 还没开。看看任务管理器里有没有 ollama。");
    WaitFor([] {
        bool ok = false;
        std::vector<wstring> ms = OllamaModels(&ok);
        if (!ok) return false;
        for (auto& m : ms) {
            wstring b = m;
            size_t q = b.find(L':');
            if (q != wstring::npos) b = b.substr(0, q);
            if (b == L"bge-m3") return true;
        }
        return false;
    }, 20);
    return Ok(L"Ollama 开好了，记忆模型也在。");
}

ActionResult Backup() {
    wstring ps = JoinPath(JoinPath(Base(), L"tools"), L"backup.ps1");
    if (!FileExists(ps)) return Bad(L"找不到备份脚本（tools\\backup.ps1）。");
    CmdResult r = PsFile(ps, L"-Dir \"" + Base() + L"\"", 600000);
    wstring file, size, files;
    for (auto& line : SplitLines(r.out)) {
        wstring t = Trim(line);
        if (t.find(L"备份好了") != wstring::npos) {
            size_t a = t.find(L'：');
            if (a == wstring::npos) a = t.find(L':');
            if (a != wstring::npos) file = Trim(t.substr(a + 1));
        }
        if (StartsWith(t, L"DATA ")) {
            for (auto& kv : SplitLines(ReplaceAll(t, L" ", L"\n"))) {
                if (StartsWith(kv, L"size=")) size = kv.substr(5);
                if (StartsWith(kv, L"files=")) files = kv.substr(6);
            }
        }
    }
    if (r.code != 0) return Bad(L"备份没成：" + TailText(Trim(r.out), 160));
    if (file.empty()) return Bad(L"备份跑完了，但没找到打包好的文件。");
    return Ok(L"备份好了：" + file + (files.empty() ? L"" : L"（" + files + L" 个文件" + (size.empty() ? L"" : L"，" + size) + L"）"));
}

ActionResult Diag() {
    wstring ps = JoinPath(JoinPath(Base(), L"tools"), L"diag.ps1");
    if (!FileExists(ps)) return Bad(L"找不到诊断脚本（tools\\diag.ps1）。");
    CmdResult r = PsFile(ps, L"-Dir \"" + Base() + L"\" -Json", 240000);
    wstring js;
    for (auto& line : SplitLines(r.out)) {
        wstring t = Trim(line);
        if (StartsWith(t, L"DIAG_JSON ")) js = t.substr(10);
    }
    if (js.empty()) return Bad(L"诊断没跑出结果：" + TailText(Trim(r.out), 160));
    wstring dir = JoinPath(Base(), L"logs");
    CreateDirectoryW(dir.c_str(), nullptr);
    wstring out = JoinPath(dir, L"diag-" + NowLocal(L"%m%d-%H%M") + L".json");
    WriteText(out, js);
    // diag.ps1 自己写了一份 txt（还进了剪贴板），这里只负责把「卡在哪」说清楚
    bool ok = false;
    J j = J::Parse(js, &ok);
    wstring file = ok ? j.Str(L"file") : L"";
    wstring sent = ok ? j.Str(L"sentence") : L"";
    wstring msg = sent.empty() ? wstring(L"求助信息记下来了。") : sent;
    if (!file.empty()) {
        if (!msg.empty() && msg.back() != L'。' && msg.back() != L'；') msg += L"。";
        msg += L"存到：" + file + L"。";
    }
    msg += L"交给 Agent 就能看。";
    return Ok(msg);
}

ActionResult AutostartFix() {
    // 开机自启的目标脚本：组件在 <工作区>\bots 下就指组件目录里的 start.cmd，
    // 老布局才指 <机器人根> 下的那几个。空串交给 PowerShell 那段的 Test-Path 挡掉。
    wstring astrCmd = ComponentStartCmd(L"AstrBot", L"start-astrbot.cmd");
    wstring breezeCmd = ComponentStartCmd(L"Breeze", L"breeze-tts\\start-breeze.cmd");
    wstring ollamaExe = JoinPath(BotPath(L"Ollama"), L"ollama.exe");
    wstring ps =
        L"$ErrorActionPreference='Stop';"
        L"$Dir=$env:DFY_DIR;$proto=$env:DFY_PROTO;$mem=$env:DFY_MEM;$voice=$env:DFY_VOICE;"
        L"$as=$env:DFY_ASTR;$bz=$env:DFY_BREEZE;$ol=$env:DFY_OLLAMA;"
        L". \"$env:DFY_SCRIPTS\\common.ps1\";"
        L"$startup=[Environment]::GetFolderPath('Startup');$ws=New-Object -ComObject WScript.Shell;"
        L"function L($p,$t,$w,$d,$a=''){$l=$ws.CreateShortcut($p);$l.TargetPath=$t;$l.Arguments=$a;"
        L"$l.WorkingDirectory=$w;$l.WindowStyle=7;$l.Description=$d;$l.Save();\"ADDED $(Split-Path $p -Leaf)\"};"
        L"if($as -and (Test-Path $as) -and -not (Test-Path \"$startup\\大肥鱼-AstrBot.lnk\")){"
        L"L \"$startup\\大肥鱼-AstrBot.lnk\" $as (Split-Path $as) '大肥鱼的大脑，别关'};"
        L"Set-QQAutostart $Dir $proto;"
        L"if($mem -eq '1' -and -not (Test-Path \"$startup\\Ollama.lnk\")){"
        L"$o=@($ol,\"$env:LOCALAPPDATA\\Programs\\Ollama\\ollama.exe\")|Where-Object{$_ -and (Test-Path $_)}|Select-Object -First 1;"
        L"if($o){L \"$startup\\Ollama.lnk\" \"$env:SystemRoot\\System32\\conhost.exe\" (Split-Path $o) '大肥鱼的记忆' \"--headless `\"$o`\" serve\"}};"
        L"if($voice -eq '4' -and $bz -and (Test-Path $bz) -and -not (Get-ChildItem $startup -Filter '*Breeze*' -ErrorAction SilentlyContinue)){"
        L"L \"$startup\\启动Breeze语音.lnk\" $bz (Split-Path $bz) '大肥鱼的语音'};"
        L"'DONE'";
    EnvList env;
    env.push_back({L"DFY_DIR", Base()});
    env.push_back({L"DFY_PROTO", Protocol()});
    env.push_back({L"DFY_MEM", std::to_wstring(Memory())});
    env.push_back({L"DFY_VOICE", std::to_wstring(Voice())});
    env.push_back({L"DFY_SCRIPTS", JoinPath(Base(), L"tools")});
    env.push_back({L"DFY_ASTR", astrCmd});
    env.push_back({L"DFY_BREEZE", breezeCmd});
    env.push_back({L"DFY_OLLAMA", ollamaExe});
    CmdResult r = PsEncoded(ps, env, 60000);
    if (r.code != 0 || r.out.find(L"DONE") == wstring::npos)
        return Bad(L"没补上：" + TailText(Trim(r.out), 160));
    int added = 0;
    for (auto& line : SplitLines(r.out))
        if (StartsWith(Trim(line), L"ADDED ")) added++;
    return Ok(added ? L"补上了 " + std::to_wstring(added) + L" 个开机自启入口。QQ 会隐藏等待网络和大脑，自动登录失效才出二维码。"
                    : L"开机自启本来就是齐的。QQ 会隐藏等待网络和大脑，自动登录失效才出二维码。");
}

bool StartWatch() {
    if (Watch().running) return true;
    std::vector<wstring> cands;
    cands.push_back(JoinPath(JoinPath(Base(), L"tools"), L"python\\pythonw.exe"));
    cands.push_back(JoinPath(Base(), L"python\\pythonw.exe"));
    for (auto& c : cands) {
        if (!FileExists(c)) continue;
        wchar_t tmp[MAX_PATH];
        GetTempPathW(MAX_PATH, tmp);
        LaunchExe(c, L"-X utf8 \"" + JoinPath(JoinPath(Base(), L"tools"), L"qq_watch.py") + L"\" --dir \"" + Base() + L"\"",
                  tmp, {}, true);
        return true;
    }
    return false;
}

ActionResult WatchMode(const wstring& mode) {
    wstring py = JoinPath(JoinPath(Base(), L"tools"), L"qq_watch.py");
    if (!FileExists(py)) return Bad(L"这一版还没放掉线提醒。到「更新」页点一键更新。");
    wstring off = P(L"private\\qq-watch-off.txt");
    if (mode == L"off") {
        CreateDirectoryW(P(L"private").c_str(), nullptr);
        WriteText(off, L"关了掉线提醒。删掉这个文件就开回来。\n");
        return Ok(L"掉线提醒关了。她掉线不会再弹通知，要自己开工作台看。");
    }
    if (mode == L"on") {
        DeleteFileW(off.c_str());
        bool started = StartWatch();
        return started ? Ok(L"掉线提醒开了。")
                       : Bad(L"开关打开了，但后台程序没起来：没找到 pythonw。");
    }
    if (mode == L"test") {
        StartWatch();
        wstring ps = JoinPath(JoinPath(Base(), L"tools"), L"qq-toast.ps1");
        CmdResult r = PsFile(ps, L"-Dir \"" + Base() + L"\" -Kind test", 40000);
        if (r.code != 0) return Bad(Trim(r.out).empty() ? wstring(L"通知没弹出来。") : TailText(Trim(r.out), 120));
        return Ok(L"看电脑右下角。点一下那条通知，就是掉线时的样子。");
    }
    return Bad(L"没有这个选项");
}

// ---------------------------------------------------------------- 三个频率开关
ActionResult FreqGroup(const wstring& mode) {
    if (mode != L"off" && mode != L"mention" && mode != L"quote" && mode != L"both") return Bad(L"没有这个选项");
    if (!Listening(BackendPort())) return Bad(L"大脑没开，改不了。先把大脑开起来。");
    AstrApi api;
    wstring err;
    if (!api.Login(&err)) return Bad(L"大脑后台没登上。" + err);
    J root;
    if (!api.GetJson(L"/config-profiles/default", root, &err)) return Bad(L"改不了：" + err);
    const J* cfgp = root.Get(L"config");
    if (!cfgp) return Bad(L"后台没给 config。");
    J cfg = *cfgp;
    bool m = mode == L"mention" || mode == L"both";
    bool q = mode == L"quote" || mode == L"both";
    cfg.PathSet(L"platform_settings.reply_with_mention", JBool(m));
    cfg.PathSet(L"platform_settings.reply_with_quote", JBool(q));
    if (!api.PutJson(L"/config-profiles/default", cfg, &err)) return Bad(L"改不了：" + err);
    // 顺手把本地文件也对齐（后台改完自己也会写，这里只是让卡片马上变）
    J local = CmdConfig();
    local.PathSet(L"platform_settings.reply_with_mention", JBool(m));
    local.PathSet(L"platform_settings.reply_with_quote", JBool(q));
    CmdConfigSave(local);
    if (mode == L"off") return Ok(L"改好了：群里回话不 @ 人、也不引用。");
    if (mode == L"mention") return Ok(L"改好了：她在群里回谁就先 @ 谁（私聊不 @）。发语音那几条不带 @。");
    if (mode == L"quote") return Ok(L"改好了：她回话会引用对方那句（私聊也会引用）。发语音那几条不带引用。");
    return Ok(L"改好了：她在群里回谁就 @ 谁，还引用对方那句。发语音那几条不带。");
}

ActionResult FreqMeme(const wstring& level) {
    int v = 0;
    if (level == L"few") v = 30;
    else if (level == L"mid") v = 60;
    else if (level == L"many") v = 100;
    else return Bad(L"没有这个选项");
    if (!Listening(BackendPort())) return Bad(L"大脑没开，改不了。先把大脑开起来。");
    AstrApi api;
    wstring err;
    if (!api.Login(&err)) return Bad(L"大脑后台没登上。" + err);
    J conf;
    if (!api.PluginConfig(L"meme_manager", conf, &err))
        return Bad(L"表情包插件还没装，先补装一下。" + err);
    conf.PathSet(L"generation.emotion.probability", JNum(v));
    if (!api.SavePluginConfig(L"meme_manager", conf, &err)) return Bad(L"改不了：" + err);
    if (level == L"few") return Ok(L"改好了：表情包少发点，她挑中表情也只有三成会发。");
    if (level == L"mid") return Ok(L"改好了：她挑中表情，六成会发图。");
    return Ok(L"改好了：她挑中表情就发图。");
}

ActionResult FreqVoice(const wstring& level) {
    double v = 0;
    if (level == L"few") v = 0.15;
    else if (level == L"mid") v = 0.33;
    else if (level == L"many") v = 0.66;
    else return Bad(L"没有这个选项");
    if (!Listening(BackendPort())) return Bad(L"大脑没开，改不了。先把大脑开起来。");
    AstrApi api;
    wstring err;
    if (!api.Login(&err)) return Bad(L"大脑后台没登上。" + err);
    J root;
    if (!api.GetJson(L"/config-profiles/default", root, &err)) return Bad(L"改不了：" + err);
    const J* cfgp = root.Get(L"config");
    if (!cfgp) return Bad(L"后台没给 config。");
    J cfg = *cfgp;
    // 语音提供商（整条合成的那种要单独改它的概率）
    wstring pid = cfg.Path(L"provider_tts_settings.provider_id") ? cfg.Path(L"provider_tts_settings.provider_id")->s : L"";
    const J* prov = nullptr;
    const J* arr = cfg.Get(L"provider");
    if (arr && arr->Arr())
        for (const J& x : arr->a)
            if (!pid.empty() && x.Str(L"id") == pid) {
                prov = &x;
                break;
            }
    if (!prov) return Bad(L"她还没接语音。想要的话去「交给 Agent」。");
    wstring type = prov->Str(L"type");
    bool whole = (type == L"seed_audio_tts" && prov->Bool(L"seed_audio_whole_reply")) ||
                 (type == L"breeze_online_tts" && prov->Bool(L"breeze_online_whole_reply"));
    wstring key = type == L"breeze_online_tts" ? L"breeze_online_reply_probability" : L"seed_audio_reply_probability";
    cfg.PathSet(L"provider_tts_settings.trigger_probability", JNum(v));
    if (!api.PutJson(L"/config-profiles/default", cfg, &err)) return Bad(L"改不了：" + err);
    if (whole) {
        J cur;
        if (api.GetJson(L"/providers/" + pid, cur, &err)) {
            const J* p = cur.Get(L"provider");
            J conf = (p && p->Obj()) ? *p : cur;
            conf.Set(key, JNum(v));
            api.SaveProvider(pid, conf, &err);
        }
    }
    J local = CmdConfig();
    local.PathSet(L"provider_tts_settings.trigger_probability", JNum(v));
    CmdConfigSave(local);
    if (level == L"few") return Ok(L"改好了：语音少发点，大约七条里一条是语音。");
    if (level == L"mid") return Ok(L"改好了：大约三条里一条是语音。");
    return Ok(L"改好了：语音多发点，大约三条里两条是语音。");
}

// ---------------------------------------------------------------- 打游戏模式
ActionResult GameOn() {
    int vc = Voice();
    // 只要本机真有服务在跑就该能开：语音没启用（vc==0）也可能有 Breeze 在吃显卡
    bool localVoice = Listening(8137);
    bool localMem = Listening(11434) && (MemoryWiring().ollama || Memory() == 1);
    bool voice = vc == 4 || localVoice;
    bool mem = Memory() == 1 || localMem;
    if (!voice && !mem) return Bad(L"本机没有在跑的语音或记忆（用的都是在线服务，不占这台电脑），打游戏不用关她。");
    wstring file = P(L"logs\\game-mode.json");
    J g = ReadJson(file);
    long long now = (long long)time(nullptr);
    if (!g.Obj() || !g.Bool(L"on")) {
        g = JObj();
        g.Set(L"on", JBool(true));
        g.Set(L"since", JNum((double)now));
        g.Set(L"tts", JBool(false));
        g.Set(L"mem", JBool(false));
        // 记下当时本机在跑什么，恢复时只把确实动过的开回来
        g.Set(L"local_voice", JBool(Listening(8137)));
        g.Set(L"local_mem", JBool(Listening(11434)));
    }
    CreateDirectoryW(P(L"logs").c_str(), nullptr);
    WriteJsonAtomic(file, g);
    GameBootHook(true);
    std::vector<wstring> notes;
    if (Listening(BackendPort())) {
        AstrApi api;
        wstring err;
        if (!api.Login(&err)) {
            notes.push_back(L"大脑后台没登上，她每条消息会慢七八秒");
        } else {
            if (voice) {
                if (!api.TtsEnable(false, &err))
                    notes.push_back(L"语音开关没关上（" + err + L"）");
                else if (!g.Bool(L"tts")) {
                    g.Set(L"tts", JBool(true));
                    WriteJsonAtomic(file, g);
                }
            }
            if (mem) {
                J on;
                bool have = api.GetJson(L"/plugins", on, &err);
                bool act = false;
                if (have && on.Arr())
                    for (const J& p : on.a)
                        if (p.Str(L"name") == L"astrbot_plugin_livingmemory") act = p.Bool(L"activated");
                if (act) {
                    if (api.PluginEnabled(L"astrbot_plugin_livingmemory", false, &err)) {
                        g.Set(L"mem", JBool(true));
                        WriteJsonAtomic(file, g);
                    } else {
                        notes.push_back(L"记忆插件没停下（" + err + L"）");
                    }
                }
            }
        }
    }
    if (voice && Listening(8137)) {
        std::wstring bdir = BotPath(L"Breeze");
        std::vector<DWORD> pids = PidsUnder(bdir);
        if (pids.empty()) KillUnder(bdir);
        else
            for (DWORD pid : pids) KillTree(pid);
        WaitFor([] { return !Listening(8137); }, 20);
        if (Listening(8137)) notes.push_back(L"Breeze 没关掉，把任务栏里「Breeze TTS」那个窗口关了");
    }
    if (mem) {
        for (DWORD pid : OllamaPids()) KillTree(pid);
        WaitFor([] { return !Listening(11434); }, 20);
        if (Listening(11434)) notes.push_back(L"Ollama 没关掉，在任务管理器里结束「ollama」");
    }
    wstring off;
    if (voice) off = L"语音";
    if (mem) off += (off.empty() ? L"" : L"、") + wstring(L"记忆");
    wstring msg = L"打游戏模式开了：本机的" + off +
                  L"都关了。她照样回消息，只是只打字、这段时间说的事不记（以前记住的都还在）。打完点「打完了，恢复」；"
                  L"忘了点也没事，重启电脑会自己恢复。";
    if (!notes.empty()) {
        msg += L"另外：";
        for (size_t i = 0; i < notes.size(); i++) msg += (i ? L"；" : L"") + notes[i];
        msg += L"。";
    }
    return Ok(msg);
}

ActionResult GameOff(bool boot) {
    wstring file = P(L"logs\\game-mode.json");
    J g = ReadJson(file);
    if (!g.Bool(L"on")) {
        GameBootHook(false);
        return Ok(L"打游戏模式本来就关着。");
    }
    int vc = Voice();
    bool voice = vc == 4 || g.Bool(L"local_voice");
    bool mem = Memory() == 1 || g.Bool(L"local_mem");
    std::vector<wstring> fails;
    if (mem) {
        if (boot && !Listening(11434)) WaitFor([] { return Listening(11434); }, 120);
        if (!Listening(11434) && !OllamaExe().empty()) {
            LaunchOllama();
            WaitFor([] { return Listening(11434); }, 60);
        }
        if (Listening(11434)) {
            // 先把记忆模型装进内存，她下一条消息不用等
            HttpPostJson(L"http://127.0.0.1:11434/api/embed", L"{\"model\":\"bge-m3\",\"input\":\"你好\"}", L"", 90000);
        } else {
            fails.push_back(L"记忆（Ollama 没开起来，点记忆那一行的「打开 Ollama」）");
        }
    }
    if (voice) {
        if (boot && !Listening(8137)) WaitFor([] { return Listening(8137); }, 150);
        if (!Listening(8137)) {
            wstring bcmd = ComponentStartCmd(L"Breeze", L"breeze-tts\\start-breeze.cmd");
            if (!bcmd.empty()) {
                LaunchCmd(bcmd, ParentDir(bcmd), false);
                WaitFor([] { return Listening(8137); }, 90);
            }
        }
        if (!Listening(8137)) fails.push_back(L"语音（Breeze 没开起来，点语音那行的「打开 Breeze」）");
    }
    if (g.Bool(L"tts") || g.Bool(L"mem")) {
        if (boot) WaitFor([] { return Listening(BackendPort()); }, 300);
        AstrApi api;
        wstring err;
        if (!Listening(BackendPort()) || !api.Login(&err))
            return Bad(L"程序都开回来了，但大脑后台没登上，语音开关和记忆插件还关着。先把大脑打开，再点一次「打完了，恢复」。");
        if (g.Bool(L"mem")) {
            if (!api.PluginEnabled(L"astrbot_plugin_livingmemory", true, &err))
                return Bad(L"后台开关没拨回去（" + err + L"）。再点一次「打完了，恢复」。");
        }
        if (g.Bool(L"tts")) {
            if (!api.TtsEnable(true, &err))
                return Bad(L"语音开关没拨回去（" + err + L"）。再点一次「打完了，恢复」。");
        }
    }
    DeleteFileW(file.c_str());
    GameBootHook(false);
    if (!fails.empty()) {
        wstring m = L"后台恢复好了，但";
        for (size_t i = 0; i < fails.size(); i++) m += (i ? L"；" : L"") + fails[i];
        return Bad(m + L"。");
    }
    return Ok(L"恢复好了：她又能发语音、记事了。");
}

// ---------------------------------------------------------------- 补装 / 更新
ActionResult Import(const wstring& block) {
    wstring b = block.empty() ? L"memes" : block;
    if (b == L"memory" && Memory() < 1) return Bad(L"你装的时候没选记忆。想要的话去「交给 Agent」。");
    if (b == L"voice" && Voice() < 1) return Bad(L"你装的时候没选语音。");
    wstring ps = JoinPath(JoinPath(Base(), L"tools"), L"import-pack.ps1");
    if (!FileExists(ps)) return Bad(L"找不到补装脚本（tools\\import-pack.ps1）。");
    std::vector<wstring> running;
    for (const wchar_t* blk : {L"core", L"plugins", L"video", L"memory", L"voice", L"memes"}) {
        if (ImportLogState(blk) == L"running") running.push_back(blk);
    }
    if (!running.empty()) return Bad(L"正在补装别的东西，等它装完。");
    CmdResult r = PsFile(ps, L"-Dir \"" + Base() + L"\" -Only " + b + L" -Background", 120000);
    if (r.code != 0) return Bad(L"补装没起来：" + TailText(Trim(r.out), 160));
    return Ok(L"补装放到后台了，日志在 logs\\import-" + b + L".log。她照常聊天。");
}

// 版本比较：取前四段数字
std::vector<int> VerParts(const wstring& s) {
    std::vector<int> out;
    wstring cur;
    for (wchar_t c : s) {
        if (c >= L'0' && c <= L'9') cur.push_back(c);
        else if (c == L'.' && !cur.empty()) {
            out.push_back(_wtoi(cur.c_str()));
            cur.clear();
        } else if (!cur.empty()) {
            break;
        }
        if (out.size() >= 4) break;
    }
    if (!cur.empty() && out.size() < 4) out.push_back(_wtoi(cur.c_str()));
    while (out.size() < 4) out.push_back(0);
    return out;
}

int VerCmp(const wstring& a, const wstring& b) {
    std::vector<int> x = VerParts(a), y = VerParts(b);
    for (int i = 0; i < 4; i++) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

wstring FetchText(const wstring& url, int timeoutMs = 8000, size_t limit = 0) {
    Http r = HttpGet(url, timeoutMs);
    if (!r.ok || r.code >= 400) return L"";
    return limit && r.body.size() > limit ? r.body.substr(0, limit) : r.body;
}

// 拿 Skill 的发布清单（releases/latest/download/skill-version.json），顺便说清为什么没拿到：
//   notpublished = 404（这个仓库还没发过 skill 包）／net = 连不上／bad = 拿到了但不是那份 JSON。
// 「没发布」和「没连上」要分开说：前者不该催用户去点更新，后者过会儿再看就好。
static wstring FetchManifest(const wstring& url, wstring* why, J* out = nullptr) {
    if (why) *why = L"net";
    Http r = HttpGet(url, 10000);
    if (!r.ok) return L"";
    if (r.code == 404) {
        if (why) *why = L"notpublished";
        return L"";
    }
    if (r.code >= 400) return L"";
    bool ok = false;
    J j = J::Parse(r.body, &ok);
    if (!ok) {
        if (why) *why = L"bad";
        return L"";
    }
    wstring v = j.Str(L"version");
    if (v.empty()) {
        if (why) *why = L"bad";
        return L"";
    }
    if (out) *out = j;
    if (why) why->clear();
    return v;
}

const wchar_t* kProxies[] = {L"https://gh.dpik.top/", L"https://edgeone.gh-proxy.com/", L"https://gh-proxy.org/", L""};
// 冥零自己的安装 Skill：跟工作台同一个仓库，发在 releases 里（tag skill-v<版本>，资产
// mingling-install.zip + skill-version.json）。这是 2026-11-07 换掉的：之前指向的是观众装
// 大肥鱼用的 zexuanw958-svg/dafeiyu-config-pack，那份 SKILL.md 通篇是大肥鱼，不是冥零的。
const wchar_t* kSkillRepo = L"linyuehua0010/mingling-workbench";
const wchar_t* kSkillDir = L"mingling-install";

// 技能装在哪：先看 <Base>\tools\skill-home.txt（装的时候记下来的），没记就按几个
// 常见家目录找。技能是单独装到 %USERPROFILE%\.agents\skills 下的机器上，工作区里那份
// tools\skill-version.json 可能根本没有——不能因为没这个文件就说「没装」。
wstring SkillHome() {
    wstring home = Trim(ReadTextFile(JoinPath(JoinPath(Base(), L"tools"), L"skill-home.txt"), 4096));
    if (!home.empty() && DirExists(home)) return home;
    wchar_t up[MAX_PATH * 2] = {0};
    if (!GetEnvironmentVariableW(L"USERPROFILE", up, MAX_PATH * 2) || !up[0]) return L"";
    static const wchar_t* kSub[] = {L"\\.agents\\skills\\mingling-install",
                                    L"\\.dsh\\skills\\mingling-install",
                                    L"\\.workbuddy\\skills\\mingling-install",
                                    // 老机器上只装过观众那份（大肥鱼），留个兜底：认不出冥零那份时还能显示版本
                                    L"\\.agents\\skills\\dafeiyu-install",
                                    L"\\.dsh\\skills\\dafeiyu-install"};
    for (const wchar_t* s : kSub) {
        wstring d = wstring(up) + s;
        if (DirExists(d)) return d;
    }
    return L"";
}

wstring SkillVersionLocal() {
    J j = ReadJson(JoinPath(JoinPath(Base(), L"tools"), L"skill-version.json"));
    wstring v = j.Str(L"version");
    if (!v.empty()) return v;
    // 工作区里那份没写下来（老安装器铺的技能、或者换过机器人根）：去技能自己的目录问
    wstring home = SkillHome();
    if (home.empty()) return L"";
    return ReadJson(JoinPath(home, L"version.json")).Str(L"version");
}

// 更新检查的缓存（工作台自己的 logs\cache.json：成功 6 小时内不再联网）
static wstring CachePath() {
    return JoinPath(JoinPath(Root(), L"logs"), L"cache.json");
}

static J UpdateCache() {
    J c = ReadJson(CachePath());
    J* u = c.GetM(L"updates");
    return u ? *u : J();
}

static wstring LatestAstrbot() {
    // PyPI 镜像的 simple 索引里翻 wheel 名字
    wstring best;
    for (const wchar_t* idx : {L"https://mirrors.aliyun.com/pypi/simple/astrbot/",
                               L"https://pypi.tuna.tsinghua.edu.cn/simple/astrbot/"}) {
        wstring t = FetchText(idx, 10000, 3000000);
        if (t.empty()) continue;
        size_t p = 0;
        while ((p = t.find(L"astrbot-", p)) != wstring::npos) {
            size_t e = p + 8, q = e;
            while (q < t.size() && ((t[q] >= L'0' && t[q] <= L'9') || t[q] == L'.')) q++;
            if (q > e && q < t.size() && t[q] == L'-') {
                wstring v = t.substr(e, q - e);
                if (best.empty() || VerCmp(v, best) > 0) best = v;
            }
            p = e;
        }
        if (!best.empty()) break;
    }
    return best;
}

// GitHub 最新 release 的版本号：先问 API，不通就让加速站跳到 releases/latest 再从地址里抠。
// url 出参是这一版 release 的网页地址（API 直接给 html_url；走加速站时按 tag 拼回来），
// 更新页的「去 GitHub 下载」就点它，不再自己拼 /releases/latest。
// 私有仓库的 releases 接口要 token 才看得见。约定：<base>\secrets\github-token.txt，一行一个 token。
// 没有这个文件就照旧匿名查（公开仓库够用），401/404 一律当「没查到」，不打扰用户。
static wstring GithubToken() {
    wstring p = SecretFile(L"github-token.txt");
    if (!FileExists(p)) return L"";
    return Trim(ReadTextFile(p, 4096));
}

// tagFilter 非空时改查「release 列表」再挑 tag 里带这个词的那一条：
// 预发布（prerelease）不会出现在 /releases/latest 里——快照通道就是这么发的版，
// 要是还问 latest，只会拿到正式版，界面就永远显示「没查到」。
static wstring LatestGithub(const wstring& repo, wstring* url = nullptr, wstring* rawTagOut = nullptr,
                            const wchar_t* tagFilter = nullptr) {
    if (url) url->clear();
    if (rawTagOut) rawTagOut->clear();
    const wstring tok = GithubToken();
    if (tagFilter && *tagFilter) {
        const wstring list = L"https://api.github.com/repos/" + repo + L"/releases?per_page=100";
        Http lr = tok.empty() ? HttpGet(list, 6000) : HttpGetJson(list, tok, 6000);
        if (lr.ok && lr.code < 400) {
            bool lok = false;
            J lj = J::Parse(lr.body, &lok);
            if (lok && lj.Arr()) {
                for (const J& it : lj.a) {
                    wstring tag = it.Str(L"tag_name");
                    if (tag.empty() || !IContains(tag, tagFilter)) continue;
                    if (rawTagOut) *rawTagOut = tag;
                    if (url) {
                        *url = it.Str(L"html_url");
                        if (url->empty()) *url = L"https://github.com/" + repo + L"/releases/tag/" + tag;
                    }
                    wstring v = tag;
                    if (v[0] == L'v') v = v.substr(1);
                    if (!v.empty()) return v;
                }
            }
        }
        // 列表里没有这个通道的 release：就当没查到，别退回去拿正式版的版本号。
        return L"";
    }
    Http r = tok.empty()
        ? HttpGet(L"https://api.github.com/repos/" + repo + L"/releases/latest", 6000)
        : HttpGetJson(L"https://api.github.com/repos/" + repo + L"/releases/latest", tok, 6000);
    if (r.ok && r.code < 400) {
        bool ok = false;
        J j = J::Parse(r.body, &ok);
        if (ok) {
            wstring tag = j.Str(L"tag_name");
            if (!tag.empty()) {
                if (rawTagOut) *rawTagOut = tag;
                if (url) {
                    *url = j.Str(L"html_url");
                    if (url->empty()) *url = L"https://github.com/" + repo + L"/releases/tag/" + tag;
                }
                if (tag[0] == L'v') tag = tag.substr(1);
                if (!tag.empty()) return tag;
            }
        }
    }
    for (const wchar_t* p : kProxies) {
        wstring t = FetchText(wstring(p) + L"https://github.com/" + repo + L"/releases/latest", 6000);
        size_t at = t.find(L"/releases/tag/");
        if (at == wstring::npos) continue;
        size_t tagStart = at + 14, tagEnd = tagStart;
        while (tagEnd < t.size()) {
            wchar_t c = t[tagEnd];
            if ((c >= L'0' && c <= L'9') || c == L'.' || c == L'-' || (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z')) {
                tagEnd++;
            } else {
                break;
            }
        }
        wstring rawTag = t.substr(tagStart, tagEnd - tagStart);
        if (rawTag.empty()) continue;
        wstring v = rawTag;
        if (v[0] == L'v') v = v.substr(1);
        while (!v.empty() && (v.back() == L'.' || v.back() == L'-')) v.pop_back();
        if (v.empty()) continue;
        if (url) *url = L"https://github.com/" + repo + L"/releases/tag/" + rawTag;
        if (rawTagOut) *rawTagOut = rawTag;
        return v;
    }
    return L"";
}

// 桌面 QQ 自动升级、SnowLuma 还没跟上：看它最新日志里「挂不上」是不是发生在最后一次挂上之后
static bool QqUpgradeSuspect() {
    if (Protocol() != L"snowluma") return false;
    wstring dir = JoinPath(BotPath(L"SnowLuma"), L"logs");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*.log").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    wstring best;
    long long bt = -1;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        long long t = ((long long)fd.ftLastWriteTime.dwHighDateTime << 32) | fd.ftLastWriteTime.dwLowDateTime;
        if (t > bt) {
            bt = t;
            best = dir + L"\\" + fd.cFileName;
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    if (best.empty()) return false;
    wstring txt = ReadTextFile(best, 300000);
    if (txt.empty()) return false;
    std::vector<wstring> lines;
    wstring cur;
    for (wchar_t c : txt) {
        if (c == L'\n') {
            lines.push_back(cur);
            cur.clear();
        } else if (c != L'\r') {
            cur.push_back(c);
        }
    }
    if (!cur.empty()) lines.push_back(cur);
    int good = -1, bad = -1;
    for (int i = 0; i < (int)lines.size(); i++) {
        const wstring& ln = lines[i];
        if (ln.find(L"pipe connected") != wstring::npos || ln.find(L"connected ws://") != wstring::npos) good = i;
        wstring low = ln;
        for (auto& c : low) if (c >= L'A' && c <= L'Z') c = (wchar_t)(c - L'A' + L'a');
        if (low.find(L"retry exhausted") != wstring::npos) bad = i;
        else if (low.find(L"unsupported") != wstring::npos || low.find(L"not supported") != wstring::npos) {
            if (low.find(L"qq") != wstring::npos || low.find(L"version") != wstring::npos) bad = i;
        }
    }
    return bad > good;
}

static const wchar_t* ItemName(const wstring& id) {
    if (id == L"astrbot") return L"AstrBot";
    if (id == L"snowluma") return L"SnowLuma";
    if (id == L"skill") return L"冥零的安装 Skill";
    return L"冥零工作台";
}

static const wchar_t* ItemWhat(const wstring& id) {
    if (id == L"astrbot") return L"她的大脑。";
    if (id == L"snowluma") return L"帮她登 QQ 的程序。";
    if (id == L"skill") return L"帮你装、帮你修的那套说明书：装在工作台外面的技能目录里，Agent 照着它动手。";
    return L"这个窗口。跟着安装 Skill 走：Skill 更新了，让 Agent 重跑一次收尾那步就会换上新的。";
}

// 旧的中间版缓存把 local 存成一整句（「AstrBot 4.29.4」），认一下
static wstring JustVer(const wstring& id, const wstring& s) {
    const wchar_t* prefix = nullptr;
    if (id == L"astrbot") prefix = L"AstrBot ";
    if (id == L"skill") prefix = L"技能 ";
    if (prefix && s.rfind(prefix, 0) == 0) return s.substr(wcslen(prefix));
    return s;
}

static UpdatesInfo ParseUpdates(const J& up) {
    UpdatesInfo u;
    u.at = (long long)up.Int(L"at");
    u.ok = up.Bool(L"ok");
    u.wb = up.Str(L"wb");
    const J* items = up.Get(L"items");
    for (const wchar_t* id : {L"astrbot", L"snowluma", L"skill"}) {
        const J* it = items ? items->Get(id) : nullptr;
        if (!it) continue;
        UpdateItem x;
        x.id = id;
        x.name = ItemName(x.id);
        x.what = ItemWhat(x.id);
        x.local = JustVer(x.id, it->Str(L"local"));
        x.latest = JustVer(x.id, it->Str(L"latest"));
        const J* notes = it->Get(L"notes");
        if (notes && notes->Arr())
            for (const J& n : notes->a)
                if (x.notes.size() < 6) x.notes.push_back(n.t == J::STR ? n.s : n.NumText());
        if (x.latest.empty()) {
            // skill 多一种说法：远端 404＝这一版还没发到 GitHub，不是网络问题，别催人去点更新
            wstring rem = it->Str(L"remote");
            x.state = (x.id == L"skill" && rem == L"notpublished") ? L"local" : L"unknown";
        } else if (VerCmp(x.latest, x.local) > 0) x.state = L"new";
        else x.state = L"latest";
        u.items.push_back(x);
    }
    // 缓存里缺谁就补一行，别让页面只剩「工作台」——用户会以为更新页坏了
    std::vector<std::pair<std::wstring, std::wstring>> vs = Versions();
    auto localOf = [&](const wchar_t* want) -> std::wstring {
        for (auto& kv : vs)
            if (kv.first == want) return kv.second;
        return std::wstring();
    };
    auto ensure = [&](const wchar_t* id, const wchar_t* verKey) {
        for (auto& x : u.items)
            if (x.id == id) return;
        UpdateItem x;
        x.id = id;
        x.name = ItemName(id);
        x.what = ItemWhat(id);
        x.local = localOf(verKey);
        if (x.local.empty()) {
            x.local = L"未找到安装";
            x.state = L"missing";
        } else {
            x.state = L"unknown";
        }
        u.items.push_back(x);
    };
    ensure(L"astrbot", L"AstrBot");
    ensure(L"snowluma", L"SnowLuma");
    ensure(L"skill", L"技能");
    UpdateItem w;
    w.id = L"wb";
    w.name = ItemName(w.id);
    w.what = ItemWhat(w.id);
    // 显示用完整串（V3.0.0-snapshot），比较用数字串（3.0.0）——快照版和正式版数字一样，
    // 只差后缀，混着比会把「两个渠道」当成同一版。
    w.local = u.wb.empty() ? APP_VERSION : u.wb;
    u.wb = w.local;
    u.wbRepo = up.Str(L"wbRepo");
    u.wbUrl = up.Str(L"wbUrl");
    w.latest = JustVer(w.id, up.Str(L"wbLatest"));
    if (w.latest.empty()) {
        w.state = L"local";  // 还没发布/查不到：就显示本机版本
    } else if (VerCmp(w.latest, APP_VERSION_PLAIN_W) > 0) {
        w.state = L"new";
    } else {
        w.state = L"latest";
    }
    u.items.push_back(w);
    return u;
}

// 真去联网查一轮，把结果写回 cache.json（结构跟旧 server.py 的 check_updates 一样）
static UpdatesInfo FetchUpdates() {
    bool okAll = true;
    J items = JObj();

    wstring al;
    for (auto& kv : Versions())
        if (kv.first == L"AstrBot") al = kv.second;
    if (!al.empty()) {
        wstring lv = LatestAstrbot();
        okAll = okAll && !lv.empty();
        J it = JObj();
        it.Set(L"local", JStr(al));
        it.Set(L"latest", JStr(lv));
        items.Set(L"astrbot", it);
    }

    if (DirExists(BotPath(L"SnowLuma"))) {
        wstring sl = ReadJson(JoinPath(BotPath(L"SnowLuma"), L"release.json")).Str(L"version");
        if (!sl.empty()) {
            wstring lv = LatestGithub(L"SnowLuma/SnowLuma");
            okAll = okAll && !lv.empty();
            J it = JObj();
            it.Set(L"local", JStr(sl));
            it.Set(L"latest", JStr(lv));
            items.Set(L"snowluma", it);
        }
    }

    wstring sl = SkillVersionLocal();
    if (!sl.empty()) {
        wstring lv;
        bool saw404 = false, sawNet = false, sawBad = false;
        std::vector<wstring> notes, reimport;
        for (const wchar_t* p : kProxies) {
            wstring w;
            J j;
            wstring got = FetchManifest(wstring(p) + L"https://github.com/" + kSkillRepo +
                                            L"/releases/latest/download/skill-version.json",
                                        &w, &j);
            if (got.empty()) {
                if (w == L"notpublished") saw404 = true;
                else if (w == L"bad") sawBad = true;
                else sawNet = true;
                continue;
            }
            lv = got;
            const J* nn = j.Get(L"notes");
            if (nn && nn->Arr())
                for (const J& n : nn->a)
                    if (notes.size() < 6) notes.push_back(n.t == J::STR ? n.s : n.NumText());
            const J* rr = j.Get(L"reimport");
            if (rr && rr->Arr())
                for (const J& n : rr->a)
                    if (reimport.size() < 6) reimport.push_back(n.t == J::STR ? n.s : n.NumText());
            break;
        }
        // 「还没发布」不算网络故障：只有真连不上、拿到坏数据时，才算这一轮没查全
        // 「还没发布」不算网络故障：只要有一个入口明确给了 404、又没有入口给出坏数据，就算没发布；
        // 只有从头到尾都没拿到确定答复（代理挂了、断网）才算这一轮没查全
        if (lv.empty() && !(saw404 && !sawBad)) okAll = false;
        // 本机比 GitHub 上还新（没发布的版本）：别提示「更新」，免得换回旧的
        if (!lv.empty() && VerCmp(lv, sl) < 0) lv = sl;
        J it = JObj();
        it.Set(L"local", JStr(sl));
        it.Set(L"latest", JStr(lv));
        if (!notes.empty()) {
            J a = JArr();
            for (auto& n : notes) a.Push(JStr(n));
            it.Set(L"notes", a);
        }
        if (!reimport.empty()) {
            J a = JArr();
            for (auto& n : reimport) a.Push(JStr(n));
            it.Set(L"reimport", a);
        }
        // 远端为什么没有版本：界面据此说「本机（这一版还没发布）」还是「查不到（网络不通）」
        if (lv.empty()) it.Set(L"remote", JStr((saw404 && !sawBad) ? L"notpublished" : L"net"));
        items.Set(L"skill", it);
    }

    // 工作台自己：只走快照通道。repo_snapshot（owner/name）配了才联网；
    // 不读正式版用的 repo，也绝不把正式 V3.0.0 的包推给快照用户。
    const wstring wbLocal = APP_VERSION_PLAIN_W;
    const wstring wbShow = APP_VERSION;
    wstring repo = Trim(SettingGet(L"repo_snapshot"));
    wstring wbUrl, wbTag;
    wstring wbLatest;
    if (!repo.empty()) {
        // 第 4 个参数是通道标记：快照 release 是 prerelease，只能从列表里挑
        wbLatest = LatestGithub(repo, &wbUrl, &wbTag, L"snapshot");
        // 列表里挑出来的 tag 一定带 snapshot；这里再兜一次底，防止以后改了筛选口径
        if (!wbLatest.empty() && !IContains(wbTag, L"snapshot")) {
            wbLatest.clear();
            wbUrl.clear();
        }
        // 本机比 GitHub 上还新（没发布的版本）：别提示「更新」，免得换回旧的
        if (!wbLatest.empty() && VerCmp(wbLatest, wbLocal) < 0) wbLatest = wbLocal;
        okAll = okAll && !wbLatest.empty();
    }

    J up = JObj();
    up.Set(L"at", JNum((double)time(nullptr)));
    up.Set(L"dir", JStr(Base()));
    up.Set(L"wb", JStr(wbShow));
    up.Set(L"wbLatest", JStr(wbLatest));
    up.Set(L"repo", JStr(repo));
    up.Set(L"wbRepo", JStr(repo));
    up.Set(L"wbUrl", JStr(wbUrl));
    up.Set(L"items", items);
    up.Set(L"ok", JBool(okAll));
    J all = ReadJson(CachePath());
    all.Set(L"updates", up);
    WriteJsonAtomic(CachePath(), all);
    return ParseUpdates(up);
}

ActionResult SkillUpdate() {
    wstring sl = SkillVersionLocal();
    if (sl.empty())
        return Bad(L"这台机器上还没装这份 Skill（mingling-install）：让 Agent 装一次，"
                   L"或用「求助页」那段话让它去装，装完这行就有版本号了。");
    for (const wchar_t* blk : {L"core", L"plugins", L"video", L"memory", L"voice", L"memes"})
        if (ImportLogState(blk) == L"running") return Bad(L"正在补装东西，等它装完再更新。");
    wstring latest;
    wstring why;
    bool saw404 = false, sawNet = false, sawBad = false;
    for (const wchar_t* p : kProxies) {
        wstring w;
        J j;
        wstring got = FetchManifest(wstring(p) + L"https://github.com/" + kSkillRepo +
                                        L"/releases/latest/download/skill-version.json",
                                    &w, &j);
        if (got.empty()) {
            if (w == L"notpublished") saw404 = true;
            else if (w == L"bad") sawBad = true;
            else sawNet = true;
            continue;
        }
        latest = got;
        break;
    }
    if (latest.empty()) {
        if (saw404 && !sawBad)
            return Bad(L"这一版还没发到 GitHub（" + wstring(kSkillRepo) + L" 的 releases 里要有 mingling-install.zip；"
                       L"仓库还得是公开的，私有仓库别人查不到），本机是 " + sl + L"，先这么用着。");
        return Bad(L"查不到新版（GitHub 和加速站都没连上），过会儿再点。");
    }
    if (VerCmp(latest, sl) <= 0) return Ok(L"已经是最新（" + sl + L"）。");
    // 下载 + 校验 + 备份 + 换 Skill + 跑收尾：整段交给 powershell
    wstring ps =
        L"$ErrorActionPreference='Stop';"
        L"$Dir=$env:DFY_DIR;$ver=$env:DFY_VER;$repo=$env:DFY_REPO;"
        L"$dl=Join-Path $Dir 'downloads';New-Item -ItemType Directory -Force -Path $dl|Out-Null;"
        L"$zp=Join-Path $dl ('mingling-install-' + $ver + '.zip');"
        L"$base='https://github.com/' + $repo + '/releases/latest/download/mingling-install.zip';"
        L"$got=$false;"
        L"foreach($p in @('https://gh.dpik.top/','https://edgeone.gh-proxy.com/','https://gh-proxy.org/','')){"
        L"  try{Invoke-WebRequest -Uri ($p+$base) -OutFile $zp -UseBasicParsing -TimeoutSec 120;if((Get-Item $zp).Length -gt 10000){$got=$true;break}}catch{}"
        L"};"
        L"if(-not $got){throw '没下下来'};"
        L"$ext=Join-Path $dl ('skill-' + [guid]::NewGuid().ToString('N'));Expand-Archive -Path $zp -DestinationPath $ext -Force;"
        L"$src=Join-Path $ext 'mingling-install';"
        L"foreach($need in @('SKILL.md','version.json','scripts\\finish.ps1')){if(-not (Test-Path (Join-Path $src $need))){throw ('包里缺 '+$need)}};"
        L"$bk=Join-Path $Dir ('旧版\\' + (Get-Date -Format 'MMdd-HHmm') + '-Skill' + $env:DFY_CUR);New-Item -ItemType Directory -Force -Path $bk|Out-Null;"
        L"$dirs=@();if($env:DFY_HOME){$dirs+=$env:DFY_HOME};"
        L"foreach($d in @((Join-Path $env:USERPROFILE '.agents\\skills\\mingling-install'),(Join-Path $env:USERPROFILE '.dsh\\skills\\mingling-install'),(Join-Path $env:USERPROFILE '.workbuddy\\skills\\mingling-install'))){if((Test-Path $d) -and ($dirs -notcontains $d)){$dirs+=$d}};"
        // 一份都没找到就装到 .agents\skills 下：收尾脚本要认「装在哪」，不能因为没装过就什么都不做
        L"if($dirs.Count -eq 0){$dirs=@((Join-Path $env:USERPROFILE '.agents\\skills\\mingling-install'))};"
        L"$n=0;"
        L"foreach($d in $dirs){if(Test-Path $d){Copy-Item -Path $d -Destination (Join-Path $bk ('skill-' + $n)) -Recurse -Force -ErrorAction SilentlyContinue;"
        L"  Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue};"
        L"  New-Item -ItemType Directory -Force -Path (Split-Path $d -Parent)|Out-Null;Copy-Item -Path $src -Destination $d -Recurse -Force;$n++};"
        L"$fin=Join-Path $src 'scripts\\finish.ps1';"
        L"if(Test-Path $fin){& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fin -Dir $Dir};"
        L"Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item $zp -Force -ErrorAction SilentlyContinue;"
        L"'DONE'";
    EnvList env;
    env.push_back({L"DFY_DIR", Base()});
    env.push_back({L"DFY_VER", latest});
    env.push_back({L"DFY_REPO", kSkillRepo});
    env.push_back({L"DFY_CUR", sl});
    wstring home = SkillHome();
    env.push_back({L"DFY_HOME", home});
    CmdResult r = PsEncoded(ps, env, 600000);
    if (r.out.find(L"DONE") == wstring::npos)
        return Bad(L"更新没成：" + TailText(Trim(r.out), 200));
    return Ok(L"更新到 " + latest + L" 了，收尾（记下装在哪儿、哪一版）也做完了。");
}

// 路径参数的收尾引号问题：末尾 \ 会把 " 吃掉（"F:\x\" 传进去只剩 F:\x"），先削尾部斜杠，
// 盘符根补回来，最后一个反斜杠再补一个（命令行里 \\" 才是字面反斜杠 + 收尾引号）
static std::wstring ArgPath(const std::wstring& s) {
    std::wstring t = s;
    while (t.size() > 2 && (t.back() == L'\\' || t.back() == L'/')) t.pop_back();
    if (t.size() == 2 && t[1] == L':') t += L'\\';
    if (!t.empty() && t.back() == L'\\') t += L'\\';
    return t;
}

ActionResult ImportMingling() {
    std::wstring ps = JoinPath(JoinPath(Root(), L"tools"), L"import-mingling.ps1");
    if (!FileExists(ps)) return Bad(L"没找到 tools\\import-mingling.ps1（这一版没带）");
    wchar_t sysroot[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH * 2);
    std::wstring pwsh =
        JoinPath(JoinPath(JoinPath(sysroot[0] ? sysroot : L"C:\\Windows", L"System32"), L"WindowsPowerShell"),
                 L"v1.0\\powershell.exe");
    CmdResult r = RunCapture(pwsh,
                             L"-NoProfile -ExecutionPolicy Bypass -File \"" + ps + L"\" -Base \"" + ArgPath(Base()) + L"\"",
                             Root(), EnvList(), 300000);
    std::wstring out = Trim(r.out);
    size_t p2 = out.rfind(L"RESULT ");
    if (p2 == std::wstring::npos) {
        std::wstring tail = out.size() > 300 ? out.substr(out.size() - 300) : out;
        return Bad(L"导入没成：" + (tail.empty() ? L"脚本没输出" : tail));
    }
    std::wstring last = out.substr(p2);
    if (last.find(L"ok=1") == std::wstring::npos) return Bad(L"导入没成：" + last);
    return Ok(L"冥零的人设已导入，默认人设也切过去了。");
}

// 自设定：跑 tools\self-setup.ps1，拿 pack\mingling-pack 把 DeepSeek、QQ 平台、聊天设置、
// 人设都配成冥零。日志逐行落到 <Base>\logs\self-setup.log，别的地方要看进度就 tail 它。
static std::wstring g_selfLogPath;
static void OnSelfLine(const std::wstring& line, void*) {
    if (g_selfLogPath.empty()) return;
    WriteTextFile(g_selfLogPath, line + L"\r\n", true);
}

// 本地时间 "MM-dd HH:mm:ss"，日志开头用
static std::wstring LocalStamp() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t b[32];
    swprintf(b, 32, L"%02d-%02d %02d:%02d:%02d", st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return b;
}

// 从 RESULT 行里抠一个字段（why= 一路读到行尾，别的读到空格）
static std::wstring ResultField(const std::wstring& line, const wchar_t* key) {
    std::wstring k(key);
    size_t p = line.find(k);
    if (p == std::wstring::npos) return L"";
    size_t s = p + k.size();
    if (k == L"why=") {
        // why= 是「读到行尾」，但行尾还挂着 next=…，得切掉
        std::wstring v = Trim(line.substr(s));
        size_t n = v.find(L" next=");
        if (n != std::wstring::npos) v = Trim(v.substr(0, n));
        return v;
    }
    size_t e = line.find(L' ', s);
    return Trim(line.substr(s, e == std::wstring::npos ? std::wstring::npos : e - s));
}

ActionResult SelfSetup(const std::wstring& block) {
    wchar_t sysroot[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH * 2);
    std::wstring pwsh =
        JoinPath(JoinPath(JoinPath(sysroot[0] ? sysroot : L"C:\\Windows", L"System32"), L"WindowsPowerShell"),
                 L"v1.0\\powershell.exe");
    // 新版本工作台自带引擎；老的安装包只有 import-mingling.ps1，那种就直接说清楚
    std::wstring script = JoinPath(JoinPath(Root(), L"tools"), L"self-setup.ps1");
    if (!FileExists(script)) {
        std::wstring legacy = JoinPath(JoinPath(Root(), L"tools"), L"import-mingling.ps1");
        if (!FileExists(legacy)) return Bad(L"没找到 tools\\self-setup.ps1（这一版没带）");
        return Bad(L"这一版工作台还没有自设定引擎（缺 tools\\self-setup.ps1），"
                   L"先用「导入冥零人设」把她说上话，再把工作台更新到带自设定的版本");
    }
    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -File \"" + script + L"\" -Base \"" + ArgPath(Base()) + L"\"";
    if (block == L"dry") args += L" -DryRun";
    else if (!block.empty() && block != L"all") args += L" -Only \"" + block + L"\"";

    g_selfLogPath = JoinPath(JoinPath(Base(), L"logs"), L"self-setup.log");
    WriteTextFile(g_selfLogPath, L"[自设定] " + block + L"  " + LocalStamp() + L"\r\n", false);

    CmdResult r = RunCaptureStream(pwsh, args, Root(), EnvList(), 15 * 60 * 1000, OnSelfLine, nullptr);
    std::wstring out = Trim(r.out);
    size_t p2 = out.rfind(L"RESULT ");
    if (r.timeout) return Bad(L"自设定跑了 15 分钟还没结束，先停了（后台卡住就先重启大脑再试）");
    if (p2 == std::wstring::npos) {
        std::wstring tail = TailText(out, 240);
        return Bad(L"自设定没给出结果（退出码 " + std::to_wstring(r.code) + L"）：" +
                   (tail.empty() ? L"脚本没输出" : tail));
    }
    std::wstring last = out.substr(p2, out.find(L'\n', p2) == std::wstring::npos ? std::wstring::npos
                                                                            : out.find(L'\n', p2) - p2);
    std::wstring why = ResultField(last, L"why=");
    if (last.find(L"ok=1") == std::wstring::npos)
        return Bad(L"自设定没全成：" + (why.empty() ? TailText(last, 200) : why) +
                   L"（明细在 logs\\self-setup.log）");
    return Ok(L"自设定完成：" + (why.empty() ? std::wstring(L"五个块都对了") : why) +
              L"，现在可以私聊她了。");
}

}  // namespace

// 更新页用：先看缓存（6 小时 / 失败 30 分钟），force 就重新联网查一轮
UpdatesInfo CheckUpdates(bool force) {
    J up = UpdateCache();
    long long at = (long long)up.Int(L"at");
    long long ttl = up.Bool(L"ok") ? 6 * 3600 : 1800;
    if (!force && at > 0 && up.Obj() && up.Str(L"dir") == Base() && (long long)time(nullptr) - at < ttl) {
        UpdatesInfo u = ParseUpdates(up);
        u.qqUpgrade = QqUpgradeSuspect();
        if (!u.items.empty()) return u;
    }
    UpdatesInfo u = FetchUpdates();
    u.qqUpgrade = QqUpgradeSuspect();
    return u;
}

std::wstring UpdatesSummary(const UpdatesInfo& u) {
    wstring msg;
    for (const UpdateItem& it : u.items) {
        if (it.id == L"wb") continue;
        wstring line = it.name + L" " + (it.local.empty() ? L"?" : it.local);
        if (it.state == L"new") line += L" → " + it.latest + L" 有新版本";
        else if (it.state == L"latest") line += L"（最新）";
        else if (it.state == L"unknown") line += L"（没查到新版）";
        msg += (msg.empty() ? L"" : L"\n") + line;
    }
    return msg.empty() ? wstring(L"没查到版本信息。") : msg;
}

ActionResult RunAction(const wstring& op, const wstring& arg) {
    if (op == L"restart_brain" || op == L"restart_astrbot") return StartBrain(true);
    if (op == L"start_brain" || op == L"start_astrbot") return StartBrain(false);
    if (op == L"relogin") return Relogin();
    if (op == L"restart_qq") return RestartQQ();
    if (op == L"start_breeze") return StartBreeze();
    if (op == L"start_ollama") return StartOllama();
    if (op == L"backup") return Backup();
    if (op == L"diag") return Diag();
    if (op == L"autostart_fix") return AutostartFix();
    if (op == L"updates") return Ok(UpdatesSummary(CheckUpdates(true)));
    if (op == L"skill_update") return SkillUpdate();
    if (op == L"watch_on" || op == L"watch_off" || op == L"watch_test") return WatchMode(op.substr(6));
    if (op == L"qq_watch") return WatchMode(arg);
    if (op == L"game_on") return GameOn();
    if (op == L"game_off") return GameOff(false);
    if (op == L"game_off_boot") return GameOff(true);
    if (op == L"group_reply") return FreqGroup(arg.empty() ? L"off" : arg);
    if (op == L"meme") return FreqMeme(arg.empty() ? L"mid" : arg);
    if (op == L"voice") return FreqVoice(arg.empty() ? L"mid" : arg);
    if (op == L"import") return Import(arg);
    if (op == L"import_skill") return ImportMingling();
    if (op == L"selfsetup") return SelfSetup(arg);
    if (op == L"feature") return SetFeature(arg);
    return Bad(L"没有这个动作：" + op);
}

int CliMain(const std::vector<std::wstring>& args) {
    bool status = false, gameOff = false;
    for (auto& a : args) {
        if (a == L"--her-status" || a == L"--status") status = true;
        if (a == L"--game-off") gameOff = true;
    }
    // 自检/回归用：--her-op <动作> [参数]
    for (size_t i = 0; i < args.size(); i++) {
        if (args[i] != L"--her-op" || i + 1 >= args.size()) continue;
        wstring op = args[i + 1];
        wstring arg = (i + 2 < args.size()) ? args[i + 2] : L"";
        ActionResult r = RunAction(op, arg);
        std::wstring out = std::wstring(r.ok ? L"OK " : L"FAIL ") + r.msg + L"\n";
        fwprintf(stdout, L"%ls", out.c_str());
        fflush(stdout);
        std::wstring dir = JoinPath(Base(), L"logs");
        CreateDirectoryW(dir.c_str(), nullptr);
        WriteTextFile(JoinPath(dir, L"her-op.txt"), out, false);
        return r.ok ? 0 : 1;
    }
    if (gameOff) {
        ActionResult r = GameOff(true);
        std::wstring out = L"GAME_OFF " + std::wstring(r.ok ? L"ok " : L"fail ") + r.msg + L"\n";
        WriteTextFile(JoinPath(JoinPath(Base(), L"logs"), L"game-off.log"), out, false);
        return r.ok ? 0 : 1;
    }
    std::wstring buf;
    if (status) {
        Status st;
        std::wstring err;
        if (!CollectStatus(st, &err)) {
            buf = L"FAIL " + err + L"\n";
        } else {
            wchar_t line[4096];
            swprintf(line, 4096, L"TODAY %lld %lld %lld %lld\n", st.stat.msgs, st.stat.replies, st.stat.tokens,
                     st.stat.mems);
            buf += line;
            swprintf(line, 4096, L"FREQ %ls %ls %ls\n", st.group.c_str(), st.meme.c_str(), st.voice.c_str());
            buf += line;
            swprintf(line, 4096, L"GAME %d %d %lld\n", st.gameOn ? 1 : 0, st.gameCan ? 1 : 0, st.gameSince);
            buf += line;
            swprintf(line, 4096, L"WATCH %d %d %d %ls %ls\n", st.watch.can ? 1 : 0, st.watch.on ? 1 : 0,
                     st.watch.running ? 1 : 0, st.watch.state.c_str(), st.watch.note.c_str());
            buf += line;
            for (auto& c : st.cards) {
                swprintf(line, 4096, L"ITEM %ls\t%ls\t%ls\t%ls\t%ls\t%ls\t%ls\t%ls\t%ls\n", c.id.c_str(),
                         c.state.c_str(), c.name.c_str(), c.text.c_str(), c.fixAct.c_str(), c.fixLbl.c_str(),
                         c.linkLbl.c_str(), c.linkHref.c_str(), c.pill.c_str());
                buf += line;
            }
            for (auto& v : st.vers) {
                swprintf(line, 4096, L"VER %ls\t%ls\n", v.first.c_str(), v.second.c_str());
                buf += line;
            }
        }
    } else {
        buf = L"用法：MinglingWorkbench.exe --her-status | --game-off\n";
    }
    // -mwindows 下没有 stdout，控制台窗口里看得到一份，另外永远落一份文件方便对照
    fwprintf(stdout, L"%ls", buf.c_str());
    fflush(stdout);
    std::wstring dir = JoinPath(Base(), L"logs");
    CreateDirectoryW(dir.c_str(), nullptr);
    WriteTextFile(JoinPath(dir, L"her-status.txt"), buf, false);
    return buf.find(L"FAIL ") == 0 ? 1 : 0;
}

}  // namespace her
