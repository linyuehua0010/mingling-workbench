#include "../src/ui.h"
#include "../src/biliapi.h"
#include <cassert>
#include <cstdio>

static vector<FeedItem> g_feed;
static vector<JobRec> g_jobs;
static wstring g_feedNote, g_bvInput=L"user draft";
static bool g_watchBusy=false, g_dshBusy=false;
static int watches=0, summaries=0;
static bool writes=true;
static her::J saved, config=her::J::Parse(LR"({"night":{"windows":[{"start":"0:00","end":"24:00"}]}})");
void UiToast(const wstring&) {}
void UiRequestRepaint() {}
static void StartWatch() { ++watches; g_watchBusy=true; }
static void DshAsk() { ++summaries; g_dshBusy=true; }
static void PostTask(TaskData* d) { delete d; }
wstring WorkspaceDir() { return L"fixture"; }
wstring StateDir() { return L"fixture-state"; }
bool BiliCfgLoad(her::J& dst, wstring*) { dst=config; return true; }
DshApiCfg DshApiLoad() { return {}; }
bool DshChat(const wstring&,const DshApiCfg&,wstring*,wstring*) { return false; }
CmdResult RunWhale(const wstring&,int) { return {}; }
vector<FeedItem> ParseFeed(const wstring&) { return {}; }
her::J her::ReadJson(const wstring&,bool*) { return saved; }
bool her::WriteJsonAtomic(const wstring&,const her::J& value) { saved=value; return writes; }
#include "../src/ui_bili_agent.inc"

static void round() {
    g_ba=her::J::Parse(LR"({"active":true,"manual":true,"enabled":false,"tasks":[]})");
    her::J tasks=her::JArr();
    for (auto bv : {L"BV1234567890",L"BV0987654321"}) {
        auto task=her::JObj();task.Set(L"bv",bv);task.Set(L"status",L"pending");task.Set(L"due",NowUnix()-1);tasks.Push(task);
    }
    g_ba.Set(L"tasks",tasks); g_watchBusy=g_dshBusy=g_baWatching=false; g_jobs.clear();
}
int main() {
    round(); BiliAgentTick();
    assert(watches==1 && g_baWatching && g_bvInput==L"user draft");
    BiliAgentTick();assert(watches==1); // Never run two watches concurrently.
    TaskData done;done.ok=true;g_watchBusy=false;BiliAgentOnWatch(&done);
    assert(summaries==1 && g_ba.Get(L"tasks")->a[0].Str(L"status")==L"done");
    BiliAgentTick();assert(watches==1); // Wait for the API summary before the next watch.
    g_dshBusy=false;BiliAgentTick();assert(watches==2);
    BiliAgentCommand(L"stop");g_watchBusy=false;BiliAgentOnWatch(&done);g_dshBusy=false;BiliAgentTick();
    assert(watches==2 && !g_ba.Bool(L"active") && !g_ba.Bool(L"enabled"));

    round();BiliAgentTick();TaskData failed;g_watchBusy=false;BiliAgentOnWatch(&failed);
    assert(!g_ba.Bool(L"active") && g_ba.Get(L"tasks")->a[1].Str(L"status")==L"cancelled");
    round();JobRec seen;seen.bv=L"BV1234567890";seen.status=L"ok";g_jobs.push_back(seen);BiliAgentTick();
    assert(g_ba.Get(L"tasks")->a[0].Str(L"status")==L"skipped");

    round();config=her::J::Parse(LR"({"night":{"windows":[]}})");g_ba.Set(L"manual",false);
    int before=watches;BiliAgentTick();assert(watches==before); // Respect sleeping hours.
    round();writes=false;BiliAgentTick();assert(watches==before && !g_ba.Bool(L"active"));writes=true;
    round();BiliAgentTick();BiliAgentSave();BiliAgentLoad();
    assert(g_ba.Get(L"tasks")->a[0].Str(L"status")==L"interrupted");

    round();g_baBusy=true;int old=g_baGeneration;BiliAgentCommand(L"stop");
    TaskData stale;stale.action=old;stale.ok=true;stale.text=LR"({"tasks":[{"status":"pending"}]})";
    BiliAgentOnPlan(&stale);assert(!g_baBusy && !BiliAgentPending());
    puts("bili scheduler lifecycle passed");
}
