// 冥零工作台 · 原生状态/维护逻辑层
// 判断和执行全部在 C++ 里：端口/进程直接问系统，统计直接读 sqlite
// （系统自带的 winsqlite3.dll），开关直接读写 astrbot 的 json 和它的 WebUI 接口。
// 不依赖旧网页工作台，也不调用任何 python 桥。
#pragma once

#include "../core.h"

#include <array>
#include <mutex>
#include <functional>
#include <utility>

namespace her {

// ================================================================ JSON
struct J {
    enum T { NUL, BOOL, NUM, STR, ARR, OBJ };
    T t = NUL;
    bool b = false;
    double num = 0;
    std::wstring s;
    std::vector<J> a;
    std::vector<std::pair<std::wstring, J>> o;

    J() {}
    J(bool v) : t(BOOL), b(v) {}
    J(double v) : t(NUM), num(v) {}
    J(int v) : t(NUM), num(v) {}
    J(long long v) : t(NUM), num((double)v) {}
    J(const wchar_t* v) : t(STR), s(v) {}
    J(const std::wstring& v) : t(STR), s(v) {}

    static J Parse(const std::wstring& text, bool* ok = nullptr);
    std::wstring Dump(int indent = 0) const;

    bool Obj() const { return t == OBJ; }
    bool Arr() const { return t == ARR; }
    bool IsNull() const { return t == NUL; }

    const J* Get(const std::wstring& key) const;
    J* GetM(const std::wstring& key);
    void Set(const std::wstring& key, const J& v);
    bool Has(const std::wstring& key) const;
    std::wstring Str(const std::wstring& key, const std::wstring& def = L"") const;
    bool Bool(const std::wstring& key, bool def = false) const;
    double Num(const std::wstring& key, double def = 0) const;
    long long Int(const std::wstring& key, long long def = 0) const;
    // "a.b.c"
    const J* Path(const std::wstring& dot) const;
    bool PathSet(const std::wstring& dot, const J& v);

