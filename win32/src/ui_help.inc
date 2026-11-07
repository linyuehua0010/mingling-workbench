// ---------------------------------------------------------------- 求助 / 帮助
// 求助：「交给 Agent」那十一张任务卡，点一下就把那句话复制走，粘到 DSH 里发出去。
// 帮助：常见问题，用冥零的说法，底下配几个直达按钮。
// 这一页不联网、不跑命令，纯静态文字 + 剪贴板。

// 每张卡有个固定 id：settings.json 的 custom_help_texts 用它索引改写后的文字。
struct AskDef {
    const char* id;
    const wchar_t* title;
    const wchar_t* text;
};

static const AskDef ASKS[] = {
    {"role", L"换成我自己的角色",
     L"用冥零的安装 Skill（mingling-install），帮我把冥零换成我自己的角色：名字叫……，性格是……，说话像……。"},
    {"voice", L"换个声音",
     L"用冥零的安装 Skill（mingling-install），帮我给冥零换个更温柔的声音，先出三个让我听了再挑。"},
    {"breeze", L"换成 Breeze 在线版",
     L"用冥零的安装 Skill（mingling-install），帮我把语音换成 Breeze 在线版：先讲清楚按字扣积分，带我注册、把 API 密钥存进 private 文件，"
     L"再挑机灵版或迷糊版；关掉原来的语音，验到能播放。"},
    {"dialect", L"听懂更多方言",
     L"用冥零的安装 Skill（mingling-install），帮我给冥零装上语音识别的增强版，湖南话这类方言、歌词能认得更准："
     L"先告诉我要多下多大、会慢多少，我同意了再装。"},
    {"group", L"让她进我的 QQ 群",
     L"用冥零的安装 Skill（mingling-install），让冥零也在我的 QQ 群里聊，群号是……。"},
    {"silent", L"她不回话了",
     L"冥零不回话了。用冥零的安装 Skill（mingling-install） 帮我查查是哪出了问题，先只看不改，查完告诉我打算怎么修。"
     L"（工作台「求助信息」存在桌面的 txt 我一起发给你）"},
    {"always", L"电脑关机她也在线",
     L"用冥零的安装 Skill（mingling-install），帮我把这台电脑上的冥零搬到云服务器上（记忆、人设、表情包一起搬）："
     L"先讲清楚利弊和要花多少钱，我还没买的话帮我挑，我回「搬」了再动。"},
    {"napcat", L"QQ 升级后先换成 NapCat",
     L"用冥零的安装 Skill（mingling-install），QQ 升级后 SnowLuma 暂时用不了，帮我先换成 NapCat；等 SnowLuma 跟上了再告诉我怎么换回来。"},
    {"backup", L"用备份还原",
     L"用冥零的安装 Skill（mingling-install），用桌面上的备份……还原冥零：先列出要动哪些东西，我确认了再动。"},
    {"uninstall", L"卸载她",
     L"用冥零的安装 Skill（mingling-install），帮我把冥零卸干净：先列清单给我看，问我要不要先备份，我回「确认」了再删。"},
    {"memory", L"记忆没接上",
     L"工作台说记忆没接好，她记不住事。用冥零的安装 Skill（mingling-install） 帮我看看是缺硅基流动的密钥、还是本机记忆模型没下；"
     L"要花钱或下大文件先问我，不想弄就帮我把记忆关掉。"},
};

static wstring g_askNote = L"复制一句，粘到 DeepSeek Harness 里发出去。";
static DWORD g_askNoteAt = 0;

static map<wstring, wstring> g_askText;

static void LoadAskTexts() {
    g_askText.clear();
    std::wstring raw = SettingRaw(L"custom_help_texts");
    if (Trim(raw).empty()) return;
    bool ok = false;
    her::J j = her::J::Parse(raw, &ok);
    if (!ok || !j.Obj()) return;
    for (const auto& kv : j.o)
        if (kv.second.t == her::J::STR) g_askText[kv.first] = kv.second.s;
}

static std::wstring AskId(int i) { return Utf8ToW(ASKS[i].id); }

static std::wstring AskTitle(int i) {
    auto it = g_askText.find(AskId(i) + L".title");
    if (it != g_askText.end() && !Trim(it->second).empty()) return it->second;
    return ASKS[i].title;
}

