# 冥零配置包 · 插件

这 10 个 AstrBot 插件是从大肥鱼配置包（zexuanw958-svg/dafeiyu-config-pack，MIT，见同目录
`LICENSE-dafeiyu-config-pack.txt`）原样拿过来的，冥零也照这套用：

```
astrbot_plugin_dafeiyu_clean         发出去前删掉内部标签；开了语音时她知道哪条是念成语音的
astrbot_plugin_dafeiyu_memelog       没真发出去的表情包不留在聊天记录里
astrbot_plugin_dafeiyu_groupimage    群里没 @ 的图也先看一眼
astrbot_plugin_dafeiyu_resetkeep     /reset 清空前先把没进长期记忆的几轮存了
astrbot_plugin_dafeiyu_signature     她自己改 QQ 签名
astrbot_plugin_dafeiyu_video         看视频、听语音（要 ffmpeg，可选本机 ASR 或硅基流动 key）
astrbot_plugin_dafeiyu_petlink       桌宠和 QQ 私聊互通（要配套的桌宠桥，默认不装开）
astrbot_plugin_breeze_online_tts     Breeze 在线语音提供商（默认不开）
astrbot_plugin_seed_audio_tts        豆包 Seed Audio 语音提供商（默认不开）
astrbot_plugin_dafeiyu_sing          现编歌词唱歌（默认不开）
```

`tools\self-setup.ps1 -Only plugins` 会：

1. 看后台 `/plugins` 里有没有；没有就把目录打成 zip 传到 `/plugins/install/upload`；
2. 按 `pack.json` 的 `plugins.items[].config` 写设置（占位 `{主人会话}`、`{ffmpeg}`、
   `{asr_dir}`、`{硅基流动key}` 换不到就跳过，不覆盖后台里已有的值）；
3. 按 `enable` 开/关，最后重载改过的插件。

想换版本：直接替换这里的同名目录，下次跑 `--only plugins` 会重新上传。
