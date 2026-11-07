#include "core.h"

// ---------------------------------------------------------------- 找 node / 内置 sidecar
static wstring FindNodeExe() {
    // 1. 安装包自带（干净机不需要装 node）
    wstring bundled = SidecarNodeExe();
    if (!bundled.empty()) return bundled;
    // 2. 环境变量
    wchar_t buf[MAX_PATH * 2] = {0};
    if (GetEnvironmentVariableW(L"BILI_NODE", buf, MAX_PATH * 2) && FileExists(buf)) return buf;
    // 3. 常规安装位置
    const wchar_t* guesses[] = {L"%ProgramFiles%\\nodejs\\node.exe", L"%ProgramFiles(x86)%\\nodejs\\node.exe",
                                L"%LOCALAPPDATA%\\Programs\\nodejs\\node.exe"};
    for (auto g : guesses) {
        wchar_t path[MAX_PATH * 2] = {0};
        ExpandEnvironmentStringsW(g, path, MAX_PATH * 2);
        if (FileExists(path)) return path;
    }
    // 4. where node
    wchar_t comspec[MAX_PATH * 2] = {0};
    GetEnvironmentVariableW(L"COMSPEC", comspec, MAX_PATH * 2);
    if (comspec[0]) {
        CmdResult r = RunCapture(comspec, L"/c where node", L"", EnvList(), 8000);
        for (auto& line : SplitLines(r.out)) {
            wstring t = Trim(line);
            if (!t.empty() && FileExists(t) && t.find(L"\\") != wstring::npos) return t;
        }
    }
    return wstring();
}

WhaleEnv FindWhale() {
    WhaleEnv e;
    e.stateDir = JoinPath(StateDir(), L"bili-state");
    e.pkgDir = SidecarWhaleDir();
    e.mjs = JoinPath(JoinPath(e.pkgDir, L"tools"), L"bili.mjs");
    e.node = FindNodeExe();
    e.config = JoinPath(StateDir(), L"bili-whale.config.json");
    e.creds = JoinPath(JoinPath(UserProfile(), L".bili-ai"), L"credentials.json");
    e.diary = JoinPath(e.stateDir, L"whale-diary.md");
    EnsureWorkspaceLayout(WorkspaceDir());
    if (!FileExists(e.config)) {
        wstring tpl = JoinPath(SidecarDir(), L"bili-whale.config.template.json");
        if (!FileExists(tpl)) tpl = JoinPath(e.pkgDir, L"bili-whale.config.template.json");
        if (FileExists(tpl)) CopyFileW(tpl.c_str(), e.config.c_str(), FALSE);
    }
    if (!FileExists(e.mjs)) e.err = L"没找到内置 B站组件（sidecar\bili-whale\tools\bili.mjs）——请重新安装工作台";
    else if (e.node.empty()) e.err = L"没找到 node 运行时（安装包应自带 sidecar\node\node.exe）";
    e.ok = e.err.empty();
    return e;
}

// 所有命令都在工作区里跑；DSH_HOME 指向用户配置目录，绝不读 ~/.dsh
static void AddBiliEnv(EnvList& env, const WhaleEnv& e) {
    wstring root = WorkspaceDir();
    env.emplace_back(L"DSH_HOME", e.stateDir);
    env.emplace_back(L"DSH_NODE", e.node);
    env.emplace_back(L"BILI_ROOT", root);
    env.emplace_back(L"BILI_OUT_ROOT", JoinPath(root, L"out"));
    env.emplace_back(L"BILI_TMP_ROOT", JoinPath(root, L"tmp"));
    env.emplace_back(L"BILI_LOGS_ROOT", JoinPath(root, L"logs"));
    if (!e.config.empty()) env.emplace_back(L"BILI_WHALE_CONFIG", e.config);
    wstring ff = SidecarFfmpegExe();
    if (!ff.empty()) env.emplace_back(L"FFMPEG", ff);
    wstring nodeDir = ParentDir(e.node);
    if (!nodeDir.empty()) {
        wchar_t old[MAX_PATH * 8] = {0};
        GetEnvironmentVariableW(L"PATH", old, MAX_PATH * 8);
        env.emplace_back(L"PATH", nodeDir + L";" + wstring(old));
    }
    env.emplace_back(L"MINGLING_WORKBENCH", L"1");  // sidecar 据此跳过夜间调度等宿主专属检查
    env.emplace_back(L"PYTHONUTF8", L"1");
}

