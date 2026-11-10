# 部署「群里看 B 站」插件（astrbot_plugin_bili_bridge）

这个插件让冥零在群里看到 B 站链接/BV 号时，调用**工作台安装目录里的** bili-whale
把视频看完（封面、九宫格、字幕条、正文），再用她自己的口气总结回群，同时写进
和工作台同一份台账。

它不依赖 DSH，也不读 `~/.dsh`。运行时用的是工作台随包分发的
`sidecar\node\node.exe` + `sidecar\bili-whale\` + `sidecar\bili-whale\bin\ffmpeg.exe`。

---

## 1. 前置

- 已经按 [deploy-qq.md](deploy-qq.md) 把 QQ 侧 + AstrBot 跑通，群里 @ 有回应。
- 已经装好冥零工作台（安装包默认在 `%LOCALAPPDATA%\Programs\MinglingWorkbench`）。
- 有一个 B 站账号的 Cookie：`SESSDATA`、`bili_jct`、`buvid3`。

## 2. 安装插件

把仓库里的 `plugin\astrbot_plugin_bili_bridge` 整个目录复制到：

```
<机器人根>\bots\AstrBot\data\plugins\astrbot_plugin_bili_bridge
```

例如 `D:\冥零工作区\bots\AstrBot\data\plugins\astrbot_plugin_bili_bridge`
（组件统一装在 `bots\` 下，见 [setup-automation.md](setup-automation.md)。老平铺布局的机器
`astrbot\data\plugins\` 这个位置仍然有效，两个地方都被人认。）
重启 AstrBot，Dashboard → 插件 里应该出现「看 B 站」。
插件没有额外 pip 依赖，AstrBot 自带的 aiohttp / 事件系统就够。

## 3. 配置插件

Dashboard → 插件 → 看 B 站 → 配置，或直接改
`<机器人根>\bots\AstrBot\data\config\astrbot_plugin_bili_bridge_config.json`（首次保存后生成；
老平铺布局是 `astrbot\data\config\`）。

| 键 | 建议值 | 说明 |
| --- | --- | --- |
| `require_at` | `true` | 群里必须 @ 才触发 |
| `grid` | `3x3` | 九宫格布局 |
| `timeout` | `300` | 单条看片超时（秒） |
| `persona_id` | `冥零` | 用哪个人设总结 |
| `bili_root` | `E:\冥零工作区` | 留空会自动找；**必须和工作台 workspace 一致** |
| `whale_dir` | 留空 | 留空自动找工作台 sidecar |
| `node_exe` | 留空 | 留空自动找 sidecar 里的 node |
| `soft_trigger` | `true` | 没 @ 但在聊 B 站时也可以软触发 |
| `soft_cooldown_min` | `10` | 软触发冷却（分钟） |
| `same_bv_per_day` | `true` | 同一天同一个 BV 不重复跑 |
| `memory_write` | `true` | 把结论写进 livingmemory |

自动发现顺序（留空时）：

1. 环境变量 `MINGLING_SIDECAR` / `BILI_WHALE_DIR`
2. `%LOCALAPPDATA%\Programs\MinglingWorkbench\sidecar`
3. `%ProgramFiles%\MinglingWorkbench\sidecar`
4. 插件目录往上找 `sidecar`

工作区自动发现：插件配置 `bili_root` → 环境变量 `BILI_ROOT` / `MINGLING_WORKSPACE` →
工作台的 `%APPDATA%\MinglingWorkbench\settings.json` → `文档\冥零工作台`。

## 4. 凭据

放到（工作台和插件共用这一份）：

```
%USERPROFILE%\.bili-ai\credentials.json
```

```json
{
  "sessdata": "……",
  "bili_jct": "……",
  "buvid3": "……"
}
```

获取方式：浏览器登录 B 站 → F12 → Application/存储 → Cookies → `bilibili.com`，
复制 `SESSDATA`、`bili_jct`、`buvid3` 三个值。Cookie 会过期（一般几个月），
过期后工作台体检页 `session` 会直接说「凭据过期/未登录」。

`quota.json`、`traffic-state.json`、`feed-search-cache.json` 也在这个目录，属于可再生的状态，
删掉只会让当天配额/风控计数重来。

## 5. 台账与产物

插件和工作台写的是**同一份**：

```
<工作区>\
├── out\<BV>\         cover.jpg / *-3x3.jpg / *-subs.jpg / *.mp4 / *-debrief.txt
├── tmp\              中间帧，抽完即删
└── logs\
    ├── jobs.jsonl    每行一条 {t,bv,title,up,source,chat,status,sink,seconds}
    └── jobs\<BV>-<unix>.txt
