# 版本规范

冥零工作台有两个渠道：**正式版**（`Vx.y.z`）和**快照版**（`Vx-snapshot-n`）。版本号只有一个出处：
**`win32\src\version.h`**。别处再写死版本号就算 bug——2.0.0 → 2.2.0 那次差点漏掉卸载列表，
就是因为版本号散落在 `app.rc`、`paths.cpp`、`mingling.iss` 三处。

## 当前状态（2026-11-10）

- 已发布正式版：**V3.2.0**（文件版本 `3.2.0.0`，安装包 `MinglingWorkbench-3.2.0-setup.exe`）。
- V3.2.0 沿用正式通道目录，和 V3.1.0 / V3.0.0 / V2.4.1 是原地升级：装过旧版的机器直接装 V3.2.0，
  安装目录、状态目录、工作区都不动。
- 出包时额外开 `-BundleSnowLuma` 的那一版是**另一个文件名**：`MinglingWorkbench-3.2.0-setup-snowluma.exe`
  （见下文「内置 SnowLuma 的那一版」），它不进正式发布通道。
- 快照通道下一版：**V4-snapshot-1**（尚未发布）。正式版发了 V3 之后，快照改叫 V4，序号从 1 重新数。
- 现在的快照通道停在 V3-snapshot-3；从快照版转正式版要重装到正式通道，配置不自动迁移。

## 正式版：`V<主>.<次>.<补丁>`

| 段 | 什么时候 +1 | 例子 |
|----|-------------|------|
| 主版本 `Vx.0.0` | 重大重构、不兼容变更、核心大功能 | 换了通信协议、工作区布局改了需要迁移 |
| 次版本 `Vx.x.0` | 普通更新：新功能、新模块 | 加了「链接与应用」配置页 |
| 补丁 `Vx.x.x` | 修 bug、优化体验、改文案 | 修好人设导入的中文问号 |

界面上写 `V3.2.0`，文件版本写 `3.2.0.0`。同一版里既有新功能又有修 bug，按高的算。

## 快照版：`V<大版本>-snapshot-<序号>`

- **第一个数字** = 现正式版最新大版本 **+ 1**。正式版是 V2.x 时，快照就是 V3。
- **第二个数字** = 这条快照通道里的第几版：`V3-snapshot-1`、`V3-snapshot-2`、`V3-snapshot-3`……
- 正式版发了 V3 之后，快照通道改叫 `V4-snapshot-1`，序号从 1 重新数。
- 安装包名跟着走：`MinglingWorkbench-4-snapshot-1-setup.exe`（中间**没有** `V`，也没有 `.0.0`）。
- 旧的 `V3.0.0-snapshot` 是历史产物，**文件名不改**；读的时候按 `V3-snapshot-1` 对待
  （`her::WbCmp` / 更新页都认这种老写法）。

新旧比较的口径（`her::WbCmp`）：同一渠道先比大版本；快照版再比序号；同大版本的**正式版**
永远比快照版新（快照是它的前身）。不能拿纯数字比较——`3-snapshot-2` 和 `3.0.0` 的数字部分
都是 3.0.0，混着比会把两个渠道当成同一版。

## 改一个文件就够

```cpp
// win32\src\version.h（快照版示例：V4-snapshot-1）
#define APP_VERSION_MAJOR 4
#define APP_VERSION_MINOR 0
#define APP_VERSION_PATCH 0
#define APP_VERSION_BUILD 1          // 文件版本第四段 = 快照序号
#define APP_VERSION_SUFFIX "-snapshot"
#define APP_SNAPSHOT 1               // 渠道开关：1 快照、0 正式
#define APP_SNAPSHOT_N 1             // 快照序号，必须等于 APP_VERSION_BUILD

#define APP_VERSION_STR   "4.0.0.1"        // 文件版本（四段数字）
#define APP_VERSION_PLAIN "4.0.0"          // 只有数字
#define APP_VERSION_TAG   "V4-snapshot-1"  // 界面、产品版本、应用和功能
#define APP_VERSION_SHORT "4-snapshot-1"   // 安装包文件名
```

正式版（当前 `V3.2.0`）则是 `MAJOR 3 / MINOR 2 / PATCH 0 / BUILD 0`、`SUFFIX ""`、`APP_SNAPSHOT 0`、
`APP_SNAPSHOT_N 0`，四个字符串分别 `"3.2.0.0"` / `"3.2.0"` / `"V3.2.0"` / `"3.2.0"`。

