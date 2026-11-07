# mingling-install —— 冥零工作台的安装 Skill

这是给 Agent 看的一份「说明书 + 脚本」，用来装、修、搬、卸冥零工作台（MinglingWorkbench V3）。
它**不是**工作台运行时的一部分：工作台不跑它，是 Agent 读它然后动手。

## 放哪儿

| 位置 | 作用 |
|---|---|
| `%USERPROFILE%\.agents\skills\mingling-install\` | Agent 的技能目录（DSH 从这里加载） |
| `<工作区>\tools\skill-home.txt` | 一行绝对路径，告诉工作台「skill 装在这儿」 |
| `<工作区>\tools\skill-version.json` | 这个 skill 的 `version.json` 拷贝，工作台更新页靠它显示版本 |

前两行之后的内容由 `scripts\finish.ps1` 写；装完 / 更新完都要跑一次。

## 目录

```
SKILL.md                 Agent 读的主文件（判断流程、常见病、规矩）
version.json             版本号、日期、这一版改了什么（工作台会读）
scripts\probe.ps1        体检：找工作台、工作区、组件、端口、skill 版本，最后给一句结论
scripts\finish.ps1       收尾：写 tools\skill-home.txt 与 tools\skill-version.json
references\自设定八块.md  八块自设定各写什么、怎么验
references\发布.md        怎么发这个 skill 的新版（工作台「一键更新」靠的 release 约定）
```

## 发布（给自己看的）

发成 GitHub Release，仓库跟工作台同一个：`linyuehua0010/mingling-workbench`。
tag `skill-v0.1.0`，两个资产：

- `mingling-install.zip` —— 打包时顶层目录必须是 `mingling-install\`（`SKILL.md`、`version.json`、
  `scripts\finish.ps1` 必须都在）
- `skill-version.json` —— 就是 `version.json` 原样上传

工作台查的是 `releases/latest/download/skill-version.json`，所以 skill 的 release 要发成
**最新**那条（非 prerelease），否则更新页查不到。

```powershell
# 在工作区根目录跑
Compress-Archive -Path skill\mingling-install -DestinationPath tmp\mingling-install.zip -Force
gh release create skill-v0.1.0 tmp\mingling-install.zip skill\mingling-install\version.json `
   --repo linyuehua0010/mingling-workbench --title "冥零安装 Skill v0.1.0" --notes "见 version.json"
```

没发布之前，工作台更新页会显示「本机 0.1.0」，不会报错——这是故意的：
查不到远端就说「本机」，不假装有新版本。
