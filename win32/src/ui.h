#pragma once
#include "core.h"

#define WM_APP_JOB (WM_APP + 1)
#define WM_APP_TOAST (WM_APP + 2)
#define WM_APP_PROGRESS (WM_APP + 3)
#define WM_APP_AUTOCFG (WM_APP + 4)
#define WM_APP_NOTIFY (WM_APP + 6)


enum TaskKind {
    TK_NONE = 0,
    TK_FEED = 1,
    TK_WATCH = 2,
    TK_CHECK = 3,
    TK_START = 4,
    TK_STOP = 5,
    TK_DIARY = 6,
    TK_STATUS = 7,
    TK_OP = 8,
    TK_UPDATES = 9,
    TK_DSHTEST = 10,   // DSH 对话 API：action 0=测试连接 1=问一句 2=链接与应用测试连接
    TK_SELFUPD = 11    // 工作台一键更新：ptr = her::UpdatePlan*（归 UiOnTask 释放）
};

struct TaskData {
    int kind = TK_NONE;
    int action = 0;              // TK_CHECK: 0=session 1=deps 2=quota 3=traffic 4=selftest
    bool ok = false;
    wstring text;                // 原始输出
    wstring bv, title, up, status, seconds, sink;
    wstring opName, opArg;       // TK_OP：跑的是哪个动作
    wstring type;                // TK_WATCH：空 = 看片，"link" = 读网页
    void* ptr = nullptr;         // TK_UPDATES：her::UpdatesInfo*（归 UiOnTask 释放）
    Debrief debrief;
    vector<FeedItem> feed;
    ~TaskData() {}
};

// 掉线提醒：后台心跳把要说的话装进这个结构，PostMessage(WM_APP_NOTIFY) 交给窗口线程。
// 窗口线程接管所有权（画完横幅自己 delete），所以别在别的线程留指针。
struct NotifyReq {
    std::wstring title;    // 标题，来自 settings.json 的 notify_title
    std::wstring body;     // 正文，{name} {time} 已经替换过
    std::wstring avatar;   // 自定义头像 png（空 = 用 art\avatar.png）
    std::wstring act;      // 「重启一下」按哪个动作（relogin / restart_brain / start_breeze）
};

void UiInit(HWND hwnd);
void UiPaint(HDC hdc, int w, int h);
void UiOnClick(int x, int y);
void UiOnRClick(int x, int y);   // 输入框右键菜单
void UiOnMove(int x, int y);
bool UiOnWheel(int x, int y, int delta);
void UiOnChar(unsigned int ch);
void UiOnKeyDown(int vk);
void UiTick();
void UiOnTask(TaskData* d);
void UiOnProgress();          // 后台线程 PostMessage(WM_APP_PROGRESS) 后调它
void UiOnAutoCfg(int pct, wstring* step);   // 同上，WM_APP_AUTOCFG：接管 step（new wstring）
void UiOnNotify(NotifyReq* r);              // WM_APP_NOTIFY：接管 r（含所有权）
bool UiAskEditorBusy();
void UiAskEditorClose(bool save);
HICON UiBalloonIcon(const std::wstring& png, int size);
void UiToast(const wstring& msg);
void UiShutdown();
void UiRequestRepaint();
