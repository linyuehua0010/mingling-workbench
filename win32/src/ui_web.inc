// 把 snapshot-2 那套状态和动作接给 HTML；业务逻辑不搬到前端来。
wstring WebUiState() {
    using namespace her;
    J s = JObj();
    s.Set(L"version", APP_VERSION); s.Set(L"tab", g_tab); s.Set(L"bsec", g_bSec);
    s.Set(L"clock", g_clock); s.Set(L"workspace", WorkspaceDir());
    s.Set(L"toast", GetTickCount() - g_toastAt < 4000 ? g_toast : L"");
    s.Set(L"watchBusy", g_watchBusy); s.Set(L"feedBusy", g_feedBusy);
    s.Set(L"checkBusy", g_checkBusy); s.Set(L"maintBusy", g_mBusy);
    s.Set(L"watchStatus", g_watchStatus); s.Set(L"progress", g_watchPct);
    s.Set(L"feedNote", g_feedNote); s.Set(L"input", g_bvInput);
    s.Set(L"check", g_checkText); s.Set(L"log", g_logText); s.Set(L"logsrc", g_logSrc);
    s.Set(L"result", g_result.raw); s.Set(L"resultTitle", g_result.title);
    s.Set(L"resultOk", g_hasResult); s.Set(L"jobDetail", g_jobDetail);
    s.Set(L"dsh", g_dshErr.empty() ? g_dshText : g_dshErr); s.Set(L"dshBusy", g_dshBusy);
    s.Set(L"note", g_mNote); s.Set(L"lastOp", g_mLastOp);
    J stats = JArr(); for (auto v : {g_mMsg, g_mReply, g_mToken, g_mMem}) stats.Push(J(v)); s.Set(L"stats", stats);
    J services = JArr();
    for (int i = 0; i < 2; ++i) { J v = JObj(); v.Set(L"name", SVCS[i].name); v.Set(L"desc", SVCS[i].desc); v.Set(L"port", SVCS[i].port); v.Set(L"up", g_svcUp[i]); v.Set(L"pid", (int)g_svcPid[i]); services.Push(v); }
    s.Set(L"services", services);
    J items = JArr();
    for (auto& i : g_mItems) { J v = JObj(); v.Set(L"name", i.name); v.Set(L"state", StateWord(i.state)); v.Set(L"text", i.text); v.Set(L"fix", i.fixAct); v.Set(L"fixLabel", i.fixLbl); v.Set(L"linkLabel", i.linkLbl); items.Push(v); }
    s.Set(L"items", items);
    J feed = JArr(); for (auto& i : g_feed) { J v = JObj(); v.Set(L"title", i.title); v.Set(L"up", i.up); v.Set(L"bv", i.bv); v.Set(L"dur", i.dur); feed.Push(v); } s.Set(L"feed", feed);
    J jobs = JArr(); for (auto& i : g_jobs) { J v = JObj(); v.Set(L"title", i.title.empty() ? i.bv : i.title); v.Set(L"source", i.source); v.Set(L"status", i.status); v.Set(L"type", i.type); v.Set(L"seconds", i.seconds); v.Set(L"time", i.t); jobs.Push(v); } s.Set(L"jobs", jobs);
    J features = JArr();
    const wchar_t* names[] = {L"astrbot_plugin_dafeiyu_petlink", L"astrbot_plugin_dafeiyu_sing", L"astrbot_plugin_seed_audio_tts", L"astrbot_plugin_breeze_online_tts"};
    for (auto n : names) features.Push(J(FeatureOn(n, false)));
    s.Set(L"features", features); s.Set(L"memory", ModeNum(L"memory", 0)); s.Set(L"voice", ModeNum(L"voice", 0));
    s.Set(L"group", g_mGroup); s.Set(L"meme", g_mMeme); s.Set(L"voiceFreq", g_mVoice);
    s.Set(L"watchOn", g_mWatchOn); s.Set(L"gameOn", g_mGameOn); s.Set(L"gameCan", g_mGameCan);
    J asks = JArr(); for (int i = 0; i < (int)(sizeof(ASKS)/sizeof(ASKS[0])); ++i) { J v = JObj(); v.Set(L"title", AskTitle(i)); v.Set(L"body", AskBody(i)); asks.Push(v); } s.Set(L"asks", asks);
    J docs = JArr(); for (auto& i : DOCS) { J v = JObj(); v.Set(L"id", i.id); v.Set(L"title", i.title); v.Set(L"hint", i.hint); docs.Push(v); } s.Set(L"docs", docs); s.Set(L"doc", g_docSrc); s.Set(L"docsel", g_docSel);
    J updates = JArr(); for (auto& i : g_up.items) { J v = JObj(); v.Set(L"id", i.id); v.Set(L"name", i.name); v.Set(L"local", i.local); v.Set(L"latest", i.latest); v.Set(L"state", i.state); v.Set(L"what", i.what); updates.Push(v); } s.Set(L"updates", updates); s.Set(L"updateBusy", g_upBusy); s.Set(L"updateError", g_up.err); s.Set(L"updateProgress", g_upProg); s.Set(L"updateMessage", g_upMsg);
    if (g_notify) { J n = JObj(); n.Set(L"title", g_notify->title); n.Set(L"body", g_notify->body); s.Set(L"notify", n); }
    if (g_tab == 1 && g_bSec == 3) {
        J rows = JArr();
        for (size_t i = 0; i < BiliCfgFields().size(); ++i) { auto& f = BiliCfgFields()[i]; J v = JObj(); v.Set(L"label", f.label); v.Set(L"hint", f.hint); v.Set(L"kind", f.kind); v.Set(L"value", BiliCfgShow(g_bcfgRoot, f)); rows.Push(v); } s.Set(L"bconfig", rows);
        rows = JArr();
        for (auto& r : g_lcRows) if (r.src) { J v = JObj(); v.Set(L"row", (int)(&r - g_lcRows.data())); v.Set(L"label", LcLabel(r)); v.Set(L"hint", LcHint(r)); v.Set(L"kind", LcKind(r)); v.Set(L"value", LcKind(r) == 5 ? L"" : r.src == 1 && r.idx == 3 ? g_lcLink.ua : LcShow(r)); rows.Push(v); }
        s.Set(L"lconfig", rows);
        s.Set(L"configNote", g_bcfgMsg + L" " + g_lcMsg);
    }
    return s.Dump();
}

