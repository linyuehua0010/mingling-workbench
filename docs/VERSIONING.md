# 版本规范（SemVer）

冥零工作台从 v2.2.0 起用一套版本号，只有一个出处：**`win32\src\version.h`**。别处再写死版本号就算 bug——这正是 2.0.0 → 2.2.0 那次差点漏掉卸载列表的原因。

## 怎么定号码

格式 `V<主>.<次>.<补丁>`，界面上写 `V2.2.0`，文件版本写 `2.2.0.0`。

| 段 | 什么时候 +1 | 例子 |
|----|-------------|------|
| 主版本 `x.0.0` | 重大重构、不兼容变更、核心大功能 | 换了通信协议、工作区布局改了需要迁移 |
| 次版本 `Vx.x.0` | 普通更新：新功能、新模块 | 加了「一键配置组件」、加了掉线提醒 |
| 补丁 `Vx.x.x` | 修 bug、优化体验、改文案 | 修好人设导入的中文问号、卡片文字可改 |

同一版里既有新功能又有修 bug，按高的算（次版本）。本版 `V2.2.0` 就属于这种。

## 改一个文件就够

```cpp
// win32\src\version.h
#define APP_VERSION_MAJOR 2
#define APP_VERSION_MINOR 2
#define APP_VERSION_PATCH 0
#define APP_VERSION_BUILD 0

#define APP_VERSION_NUM   APP_VERSION_MAJOR,APP_VERSION_MINOR,APP_VERSION_PATCH,APP_VERSION_BUILD
#define APP_VERSION_STR   "2.2.0.0"   // 资源 FileVersion
#define APP_VERSION_PLAIN "2.2.0"     // 安装包 / 卸载列表
#define APP_VERSION_TAG   "V2.2.0"    // 界面、ProductVersion
#define APP_VERSION         L"V2.2.0" // C++ 宽字符
#define APP_VERSION_PLAIN_W L"2.2.0"
#define APP_VERSION_FULL_W  L"2.2.0.0"
```

数字和字符串是两份写法（`windres` 只吃逗号分隔的数字），所以改完要跑一遍自检：

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1
```

`win32\build.bat` 和 `installer\build-installer.bat` 开头都会先跑它，走散就停下，不会打出一个人造版本。

## 谁在用这份号码

| 地方 | 取法 | 用户在哪看到 |
|------|------|--------------|
| `win32\res\app.rc` | `APP_VERSION_NUM` / `APP_VERSION_STR` / `APP_VERSION_TAG` | 资源管理器「属性 → 详细信息」 |
| `win32\src\ui_pages.inc:427` | `APP_VERSION` | 侧边栏「工作台 · V2.2.0」 |
| `win32\src\ui_help.inc:259` | `APP_VERSION` | 帮助页开头一行 |
| `win32\src\paths.cpp:400` | `APP_NAME` + `APP_VERSION` / `APP_VERSION_PLAIN_W` | 设置「应用和功能」里的名称与版本 |
| `win32\src\main.cpp` | `APP_VERSION` | 窗口标题、`--version`、`--paths` 第一行 |
| `installer\version_auto.iss` | `build-installer.bat` 从 `version.h` 生成 | 安装向导标题「冥零工作台 V2.2.0」、安装包文件名 |

`installer\mingling.iss` 只 `#include "version_auto.iss"`，别再往里写 `#define AppVer`。`version_auto.iss` 是生成物，提交进仓库只是为了让人直接在 Inno 里点编译也能出包。

## 发一版要走的顺序

1. 改 `win32\src\version.h` 的四个数字，以及对应的字符串（同一个文件里，紧挨着）。
2. `powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1` → 打 `[版本] OK V2.3.0 (2.3.0.0)`。
3. 关掉正在跑的工作台（`Get-Process MinglingWorkbench | Stop-Process`），否则 `build.bat` 复制 exe 会失败却仍打印 OK。
4. `win32\build.bat` → `installer\build-installer.bat`。
5. 核对：`--version` 打的、exe 属性里的、`dist\MinglingWorkbench-V?-setup.exe` 文件名、安装后「应用和功能」里的版本，四者一致。
6. `docs\CHANGES.md` 加一节，写清这一版是「新功能」还是「修 bug」，以及升级时用户要不要动配置。

## 老底子

- 2.0.0 时的版本号散落在 `app.rc`、`paths.cpp`、`mingling.iss` 三处，发版前手工对齐，`README.md` 里的安装包名还是手抄的。
- 2.2.0 时先手工改了三处，随后抽成 `version.h` + 自检脚本 + 生成式 `version_auto.iss`，从 2.2.1 起只改一个文件。
- 安装包文件名跟着 `version.h` 走，`dist\` 里同时留着 2.0.0 的旧包属于正常（历史产物没删）。
