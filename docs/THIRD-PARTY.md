# 第三方组件与许可证

本安装包分发以下第三方组件。它们只在本地运行，不联网鉴权，不依赖 DSH。
其中第 4 项（QQ 登录端）是**可选的**：默认安装包不含它，只在出包时显式开启
内置通道的那一版才有。

## 1. bili-whale（sidecar\bili-whale）

- 上游：`dsh-bili-whale` 0.4.6
- 许可证：MIT License，Copyright (c) 2026 ALTERSSSS
- 完整许可证：`sidecar\bili-whale\LICENSE`
- 本仓库对它的修改（可用 `tools\patch-sidecar.mjs` 复现，幂等）：
  1. `tools/lib/paths.mjs` 新增 `biliRoot()/outRoot()/mediaDir()/tmpRoot()/logsRoot()`，
     产物路径改由 `BILI_ROOT` / `BILI_OUT_ROOT` 等环境变量决定；
  2. `tools/commands/debrief.mjs` 的封面、九宫格、字幕缓存改写到 `<工作区>\out\<BV>\`；
  3. `tools/commands/bili-watch.mjs` 的中间帧改写到 `<工作区>\tmp\`，抽完立即回收。
- 这些修改不改变上游的命令行接口，也不改变其许可证。

MIT 许可证正文：

```
MIT License

Copyright (c) 2026 ALTERSSSS

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. Node.js（sidecar\node\node.exe）

- 许可证：MIT 及若干第三方许可证，版权归 Node.js contributors / OpenJS Foundation
- 许可证文本：https://github.com/nodejs/node/blob/main/LICENSE
- 分发方式：官方 Windows x64 `node.exe` 单文件，未修改。

## 3. FFmpeg（sidecar\bili-whale\bin\ffmpeg.exe）

- 许可证：GPL v3（Gyan Doshi 的 Windows essentials 构建，含 GPL 组件）
- 项目主页：https://ffmpeg.org/
- 源码：https://ffmpeg.org/download.html ，构建脚本见 https://www.gyan.dev/ffmpeg/builds/
- 分发方式：原样分发官方构建的 `ffmpeg.exe`，未修改、未静态链接进本程序。
- 如你所在的分发场景需要，可把 `sidecar\bili-whale\bin\ffmpeg.exe` 换成 LGPL 构建，
  工作台通过 `FFMPEG` 环境变量或同路径加载，不需要改代码。

## 4. QQ 登录端（可选内置，`pack\login\` / 装好后的 `bots\<登录端目录>`）

**默认安装包不含它。** 装完之后由 `tools\bootstrap.ps1` 按 `tools\components.json`
里对应条目从上游发布页下载原版包，校验 SHA256 后解压到 `<工作区>\bots\<登录端目录>\`。
只有出包时显式加 `installer\build-installer.bat -BundleLogin` 的那一版安装包，才会把这个
原版 zip 一起打进 `{app}\pack\login\`（装完之后同样是这个目录下的原版文件被解压
过去，跳过下载）。

- 上游：QQ 登录端 2.4.2（一个独立的开源 QQ 登录端项目，发布在 GitHub 上）
- 分发方式：**上游发布的 Windows x64 原版 zip，一个字节都没有修改**，
  包内自带它自己的 `EULA.md` 与 `PRIVACY.md`，装完可在 `<登录端目录>` 里读到，
  许可证全文以那两份文件为准。本项目不反编译、不替换其组件、不重新打包其内容。
- 该组件是一个独立第三方项目，与本项目、与腾讯及 QQ 均无隶属关系。

**关于这一条要注意的事**（照抄上游许可协议的要点，不代为解释）：

- 第 2.2 条：任何商业使用，以及公开发布修改版或衍生版，均须事先取得著作权人的书面授权。
- 第 5.4 条：除事先取得著作权人的书面授权外，不得复制、修改、单独再分发或再许可该组件；
  **将其并入第三方安装包或 Docker 镜像、通过自动化脚本部署**，或者将其用于任何商业用途，
  均须事先取得书面授权。
- 第 3.6 条：使用非官方协议工具可能违反平台服务条款，账号风险由使用者自负。

因此「把登录端打进安装包」这条通道在本项目里是**出包时逐个显式开启的构建开关**，
不是默认行为：谁开启，谁负责确认自己已满足上面第 5.4 条的前提。
`installer\prepare-login.ps1` 每次出内置包都会把这段提示再打印一遍。

登录端的工作方式（注入本机已登录的桌面 QQ，对外提供 OneBot 11 接口，不是自己登协议）
见 `deploy-qq.md` 第 3 节。

## 5. 本程序自身

`win32\src` 下的 C++ 源码、`art\` 下的界面图、安装脚本与文档由本项目维护。
安装包不包含 Chromium / WebView2 / Electron / Python 运行时。