static std::wstring AskBody(int i) {
    auto it = g_askText.find(AskId(i));
    if (it != g_askText.end() && !Trim(it->second).empty()) return it->second;
    return ASKS[i].text;
}

static void SetAskText(int i, const std::wstring& body) {
    std::wstring k = AskId(i);
    if (Trim(body).empty()) g_askText.erase(k);
    else g_askText[k] = body;
    if (g_askText.empty()) {
        SettingSet(L"custom_help_texts", L"");
        return;
    }
    her::J j = her::JObj();
    for (const auto& kv : g_askText) j.Set(kv.first, her::J(kv.second));
    SettingRawSet(L"custom_help_texts", j.Dump(2));
}

// ---- 改文字的小浮层：自绘面板 + 一个原生 EDIT 盖在上面
static HWND g_askEditor = nullptr;
static int g_askEditIdx = -1;

static void CloseAskEditor(bool save) {
    if (!g_askEditor) return;
    if (save && g_askEditIdx >= 0) {
        int n = (int)(sizeof(ASKS) / sizeof(ASKS[0]));
        if (g_askEditIdx < n) {
            std::wstring t;
            int len = GetWindowTextLengthW(g_askEditor);
            if (len > 0) {
                t.resize((size_t)len + 1);
                int got = GetWindowTextW(g_askEditor, &t[0], len + 1);
                t.resize(got > 0 ? (size_t)got : 0);
            }
            SetAskText(g_askEditIdx, Trim(t));
            UiToast(Trim(t).empty() ? L"这张卡回到默认那句了" : L"改好了，就按你的说法来");
        }
    }
    DestroyWindow(g_askEditor);
    g_askEditor = nullptr;
    g_askEditIdx = -1;
    if (g_hwnd) SetFocus(g_hwnd);
    UiRequestRepaint();
}

