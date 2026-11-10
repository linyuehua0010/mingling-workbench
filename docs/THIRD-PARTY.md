# 第三方组件与许可证

本安装包分发以下第三方组件。它们只在本地运行，不联网鉴权，不依赖 DSH。
每一项都是原样分发上游发布的构建，未修改源码、未静态链接进本程序。

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

## 4. 本程序自身

`win32\src` 下的 C++ 源码、`art\` 下的界面图、安装脚本与文档由本项目维护。
安装包不包含 Chromium / WebView2 / Electron / Python 运行时。
