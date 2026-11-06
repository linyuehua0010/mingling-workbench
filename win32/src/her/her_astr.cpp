// 冥零工作台 · 跟 AstrBot 后台说话（原生版 astr_* 那一组）
// 全部走 http://127.0.0.1:{backend_port}/api/v1，头里带 Bearer token。
// 这套接口是照着旧 server.py 里 astr_call / astr_login / astr_tts 的实际用法抄的：
//   * 返回值统一取 data 字段，status=="error" 当失败；
//   * 登录先试明文密码，再试 md5（在后台网页上改过密码的存的是 md5）；
//   * 改整份配置是 GET /config-profiles/default 拿 config，改完原样 PUT 回去；
//   * 插件配置是 GET /plugins/config?plugin_id=xxx 拿 config，PUT /plugins/config；
//   * 语音提供商配置是 GET /providers/{id} 拿 provider，PUT /providers/{id} {"config": ...}。
#include "her.h"

#include <cstdio>

namespace her {

namespace {

wstring ApiBase() {
    return L"http://127.0.0.1:" + std::to_wstring(BackendPort()) + L"/api/v1";
}

wstring PctEncode(const wstring& s) {
    std::string b = WToUtf8(s);
    wstring o;
    static const wchar_t* hex = L"0123456789ABCDEF";
    for (unsigned char c : b) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ||
            c == '.' || c == '~') {
            o.push_back((wchar_t)c);
        } else {
            o.push_back(L'%');
            o.push_back(hex[c >> 4]);
            o.push_back(hex[c & 15]);
        }
    }
    return o;
}

wstring Short(const wstring& s, size_t n = 120) { return s.size() > n ? s.substr(0, n) : s; }

// 响应体 -> data；失败返回 false 并给一句人话
bool Unwrap(const Http& r, J& out, wstring* err) {
    if (!r.ok) {
        if (err) *err = L"连不上大脑后台（端口 " + std::to_wstring(BackendPort()) + L"）";
        return false;
    }
    bool pok = false;
    J j = J::Parse(r.body, &pok);
    if (!pok || !j.Obj()) {
        if (err) *err = L"后台回的东西看不懂（HTTP " + std::to_wstring(r.code) + L"）";
        return false;
    }
    if (j.Str(L"status") == L"error") {
        wstring m = j.Str(L"message");
        if (m.empty()) m = L"HTTP " + std::to_wstring(r.code);
        if (err) *err = Short(m);
        return false;
    }
    if (r.code >= 400) {
        if (err) *err = L"HTTP " + std::to_wstring(r.code);
        return false;
    }
    const J* d = j.Get(L"data");
    out = d ? *d : j;
    return true;
}

// 后台密码：先 private\backend.txt，再 AstrBot 自己存的（md5/pbkdf2 那串，登录接口认 md5）
std::wstring DashboardPassword() {
    std::wstring pw = ReadKv(SecretFile(L"backend.txt"), L"password");
    if (!pw.empty()) return pw;
    J cfg = ReadJson(P(L"astrbot\\data\\cmd_config.json"));
    const J* d = cfg.Get(L"dashboard");
    return d ? Trim(d->Str(L"password")) : std::wstring();
}

}  // namespace

