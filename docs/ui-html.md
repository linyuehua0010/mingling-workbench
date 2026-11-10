# V3.2.0 · 内嵌 HTML 界面

把工作台做成「她值夜班时的桌子」：深夜蓝的房间、冰蓝的灯、她的立绘放在最显眼的地方，
文案全部按 `冥零人设.md` 的口吻写——短句、括号动作、不客服腔。C++ 后端沿用 V3 线已有的功能，
HTML 只负责长相和交互。V3.2.0 没改页面结构和交互契约，做的是可用性和主题一致性：键盘能操作页签和
子列表、重绘后焦点不丢；日志和检查结果贴底跟随，往上翻不被拽回去；toast 加宽并保留换行，
带路径和错误码的报错不再被截断，失败类提示留 12 秒（正常 4 秒）。照顾她页的分区在 V3.1.0 收成四个：
组件与操作、相处的习惯、她会做的事、外观主题。

## 设计

- **外观设置**：照顾她 → 外观主题，可切黑夜、白天、自定义。黑夜保留原配色；白天用瓷白卡片、
  浅蓝背景与深蓝文字。自定义可选深浅基础并调整背景、卡片、文字、强调色，保存到本机设置。
- **窗口控制**：系统标题栏隐藏图标和版本标题，只保留一组系统最小化、最大化/还原和关闭按钮。
  拖动页面栏或左上角头像区域移动窗口，双击可最大化/还原，窗口边缘仍能缩放。

- **底色**：`#070d18` 的夜，面板 `#0e1a2e`，正文 `#e9effc`，次要 `#a6b4d0`；强调色取她眼睛的
  冰蓝 `#5a97ff` / `#8fd6ff`。body 上叠三层径向渐变，像房间里只开了一盏灯。
- **字体**：微软雅黑 UI 打底，标题字重 500–600；数字与时钟用 Segoe UI，等宽日志用 Cascadia Mono。
- **窗口边框**：空白系统标题栏与边框的 DWM 深浅模式跟随当前主题；WebView2 首帧底色也读取已保存的主题。
- **总览**：左半边是她的问候（按当前时段换：还没睡啊 / 早… / 在 / 晚上好 / 这么晚了），
  右半边是 `art/hero.png` 立绘，`mask-image` 向左淡出；下面一排四个数字，再接「她身边」「扔个链接过来」。
- **侧栏**：头像 + 名字 + 版本，小标「她 的 桌 子」，七个页签带内联 SVG 图标和数字键；
  最下面是她的对话框（「（趴在桌上）我在。」）和连接状态。
- **页签名字**（功能没变，只是换成她的说法）：

  | # | 页签 | 原来的名字 |
  | --- | --- | --- |
  | 1 | 总览 | 总览 |
  | 2 | 一起看看 | B站 |
  | 3 | 做过的事 | 队列 |
  | 4 | 日志 | 日志 |
  | 5 | 哪儿卡了 | 体检 |
  | 6 | 照顾她 | 维护 |
  | 7 | 帮帮忙 | 帮助中心（教程 / 检查更新 / 找人帮忙） |

- **文案规矩**：状态、数字、报错原因照实写，不许为了人设吞掉；只有包在外面的句子用她的口吻。
  操作按钮保持「看得懂」优先，她的吐槽放在旁边或页头那句括号里。
- **空状态**：统一走 `empty()`，默认一个 `（摊手）`，可以带一句补充和直达按钮。

## 页面结构

- `win32/web/index.html`：HTML、CSS、JavaScript 全在这一个文件里（单行压缩的 CSS + 一个 `<script>`）。
- `win32/src/webui.cpp`：WebView2 生命周期、尺寸同步、资源响应和消息桥。
- `win32/src/ui_web.inc`：`WebUiStateJson()` 把 C++ 状态拼成 JSON，`WebUiCommand()` 解析白名单命令，
  `WebUiPublish()` 推送。
- `win32/res/app.rc`：把 `index.html`、`hero.png`、`avatar.png` 编进 exe（资源号 200/201/202）。

### 页面里的两处结构

- **做过的事（`jobs()`）**：双栏，左「本子」右「这一次」。左栏是任务列表（`jobRows()`，每行
  `data-job` 带序号、标题、来源、时间、状态），右栏常驻选中任务详情：没有选中时显示空态
  「挑一条，展开看看 / 点左边本子上的记录，详情会显示在这里 /（翻页）」，选中后显示
  `<pre>` 详情和「复制记录」「打开产物」。点左边任意一条发 `{cmd:"job",index}`，右侧立即换成
  这条的详情，不用先展开。
