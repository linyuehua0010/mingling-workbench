#pragma once

// ─────────────────────────────────────────────────────────────────────────────
//  冥零工作台 · 唯一的版本源
//
//  改版本只改这一个文件，下面这些地方都从它取，别再手抄版本号：
//    win32\res\app.rc             资源里的 FILEVERSION / FileVersion / ProductVersion
//    win32\src\ui_pages.inc       侧边栏版本串
//    win32\src\ui_help.inc        帮助中心「关于」那一节
//    win32\src\paths.cpp          卸载列表的 DisplayName / DisplayVersion
//    win32\src\main.cpp           窗口标题 / --version / --paths
//    installer\version_auto.iss   安装包版本与文件名（installer\build-installer.bat 生成）
//
//  正式版规则（详见 docs\VERSIONING.md）：
//    Vx.0.0   大更新：重大重构 / 不兼容变更 / 核心大功能
//    Vx.x.0   普通更新：新增功能、新模块
//    Vx.x.x   补丁：修 bug、优化体验
//
//  快照版规则：V<大版本>-snapshot-<序号>
//    第一个数字 = 现正式版最新大版本 + 1（正式版 V2.x 时快照就是 V3）；
//    第二个数字 = 这条快照通道里的第几版（V3-snapshot-1、V3-snapshot-2…）。
//    正式版发了 V3 之后，快照改叫 V4-snapshot-1。
//    旧的 V3.0.0-snapshot 是历史产物，保留原名，读的时候按 V3-snapshot-1 对待。
//
//  数字与字符串的对应（快照版）：
//    APP_VERSION_MAJOR/MINOR/PATCH  = 3 / 0 / 0   → 文件版本前三段
//    APP_VERSION_BUILD              = 快照序号 2   → 文件版本第四段（3,0,0,2）
//    APP_SNAPSHOT_N                 = 快照序号 2
//    APP_VERSION_TAG                = V3-snapshot-2（界面 / 产品版本 / 应用和功能）
//    APP_VERSION_SHORT              = 3-snapshot-2（安装包文件名）
//
//  ⚠ 数字和字符串是两份写法（windres 只吃逗号分隔的数字），改完跑
//    tools\check-version.ps1，或者直接 build.bat（它会先跑一遍，走散就停）。
// ─────────────────────────────────────────────────────────────────────────────

#define APP_VERSION_MAJOR 3
#define APP_VERSION_MINOR 0
#define APP_VERSION_PATCH 0
#define APP_VERSION_BUILD 2

// 渠道后缀：正式版是空串，快照版写 "-snapshot"。tools\check-version.ps1 核对它和 APP_SNAPSHOT。
#define APP_VERSION_SUFFIX "-snapshot"

// 快照通道：1 = 和正式版并存（独立状态目录 / 窗口类 / AppUserModelID / 卸载项 / 安装目录），
// 0 = 正式通道。必须与 APP_VERSION_SUFFIX 是否为空保持一致。
#define APP_SNAPSHOT 1

// 快照序号：V3-snapshot-2 里的 2。正式版为 0，且必须等于 APP_VERSION_BUILD。
#define APP_SNAPSHOT_N 2

// 资源文件用：FILEVERSION / PRODUCTVERSION（3,0,0,2）
#define APP_VERSION_NUM APP_VERSION_MAJOR,APP_VERSION_MINOR,APP_VERSION_PATCH,APP_VERSION_BUILD

// 窄字符串：.rc / Inno Setup / NSIS / 脚本
#define APP_VERSION_STR   "3.0.0.2"        // 文件版本（四段数字）
#define APP_VERSION_PLAIN "3.0.0"          // 只有数字，不带渠道
#define APP_VERSION_TAG   "V3-snapshot-2"  // 给人看的完整串
#define APP_VERSION_SHORT "3-snapshot-2"   // 安装包文件名用

// 宽字符串：C++ / GDI+ 绘制
#define APP_VERSION         L"V3-snapshot-2"
#define APP_VERSION_PLAIN_W L"3.0.0"
#define APP_VERSION_FULL_W  L"3.0.0.2"
#define APP_VERSION_SHORT_W L"3-snapshot-2"
#define APP_NAME            L"冥零工作台"
