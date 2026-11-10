# 第三方组件与许可证

本安装包分发以下第三方组件。它们只在本地运行，不联网鉴权，不依赖 DSH。
其中第 4 项（SnowLuma）是**可选的**：默认安装包不含它，只在出包时显式开启
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

## 4. SnowLuma（可选内置，`pack\snowluma\` / 装好后的 `bots\SnowLuma`）

**默认安装包不含 SnowLuma。** 装完之后由 `tools\bootstrap.ps1` 按
`tools\components.json` 的 `snowluma` 条目从上游发布页下载官方原版包，
校验 SHA256 后解压到 `<工作区>\bots\SnowLuma\`。只有出包时显式加
`installer\build-installer.bat -BundleSnowLuma` 的那一版安装包，才会把这个
原版 zip 一起打进 `{app}\pack\snowluma\`（装完之后同样是这个目录下的原版
文件被解压过去，跳过下载）。

- 上游：SnowLuma 2.4.2（<https://github.com/TomyJan/SnowLuma>）
- 发布页：<https://github.com/TomyJan/SnowLuma/releases>
- 分发方式：**上游发布的 Windows x64 原版 zip，一个字节都没有修改**，
  包内自带 `EULA.md` 与 `PRIVACY.md`，装完可在 `bots\SnowLuma\` 里读到。
  本项目不反编译、不替换其组件、不重新打包其内容。
- 许可证：SnowLuma 自带《最终用户许可协议》（EULA v1.1，2026-07-21 生效），
  完整正文见包内 `EULA.md` 与 <https://github.com/TomyJan/SnowLuma/blob/main/EULA.md>。

**关于这一条要注意的事**（照抄上游原文的要点，不代为解释）：

- EULA 第 2.2 条：任何商业使用，以及公开发布修改版或衍生版，均须事先取得著作权人的书面授权。
- EULA 第 5.4 条：除事先取得著作权人的书面授权外，不得复制、修改、单独再分发或再许可该组件；
  **将其并入第三方安装包或 Docker 镜像、通过自动化脚本部署**，或者将其用于任何商业用途，
  均须事先取得书面授权。
- EULA 第 3.1 条：SnowLuma 与腾讯及 QQ 无隶属关系。
- EULA 第 3.6 条：使用非官方协议工具可能违反平台服务条款，账号风险由使用者自负。

因此「把 SnowLuma 打进安装包」这条通道在本项目里是**出包时逐个显式开启的构建开关**，
不是默认行为：谁开启，谁负责确认自己已满足上面第 5.4 条的前提。
`installer\prepare-snowluma.ps1` 每次出内置包都会把这段提示再打印一遍。

SnowLuma 的工作方式（注入本机已登录的桌面 QQ，对外提供 OneBot 11 接口，
不是自己登协议）见 `docs\snowluma.md`。

## 5. 本程序自身

`win32\src` 下的 C++ 源码、`art\` 下的界面图、安装脚本与文档由本项目维护。
安装包不包含 Chromium / WebView2 / Electron / Python 运行时。
