#include "../src/bili_plan.h"
#include <cassert>
#include <cstdio>

static her::Http response;
static wstring requestedUrl, requestedBody, requestedKey;
her::Http her::HttpPostJson(const wstring& url, const wstring& json, const wstring& bearer, int) {
    requestedUrl = url; requestedBody = json; requestedKey = bearer; return response;
}
int main() {
    DshApiCfg api; api.enabled = true; api.base = L"https://example.test/v1/";
    api.path = L"/chat/completions"; api.model = L"fixture-model"; api.key = L"fixture-secret";
    assert(DshApiUrl(api) == L"https://example.test/v1/chat/completions");
    api.base = L"https://example.test/v1/chat/completions";
    assert(DshApiUrl(api) == api.base);
    api.base = L"https://example.test/v1"; api.path = L"/v1/chat/completions";
    assert(DshApiUrl(api) == L"https://example.test/v1/chat/completions");
    wstring reply, error;
    response = {200, LR"({"choices":[{"message":{"content":"连接成功"}}]})", true};
    assert(DshChat(L"测试中文", api, &reply, &error)); assert(reply == L"连接成功");
    assert(requestedKey == api.key && requestedUrl == L"https://example.test/v1/chat/completions");
    auto request = her::J::Parse(requestedBody);
    assert(request.Str(L"model") == api.model && request.Get(L"messages")->a[0].Str(L"content") == L"测试中文");
    response = {400, LR"({"error":{"message":"unknown model fixture-secret"}})", true};
    assert(!DshChat(L"test", api, &reply, &error));
    assert(error.find(L"unknown model") != wstring::npos && error.find(api.key) == wstring::npos);
    response = {200, LR"({"choices":[]})", true}; assert(!DshChat(L"test", api, &reply, &error));
    response = {0, L"", false}; assert(!DshChat(L"test", api, &reply, &error));

    FeedItem first, second; first.bv=L"BV1234567890"; first.title=L"候选一"; second.bv=L"BV0987654321";
    vector<FeedItem> candidates{first,second}; her::J plan;
    assert(bili::ParsePlan(LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":0},{"bv":"BV0987654321","delay_minutes":0}],"next_refresh_minutes":1})", candidates, 1000, 3, &plan, &error));
    assert(plan.Int(L"nextRefresh") == 1900 && plan.Get(L"tasks")->a[1].Int(L"due") == 1600);
    for (const auto* bad : {
        LR"({"tasks":[{"bv":"BV0000000000","delay_minutes":0}]})",
        LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":0},{"bv":"BV1234567890","delay_minutes":1}]})",
        LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":-1}]})",
        LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":0.5}]})",
        LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":121}]})", L"not json"})
        assert(!bili::ParsePlan(bad, candidates, 1000, 3, &plan, &error));
    assert(!bili::ParsePlan(LR"({"tasks":[{"bv":"BV1234567890","delay_minutes":0}]})", candidates, 1000, 0, &plan, &error));
    assert(bili::ParsePlan(L"```json\n{\"tasks\":[]}\n```", candidates, 1000, 3, &plan, &error));
    auto config=her::J::Parse(LR"({"night":{"windows":[{"start":"22:00","end":"6:00"}]}})");
    assert(bili::InWindow(config,23*60) && bili::InWindow(config,5*60) && !bili::InWindow(config,12*60));
    assert(bili::Minute(L"24:00")==1440 && bili::Minute(L"24:01")==-1 && bili::Minute(L"6:x0")==-1);
    puts("bili API and plan validation passed");
}