```

`source` 的取值：

| 来源 | source | chat |
| --- | --- | --- |
| 群里发链接（插件 `_handle`） | `qq` | 群号/会话 |
| 模型自己调 `bili_watch` 工具 | `tool` | 会话 |
| 工作台界面 / `--watch` | `console` | `工作台` |

所以工作台「做过的事」页能直接看到群里看过的片，点开就是同一份正文。

## 6. 插件提供的命令与工具

| 名称 | 作用 |
| --- | --- |
| `@机器人 <B站链接或BV>` | 看完 + 总结 + 九宫格回群 |
| `/bili` | 查 bili-whale 登录状态与今天剩余配额 |
| `/bili_mem <BV>` | 重新把某条写进记忆 |
| LLM 工具 `bili_watch(bv_or_url)` | 模型自己决定看一条 |
| LLM 工具 `bili_feed()` | 拉今日选题（`feed --n 5`） |
| LLM 工具 `bili_status()` | `session` + `quota status` |

缓存：同一个 BV 30 分钟内重复 @ 不再跑，直接复用上次结果。

## 7. 常见错误码

插件把 sidecar 的输出归类成下面几个码，回群文案就是括号里的意思：

| 错误码 | 含义 | 排查 |
| --- | --- | --- |
| `BILI_E_NO_WHALE` | 找不到 sidecar 的 `tools\bili.mjs` | 工作台是否装好；`whale_dir` 是否指对；`%LOCALAPPDATA%\Programs\MinglingWorkbench\sidecar\bili-whale\tools\bili.mjs` 是否存在 |
| `BILI_E_AUTH` | 凭据过期/未登录 | 重新导出 `.bili-ai\credentials.json`；工作台体检 `session` |
| `BILI_E_QUOTA` | 今日观看配额用完 | 等明天，或改 `%APPDATA%\MinglingWorkbench\bili-whale.config.json` 的 quota 段 |
| `BILI_E_PATCH` | 抽帧补丁/ffmpeg 缺失 | 确认 `sidecar\bili-whale\bin\ffmpeg.exe` 在；重装工作台 |
| `BILI_E_TIMEOUT` | 超过 `timeout` 秒 | 调大 `timeout`；网络慢时先在工作台试同一条 |
| `BILI_E_RUN` | node 起不来 | 确认 `sidecar\node\node.exe` 在；`node_exe` 是否指向坏了 |
| `BILI_E_UNKNOWN` | 其它 | 看 AstrBot 日志里插件打印的 `raw` 尾部 |

## 8. 白名单

两条白名单都要过：

1. **会话白名单**（AstrBot 平台设置 `id_whitelist`）：群/私聊是否允许机器人说话。
   格式 `<平台ID>:GroupMessage:<群号>`。
2. **插件白名单**（AstrBot 配置 `plugin_set`）：允许哪些插件运行。
   默认 `["*"]` 是全部；想收紧就写成：

   ```json
   "plugin_set": ["astrbot_plugin_bili_bridge", "astrbot_plugin_livingmemory"]
   ```

   只留需要的插件。改完重启 AstrBot。

## 9. 不上 QQ 也能先验证

在工作台安装目录：

```bat
MinglingWorkbench.exe --paths
MinglingWorkbench.exe --feed
MinglingWorkbench.exe --watch BV1xxxxxxxxx
```

`--watch` 成功会打印标题、九宫格路径、正文路径，并往 `logs\jobs.jsonl` 写一条
`source=console`。插件走的是同一个 CLI、同一套环境变量，所以这一步通了，
群里那条链路只剩「AstrBot → 插件 → CLI」的配置问题。
