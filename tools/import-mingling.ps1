# 冥零 · 把人设模板注入 AstrBot（需求 2 的注入器）
#
# 谁调：工作台维护页「导入冥零人设」（her::RunAction("import_skill")），也可以手跑：
#   powershell -ExecutionPolicy Bypass -File tools\import-mingling.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File tools\import-mingling.ps1 -Profile private\mingling-persona.json
#
# 做什么：
#   1. 读 plugin\mingling_skill\mingling_skill.json + persona\mingling.md
#   2. 用 -Profile（一段 JSON）或 private\mingling-persona.json 填占位符
#   3. 登录 AstrBot 后台，GET 人设 → 有就 PUT、没有就 POST
#   4. 把 agent_runner.config.persona.persona_id 切成新人设（不切就不生效）
#   5. 白名单里的旧人设名前缀一起换掉
#   6. 同一份正文写到 tools\pet-persona-mine.txt（桌宠共用）
#   7. 打一行 RESULT 给调用方读
#
# 输出协议（C++ 只认这一行）：
#   RESULT ok=<0|1> persona=<id> why=<一句话> next=<下一步>
param(
    [string]$Manifest = "",
    [string]$Profile = "",
    [string]$PersonaId = "",
    [string]$PersonaFile = "",
    [string]$Base = "",
    [string]$Token = "",
    [switch]$DryRun,
    [switch]$SkipDefault,
    [switch]$SkipPet
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
# 输出给 C++ 的是管道，RunCaptureStream 按 UTF-8 解码；不改这一句中文会变乱码
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}

function Say($m) { Write-Host "[mingling] $m" }
function Done($ok, $id, $why, $next) {
    "RESULT ok=$ok persona=$id why=$why next=$next" | Write-Output
    if ($ok -eq 0) { exit 1 } else { exit 0 }
}

# ------------------------------------------------------------------ 定位
$PackRoot = Split-Path -Parent $PSScriptRoot                        # tools 的上一级 = 仓库根
if (-not $Manifest) { $Manifest = Join-Path $PackRoot "plugin\mingling_skill\mingling_skill.json" }
if (-not (Test-Path $Manifest)) {
    # 安装版可能把模板放在 exe 旁边
    $alt = Join-Path (Split-Path -Parent $PSScriptRoot) "plugin\mingling_skill\mingling_skill.json"
    if (Test-Path $alt) { $Manifest = $alt }
}
if (-not (Test-Path $Manifest)) { Done 0 "-" "找不到 mingling_skill.json" "确认 plugin\mingling_skill\ 完整" }

