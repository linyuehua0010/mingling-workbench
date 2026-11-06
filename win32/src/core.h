// 冥零工作台 · C++ 版公共声明
// 只依赖 Win32 + GDI+，目标：常驻内存 10~20MB，秒开、没有浏览器内核。
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <windowsx.h>
#include <objidl.h>
#include <propidl.h>
#include <gdiplus.h>

#include <string>
#include <vector>
#include <map>
#include <thread>
#include <atomic>
#include <algorithm>

using std::wstring;
using std::vector;
using std::map;

// ---------------------------------------------------------------- 文件 / 文本
wstring ExeDir();
wstring UserProfile();
wstring JoinPath(const wstring& a, const wstring& b);
bool FileExists(const wstring& p);
bool DirExists(const wstring& p);
wstring ReadTextFile(const wstring& path, size_t maxBytes = 0);
bool WriteTextFile(const wstring& path, const wstring& text, bool append = false);

wstring Trim(const wstring& s);
vector<wstring> SplitLines(const wstring& s);
wstring ReplaceAll(wstring s, const wstring& from, const wstring& to);
// B站标题里带 &amp; &#39; 这类实体，画之前换成真字符
wstring UnescapeHtml(const wstring& s);
bool StartsWith(const wstring& s, const wstring& p);
bool Contains(const wstring& s, const wstring& p);
bool IContains(const wstring& s, const wstring& p);   // 大小写不敏感
wstring Utf8ToW(const std::string& s);
std::string WToUtf8(const wstring& s);
wstring Num(long long v);
wstring Pad2(int v);

wstring NowStamp();                       // 2026-11-03 23:16:12
wstring TodayStr();                       // 2026-11-03
long long NowUnix();
wstring PrettyBytes(double bytes);

// ---------------------------------------------------------------- 路径 / 设置 / 内置 sidecar
// 契约见 paths.cpp 顶部注释：产物只落 <工作区>\out\<bv>、tmp、logs。
wstring ParentDir(const wstring& p);
wstring AppDir();
wstring StateDir();                       // %APPDATA%\MinglingWorkbench
wstring SettingsFile();
wstring SettingGet(const wstring& key);
void SettingSet(const wstring& key, const wstring& value);
// 任意 JSON 值的原文读写：字典/数组也能存（custom_help_texts 用）。
wstring SettingRaw(const wstring& key);
void SettingRawSet(const wstring& key, const wstring& jsonValue);
wstring DefaultWorkspaceDir();            // 开发树=<仓库>，安装版=文档\冥零工作台
wstring WorkspaceDir();                   // MINGLING_WORKSPACE → settings.json → 默认
void SetWorkspaceDir(const wstring& dir);
wstring BaseDir();                        // SnowLuma/AstrBot 的上一级，默认=工作区上级
void SetBaseDir(const wstring& dir);
// 组件根：五个组件统一放 <工作区>\bots（老机器散在 Base 下，由 her::BotPath 兜底）
wstring BotRoot();
wstring BotDir(const wstring& name);
void EnsureWorkspaceLayout(const wstring& root);
// 密钥目录：%MINGLING_SECRETS% → settings 的 secrets 键 → <Base>\secrets。
wstring SecretsDir();
// secrets\name 优先，private\name 兜底；两边都没有时返回「应该放在哪」。
wstring SecretFile(const wchar_t* name);
bool EnsureSecrets();                     // 建目录 + README（幂等）
wstring SidecarDir();                     // <exe>\sidecar（或 <exe>\..\sidecar）
wstring SidecarWhaleDir();
wstring SidecarNodeExe();                 // <sidecar>\node\node.exe
wstring SidecarFfmpegExe();               // <sidecar>\ffmpeg\bin\ffmpeg.exe 等
wstring PickFolder(HWND owner, const wstring& title, const wstring& initial);
void MigrateWorkspaceData(const wstring& from, const wstring& to);
// 首次启动时把「应用和功能」卸载项写到 HKCU（安装器可能没有权限写这条键）。
void RegisterUninstallEntry();

// ---------------------------------------------------------------- 网络 / 进程
bool PortOpen(int port, int timeoutMs = 250);
DWORD PidOnPort(int port);
bool KillPid(DWORD pid);
vector<int> ListPidsOf(const wstring& exeNameLower);

struct CmdResult {
    int code = -1;
    bool started = false;
    bool timeout = false;
    wstring out;
};

typedef vector<std::pair<wstring, wstring>> EnvList;   // key=value 覆盖项

CmdResult RunCapture(const wstring& exe, const wstring& args, const wstring& cwd,
                     const EnvList& env, int timeoutMs = 120000);
// 逐行回调版：stdout/stderr 走管道，读到一行就回调一次（UI 用它画进度）
typedef void (*StreamCb)(const wstring& line, void* user);
CmdResult RunCaptureStream(const wstring& exe, const wstring& args, const wstring& cwd,
                           const EnvList& env, int timeoutMs, StreamCb cb, void* user);
DWORD SpawnDetached(const wstring& exe, const wstring& args, const wstring& cwd,
                    const EnvList& env, const wstring& logPath);
wstring TailFile(const wstring& path, int lines, size_t maxBytes = 240000);

// ---------------------------------------------------------------- bili-whale
struct WhaleEnv {
    bool ok = false;
    wstring node;        // node.exe
    wstring mjs;         // tools/bili.mjs
    wstring pkgDir;      // 包目录（cwd）
    wstring dshDir;      // 兼容字段（旧 ~/.dsh，现在不用）
    wstring stateDir;    // %APPDATA%\MinglingWorkbench\bili-state（DSH_HOME）
    wstring config;      // bili-whale.config.json
    wstring creds;       // ~/.bili-ai/credentials.json
    wstring diary;       // 日记 md
    wstring err;
};

WhaleEnv FindWhale();
CmdResult RunWhale(const wstring& args, int timeoutMs = 120000);

struct FeedItem {
    wstring bv, title, up, dur, dm, play;
};

struct Debrief {
    bool ok = false;
    wstring raw;        // 脚本原始输出
    wstring title, up, stat;
    wstring section[8]; // ①..⑥ 分节文本
    wstring sheet, subs, cover;
    float seconds = 0;
};

vector<FeedItem> ParseFeed(const wstring& out);
Debrief ParseDebrief(const wstring& out);
wstring ExtractBv(const wstring& text);

// ---------------------------------------------------------------- 任务记录（和 QQ 插件共用一份）
struct JobRec {
    long long t = 0;
    wstring bv, title, up, source, chat, status, sink, seconds;
};

wstring JobsFile();
vector<JobRec> ReadJobs(int maxRows = 200);
void AppendJob(const JobRec& j);