bool AstrApi::Login(wstring* err) {
    wstring name = ReadKv(SecretFile(L"backend.txt"), L"username");
    wstring pw = ReadKv(SecretFile(L"backend.txt"), L"password");
    if (name.empty()) name = L"astrbot";
    if (pw.empty()) pw = DashboardPassword();
    if (pw.empty()) {
        J cfg = ReadJson(P(L"astrbot\\data\\cmd_config.json"));
        const J* d = cfg.Get(L"dashboard");
        std::wstring un = d ? d->Str(L"username") : L"";
        if (err)
            *err = L"没读到后台密码：在 " + SecretFile(L"backend.txt") +
                   L" 里写 username/password（后台网页登录用的那对），或在 AstrBot 的 dashboard 里看用户名" +
                   (un.empty() ? L"" : L"（现在是 " + un + L"）");
        return false;
    }
    std::vector<wstring> tries = {pw, Md5Hex(pw)};
    for (const wstring& p : tries) {
        J body;
        body.Set(L"username", J(name));
        body.Set(L"password", J(p));
        Http r = Call(L"POST", L"/auth/login", body.Dump(), 15000, true);
        J d;
        wstring e;
        if (Unwrap(r, d, &e)) {
            wstring t = d.Str(L"token");
            if (!t.empty()) {
                token = t;
                if (err) err->clear();
                return true;
            }
        }
    }
    if (err) *err = L"用户名或密码不对（在后台网页上改过密码的话，改 " + SecretFile(L"backend.txt") + L"）";
    return false;
}

// loginOnly=true 时即使已有 token 也不带（登录本身不能带旧 token）
Http AstrApi::Call(const wstring& method, const wstring& path, const wstring& body, int timeoutMs, bool loginOnly) {
    wstring url = ApiBase() + path;
    std::vector<std::pair<wstring, wstring>> h;
    h.push_back({L"Content-Type", L"application/json"});
    if (!loginOnly && !token.empty()) h.push_back({L"Authorization", L"Bearer " + token});
    return HttpCall(method, url, body, h, timeoutMs);
}

bool AstrApi::GetJson(const wstring& path, J& out, wstring* err) {
    Http r = Call(L"GET", path);
    return Unwrap(r, out, err);
}

bool AstrApi::PutJson(const wstring& path, const J& body, wstring* err) {
    Http r = Call(L"PUT", path, body.Dump());
    J d;
    return Unwrap(r, d, err);
}

bool AstrApi::TtsEnable(bool on, wstring* err) {
    J root;
    if (!GetJson(L"/config-profiles/default", root, err)) return false;
    const J* cfgp = root.Get(L"config");
    if (!cfgp || !cfgp->Obj()) {
        if (err) *err = L"后台没给 config";
        return false;
    }
    J cfg = *cfgp;
    J* tts = cfg.GetM(L"provider_tts_settings");
    if (!tts) {
        cfg.Set(L"provider_tts_settings", JObj());
        tts = cfg.GetM(L"provider_tts_settings");
    }
    if (tts->Bool(L"enable") == on) return true;  // 本来就是
    tts->Set(L"enable", JBool(on));
    return PutJson(L"/config-profiles/default", cfg, err);
}

bool AstrApi::PluginEnabled(const wstring& pluginId, bool on, wstring* err) {
    J body;
    body.Set(L"plugin_id", J(pluginId));
    body.Set(L"enabled", JBool(on));
    Http r = Call(L"PATCH", L"/plugins/enabled", body.Dump(), 60000);
    J d;
    return Unwrap(r, d, err);
}

bool AstrApi::PluginConfig(const wstring& pluginId, J& conf, wstring* err) {
    J root;
    if (!GetJson(L"/plugins/config?plugin_id=" + PctEncode(pluginId), root, err)) return false;
    const J* c = root.Get(L"config");
    conf = (c && c->Obj()) ? *c : root;
    if (!conf.Obj()) {
        if (err) *err = L"插件配置不是对象";
        return false;
    }
    return true;
}

bool AstrApi::SavePluginConfig(const wstring& pluginId, const J& conf, wstring* err) {
    J body;
    body.Set(L"plugin_id", J(pluginId));
    body.Set(L"config", conf);
    Http r = Call(L"PUT", L"/plugins/config", body.Dump(), 60000);
    J d;
    return Unwrap(r, d, err);
}

bool AstrApi::SaveProvider(const wstring& providerId, const J& conf, wstring* err) {
    J body;
    body.Set(L"config", conf);
    Http r = Call(L"PUT", L"/providers/" + PctEncode(providerId), body.Dump(), 60000);
    J d;
    return Unwrap(r, d, err);
}

}  // namespace her