$pack = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$packDir = Split-Path -Parent $Manifest
$personaPath = Join-Path $packDir ($pack.persona.file -replace "/", "\")
if (-not (Test-Path $personaPath)) { Done 0 "-" ("模板不在：" + $personaPath) "重新解压 plugin\mingling_skill" }
$verbatim = $false
if ($PersonaFile) {
    if (-not (Test-Path $PersonaFile)) { Done 0 "-" ("给了 -PersonaFile 但文件不在：" + $PersonaFile) "检查路径" }
        $personaPath = $PersonaFile
        $verbatim = $true
}

# Base：优先参数，其次工作台 settings.json 里的 base
if (-not $Base) {
    $setFile = Join-Path $env:APPDATA "MinglingWorkbench\settings.json"
    if (Test-Path $setFile) {
        $raw = Get-Content $setFile -Raw -Encoding UTF8
        if ($raw -match '"base"\s*:\s*"((?:[^"\\]|\\.)*)"') { $Base = ($matches[1] -replace '\\\\', '\') }
    }
}
if (-not $Base) { $Base = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path (Join-Path $Base "answers.json")) -and -not (Test-Path (Join-Path $Base "astrbot"))) {
    Say ("提醒：" + $Base + " 里没有 answers.json / astrbot，可能不是机器人根；用 -Base 明确指定。")
}

$answersFile = Join-Path $Base "answers.json"
$answers = @{}
if (Test-Path $answersFile) {
    try { $answers = Get-Content $answersFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $answers = @{} }
}

function Read-Kv([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return "" }
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $t = $line.Trim().TrimStart([char]0xFEFF)
        if (-not $t -or $t.StartsWith("#")) { continue }
        $i = $t.IndexOfAny([char[]]@(':', [char]0xFF1A))
        if ($i -lt 0) { continue }
        if ($t.Substring(0, $i).Trim().ToLower() -eq $Key.ToLower()) { return $t.Substring($i + 1).Trim() }
    }
    return ""
}

function Get-Md5([string]$Text) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

# PS 5.1 的 Invoke-RestMethod 发字符串 body 时会按 ANSI 编码，中文会变成 ??；
# 必须自己转成 UTF-8 字节再发
function Send-Json([string]$Method, [string]$Url, $Obj, [hashtable]$H, [int]$Timeout = 60) {
    $json = $Obj | ConvertTo-Json -Depth 30
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod $Url -Method $Method -Headers $H -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec $Timeout
}

# PS 5.1 的 Invoke-RestMethod 读响应时也按 ANSI 解码（服务端没写 charset），中文会变 ??；
# 取原始字节自己按 UTF-8 解
function Get-Json([string]$Url, [hashtable]$H, [int]$Timeout = 30) {
    $resp = Invoke-WebRequest $Url -Headers $H -UseBasicParsing -TimeoutSec $Timeout
    $bytes = $resp.RawContentStream.ToArray()
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $json | ConvertFrom-Json
}

# ------------------------------------------------------------------ 占位符
$fill = [ordered]@{
    persona_id    = ""
    bot_name      = ""
    owner_qq      = ""
    owner_name    = ""
    user_persona  = ""
    user_tone     = ""
    user_examples = ""
}
# 1) 模板里的默认值（persona_id 之类）
foreach ($k in @($pack.placeholders.PSObject.Properties.Name)) { if ($fill.Contains($k)) { $fill[$k] = [string]$pack.placeholders.$k } }
# 2) 填表文件覆盖：-Profile → private\mingling-persona.json
if (-not $Profile) {
    $auto = Join-Path $Base "private\mingling-persona.json"
    if (Test-Path $auto) { $Profile = $auto }
}
if ($Profile -and (Test-Path $Profile)) {
    try {
        $p = Get-Content $Profile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($fill.Keys)) {
            if ($p.PSObject.Properties.Name -contains $k -and "$($p.$k)".Trim()) { $fill[$k] = [string]$p.$k }
        }
    } catch { Say ("填表文件读不了，按模板原样走：" + $_.Exception.Message) }
}
if ($PersonaId) { $fill.persona_id = $PersonaId }
if (-not $fill.persona_id -or $fill.persona_id -match '^\{') { $fill.persona_id = "冥零" }

