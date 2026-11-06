密钥文件夹（secrets）
====================

这个文件夹跟工作区放在同一级（默认 C:\Users\<你>\Documents\secrets，
工作区选在 D:\MinglingWorkbench 时就是 D:\secrets）。
它在程序安装目录（{app}）之外，所以**卸载、重装都不会删**：重装回来直接就能用。

放什么（都是纯文本，一行一个，写成 键=值 或者只写值）：

  snowluma-webui.txt   SnowLuma 网页后台的密码
                       例：password=你的密码
  backend.txt          AstrBot 后台的账号密码（网页登录用的那对）
                       例：username=astrbot
                           password=你的密码
  deepseek-key.txt     DeepSeek 的 API Key
                       例：key=sk-xxxxxxxx
  protocol.txt         QQ 用的是哪个协议端：napcat 或 snowluma

读的顺序
--------
1. 环境变量 MINGLING_SECRETS 指向的目录（排障时临时改指向用）
2. 设置里的 secrets 键（settings.json）
3. 这个文件夹
4. 老版本的位置：工作区上一级的 private\（老用户的密钥不用搬，程序会回退去读）

所以要换密钥：改这个文件夹里的文件就行，程序每次用的时候现读。
想彻底不让人看到：把这个文件夹换个地方，再把 settings.json 里的 secrets 指过去。