CmdResult RunWhale(const wstring& args, int timeoutMs) {
    WhaleEnv e = FindWhale();
    if (!e.ok) {
        CmdResult r;
        r.out = e.err;
        return r;
    }
    EnvList env;
    AddBiliEnv(env, e);
    return RunCapture(e.node, L"\"" + e.mjs + L"\" " + args, WorkspaceDir(), env, timeoutMs);
}

// ---------------------------------------------------------------- 解析 feed
static bool AllDigits(const wstring& s) {
    if (s.empty()) return false;
    for (wchar_t c : s)
        if (!iswdigit(c)) return false;
    return true;
}

vector<FeedItem> ParseFeed(const wstring& out) {
    vector<FeedItem> items;
    for (auto& rawLine : SplitLines(out)) {
        wstring s = Trim(rawLine);
        if (s.size() < 16 || !iswdigit(s[0])) continue;
        size_t dot = s.find(L". ");
        if (dot == wstring::npos || dot > 3) continue;
        wstring rest = s.substr(dot + 2);
        size_t sp = rest.find(L' ');
        if (sp == wstring::npos) continue;
        FeedItem it;
        it.bv = rest.substr(0, sp);
        if (!StartsWith(it.bv, L"BV") || it.bv.size() < 12) continue;
        size_t dpos = rest.find(L"s ", sp);
        if (dpos == wstring::npos) continue;
        it.dur = Trim(rest.substr(sp, dpos - sp));
        size_t dm = rest.find(L"弹幕", dpos);
        if (dm == wstring::npos) continue;
        size_t numStart = dm + 2;
        while (numStart < rest.size() && (rest[numStart] == L' ' || rest[numStart] == L'\t')) numStart++;
        size_t numEnd = numStart;
        while (numEnd < rest.size() && iswdigit(rest[numEnd])) numEnd++;
        it.dm = rest.substr(numStart, numEnd - numStart);
        size_t pl = rest.find(L"播放", numEnd);
        if (pl == wstring::npos) continue;
        size_t p2 = pl + 2;
        while (p2 < rest.size() && rest[p2] == L' ') p2++;
        size_t p3 = p2;
        while (p3 < rest.size() && iswdigit(rest[p3])) p3++;
        it.play = rest.substr(p2, p3 - p2);
        wstring tail = Trim(rest.substr(p3));
        // 尾部可能带 "  @UP名" 和 " [词+词]"
        size_t bracket = tail.rfind(L" [");
        if (bracket != wstring::npos && tail.back() == L']') tail = Trim(tail.substr(0, bracket));
        size_t at = tail.rfind(L"  @");
        if (at != wstring::npos) {
            it.title = UnescapeHtml(Trim(tail.substr(0, at)));
            it.up = UnescapeHtml(Trim(tail.substr(at + 3)));
        } else {
            it.title = UnescapeHtml(tail);
        }
        if (it.title.empty()) continue;
        items.push_back(it);
    }
    return items;
}

// ---------------------------------------------------------------- 解析 debrief
wstring ExtractBv(const wstring& text) {
    for (size_t i = 0; i + 12 <= text.size(); i++) {
        if (text[i] == L'B' && text[i + 1] == L'V') {
            bool ok = true;
            for (size_t k = 2; k < 12; k++) {
                wchar_t c = text[i + k];
                if (!(iswalnum(c))) { ok = false; break; }
            }
            if (ok) return text.substr(i, 12);
        }
    }
    return wstring();
}