数字和字符串是两份写法（`windres` 只吃逗号分隔的数字），所以改完要跑一遍自检：

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1
```

它会核对数字、渠道、快照序号和五个字符串有没有走散，通过时打印一行
`[版本] OK V4-snapshot-1 (4.0.0.1)`。`win32\build.bat` 和 `installer\build-installer.bat`
开头都会先跑它，走散就停下，不会打出一个人造版本。

## 渠道隔离（快照版和正式版可以同装一台机器）

`APP_SNAPSHOT=1` 时这些地方自动分流，两套互不覆盖：

| 东西 | 正式版 | 快照版 |
|------|--------|--------|
| 状态目录 | `%APPDATA%\MinglingWorkbench` | `%APPDATA%\MinglingWorkbench\snapshot` |
| 窗口类 / 单实例 | `MinglingWorkbench` | `MinglingWorkbench.snapshot` |
| AppUserModelID | `Mingling.Workbench.2` | `Mingling.Workbench.snapshot` |
| 卸载项 | `MinglingWorkbench_is1` | `MinglingWorkbench_snapshot_is1` |
| 安装目录 | `…\Programs\MinglingWorkbench` | `…\Programs\MinglingWorkbench-snapshot` |
| 快捷方式 | 冥零工作台 | 冥零工作台（快照） |

工作区（`out` / `tmp` / `logs` / `bots`）和 `<Base>\secrets` 两渠道共用，看片产物、台账、
密钥都不变。

回正式版：`SUFFIX` 改回 `""`、`APP_SNAPSHOT` 改回 `0`、`APP_SNAPSHOT_N` 改回 `0`，
跑一次 `check-version.ps1`，再打包。V3.0.0 就是这么回来的：`APP_VERSION_TAG "V3.0.0"`、
`APP_VERSION_STR "3.0.0.0"`、`APP_SNAPSHOT 0`，安装目录仍用 `…\Programs\MinglingWorkbench`，
与 V2.4.1 原地升级；从快照版过来的用户要重装到正式通道，配置不自动迁移。

## 谁在用这份号码

| 地方 | 取法 | 用户在哪看到 |
|------|------|--------------|
| `win32\res\app.rc` | `APP_VERSION_NUM` / `APP_VERSION_STR` / `APP_VERSION_TAG` | 资源管理器「属性 → 详细信息」 |
| `win32\src\ui_pages.inc` | `APP_VERSION` | 侧边栏「工作台 · V3.2.0」 |
| `win32\src\ui_help.inc` | `APP_VERSION` | 帮助中心「关于」 |
| `win32\src\paths.cpp` | `APP_NAME` + `APP_VERSION` | 「应用和功能」里的名称与版本 |
| `win32\src\main.cpp` | `APP_VERSION` / `APP_VERSION_FULL_W` | 窗口标题、`--version`、`--paths` |
| `installer\version_auto.iss` | `build-installer.bat` 从 `version.h` 生成 | 安装向导、安装包文件名、文件属性 |
| `win32\src\her\her_actions.cpp` | `APP_VERSION` + `WbCmp` | 更新页「本机 → 最新」的比较 |

`installer\mingling.iss` 只 `#include "version_auto.iss"`，别再往里写 `#define AppVer`。
`version_auto.iss` 是生成物，提交进仓库只是为了让人直接在 Inno 里点编译也能出包。安装器的
`AppVersion` / `AppVerName` 用显示串（`V3.2.0`，这就是「应用和功能」那一列），
`VersionInfoVersion` 用四段数字（`3.2.0.0`），`OutputBaseFilename` 用短串（`3.2.0`）。
内置 SnowLuma 的那一版在短串后再拼 `-snowluma`（`{#OutSuffix}`），所以两份包不会互相覆盖。

## 发一版要走的顺序

1. 改 `win32\src\version.h` 的数字、渠道、快照序号和五个字符串（同一个文件里，紧挨着）。
2. `powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1`
   → 打 `[版本] OK V3.2.0 (3.2.0.0)`。
3. 关掉正在跑的工作台（`Get-Process MinglingWorkbench | Stop-Process`），否则 `build.bat` 复制 exe 会失败。
4. `win32\build.bat` → `installer\build-installer.bat`。
   要出「内置 SnowLuma」的那一版，第 4 步改成 `installer\build-installer.bat -BundleSnowLuma`
   （离线出包加 `-Offline`），详见 [snowluma.md](snowluma.md) 第 14 节。
5. 核对四处：`--version` 打的、exe 属性里的、`dist\MinglingWorkbench-3.2.0-setup.exe`
   文件名、安装后「应用和功能」里的版本（V3.2.0 显示为「冥零工作台 V3.2.0」）。
6. 打 tag 发 release：快照版发成 **prerelease**（更新页只从 release 列表里挑带 `snapshot` 的 tag，
   `/releases/latest` 永远只给正式版）。仓库地址配在 `settings.json` 的 `repo_snapshot`。
7. `docs\CHANGES.md` 加一节，写清这一版是「新功能」还是「修 bug」，以及升级时用户要不要动配置。

## 老底子

- 2.0.0 时版本号散落三处，发版前手工对齐，`README.md` 里的安装包名还是手抄的。
- 2.2.0 时抽成 `version.h` + 自检脚本 + 生成式 `version_auto.iss`，从 2.2.1 起只改一个文件。
- V3.0.0-snapshot 是第一条快照通道（后缀 `-snapshot` 拼在完整版本号后面）。V3-snapshot-2 起
  改成 `V<大版本>-snapshot-<序号>`，旧 tag 继续认。
- V3.0.0 是 V3 线第一个正式版：内嵌 HTML 界面定稿，正式通道目录沿用 V2.4.1，安装时原地升级。
- V3.1.0 把安装收成一条自动链路（`tools\components.json` + `tools\bootstrap.ps1`），
  并新增唱歌、桌宠、豆包语音；安装包 88,855,864 B，SHA256 `ff9982cd…809f8`。
- V3.2.0 让安装包能自带 SnowLuma（`-BundleSnowLuma`，显式开关）、界面做了一轮可用性与主题优化，
  文档全面对齐到当前版本。
- 安装包文件名跟着 `version.h` 走，`dist\` 里同时留着旧包属于正常（历史产物没删）。
