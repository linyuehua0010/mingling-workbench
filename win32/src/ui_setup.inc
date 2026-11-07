// ---------------------------------------------------------------- 功能开关（并进「维护」页）
// 配置包里默认关着的几样（桌宠、唱歌、豆包语音、在线 Breeze）和记忆/语音路线，
// 都在「维护」页下半截点。点一下只写 private\*.txt 覆盖文件，真正接上去是跑一次自设定块；
// 缺 key、缺音色什么的，脚本会明说。

// 点一下：先写覆盖，再跑对应块。不阻塞界面。
static void StartFeature(const std::wstring& spec) {
    if (g_mBusy) {
        UiToast(L"上一件事还在做，等它一会儿");
        return;
    }
    std::wstring block = L"plugins";
    if (spec.rfind(L"memory/", 0) == 0) block = L"memory";
    else if (spec.rfind(L"voice/", 0) == 0) block = L"plugins,voice";
    her::ActionResult r = her::SetFeature(spec);
    if (!r.ok) {
        UiToast(r.msg);
        return;
    }
    RunHerOp(L"selfsetup", block);
}

struct FeatOpt {
    const wchar_t* label;
    const wchar_t* spec;   // plugin/<名字>/<值>、memory/<值>、voice/<值>
    int val;
};

static void SetupRow(Graphics& g, float x, float y, float w, float rowH, const wchar_t* title, const wchar_t* desc,
                     const FeatOpt* opts, int n, int cur) {
    RectF card(x, y, w, rowH);
    Round(g, card, S(14), C_PANEL, C_LINE);
    Txt(g, title, RectF(x + S(22), y + S(14), S(260), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0, true);
    Txt(g, desc, RectF(x + S(22), y + S(42), w - S(360), S(20)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);
    // 选项从右往左排，选中的那个是蓝底
    float cw = S(96), chh = S(30), bx = x + w - S(18);
    for (int i = n - 1; i >= 0; i--) {
        bx -= cw;
        RectF r(bx, y + (rowH - chh) / 2, cw, chh);
        std::string id = "op:feat:" + WToUtf8(opts[i].spec);
        Button(g, r, opts[i].label, id, opts[i].val == cur ? 1 : 0, true, !g_mBusy);
        bx -= S(8);
    }
}

// 画在「维护」页下半截：标题一行 + 六行开关。返回这一段占的高度。
static float PaintFeatures(Graphics& g, float x0, float y0, float w, float rowH, float gap) {
    Txt(g, L"功能", RectF(x0 + S(4), y0 + S(6), S(200), S(24)), Fnt(TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"配置包里默认关着的几样，点一下就开：写 private\\，再跑一次自设定接上。",
        RectF(x0 + S(74), y0 + S(11), w - S(90), S(20)), Fnt(HINT_SIZE, 1, 0), C_FAINT, 0, true);

    float ry = y0 + S(40);
    auto pluginRow = [&](const wchar_t* title, const wchar_t* desc, const wchar_t* name, float y) {
        bool on = her::FeatureOn(name, false);
        std::wstring sOn = std::wstring(L"plugin/") + name + L"/1";
        std::wstring sOff = std::wstring(L"plugin/") + name + L"/0";
        FeatOpt o[2] = {{L"开", sOn.c_str(), 1}, {L"关", sOff.c_str(), 0}};
        SetupRow(g, x0, y, w, rowH, title, desc, o, 2, on ? 1 : 0);
    };
    pluginRow(L"桌宠", L"让桌宠跟她用同一份人设，聊天记录也共用（petlink）。", L"astrbot_plugin_dafeiyu_petlink", ry);
    pluginRow(L"唱歌", L"群里让她点歌唱歌，要装 ffmpeg（sing）。", L"astrbot_plugin_dafeiyu_sing", ry + rowH + gap);
    pluginRow(L"豆包语音", L"用火山豆包的 Seed Audio 发声音，要 app id 和 token。",
              L"astrbot_plugin_seed_audio_tts", ry + 2 * (rowH + gap));
    pluginRow(L"在线 Breeze 语音", L"用 Breeze 线上音色，不占这台电脑，要密钥和 voc_ 音色 ID。",
              L"astrbot_plugin_breeze_online_tts", ry + 3 * (rowH + gap));

    FeatOpt memo[3] = {{L"关", L"memory/0", 0}, {L"本机 bge-m3", L"memory/1", 1}, {L"硅基流动", L"memory/2", 2}};
    SetupRow(g, x0, ry + 4 * (rowH + gap), w, rowH, L"长期记忆",
             L"她记住聊过的事；本机跑 Ollama，不花钱（要拉过 bge-m3）。",
             memo, 3, her::ModeNum(L"memory", 0));

    FeatOpt voic[5] = {{L"关", L"voice/0", 0},          {L"Edge", L"voice/1", 1},
                       {L"豆包", L"voice/3", 3},        {L"本机 Breeze", L"voice/4", 4},
                       {L"在线 Breeze", L"voice/5", 5}};
    SetupRow(g, x0, ry + 5 * (rowH + gap), w, rowH, L"语音路线",
             L"她说话用什么嗓子；本机 Breeze 用的是你给她做的音色。",
             voic, 5, her::ModeNum(L"voice", 0));

    return S(40) + 6 * (rowH + gap);
}