static bool LooksLikeImagePath(const wstring& line) {
    wstring l = line;
    for (auto& c : l) c = (wchar_t)towlower(c);
    return (l.find(L".jpg") != wstring::npos || l.find(L".png") != wstring::npos) &&
           (l.find(L":\\") != wstring::npos);
}

Debrief ParseDebrief(const wstring& out) {
    Debrief d;
    d.raw = out;
    vector<wstring> lines = SplitLines(out);
    int section = -1;
    for (auto& line : lines) {
        wstring t = Trim(line);
        if (t.find(L"══════════") != wstring::npos) {
            if (t.find(L"①") != wstring::npos) section = 0;
            else if (t.find(L"②") != wstring::npos) section = 1;
            else if (t.find(L"③") != wstring::npos) section = 2;
            else if (t.find(L"④") != wstring::npos) section = 3;
            else if (t.find(L"⑤") != wstring::npos) section = 4;
            else if (t.find(L"⑥") != wstring::npos) section = 5;
            else section = -1;
            continue;
        }
        if (section >= 0) {
            d.section[section] += line;
            d.section[section] += L"\n";
        }
        if (StartsWith(t, L"标题: ")) d.title = UnescapeHtml(t.substr(4));
        else if (StartsWith(t, L"UP: ")) {
            wstring u = t.substr(4);
            size_t cut = u.find(L"   时长");
            if (cut != wstring::npos) u = u.substr(0, cut);
            d.up = Trim(u);
        } else if (StartsWith(t, L"SHEET:")) {
            d.sheet = Trim(t.substr(6));
        } else if (StartsWith(t, L"SUBS:")) {
            d.subs = Trim(t.substr(5));
        } else if (section == 1 && LooksLikeImagePath(t)) {
            size_t cut = t.find(L"（");
            d.cover = Trim(cut == wstring::npos ? t : t.substr(0, cut));
        }
    }
    d.ok = !out.empty() && (out.find(L"══") != wstring::npos);
    if (!d.ok) {
        // 失败时把关键报错挑出来给界面看
        for (auto& line : lines) {
            if (line.find(L"✗") != wstring::npos || line.find(L"失败") != wstring::npos ||
                line.find(L"错误") != wstring::npos || line.find(L"Error") != wstring::npos) {
                d.title = UnescapeHtml(Trim(line));
                break;
            }
        }
    }
    return d;
}

// ---------------------------------------------------------------- 任务记录
wstring JobsFile() { return JoinPath(JoinPath(WorkspaceDir(), L"logs"), L"jobs.jsonl"); }

static wstring JsonEscape(const wstring& s) {
    wstring o;
    for (wchar_t c : s) {
        switch (c) {
            case L'"': o += L"\\\""; break;
            case L'\\': o += L"\\\\"; break;
            case L'\n': o += L"\\n"; break;
            case L'\r': break;
            case L'\t': o += L' '; break;
            default:
                if (c < 0x20) o += L' ';
                else o += c;
        }
    }
    return o;
}

bool QueueJobMemory(const JobRec& j, const wstring& body) {
    if (j.status != L"ok" || body.empty()) return false;
    wstring dir = JoinPath(JoinPath(WorkspaceDir(), L"logs"), L"memory-inbox");
    CreateDirectoryW(JoinPath(WorkspaceDir(), L"logs").c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);
    static volatile LONG sequence = 0;
    wstring path = JoinPath(dir, Num(j.t) + L"-" + Num(GetCurrentProcessId()) + L"-" + Num(GetTickCount64()) + L"-" + Num(InterlockedIncrement(&sequence)) + L".json");
    wstring content = L"【工作台阅读记录】" + j.title + L"\n来源：" + j.bv + L"\n" + body.substr(0, 6000);
    wstring record = L"{\"bv\":\"" + JsonEscape(j.bv) + L"\",\"content\":\"" + JsonEscape(content) +
        L"\",\"metadata\":{\"memory_origin\":\"workbench\",\"source\":\"" +
        JsonEscape(j.type.empty() ? L"bilibili" : j.type) + L"\",\"bili_bv\":\"" + JsonEscape(j.bv) +
        L"\",\"title\":\"" + JsonEscape(j.title) + L"\"}}";
    // Publish one immutable file per result; the plugin never rewrites a producer's queue.
    if (!WriteTextFile(path + L".tmp", record)) return false;
    return MoveFileExW((path + L".tmp").c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH) != FALSE;
}

