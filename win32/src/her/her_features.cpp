#include "her.h"
#include <shlwapi.h>
#include <stdexcept>
#include <winhttp.h>
#include <memory>

namespace her {
namespace {
wstring SettingsPath() { return JoinPath(Base(), L"private\\feature-settings.json"); }
wstring Credential(const wchar_t* file) { return JoinPath(JoinPath(Base(), L"private"), file); }
J LocalSettings() {
    if (!FileExists(SettingsPath())) return JObj();
    bool ok = false; J s = ReadJson(SettingsPath(), &ok);
    return ok && s.Obj() ? s : J();
}
J SingingHealth(const wstring& url) {
    struct Probe { std::mutex mutex; wstring url; J state = JObj(); ULONGLONG at = 0; bool pending = false; };
    static auto probe = std::make_shared<Probe>();
    std::lock_guard<std::mutex> lock(probe->mutex);
    if (probe->url != url) { probe->url = url; probe->state = JObj(); probe->at = 0; }
    if (!probe->pending && (probe->at == 0 || GetTickCount64() - probe->at >= 5000)) {
        probe->pending = true;
        std::thread([cache = probe, url] {
            Http response = HttpGet(url + L"/health", 1500);
            bool parsed = false; J body = J::Parse(response.body, &parsed), status = JObj();
            bool ready = response.code == 200 && parsed && body.Bool(L"ok");
            const J* backends = body.Get(L"backends"); bool hasSoulx = false;
            if (backends && backends->Arr()) for (const auto& b : backends->a) if (b.s == L"soulx") hasSoulx = true;
            status.Set(L"ready", ready && hasSoulx); status.Set(L"device", body.Str(L"device"));
            status.Set(L"voice_name", body.Str(L"voice_name"));
            std::lock_guard<std::mutex> done(cache->mutex);
            if (cache->url == url) { cache->state = status; cache->at = GetTickCount64(); }
            cache->pending = false;
        }).detach();
    }
    J result = probe->state; result.Set(L"checking", probe->pending); return result;
}
J Section(const J& settings, const wchar_t* key) {
    const J* s = settings.Get(key); return s && s->Obj() ? *s : JObj();
}
wstring Saved(const wchar_t* file) { return Trim(ReadTextFile(Credential(file), 16384)); }
bool DoubaoReady(wstring* appOut = nullptr, wstring* tokenOut = nullptr) {
    wstring app = Saved(L"volc-app-id.txt"), token = Saved(L"volc-token.txt");
    J sing = ReadJson(JoinPath(Data(), L"config\\astrbot_plugin_dafeiyu_sing_config.json"));
    auto candidate = [&](const wstring& a, const wstring& t) {
        if (a.empty() || t.empty() || !token.empty()) return;
        if (app.empty()) { app = a; token = t; }
        else if (app == a) token = t;
    };
    // 只复用一整套凭据，或同一个 APP ID 的 Token，不拼接不同账户。
    if (token.empty()) candidate(sing.Str(L"doubao_app_id"), sing.Str(L"doubao_access_token"));
    J config = CmdConfig(); const J* providers = config.Get(L"provider");
    if (providers && providers->Arr()) for (const auto& p : providers->a) {
        if (p.Str(L"type") != L"seed_audio_tts") continue;
        candidate(p.Str(L"app_id"), p.Str(L"access_key"));
    }
    if (appOut) *appOut = app;
    if (tokenOut) *tokenOut = token;
    return !app.empty() && !token.empty();
}
bool Url(const wstring& s) {
    if (s.size() >= 2048 || s.find_first_of(L"\r\n\" ?#") != wstring::npos) return false;
    URL_COMPONENTS parsed{}; parsed.dwStructSize = sizeof(parsed);
    parsed.dwHostNameLength = parsed.dwUserNameLength = parsed.dwPasswordLength = (DWORD)-1;
    return WinHttpCrackUrl(s.c_str(), 0, 0, &parsed) && parsed.dwHostNameLength > 0 &&
        (parsed.nScheme == INTERNET_SCHEME_HTTP || parsed.nScheme == INTERNET_SCHEME_HTTPS) &&
        parsed.dwUserNameLength == 0 && parsed.dwPasswordLength == 0;
}
bool SafePath(const wstring& s) {
    return !s.empty() && s.size() < 1024 && !PathIsRelativeW(s.c_str()) &&
           s.find_first_of(L"\r\n\"|<>*?") == wstring::npos && s.back() != L'\\' && s.back() != L'/';
}
void Backup(const wstring& path) {
    if (!FileExists(path)) return;
    static std::atomic<unsigned long> sequence{0};
    wstring dir = JoinPath(JoinPath(Base(), L"旧版"), L"feature-config-" + NowLocal(L"%Y%m%d-%H%M%S") + L"-" + Num(GetCurrentProcessId()) + L"-" + Num(++sequence));
    CreateDirectoryW(JoinPath(Base(), L"旧版").c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);
    if (!CopyFileW(path.c_str(), JoinPath(dir, PathFindFileNameW(path.c_str())).c_str(), TRUE))
        throw std::runtime_error("backup");
}
void SaveJson(const wstring& path, const J& j) {
    Backup(path); if (!WriteJsonAtomic(path, j)) throw std::runtime_error("write");
}
void SaveSecret(const J& fields, const wchar_t* key, const wchar_t* file) {
    const J* v = fields.Get(key);
    if (!v || v->t != J::STR || Trim(v->s).empty()) return; // 留空保留现有凭据
    if (Saved(file) == Trim(v->s)) return;
    wstring path = Credential(file); Backup(path);
    if (!WriteTextFile(path, Trim(v->s))) throw std::runtime_error("write");
}
ActionResult Script(const wchar_t* file, const wstring& args, DWORD timeout) {
    wstring path = JoinPath(JoinPath(Root(), L"tools"), file);
    if (!FileExists(path)) return {false, L"找不到功能配置脚本，请修复安装。"};
    CmdResult r = RunCapture(L"powershell.exe", L"-NoProfile -ExecutionPolicy Bypass -File \"" + path + L"\" " + args,
                             Root(), {}, timeout);
    auto lines = SplitLines(r.out);
    wstring result;
    for (const auto& line : lines) { size_t pos = line.find(L"RESULT "); if (pos != wstring::npos) result = Trim(line.substr(pos)); }
    if (r.timeout) return {false, L"操作超时，查看工作区 logs 中的服务日志。"};
    wstring description = result;
    size_t why = result.find(L"why=");
    if (why != wstring::npos) description = result.substr(why + 4);
    else if (result.find(L"pet=ok") != wstring::npos) description = L"桌宠连接正常。";
    size_t next = description.find(L" next=");
    if (next != wstring::npos) description = description.substr(0, next);
    if (r.code != 0 || (result.find(L"ok=1") == wstring::npos && result.find(L"pet=ok") == wstring::npos))
        return {false, result.empty() ? L"操作没完成，查看工作区 logs 中的服务日志。" : description};
    return {true, description};
}
}

J FeatureSettings() {
    J local = LocalSettings(), result = JObj();
    if (!local.Obj()) result.Set(L"config_error", L"功能配置文件已损坏，请修复后再保存；原文件未覆盖。" );
    result.Set(L"progress", ReadJson(JoinPath(Base(), L"logs\\singing-progress.json")));
    J liveSing = ReadJson(JoinPath(Data(), L"config\\astrbot_plugin_dafeiyu_sing_config.json"));
    J sing = Section(local, L"sing");
    if (!sing.Has(L"backend")) sing.Set(L"backend", liveSing.Str(L"backend", L"doubao"));
    if (!sing.Has(L"root")) sing.Set(L"root", BotDir(L"SoulXSinger"));
    if (!sing.Has(L"server_url")) sing.Set(L"server_url", liveSing.Str(L"server_url", L"http://127.0.0.1:18620"));
    if (!sing.Has(L"tries")) sing.Set(L"tries", (int)liveSing.Int(L"doubao_tries", 2));
    if (!sing.Has(L"breeze_voice")) sing.Set(L"breeze_voice", L"mingling");
    if (!sing.Has(L"breeze_url")) sing.Set(L"breeze_url", L"http://127.0.0.1:8137/v1");
    if (!sing.Has(L"breeze_text")) sing.Set(L"breeze_text", Trim(ReadTextFile(JoinPath(Root(), L"pack\\mingling-pack\\voice\\mingling-参考.txt"))));
    J voice = ReadJson(JoinPath(sing.Str(L"root"), L"voice\\reference.json"));
    sing.Set(L"voice_name", voice.Str(L"name", L"尚未应用冥零参考"));
    sing.Set(L"installed", FileExists(JoinPath(sing.Str(L"root"), L"installed.json")) && FileExists(JoinPath(sing.Str(L"root"), L"sing_server.py")) &&
                               FileExists(JoinPath(sing.Str(L"root"), L"venv\\Scripts\\python.exe")) && FileExists(JoinPath(sing.Str(L"root"), L"models\\SoulX-Singer\\model.pt")));
    J health = SingingHealth(sing.Str(L"server_url"));
    sing.Set(L"running", health.Bool(L"ready")); sing.Set(L"checking", health.Bool(L"checking")); sing.Set(L"device", health.Str(L"device"));
    if (health.Bool(L"ready") && !health.Str(L"voice_name").empty()) sing.Set(L"voice_name", health.Str(L"voice_name"));
    result.Set(L"sing", sing);
    J doubao = JObj();
    wstring appId; bool doubaoReady = DoubaoReady(&appId);
    doubao.Set(L"app_id", appId);
    doubao.Set(L"token_set", doubaoReady);
    result.Set(L"doubao", doubao);
    J answers = ReadJson(JoinPath(Base(), L"answers.json"));
    J breeze = JObj();
    breeze.Set(L"voice_id", answers.Str(L"breeze_voice_id"));
    breeze.Set(L"key_set", !Saved(L"breeze-key.txt").empty());
    result.Set(L"breeze", breeze);
    J pet = Section(local, L"pet");
    if (!pet.Has(L"dsh_home")) pet.Set(L"dsh_home", JoinPath(UserProfile(), L".dsh"));
    if (!pet.Has(L"recent_count")) pet.Set(L"recent_count", 8);
    if (!pet.Has(L"recent_hours")) pet.Set(L"recent_hours", 12);
    if (!pet.Has(L"redirect_reminders")) pet.Set(L"redirect_reminders", true);
    result.Set(L"pet", pet);
    return result;
}

ActionResult ConfigureFeature(const J& request) {
    wstring kind = request.Str(L"kind"), action = request.Str(L"action", L"save");
    if (kind != L"sing" && kind != L"pet" && kind != L"doubao" && kind != L"breeze")
        return {false, L"不认识的功能配置"};
    const J* fieldsPtr = request.Get(L"fields");
    if (!fieldsPtr || !fieldsPtr->Obj()) return {false, L"配置格式不对"};
    const J& fields = *fieldsPtr;
    const std::vector<wstring> actions = {L"save", L"apply", L"install", L"start", L"check", L"test", L"connect", L"voice_existing", L"voice_breeze"};
    if (std::find(actions.begin(), actions.end(), action) == actions.end()) return {false, L"不认识的配置操作"};
    if (kind != L"sing" && (action == L"install" || action == L"start" || action == L"test" || action == L"voice_existing" || action == L"voice_breeze"))
        return {false, L"该功能没有这个操作"};
    if (kind != L"pet" && action == L"connect") return {false, L"该功能不能接通桌宠"};
    for (const auto& f : fields.o)
        if (f.second.t == J::STR && (f.second.s.size() > 8192 || f.second.s.find_first_of(L"\r\n") != wstring::npos))
            return {false, L"配置内容过长或含换行，请检查输入"};
    J settings = LocalSettings(), section = Section(settings, kind.c_str());
    if (!settings.Obj()) return {false, L"功能配置文件读不了，原文件已保留，请先修复配置。"};
    J defaults = FeatureSettings();
    if ((kind == L"sing" || kind == L"doubao") && !Trim(fields.Str(L"app_id")).empty() &&
        Trim(fields.Str(L"app_id")) != Saved(L"volc-app-id.txt") &&
        !Saved(L"volc-token.txt").empty() && Trim(fields.Str(L"token")).empty())
        return {false, L"更换豆包 APP ID 时请同时填写对应的 Access Token，避免混用账户。"};
    if (!section.Obj() || section.o.empty()) section = Section(defaults, kind.c_str());
    if (kind == L"sing") {
        wstring backend = fields.Str(L"backend", section.Str(L"backend", L"doubao"));
        wstring root = fields.Str(L"root", section.Str(L"root", BotDir(L"SoulXSinger")));
        wstring url = fields.Str(L"server_url", section.Str(L"server_url", L"http://127.0.0.1:18620"));
        while (url.size() > 8 && url.back() == L'/') url.pop_back();
        int tries = (int)fields.Int(L"tries", section.Int(L"tries", 2));
        wstring voice = fields.Str(L"breeze_voice", section.Str(L"breeze_voice", L"mingling"));
        wstring breezeUrl = fields.Str(L"breeze_url", section.Str(L"breeze_url", L"http://127.0.0.1:8137/v1"));
        wstring breezeText = fields.Str(L"breeze_text", section.Str(L"breeze_text"));
        if (voice.empty() || voice.size() > 128 || !Url(breezeUrl) || breezeText.size() > 160)
            return {false, L"检查已有 Breeze 音色名、服务地址和参考句子（最多 160 字）"};
        if ((backend != L"doubao" && backend != L"soulx") || !Url(url) || !SafePath(root) || tries < 1 || tries > 5)
            return {false, L"检查唱歌方式、服务地址、绝对安装目录和尝试次数（1—5）"};
        section = JObj(); section.Set(L"backend", backend); section.Set(L"root", root);
        section.Set(L"server_url", url); section.Set(L"tries", tries);
        section.Set(L"breeze_voice", voice); section.Set(L"breeze_url", breezeUrl); section.Set(L"breeze_text", breezeText);
    } else if (kind == L"pet") {
        wstring home = fields.Str(L"dsh_home", section.Str(L"dsh_home", JoinPath(UserProfile(), L".dsh")));
        int count = (int)fields.Int(L"recent_count", section.Int(L"recent_count", 8));
        int hours = (int)fields.Int(L"recent_hours", section.Int(L"recent_hours", 12));
        if (!SafePath(home) || count < 0 || count > 50 || hours < 1 || hours > 168)
            return {false, L"检查桌宠目录、最近消息条数（0—50）和小时数（1—168）"};
        section = JObj(); section.Set(L"dsh_home", home); section.Set(L"recent_count", count);
        section.Set(L"recent_hours", hours); section.Set(L"redirect_reminders", fields.Bool(L"redirect_reminders", true));
    } else if (kind == L"breeze") {
        wstring voice = fields.Str(L"voice_id");
        if (!StartsWith(voice, L"voc_") || voice.size() < 5 || voice.find_first_not_of(L"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", 4) != wstring::npos)
            return {false, L"请输入 voc_ 开头的 Breeze 音色 ID"};
    }
    J answers;
    if (kind == L"breeze") {
        answers = ReadJson(JoinPath(Base(), L"answers.json"));
        if (!answers.Obj()) return {false, L"answers.json 读不了，已保留原文件，请先修复配置。"};
    }
    try {
        CreateDirectoryW(JoinPath(Base(), L"private").c_str(), nullptr);
        if (kind == L"sing" || kind == L"doubao") {
            SaveSecret(fields, L"app_id", L"volc-app-id.txt"); SaveSecret(fields, L"token", L"volc-token.txt");
            if (kind == L"doubao" && action == L"apply") {
                wstring app, token;
                if (DoubaoReady(&app, &token)) {
                    J shared = JObj(); shared.Set(L"app_id", app); shared.Set(L"token", token);
                    SaveSecret(shared, L"app_id", L"volc-app-id.txt"); SaveSecret(shared, L"token", L"volc-token.txt");
                }
            }
        }
        if (kind == L"breeze") {
            SaveSecret(fields, L"key", L"breeze-key.txt");
            answers.Set(L"breeze_voice_id", fields.Str(L"voice_id"));
            SaveJson(JoinPath(Base(), L"answers.json"), answers);
        }
        if (kind == L"sing" || kind == L"pet") { settings.Set(kind, section); SaveJson(SettingsPath(), settings); }
    } catch (...) { return {false, L"配置备份或保存失败，请检查目录权限和磁盘空间。"}; }
    if (action == L"save") return {true, L"配置已保存。密钥留空时保留已保存的值。"};
    if (kind == L"sing" && (action == L"install" || action == L"start" || action == L"test" || action == L"voice_existing" || action == L"voice_breeze" || (action == L"check" && section.Str(L"backend") == L"soulx"))) {
        return Script(L"setup-singing.ps1", L"-Base \"" + Base() + L"\" -Root \"" + section.Str(L"root") + L"\" -Action " + action,
                      action == L"install" ? 90 * 60 * 1000 : 10 * 60 * 1000);
    }
    if (kind == L"pet" && action == L"connect") {
        ActionResult enabled = SetFeature(L"plugin/astrbot_plugin_dafeiyu_petlink/1");
        if (!enabled.ok) return enabled;
    }
    if (kind == L"pet" && (action == L"check" || action == L"connect"))
        return Script(L"setup-pet.ps1", L"-Dir \"" + Base() + L"\" -DshHome \"" + section.Str(L"dsh_home") + L"\"" + (action == L"check" ? L" -Check" : L""), 10 * 60 * 1000);
    if (action == L"check") {
        if ((kind == L"doubao" || kind == L"sing") && !DoubaoReady())
            return {false, L"请先填写豆包 APP ID 和 Access Token。"};
        if (kind == L"breeze" && Saved(L"breeze-key.txt").empty()) return {false, L"请先填写 Breeze API 密钥。"};
        return {true, L"所需凭据已填写；检测未调用付费合成。"};
    }
    if (kind == L"sing" && section.Str(L"backend") == L"doubao" && !DoubaoReady())
        return {false, L"唱歌设置已保存；请先填写豆包 APP ID 和 Access Token，再启用云端唱歌。"};
    wstring spec = kind == L"sing" ? L"plugin/astrbot_plugin_dafeiyu_sing/1" : kind == L"pet" ? L"plugin/astrbot_plugin_dafeiyu_petlink/1" : kind == L"doubao" ? L"voice/3" : L"voice/5";
    ActionResult enabled = SetFeature(spec);
    if (!enabled.ok) return enabled;
    return RunAction(L"selfsetup", kind == L"sing" || kind == L"pet" ? L"plugins" : L"plugins,voice");
}
}
