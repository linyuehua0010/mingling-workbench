#pragma once

// ─────────────────────────────────────────────────────────────────────────────
//  冥零工作台 · 唯一的版本源
//
//  改版本只改这一个文件，下面这些地方都从它取，别再手抄版本号：
//    win32\res\app.rc             资源里的 FILEVERSION / FileVersion / ProductVersion
//    win32\src\ui_pages.inc       侧边栏「工作台 · V2.2.0」
//    win32\src\ui_help.inc        帮助页「冥零工作台 V2.2.0 · …」
//    win32\src\paths.cpp          卸载列表的 DisplayName / DisplayVersion
//    win32\src\main.cpp           窗口标题 / --version / --paths
//    installer\version_auto.iss   安装包版本（installer\build-installer.bat 生成）
//
//  规则（详见 docs\VERSIONING.md）：
//    Vx.0.0   大更新：重大重构 / 不兼容变更 / 核心大功能
//    Vx.x.0   普通更新：新增功能、新模块
//    Vx.x.x   补丁：修 bug、优化体验
//
//  ⚠ 数字和字符串是两份写法（windres 只吃逗号分隔的数字），改完跑
//    tools\check-version.ps1，或者直接 build.bat（它会先跑一遍，走散就停）。
// ─────────────────────────────────────────────────────────────────────────────

#define APP_VERSION_MAJOR 2
#define APP_VERSION_MINOR 2
#define APP_VERSION_PATCH 0
#define APP_VERSION_BUILD 0

// 资源文件用：FILEVERSION / PRODUCTVERSION
#define APP_VERSION_NUM APP_VERSION_MAJOR,APP_VERSION_MINOR,APP_VERSION_PATCH,APP_VERSION_BUILD

// 窄字符串：.rc / Inno Setup / NSIS / 脚本
#define APP_VERSION_STR   "2.2.0.0"
#define APP_VERSION_PLAIN "2.2.0"
#define APP_VERSION_TAG   "V2.2.0"

// 宽字符串：C++ / GDI+ 绘制
#define APP_VERSION         L"V2.2.0"
#define APP_VERSION_PLAIN_W L"2.2.0"
#define APP_VERSION_FULL_W  L"2.2.0.0"
#define APP_NAME            L"冥零工作台"