bool AppendJob(const JobRec& j) {
    bool queued = j.source == L"console" && j.status == L"ok" && QueueJobMemory(j, ReadTextFile(j.sink, 64 * 1024));
    wstring line = L"{\"t\":" + Num(j.t) + L",\"bv\":\"" + JsonEscape(j.bv) + L"\",\"title\":\"" +
                   JsonEscape(j.title) + L"\",\"up\":\"" + JsonEscape(j.up) + L"\",\"source\":\"" +
                   JsonEscape(j.source) + L"\",\"chat\":\"" + JsonEscape(j.chat) + L"\",\"status\":\"" +
                   JsonEscape(j.status) + L"\",\"sink\":\"" + JsonEscape(j.sink) + L"\",\"seconds\":\"" +
                   JsonEscape(j.seconds) + L"\"";
    // type 只在真有值时才写：老记录没有这个键，读的人也不能指望它
    if (!j.type.empty()) line += L",\"type\":\"" + JsonEscape(j.type) + L"\"";
    if (queued) line += L",\"memory_queued\":true";
    line += L"}\n";
    WriteTextFile(JobsFile(), line, true);
    return queued;
}

static bool JsonGetString(const wstring& line, const wstring& key, wstring& out) {
    wstring pat = L"\"" + key + L"\":\"";
    size_t p = line.find(pat);
    if (p != wstring::npos) {
        size_t i = p + pat.size();
        wstring v;
        while (i < line.size()) {
            wchar_t c = line[i];
            if (c == L'\\' && i + 1 < line.size()) {
                wchar_t n = line[i + 1];
                if (n == L'n') v += L'\n';
                else if (n == L'"') v += L'"';
                else if (n == L'\\') v += L'\\';
                else v += n;
                i += 2;
                continue;
            }
            if (c == L'"') break;
            v += c;
            i++;
        }
        out = v;
        return true;
    }
    pat = L"\"" + key + L"\":";
    p = line.find(pat);
    if (p != wstring::npos) {
        size_t i = p + pat.size();
        while (i < line.size() && (line[i] == L' ' || line[i] == L'"')) i++;
        wstring v;
        while (i < line.size() && line[i] != L',' && line[i] != L'}' && line[i] != L'"') v += line[i++];
        out = Trim(v);
        return true;
    }
    return false;
}

vector<JobRec> ReadJobs(int maxRows) {
    vector<JobRec> jobs;
    wstring text = ReadTextFile(JobsFile(), 600 * 1024);
    if (text.empty()) return jobs;
    vector<wstring> lines = SplitLines(text);
    int start = (int)lines.size() > maxRows ? (int)lines.size() - maxRows : 0;
    for (int i = (int)lines.size() - 1; i >= start; i--) {
        const wstring& l = lines[i];
        if (l.find(L"\"bv\"") == wstring::npos) continue;
        JobRec j;
        wstring v;
        if (JsonGetString(l, L"t", v)) j.t = _wtoi64(v.c_str());
        if (JsonGetString(l, L"bv", v)) j.bv = v;
        if (JsonGetString(l, L"title", v)) j.title = v;
        if (JsonGetString(l, L"up", v)) j.up = v;
        if (JsonGetString(l, L"source", v)) j.source = v;
        if (JsonGetString(l, L"chat", v)) j.chat = v;
        if (JsonGetString(l, L"status", v)) j.status = v;
        if (JsonGetString(l, L"sink", v)) j.sink = v;
        if (JsonGetString(l, L"seconds", v)) j.seconds = v;
        if (JsonGetString(l, L"type", v)) j.type = v;
        jobs.push_back(j);
    }
    return jobs;
}
