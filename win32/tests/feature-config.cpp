#include "../src/her/her.h"
#include <cassert>
#include <cstdio>

bool her::Listening(int) { return false; }
static std::mutex healthMutex;
static wstring healthBody = L"{}";
her::Http her::HttpGet(const wstring&, int) { std::lock_guard<std::mutex> lock(healthMutex); return {200, healthBody, true}; }
her::ActionResult her::RunAction(const wstring&, const wstring&) { return {true, L"test apply"}; }

int main() {
    wchar_t current[2048]; GetCurrentDirectoryW(2048, current);
    const wstring ws = JoinPath(current, L"tmp\\feature-config-test-" + Num(GetCurrentProcessId()));
    CreateDirectoryW(JoinPath(current, L"tmp").c_str(), nullptr);
    CreateDirectoryW(ws.c_str(), nullptr);
    const wstring state = JoinPath(ws, L"state"); CreateDirectoryW(state.c_str(), nullptr);
    SetEnvironmentVariableW(L"MINGLING_WORKSPACE", ws.c_str());
    SetEnvironmentVariableW(L"MINGLING_STATE_DIR", state.c_str());
    EnsureWorkspaceLayout(ws);
    her::J answers = her::JObj(); answers.Set(L"preserve", L"unknown-setting");
    assert(her::WriteJsonAtomic(JoinPath(ws, L"answers.json"), answers));
    auto request = her::J::Parse(LR"({"kind":"sing","action":"save","fields":{"backend":"soulx","root":"F:\\sing-test","server_url":"http://127.0.0.1:18620","tries":2,"app_id":"test-app","token":"fixture-only-secret"}})");
    assert(her::ConfigureFeature(request).ok);
    auto publicState = her::FeatureSettings();
    assert(publicState.Dump().find(L"fixture-only-secret") == wstring::npos);
    assert(publicState.Get(L"doubao")->Bool(L"token_set"));
    auto stored = her::ReadJson(JoinPath(ws, L"private\\feature-settings.json"));
    assert(stored.Get(L"sing")->Str(L"backend") == L"soulx");
    assert(stored.Dump().find(L"fixture-only-secret") == wstring::npos);
    auto invalid = request; invalid.GetM(L"fields")->Set(L"root", L"relative-folder");
    assert(!her::ConfigureFeature(invalid).ok);
    assert(her::ReadJson(JoinPath(ws, L"private\\feature-settings.json")).Dump() == stored.Dump());
    request.GetM(L"fields")->Set(L"token", L"");
    assert(her::ConfigureFeature(request).ok);
    assert(Trim(ReadTextFile(JoinPath(ws,L"private\\volc-token.txt"))) == L"fixture-only-secret");
    auto accountChange = request; accountChange.GetM(L"fields")->Set(L"app_id", L"another-account");
    assert(!her::ConfigureFeature(accountChange).ok);
    assert(Trim(ReadTextFile(JoinPath(ws,L"private\\volc-app-id.txt"))) == L"test-app");
    auto breeze = her::J::Parse(LR"({"kind":"breeze","action":"save","fields":{"voice_id":"voc_fixture","key":"breeze-test-secret"}})");
    assert(her::ConfigureFeature(breeze).ok);
    answers = her::ReadJson(JoinPath(ws, L"answers.json"));
    assert(answers.Str(L"preserve") == L"unknown-setting" && answers.Str(L"breeze_voice_id") == L"voc_fixture");
    assert(her::FeatureSettings().Dump().find(L"breeze-test-secret") == wstring::npos);
    invalid = request; invalid.Set(L"action",L"arbitrary-command"); assert(!her::ConfigureFeature(invalid).ok);
    invalid = request; invalid.GetM(L"fields")->Set(L"server_url", L"http://"); assert(!her::ConfigureFeature(invalid).ok);
    assert(WriteTextFile(JoinPath(ws, L"private\\feature-settings.json"), L"{damaged"));
    assert(!her::ConfigureFeature(request).ok);
    assert(ReadTextFile(JoinPath(ws, L"private\\feature-settings.json")) == L"{damaged");
    assert(!her::FeatureSettings().Str(L"config_error").empty());
    assert(her::WriteJsonAtomic(JoinPath(ws, L"private\\feature-settings.json"), stored));
    for(int i=0;i<100 && her::FeatureSettings().Get(L"sing")->Bool(L"checking");++i) Sleep(5);
    { std::lock_guard<std::mutex> lock(healthMutex); healthBody = LR"({"ok":true,"backends":["unrelated-service"]})"; }
    request.GetM(L"fields")->Set(L"server_url", L"http://127.0.0.1:18621/");
    assert(her::ConfigureFeature(request).ok);
    for(int i=0;i<100 && her::FeatureSettings().Get(L"sing")->Bool(L"checking");++i) Sleep(5);
    assert(!her::FeatureSettings().Get(L"sing")->Bool(L"running"));
    { std::lock_guard<std::mutex> lock(healthMutex); healthBody = LR"({"ok":true,"backends":["soulx"],"device":"cuda"})"; }
    request.GetM(L"fields")->Set(L"server_url", L"http://127.0.0.1:18622/");
    assert(her::ConfigureFeature(request).ok);
    for(int i=0;i<100 && her::FeatureSettings().Get(L"sing")->Bool(L"checking");++i) Sleep(5);
    assert(her::FeatureSettings().Get(L"sing")->Bool(L"running"));
    assert(her::ReadJson(JoinPath(ws, L"private\\feature-settings.json")).Get(L"sing")->Str(L"server_url") == L"http://127.0.0.1:18622");
    std::puts("PASS: feature validation, route persistence, secret redaction, blank-secret preservation, unrelated settings");
    return 0;
}