// 原生输入框要 GDI 字体（GDI+ 的 Font 换不出去）
static HFONT AskEditorFont() {
    static HFONT f = nullptr;
    if (!f)
        f = CreateFontW(-(int)S(15), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
    return f;
}

static void OpenAskEditor(int i) {
    int n = (int)(sizeof(ASKS) / sizeof(ASKS[0]));
    if (i < 0 || i >= n) return;
    if (g_askEditor) CloseAskEditor(false);
    g_askEditIdx = i;
    float w = S(520), h = S(300);
    int x = (int)((g_w - w) / 2.0f), y = (int)((g_h - h) / 2.0f);
    g_askEditor = CreateWindowExW(0, L"EDIT", AskBody(i).c_str(),
                                  WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL |
                                      ES_WANTRETURN,
                                  x + (int)S(20), y + (int)S(64), (int)(w - S(40)), (int)(h - S(124)), g_hwnd,
                                  (HMENU)0x9101, GetModuleHandleW(nullptr), nullptr);
    if (!g_askEditor) {
        g_askEditIdx = -1;
        UiToast(L"输入框没开起来，再点一次试试");
        return;
    }
    SendMessageW(g_askEditor, WM_SETFONT, (WPARAM)AskEditorFont(), TRUE);
    SendMessageW(g_askEditor, EM_SETSEL, 0, -1);
    SetFocus(g_askEditor);
    UiRequestRepaint();
}

bool UiAskEditorBusy() { return g_askEditor != nullptr; }

void UiAskEditorClose(bool save) {
    CloseAskEditor(save);
}

static void PaintAskEditor(Graphics& g) {
    SolidBrush veil(Color(150, 3, 5, 9));
    g.FillRectangle(&veil, RectF(0, 0, (float)g_w, (float)g_h));
    float w = S(520), h = S(300);
    float x = (g_w - w) / 2.0f, y = (g_h - h) / 2.0f;
    RectF pan(x, y, w, h);
    Round(g, pan, S(14), C_PANEL, C_ACCENT);
    int i = g_askEditIdx;
    Txt(g, L"改这张卡的说明", RectF(x + S(20), y + S(16), w - S(40), S(24)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT, 0);
    std::wstring sub = L"改的是「" + (i >= 0 ? wstring(ASKS[i].title) : wstring()) + L"」；留空就回到默认那句。";
    Txt(g, sub, RectF(x + S(20), y + S(44), w - S(40), S(18)), Fnt(MICRO_SIZE, 0, 0), C_FAINT, 0, true);
    Button(g, RectF(x + w - S(228), y + h - S(46), S(96), S(28)), L"保存", "askeditor:save", 1, true, true);
    Button(g, RectF(x + w - S(124), y + h - S(46), S(96), S(28)), L"取消", "askeditor:cancel", 0, true, true);
}

// 画在「帮助中心 → 求助」这一块里：坐标和尺寸由外面给
static void PaintAskBody(Graphics& g, const RectF& area) {
    float x0 = area.X, y0 = area.Y, w = area.Width, h = area.Height;

    // ---- 头
    float headH = S(92);
    RectF head(x0, y0, w, headH);
    Card(g, head, C_PANEL, C_LINE);
    Txt(g, L"交给 Agent", RectF(x0 + S(22), y0 + S(16), S(320), S(26)), Fnt(PAGE_TITLE_SIZE, 0, 0), C_TEXT, 0);
    Txt(g, L"换角色、换声音、搬家、修坏了，交给 DeepSeek Harness 里的 Agent。",
        RectF(x0 + S(22), y0 + S(46), w - S(340), S(18)), Fnt(HINT_SIZE, 1, 0), C_SUB, 0, true);
    Txt(g, g_askNote, RectF(x0 + S(22), y0 + S(68), w - S(340), S(18)), Fnt(HINT_SIZE, 1, 0),
        GetTickCount() - g_askNoteAt < 6000 ? C_ACCENT : C_FAINT, 0, true);
    Button(g, RectF(x0 + w - S(158), y0 + S(16), S(138), S(28)), g_mBusy ? L"在做…" : L"复制求助信息", "op:diag", 0, true, !g_mBusy);

    // ---- 十一张任务卡（2 列，最后一行一张）
    float gy = y0 + headH + S(14);
    float gap = S(12);
    float cw = (w - gap) / 2.0f;
    float chh = std::min((y0 + h - gy - gap * 5) / 6.0f, S(96));
    int n = (int)(sizeof(ASKS) / sizeof(ASKS[0]));
    for (int i = 0; i < n; i++) {
        int col = i % 2, row = i / 2;
        RectF c(x0 + col * (cw + gap), gy + row * (chh + gap), cw, chh);
        Round(g, c, S(13), C_PANEL, C_LINE);
        Dot(g, c.X + S(18), c.Y + S(22), S(3.4f), C_ACCENT2);
        Txt(g, AskTitle(i), RectF(c.X + S(28), c.Y + S(12), c.Width - S(150), S(22)), Fnt(SUBTITLE_SIZE, 0, 0), C_TEXT, 0, true);
        TxtWrap(g, AskBody(i), RectF(c.X + S(28), c.Y + S(36), c.Width - S(150), chh - S(46)), Fnt(HINT_SIZE, 1, 0), C_SUB, 0);
        RectF b(c.X + c.Width - S(112), c.Y + chh - S(34), S(96), S(24));
        bool hov = Hov("ask:" + std::to_string(i));
        Round(g, b, S(8), hov ? C_ACCENT : C_ACCENT_S, hov ? C_ACCENT : C_LINE);
        Txt(g, L"复制这句", b, Fnt(HINT_SIZE, hov ? 0 : 1, 0), hov ? 0xFFFFFFFF : C_ACCENT, 1);
        AddHit(b, "ask:" + std::to_string(i));
        Button(g, RectF(c.X + c.Width - S(206), c.Y + chh - S(34), S(84), S(24)), L"改文字",
               "askedit:" + std::to_string(i), 0, true, true);
    }
    if (g_askEditor) PaintAskEditor(g);
}

// ---------------------------------------------------------------- 帮助
static float g_helpScroll = 0;
static float g_helpH = 0;
static RectF g_rcHelp;

static const wchar_t* FAQ_TEXT =
    L"══════════ 怎么跟她聊 ══════════\n"
    L"用你的大号私聊她，群里就 @ 她。别人她不理。想让她忘掉之前聊的，私聊发 /reset。\n"
    L"她的话要经过 DeepSeek，所以得有网、有余额。\n"
    L"\n"
    L"══════════ 她不回我了 ══════════\n"
    L"先看「维护」页：哪张卡是红的，就点那张卡上的修复按钮。\n"
    L"还是不行，点「复制求助信息」——她会把日志、版本、配置打包成桌面上的 txt，再回「帮助中心 → 求助」复制「她不回话了」那句，一起发给 Agent。\n"
    L"\n"
    L"══════════ 小号被踢下线 ══════════\n"
    L"QQ 风控挺严，小号偶尔被踢很正常，不是坏了。点「重登 QQ」，照弹出来的窗口做（有头像点登录，是二维码就用小号的手机扫）。\n"
    L"同一个小号别在两处同时挂机器人，会互相挤掉。\n"
    L"\n"
    L"══════════ 一个月花多少 ══════════\n"
    L"聊天走 DeepSeek，按用量扣：私聊很省，群聊和发图费一点。本机 Breeze 语音不花钱（用你的显卡）。\n"
    L"余额在「维护」页 DeepSeek 那张卡上，点「看每天花了多少」看明细。\n"
    L"\n"
    L"══════════ 开机以后要做什么 ══════════\n"
    L"什么都不用做。双击桌面「冥零工作台」，点「全部启动」，等一两分钟她就在线了。\n"
    L"任务栏里那几个最小化的黑窗口别关，关了她就下线。桌面 QQ 要设成开机自启、登录时勾「自动登录」。\n"
    L"\n"
    L"══════════ 打游戏的时候 ══════════\n"
    L"「维护」页右上角点「开打游戏模式」：把本机语音（Breeze 占显存）和记忆（Ollama 占内存）先关掉，她照样回消息，只是只打字、这段时间说的事不记。\n"
    L"打完点「打完了，恢复」。忘了点也没事，重启电脑会自己恢复。\n"
    L"\n"
    L"══════════ 她掉线了怎么知道 ══════════\n"
    L"「维护」页「掉线提醒」开着的话，小号掉线会在右下角弹一条通知，点一下就能重登。\n"
    L"点「试一条」可以先看看通知长什么样；不想被打扰就点「关」。\n"
    L"\n"
    L"══════════ 她能看 B 站 ══════════\n"
    L"群里 @ 她 发链接，或者工作台「B站」页挑一条点「让她看」。\n"
    L"工作台的 B 站能力是内置的，装好就能用，不需要另装 DeepSeek Harness。\n"
    L"结果会写进「队列」页；封面、九宫格、字幕、原片在「工作区\\out\\<BV>\\」，正文在 logs/jobs/ 下。\n"
    L"\n"
    L"══════════ 文件都放在哪 ══════════\n"
    L"看 B 站的产物在「工作区」的 out\\<BV>\\（封面、九宫格、字幕条、原片），中间文件在 tmp，日志和台账在 logs。\n"
    L"工作区在「维护」页点「打开工作区」就能看到，也可以换到别的盘；换的时候会问你要不要搬旧文件。\n"
    L"凭据、日记、限额这些状态在用户配置目录，备份时会一起打包。\n"
    L"\n"
    L"══════════ 换电脑、重装系统前 ══════════\n"
    L"先点「备份到桌面」把那个 zip 拷走。新电脑上装到能聊天，再去「帮助中心 → 求助」复制「用备份还原」那句。\n"
    L"看 B 站的 out/logs 数据不在这份备份里，换电脑时把整个工作区文件夹一起拷走。\n"
    L"备份里有你的密钥，别发给别人。\n"
    L"\n"
    L"══════════ 这个窗口关了会怎样 ══════════\n"
    L"不影响她。工作台只是看看、修修，关了她照常在 QQ 上聊。想再看就双击桌面图标。\n"
    L"\n"
    L"══════════ 键盘和快捷键 ══════════\n"
    L"@@HOTKEYS@@\n"
    L"\n"
    L"══════════ 关于 ══════════\n"
    L"冥零工作台 " APP_VERSION L" · 单个 exe，Win32 + GDI+ 自绘，不挂浏览器内核。\n";

static std::wstring HelpText() {
    std::wstring t = FAQ_TEXT;
    // 页签数、快捷键跟着 TABS 走，别在文案里写死
    {
        int n = (int)(sizeof(TABS) / sizeof(TABS[0]));
        std::wstring hk = (n > 1 ? (L"1–" + std::to_wstring(n)) : std::wstring(L"1")) +
                          L" 切左侧页签（0 跳到最后），F5 刷新当前页，F9 全部启动，F10 全部关闭。";
        size_t at = t.find(L"@@HOTKEYS@@");
        if (at != std::wstring::npos) t.replace(at, 11, hk);
    }
    t += L"\n══════════ 当前路径 ══════════\n";
    t += L"工作区：" + WorkspaceDir() + L"\n";
    t += L"台账：" + JobsFile() + L"\n";
    t += L"状态：" + StateDir() + L"\n";
    t += L"\n══════════ 组件路径 ══════════\n";
    t += L"组件根：" + BotRoot() + L"\n";
    t += L"AstrBot：" + her::BotPath(L"AstrBot") + L"\n";
    t += L"SnowLuma：" + her::BotPath(L"SnowLuma") + L"\n";
    t += L"Breeze：" + her::BotPath(L"Breeze") + L"\n";
    t += L"Ollama：" + her::BotPath(L"Ollama") + L"\n";
    return t;
}

// 画在「帮助中心 → 帮助」这一块里：坐标和尺寸由外面给
static void PaintHelpBody(Graphics& g, const RectF& area) {
    float x0 = area.X, y0 = area.Y, w = area.Width, h = area.Height;

    float headH = S(96);
    RectF head(x0, y0, w, headH);
    Card(g, head, C_PANEL, C_LINE);
    // 教程：随安装包带的几篇，离线读
    Txt(g, L"教程", RectF(x0 + S(22), y0 + S(12), S(60), S(22)), Fnt(HINT_SIZE, 0, 0), C_SUB, 0);
    DocChipRow(g, x0 + S(74), y0 + S(8), w - S(330));
    if (g_docSel >= 0) {
        Button(g, RectF(x0 + w - S(198), y0 + S(6), S(96), S(30)), L"用系统打开", "docopen", 0, true, true);
        Button(g, RectF(x0 + w - S(96), y0 + S(6), S(74), S(30)), L"回 FAQ", "docback", 0, true, true);
    }

    struct Btn { const wchar_t* label; const char* id; };
    static const Btn bs[6] = {
        {L"打开说明", "doc:readme"},
        {L"工作目录", "doc:base"},
        {L"日志目录", "doc:logs"},
        {L"台账文件", "doc:jobs"},
        {L"美术素材", "doc:art"},
        {L"组件目录", "doc:bots"},
    };
    Txt(g, L"文件", RectF(x0 + S(22), y0 + S(58), S(60), S(22)), Fnt(HINT_SIZE, 0, 0), C_SUB, 0);
    float bw = S(88), bx = x0 + S(74);
    for (int i = 0; i < 6; i++) {
        Button(g, RectF(bx + i * (bw + S(8)), y0 + S(52), bw, S(28)), bs[i].label, bs[i].id, 0, true, true);
    }

    // ---- 正文：富文本 + 滚动
    RectF panel(x0, y0 + headH + S(12), w, (y0 + h) - (y0 + headH + S(12)));
    Card(g, panel, C_PANEL, C_LINE);
    RectF text(panel.X + S(22), panel.Y + S(16), panel.Width - S(44), panel.Height - S(32));
    g_rcHelp = text;
    float total = 0;
    if (g_docSel >= 0) {
        DocLoad(g_docSel);
        wstring name = (g_docSel >= 0 && g_docSel < DOC_COUNT) ? wstring(DOCS[g_docSel].file) : wstring();
        Txt(g, name + L"　·　随安装包带的，不联网", RectF(text.X, text.Y, text.Width, S(22)),
            Fnt(MICRO_SIZE, 0, 0), C_FAINT, 0, true);
        RectF body(text.X, text.Y + S(26), text.Width, text.Height - S(26));
        g_rcHelp = body;
        total = DrawDoc(g, body, g_docScroll) + S(26);
    } else {
        total = DrawRich(g, HelpText(), text, g_helpScroll);
    }
    g_helpH = total;
    ScrollBar(g, text, g_docSel >= 0 ? g_docScroll : g_helpScroll, total);
}
