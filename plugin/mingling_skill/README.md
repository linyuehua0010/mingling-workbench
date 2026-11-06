# 冥零专属 Skill（mingling_skill）

给「冥零工作台 v2」用的人设模板：结构照大肥鱼那套（`dafeiyu-install`），但**人设正文故意留空**——`persona/mingling.md` 里的 `{user_persona}`（她是谁）和 `{user_tone}`（她怎么说话）由你填。

## 三步

1. **填**：打开 `persona/mingling.md`，把 `{user_persona}` / `{user_tone}` 换成你自己的角色设定。
   不想改模板文件也行：复制 `persona/mingling-persona.sample.json` 到 `<Base>\private\mingling-persona.json` 再填。
2. **预览**：`powershell -ExecutionPolicy Bypass -File tools\import-mingling.ps1 -DryRun`
   只生成 `<Base>\logs\mingling-persona.filled.md`，不碰后台。
   已经有一份写好的整篇人设（不是模板）时，直接用 `-PersonaFile <那个.md>` 跳过填空，例如：
   `-PersonaFile "D:\\dafeiyu-config-pack\persona\大肥鱼.md"`。
3. **导入**：去掉 `-DryRun` 再跑一次（或在工作台维护页点「导入冥零人设」）。

导入做了什么：

- 登录 AstrBot 后台（`private\backend.txt` 的 username/password），把人设写进 `personas` 表：有同 id 就更新，没有就新建；
- 把 `agent_runner.config.persona.persona_id` 切成新人设（不切就不生效）；
- 白名单条目 `"旧名字:FriendMessage:<qq>"` 的前缀一起换成新名字；
- 同一份正文写到 `<Base>\tools\pet-persona-mine.txt`，桌宠共用。

## 为什么只注入 AstrBot

SnowLuma 只管登 QQ、收发消息，它的配置文件只有 `onebot / notifications / runtime / ui / webui`，**没有人设字段**；硬塞进去下次启动就被覆盖。人设只存在 AstrBot 的数据库里。

## 占位符

| 占位 | 填什么 | 会进人设正文吗 |
|------|--------|----------------|
| `{persona_id}` | 人设名（默认「冥零」） | 不进 |
| `{bot_name}` | 她在 QQ 上显示的名字 | 进（第一行） |
| `{owner_qq}` | 你的 QQ 号 | 进（只用于「主人识别」一节，白名单也用它） |
| `{owner_name}` | 她怎么叫你 | 不进（仅参考） |
| `{user_persona}` | 她是谁 | 进 |
| `{user_tone}` | 她怎么说话 | 进 |
| `{user_examples}` | 3~6 段对话示例，可留空 | 进 |

> 没填的 `{user_persona}` / `{user_tone}` 会被替换成一句「这里还没填」的提示，不会留一行花括号。

## 常见问题

- **导入说没登录上**：`<Base>\private\backend.txt` 写两行 `username: …` / `password: …`（后台网页登录用的那对；改过密码的话存的是 md5，脚本两种都会试）。
  不想碰密码也行：用 `-Token <后台令牌>` 直接传 JWT（后台 `cmd_config.json` 的 `dashboard.jwt_secret` 能自己签一个，payload `{"username":…,"exp":…}`，HS256）。
- **中文变问号**：PS 5.1 的 `Invoke-RestMethod` 发/收 JSON 都按 ANSI 处理过，脚本里已经改成「发 UTF-8 字节、收原始字节自己解」，别改回去。
- **导入成功但聊天还是旧人设**：重启 AstrBot，或在后台「人格」页点一下保存——默认人设是启动时读的。
- **想恢复成大肥鱼**：在后台把人设切回去即可，本工具只改名不删旧人设。