    void Push(const J& v) { t = ARR; a.push_back(v); }
    // 数字转字符串（整数不带小数点）
    std::wstring NumText() const;
};

J JObj();
J JArr();
J JStr(const std::wstring& v);
J JNum(double v);
J JBool(bool v);

// ================================================================ 路径与配置
std::wstring Base();                      // 工作区根目录（默认 D:\）
std::wstring Root();                      // D:\MinglingWorkbench（工作台自己）
std::wstring P(const wchar_t* rel);       // Base()\rel
std::wstring BotPath(const wchar_t* name);   // <工作区>\bots\name 优先，老布局兜底
// 组件启动脚本：先 <组件目录>\start.cmd（bots 布局），再 <组件目录>\start-breeze.cmd，
// 最后 <机器人根>\baseCmd（老布局，例如 start-snowluma.cmd）。都没有返回空串。
std::wstring ComponentStartCmd(const wchar_t* name, const wchar_t* baseCmd = nullptr);
std::wstring Data();                      // astrbot 的 data 目录
std::wstring Answers(const wchar_t* key, const wchar_t* def = L"");
int Voice();                              // 1 Edge / 2 MiMo / 3 豆包 / 4 Breeze 本机 / 5 Breeze 在线
int Memory();                             // living memory 开没开
int Video();                              // 看图看视频开没开
// 「功能」页写的覆盖文件：private\features.txt（一行 "<插件名>=1/0"）、
// private\memory-mode.txt、private\voice-mode.txt。文件在就以文件为准。
bool FeatureOn(const std::wstring& name, bool def);
int ModeNum(const std::wstring& key, int def);
std::wstring Protocol();                  // snowluma / napcat
bool IsCli();                             // start-astrbot.cmd 在不在（CLI 版安装）
int BackendPort();                        // 从 answers.base_url 里取端口
std::wstring ReadKv(const std::wstring& path, const std::wstring& key);
std::wstring MaskQQ(const std::wstring& qq);
std::wstring PrettyDur(long long sec);
std::wstring NowLocal(const wchar_t* fmt);       // wcsftime
long long BootUnix();

J ReadJson(const std::wstring& path, bool* ok = nullptr);
bool WriteJsonAtomic(const std::wstring& path, const J& v);

J CmdConfig();                            // astrbot\data\cmd_config.json
bool CmdConfigSave(const J& cfg);

struct Balance {
    bool has = false;      // 有 key
    std::wstring state = L"nokey";  // ok / auth / http / net / nokey
    double amount = 0;
    std::wstring currency = L"CNY";
    long long at = 0;
};
Balance DeepSeekBalance(bool force = false);
bool WhitelistOn();

struct Wiring {
    bool installed = false, on = false;
    std::wstring provider;   // 配置里写的 embedding provider id
    std::wstring model, base, key;
    bool ollama = false;     // 本机 Ollama 兜底
    bool online = false;     // 走在线 API
};
Wiring MemoryWiring();
std::wstring AsrState();                 // local / plus / online / half / none
bool LauncherAutostart();                // 注册表里 AstrBot Launcher 自启是否被禁用

struct MemeInfo {
    int expected = 0;
    int installed = 0;
    int pictures = 0;
    std::wstring note;
};
MemeInfo MemeState();
std::wstring ImportLogState(const wchar_t* block);   // 返回 "" / running / RESULT 文案

struct WatchInfo {
    bool can = true;
    bool on = false;
    bool running = false;
    long long at = 0;
    std::wstring state, note;
};
WatchInfo Watch();

struct GameInfo {
    bool on = false;
    long long since = 0;
    bool tts = false, mem = false;
    bool can = false;
};
GameInfo Game();

// 版本行
std::vector<std::pair<std::wstring, std::wstring>> Versions();

// ================================================================ 更新
// 结构跟原来网页版的 check_updates 一致，缓存落在工作台自己的 logs\cache.json。
struct UpdateItem {
    std::wstring id;      // astrbot / snowluma / skill / wb
    std::wstring name;
    std::wstring what;
    std::wstring local, latest;
    std::wstring state;   // new / latest / local / unknown
    std::vector<std::wstring> notes;
};
struct UpdatesInfo {
    bool ok = false;
    bool busy = false;
    long long at = 0;
    std::wstring wb;          // 本机工作台版本（APP_VERSION_PLAIN）
    std::wstring wbRepo;      // 在查的 GitHub 仓库 owner/name（空 = 用默认仓库）
    std::wstring wbUrl;       // 最新 release 的网页地址（查不到为空）
    std::wstring err;
    bool qqUpgrade = false;   // 桌面 QQ 像是自动升级了，SnowLuma 挂不上
    std::vector<UpdateItem> items;
};
UpdatesInfo CheckUpdates(bool force = false);
// 旧接口：给 --her 命令行 / 别处要一句话摘要时用
std::wstring UpdatesSummary(const UpdatesInfo& u);

// ================================================================ 系统 / 端口 / 进程
struct Est { int lport = 0, rport = 0; DWORD pid = 0; };
struct NetSnap {
    std::map<int, DWORD> listen;
    std::vector<Est> est;
    DWORD at = 0;
};
NetSnap Net();   // 每次给一份拷贝：端口表会被多个线程同时问，别共享同一份可变状态
bool Listening(int port);
DWORD ListenPid(int port);
std::wstring ImagePath(DWORD pid);                       // 小写全路径
std::vector<DWORD> PidsUnder(const std::wstring& rootLower);
std::vector<DWORD> PidsNamed(const std::wstring& exeLower);
bool ExeUnder(DWORD pid, const std::wstring& rootLower);
std::vector<DWORD> ChildrenOf(DWORD pid);
bool KillTree(DWORD pid);
int KillUnder(const std::wstring& rootLower);
std::vector<DWORD> AstrBotPids();
bool QqOnline();
bool IsSelf(DWORD pid);

struct Http {
    int code = 0;
    std::wstring body;
    bool ok = false;        // 传输层成功（code != 0）
};
Http HttpCall(const std::wstring& method, const std::wstring& url, const std::wstring& bodyUtf8,
              const std::vector<std::pair<std::wstring, std::wstring>>& headers, int timeoutMs = 8000);
Http HttpGet(const std::wstring& url, int timeoutMs = 8000);
Http HttpPostJson(const std::wstring& url, const std::wstring& json, const std::wstring& bearer, int timeoutMs = 8000);
Http HttpGetJson(const std::wstring& url, const std::wstring& bearer, int timeoutMs = 8000);

void LaunchCmd(const std::wstring& batPath, const std::wstring& cwd, bool visible);
DWORD LaunchExe(const std::wstring& exe, const std::wstring& args, const std::wstring& cwd, const EnvList& env,
                bool hidden);
bool WaitFor(const std::function<bool()>& fn, int seconds, const std::function<void(int)>& tick = nullptr);
std::wstring Md5Hex(const std::wstring& s);

// 本机这两个家伙的启停（状态卡和动作都要用）
std::wstring OllamaExe();
bool LaunchOllama();
std::vector<std::wstring> OllamaModels(bool* ok = nullptr);
std::vector<std::wstring> StartupNames();   // 启动文件夹里的文件名

// ================================================================ sqlite（系统 winsqlite3.dll）
struct Sqlite {
    void* db = nullptr;
    ~Sqlite() { Close(); }
    bool OpenRead(const std::wstring& path, std::wstring* err = nullptr);
    void Close();
    bool QueryLongs(const std::wstring& sql, std::vector<long long>& out, std::wstring* err = nullptr);
    bool QueryTexts(const std::wstring& sql, std::vector<std::vector<std::wstring>>& rows, std::wstring* err = nullptr);
};

// ================================================================ AstrBot WebUI 接口
struct AstrApi {
    std::wstring token;
    std::wstring base;
    bool Login(std::wstring* err = nullptr);
    Http Call(const std::wstring& method, const std::wstring& path, const std::wstring& body = L"",
              int timeoutMs = 8000, bool loginOnly = false);
    bool GetJson(const std::wstring& path, J& out, std::wstring* err = nullptr);
    bool PutJson(const std::wstring& path, const J& body, std::wstring* err = nullptr);
    bool TtsEnable(bool on, std::wstring* err = nullptr);
    bool PluginEnabled(const std::wstring& pluginId, bool on, std::wstring* err = nullptr);
    bool PluginConfig(const std::wstring& pluginId, J& conf, std::wstring* err = nullptr);
    bool SavePluginConfig(const std::wstring& pluginId, const J& conf, std::wstring* err = nullptr);
    bool SaveProvider(const std::wstring& providerId, const J& conf, std::wstring* err = nullptr);
};

// ================================================================ 状态（九张卡）
struct Card {
    std::wstring id, state, name, text, fixAct, fixLbl, linkLbl, linkHref, pill;
};
struct Stat {
    long long msgs = 0, replies = 0, tokens = 0, mems = 0;
    bool ok = false;
};

// AstrBot 后台自己算的今日用量（回复条数 / token）。拿不到时 ok=false，调用方退回读库。
struct TokStat {
    bool ok = false;
    long long todayTokens = 0, todayCalls = 0;
};
TokStat ProviderTokens(int days = 1);
struct Status {
    std::vector<Card> cards;
    Stat stat;
    std::wstring group = L"off", meme = L"few", voice = L"few";
    bool gameOn = false, gameCan = false;
    long long gameSince = 0;
    WatchInfo watch;
    std::vector<std::pair<std::wstring, std::wstring>> vers;
    std::wstring note;
};
bool CollectStatus(Status& st, std::wstring* err = nullptr);
Stat TodayStats(bool force = false);

// ================================================================ 动作
struct ActionResult {
    bool ok = false;
    std::wstring msg;
};

ActionResult RunAction(const std::wstring& op, const std::wstring& arg);
// 「功能」页用：写覆盖文件（不动 answers.json）。
// arg 形如 "plugin:dafeiyu_petlink:1" / "memory:2" / "voice:5"。
ActionResult SetFeature(const std::wstring& arg);
std::wstring GroupReplyMode();
std::wstring MemeMode();
std::wstring VoiceMode();

// ================================================================ 一键自动配置
struct SetupStep {
    std::wstring name;
    bool ok = false;
    std::wstring detail;
};
struct SetupReport {
    bool ok = false;
    int fixed = 0;
    std::vector<SetupStep> steps;
    std::wstring summary;
};
// onStep(百分比, 当前步骤)。只做回调，调用方自己决定怎么回 UI。
SetupReport AutoSetup(const std::function<void(int, const std::wstring&)>& onStep);
// 五个组件（AstrBot/SnowLuma/Breeze/Ollama/bili-whale）装进 <工作区>\bots。
// 真正的下载在 tools\auto-setup.ps1，这里只拉起它并把 ##STEP/##OK/##RESULT 翻成步骤。
SetupReport BotsSetup(const std::function<void(int, const std::wstring&)>& onStep);
// 自设定：拿 pack\mingling-pack\pack.json 把 DeepSeek、QQ 平台、聊天设置、人设都配成冥零。
// 真正的活在 tools\self-setup.ps1（分 provider/platform/chat/plugins/memory/voice/persona/verify 八块），
// 这里只拉起它、把 ##STEP/##OK/##FAIL/##RESULT 翻成步骤。
SetupReport Configure(const std::function<void(int, const std::wstring&)>& onStep, bool dryRun = false);

// --her-status：命令行自检（GUI 版也带，方便对照 / 交给 Agent 看）
int CliMain(const std::vector<std::wstring>& args);

}  // namespace her