# owner_qq：填表没有就从 answers.json 的 owner_qq_file 读
if ($fill.owner_qq -notmatch '^\d{5,12}$' -and $answers.owner_qq_file) {
    $f = [string]$answers.owner_qq_file
    if (-not [System.IO.Path]::IsPathRooted($f)) { $f = Join-Path $Base $f }
    if (Test-Path $f) { $fill.owner_qq = (Get-Content $f -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim() }
}
if (-not $fill.bot_name -or $fill.bot_name -match '^[（(]') { $fill.bot_name = $fill.persona_id }
if (-not $fill.owner_name -or $fill.owner_name -match '^[（(]') { $fill.owner_name = "主人" }

if ($fill.owner_qq -notmatch '^\d{5,12}$') { $fill.owner_qq = "（未填）" }

# 正文里没填的两块，给一句能读的占位说明，别留一行花括号
if (-not $fill.user_persona.Trim() -or $fill.user_persona -match '^\(') {
    $fill.user_persona = "（这里还没填：打开 plugin\mingling_skill\persona\mingling.md，把 {user_persona} 换成你自己的角色设定。）"
}
if (-not $fill.user_tone.Trim() -or $fill.user_tone -match '^\(') {
    $fill.user_tone = "（这里还没填：同上，把 {user_tone} 换成她说话的样子。）"
}

$text = Get-Content $personaPath -Raw -Encoding UTF8
foreach ($k in $fill.Keys) { $text = $text.Replace("{$k}", $fill[$k]) }
$text = $text.Replace("{OWNER_QQ}", $fill.owner_qq)

# 落一份成品，排错时直接看这份
$outDir = Join-Path $Base "logs"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$filledPath = Join-Path $outDir "mingling-persona.filled.md"
Set-Content -LiteralPath $filledPath -Value $text -Encoding UTF8
Say ("人设正文已生成：" + $filledPath + "（" + $text.Length + " 字）")

if ($DryRun) {
    Say "---- 预览前 12 行 ----"
    ($text -split "`n" | Select-Object -First 12) | ForEach-Object { Say $_ }
    Done 1 $fill.persona_id "dry-run，没有写任何东西" ("确认后去掉 -DryRun 再跑一次")
}

# ------------------------------------------------------------------ 后台地址与登录
$port = 6185
if ($answers.base_url -and ([string]$answers.base_url) -match ":(\d+)") { $port = [int]$matches[1] }
$api = "http://127.0.0.1:$port/api/v1"

$kvFile = Join-Path $Base "private\backend.txt"
$user = Read-Kv $kvFile "username"
$pass = Read-Kv $kvFile "password"
# 也能直接存一个后台令牌：token: eyJ...
if (-not $Token) { $Token = Read-Kv $kvFile "token" }
if (-not $user) { $user = "astrbot" }

$hdr = @{ "Content-Type" = "application/json" }
$token = $Token
if (-not $token -and $pass) {
    foreach ($try in @($pass, (Get-Md5 $pass))) {
        try {
            $r = Send-Json "Post" "$api/auth/login" @{ username = $user; password = $try } $hdr 20
            if ($r.data.token) { $token = $r.data.token; break }
        } catch { }
    }
}
if (-not $token) {
    Done 0 $fill.persona_id ("后台没登录上（" + $api + "）") "在 private\backend.txt 写 username/password，或用 -Token 传后台令牌"
}
$h = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
Say ("已登录后台 " + $api)

# ------------------------------------------------------------------ 人设写入
$id = $fill.persona_id
$esc = [uri]::EscapeDataString($id)
$foundId = $null
try {
    $probe = Get-Json "$api/personas/$esc" $h 20
    if ($probe.data -and $probe.data.persona_id -eq $id) { $foundId = $id }
} catch { }

$body = @{
    persona_id    = $id
    system_prompt = $text
    begin_dialogs = @()
    tools         = $null
}

try {
    if ($foundId) {
        Send-Json "Put" "$api/personas/$esc" $body $h 60 | Out-Null
        Say ("人设已更新：" + $id)
    } else {
        Send-Json "Post" "$api/personas" $body $h 60 | Out-Null
        Say ("人设已新建：" + $id)
    }
} catch {
    $why = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $why = $why + " | " + $_.ErrorDetails.Message }
    Done 0 $id ("写人设失败：" + $why) "看后台是否在跑、账号有没有权限"
}

# ------------------------------------------------------------------ 切默认人设 + 白名单
if (-not $SkipDefault) {
    try {
        $prof = Get-Json "$api/config-profiles/default" $h 30
        # 这个接口收的就是「配置本体」，不要再套一层 .config（套了会 400: agent_runner must be an object）
        $cfg = $prof.data.config
        if ($cfg.agent_runner -and $cfg.agent_runner.config -and $cfg.agent_runner.config.persona) {
            $cfg.agent_runner.config.persona.persona_id = $id
        }
        # 白名单条目形如 "大肥鱼:FriendMessage:2957389852"，把前缀换成新人设名
        if ($cfg.platform_settings -and $cfg.platform_settings.id_whitelist) {
            $new = @()
            foreach ($e in $cfg.platform_settings.id_whitelist) {
                $parts = ([string]$e) -split ":", 2
                if ($parts.Count -eq 2) { $new += ($id + ":" + $parts[1]) } else { $new += $e }
            }
            $cfg.platform_settings.id_whitelist = $new
        }
        Send-Json "Put" "$api/config-profiles/default" $cfg $h 60 | Out-Null
        Say "已切成默认人设，白名单前缀一起改了"
    } catch {
        Say ("切默认人设没成（可以后台手动选）：" + $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ 桌宠共用同一份正文
if (-not $SkipPet) {
    $pet = Join-Path $Base "tools\pet-persona-mine.txt"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pet) | Out-Null
        Set-Content -LiteralPath $pet -Value $text -Encoding UTF8
        Say ("桌宠人设已更新：" + $pet)
    } catch { Say ("桌宠文本没写成：" + $_.Exception.Message) }
}

Done 1 $id "人设已写入 AstrBot" "重启 AstrBot 或在后台点一下保存，之后就能聊了"