- **照顾她（`maintenance()`）**：拆成四个分区 tab（`data-maint` 0–3）——组件与操作、相处的习惯、
  她会做的事、外观主题；每个分区自己渲染，全局 `maintSec` 记住当前分区。
  切分区只在页面内做（改 `maintSec` 后重绘），**不发消息给 C++**。
- **渲染签名**：`JSON.stringify([comparable,helpSec,cfgSec,maintSec])`，分区也算进签名，切分区
  立即重绘；同一签名下需要强制重绘时置 `force=true`（任务详情、分区点击都这么用）。

页面地址是 `https://mingling.local/`，所有请求由 C++ 拦截，**没有本机 HTTP 服务或开放端口**；
只应答这三个资源，其它一律 404。CSP 关闭外链、表单提交和框架；消息桥校验来源，动作走固定白名单，
所有动态文本先转义再插入。

配置沿用原有的校验 / 备份 / 写入接口，API Key 不回传页面（留空表示保留原值）；正在编辑的表单
不会因为状态推送被重建，输入框、分段选择和滚动位置都保留。

## 交互契约

| 页面动作 | 消息 | 说明 |
| --- | --- | --- |
| 切页 | `{cmd:"tab",index}` | 侧栏和 `1`–`7`、`0` 都走这条 |
| B 站分区 | `{cmd:"section",index}` | 今天看啥 / 丢个链接 / 看完了 / 配置 |
| 操作按钮 | `{cmd:"action",value}` | `btn:*`、`op:*`、`fix:*`、`freq:*`、`plugin/*`、`memory/*`、`voice/*` 等 |
| 任务详情 | `{cmd:"job",index}` | 点「做过的事」左栏某一条；不在第 3 页时顺带切回 `tab` 2 |
| 看片 / 读链接 | `{cmd:"watch",value}` | 输入框回车也发这条 |
| 保存配置 | `{cmd:"configsave",value,fields}` | 只提交改过的字段，密码清空后提交空值表示保留 |
| 求助卡改字 | `{cmd:"asksave",index,value}` | 存在 `settings.json` 的 `custom_help_texts` |
| 外观主题 | `{cmd:"theme",value,base,bg,panel,ink,accent}` | 三种模式；颜色只接受 `#RRGGBB`；重启保留 |
| 窗口控制 | `{cmd:"window",value}` | 仅接受 `minimize/maximize/close/drag` |
| 快捷键 | `F5` 刷新当前页、`F9` 全部启动、`F10` 全部关闭 | `F5` 按页面分派 `mref` / `feed` / `jobs_refresh` / `log_refresh` |

## 编译

```bat
win32\build.bat
```

产物固定是 `bin\MinglingWorkbench.exe`。`build.bat` 先跑 `tools\check-version.ps1`，再用 windres
编资源、g++ 静态链接、把 `WebView2Loader.dll` 拷到 `bin\`；版本号只改 `win32\src\version.h`，
不要在别处另写。exe 与 `WebView2Loader.dll` 必须在同一目录；运行需要 Microsoft Edge WebView2
Runtime，缺少时会显示错误说明。安装器已经带上 Loader，但没有自动下载 Runtime。

WebView2 SDK 固定 **1.0.2903.40**（微软官方 NuGet 包），头文件、x64 Loader、LICENSE、NOTICE
都在 `win32/vendor/webview2/`，编译不需要联网。

## 检查

```bat
sidecar\node\node.exe --test win32\tests\webui.test.cjs
powershell -NoProfile -File tools\check-version.ps1
```

`webui.test.cjs` 用 `vm` 跑页面脚本（没有 DOM，自己伪造一层壳）：七页都能渲染出 `<h1>`、
外部内容会转义、输入框和配置表单在状态推送时不重绘、`1`–`7` 键盘切页、保存时只提交改过的字段。

看样子的办法（不碰真实配置）：

```powershell
# 起一个临时状态的实例，并打开 WebView2 远程调试
$env:MINGLING_STATE_DIR = "tmp\ui-check\state"
$env:MINGLING_WORKSPACE = "tmp\ui-check\workspace"
$env:MINGLING_SECRETS   = "tmp\ui-check\secrets"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9222"
Start-Process bin\MinglingWorkbench.exe
# 然后：node tmp\cdp.mjs shot out.png "send('tab',{index:5})"
```

`tmp/cdp.mjs` 走 CDP 截图 / 执行脚本，窗口尺寸由 `CDP_W`、`CDP_H` 覆盖；`tmp/mkpreview.cjs`
可以生成一个带假数据的静态页，方便在浏览器里点着看。