void WebUiCommand(const wstring& message) {
    using namespace her;
    if (message.size() > 128000) return;
    bool ok = false; J m = J::Parse(message, &ok); if (!ok || !m.Obj()) return;
    wstring cmd = m.Str(L"cmd"), value = m.Str(L"value"); int index = (int)m.Int(L"index", -1);
    if (cmd == L"ready") { RefreshStatus(false); return; }
    if (cmd == L"tab" && index >= 0 && index < 7) { DispatchAction("tab:" + std::to_string(index)); return; }
    if (cmd == L"section" && index >= 0 && index < 4) {
        g_bSec = index;
        if (index == 3) { BiliCfgOpen(); LinkCfgOpen(); }
        return;
    }
    if (cmd == L"watch") { if (value.size() > 8192) return; g_bvInput = value; g_tab = 1; g_bSec = 1; StartWatch(); return; }
    if (cmd == L"feed") { RefreshFeed(); return; }
    if (cmd == L"pick" && index >= 0 && index < (int)g_feed.size()) { g_bvInput = g_feed[index].bv; g_bSec = 1; return; }
    if (cmd == L"job" && index >= 0 && index < (int)g_jobs.size()) { g_jobSel = index; LoadJobDetail(index); return; }
    if (cmd == L"log" && index >= 0 && index < 3) { g_logSrc = index; RefreshLogsNow(); return; }
    if (cmd == L"check" && index >= 0 && index < 5) { RunCheck(index); return; }
    if (cmd == L"service" && index >= 0 && index < 2) { if (value == L"start") StartService(index); else if (value == L"stop") StopService(index); return; }
    if (cmd == L"doc" && index >= 0 && index < DOC_COUNT) { g_docSel = index; DocLoad(index); return; }
    if (cmd == L"askcopy" && index >= 0 && index < (int)(sizeof(ASKS)/sizeof(ASKS[0]))) { CopyText(AskBody(index)); UiToast(L"复制好了，发给 Agent 就行。"); return; }
    if (cmd == L"asksave" && index >= 0 && index < (int)(sizeof(ASKS)/sizeof(ASKS[0])) && value.size() < 16000) { SetAskText(index, value); UiToast(L"记下了。"); return; }
    if (cmd == L"configsave") {
        const J* fields = m.Get(L"fields"); if (!fields || !fields->Arr()) return;
        wstring err;
        // 「链接与对话 API」那张表先在内存草稿上校验，通过才落盘。
        if (value == L"link") {
            LinkCfg oldLink = g_lcLink; DshApiCfg oldApi = g_lcApi;
            for (auto& f : fields->a) {
                int r = (int)f.Int(L"row", -1);
                if (r < 0 || r >= (int)g_lcRows.size() || !g_lcRows[r].src) continue;
                if (LcKind(g_lcRows[r]) == 5 && f.Str(L"value").empty()) continue;
                if (!LcApply(g_lcRows[r], f.Str(L"value"), &err)) { g_lcLink = oldLink; g_lcApi = oldApi; UiToast(err); return; }
            }
            LinkCfgClose(true);
        } else if (value == L"bili") {
            J draft = g_bcfgRoot;
            for (auto& f : fields->a) { int r = (int)f.Int(L"row", -1); if (r < 0 || r >= (int)BiliCfgFields().size() || BiliCfgFields()[r].kind == 4) continue;
                if (!BiliCfgApply(draft, BiliCfgFields()[r], f.Str(L"value"), &err)) { UiToast(err); return; }
            }
            g_bcfgRoot = draft; BiliCfgClose(true);
        }
        return;
    }
    if (cmd != L"action") return;
    // 只认下面这张白名单：不让 HTML 传任意命令、URL、路径或操作。
    const wchar_t* allowed[] = { L"btn:allstart", L"btn:allstop", L"btn:copy", L"btn:copy_job", L"btn:jobs_refresh", L"btn:log_refresh", L"btn:logdir", L"btn:diary", L"btn:open_sheet", L"btn:open_cover", L"btn:open_shotdir", L"doc:base", L"doc:bots", L"doc:logs", L"doc:jobs", L"docopen", L"ws:pick", L"mref", L"up:refresh", L"up:wbgo", L"up:wbdl", L"upact:skill", L"upact:astrbot", L"upact:snowluma", L"op:restart_brain", L"op:relogin", L"op:restart_qq", L"op:backup", L"op:diag", L"op:start_breeze", L"op:start_ollama", L"op:autostart_fix", L"op:autosetup", L"op:selfsetup", L"op:import_skill", L"op:skill_update", L"op:watch_on", L"op:watch_off", L"op:watch_every", L"op:watch_test", L"op:game_on", L"op:game_off", L"op:game_hint", L"notify:close", L"notify:fix" };
    if (value == L"dsh") { if (!g_dshBusy && g_hasResult) DshAsk(); return; }
    if (value == L"testapi") { if (!g_lcTestBusy) LinkCfgTest(); return; }
    for (auto a : allowed) if (value == a) {
        // 配置面板开着的时候，旧的分发器会把什么都往那儿送，这里只临时关掉分区。
        int tab = g_tab, sec = g_bSec; g_bSec = 0;
        DispatchAction(WToUtf8(value));
        if (g_tab == tab) g_bSec = sec;
        return;
    }
    for (size_t i = 0; i < g_mItems.size(); ++i) {
        if (!g_mItems[i].fixAct.empty() && value == L"fix:" + g_mItems[i].fixAct) { RunHerOp(g_mItems[i].fixAct, L""); return; }
        if (value == L"lnk:" + Num(i)) { DispatchAction(WToUtf8(value)); return; }
    }
    const wchar_t* plugins[] = {L"astrbot_plugin_dafeiyu_petlink", L"astrbot_plugin_dafeiyu_sing", L"astrbot_plugin_seed_audio_tts", L"astrbot_plugin_breeze_online_tts"};
    for (auto p : plugins) for (int n = 0; n < 2; ++n) if (value == L"plugin/" + wstring(p) + L"/" + Num(n)) { StartFeature(value); return; }
    for (auto spec : {L"memory/0", L"memory/1", L"memory/2", L"voice/0", L"voice/1", L"voice/3", L"voice/4", L"voice/5"}) if (value == spec) { StartFeature(value); return; }
    for (auto k : {L"group", L"meme", L"voice"}) for (auto v : {L"off", L"mention", L"quote", L"both", L"few", L"mid", L"many"}) if (value == L"freq:" + wstring(k) + L":" + v) { DispatchAction(WToUtf8(value)); return; }
}
