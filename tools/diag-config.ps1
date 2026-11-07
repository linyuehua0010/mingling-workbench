# 冥零 · 配置级验收
#
# 谁调：tools\self-setup.ps1 的 verify 块，也可以手跑：
#   powershell -ExecutionPolicy Bypass -File tools\diag-config.ps1 -Base F:\dafeiyu\bili
#   powershell -ExecutionPolicy Bypass -File tools\diag-config.ps1 -Quick   （不测模型接口）
#
# 逐项打 CHECK，最后一行给 RESULT。只读，不改任何东西。
#   CHECK <名称> ok|bad <证据>
#   RESULT ok=<0|1> bad=<n> why=<一句话>
param(
    [string]$Base = "",
    [switch]$Quick
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}

function Say($m) { Write-Host "[diag] $m" }
function Check([string]$name, [bool]$ok, [string]$detail) {
    Write-Host ("CHECK " + $name + " " + $(if ($ok) { "ok" } else { "bad" }) + " " + $detail)
}
function Done([int]$ok, [int]$bad, [string]$why) {
    Write-Host ("RESULT ok=" + $ok + " bad=" + $bad + " why=" + $why)
    if ($ok -ne 1) { exit 1 } else { exit 0 }
}

$script:Token = ""
$script:ApiRoot = ""
$script:LastError = ""

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

function Api([string]$Method, [string]$Path, $Body = $null, [int]$Timeout = 30) {
    $script:LastError = ""
    $url = $script:ApiRoot + $Path
    $hdr = @{}
    if ($script:Token) { $hdr["Authorization"] = "Bearer " + $script:Token }
    try {
        if ($null -eq $Body) {
            $r = Invoke-WebRequest $url -Method $Method -Headers $hdr -UseBasicParsing -TimeoutSec $Timeout
        } else {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30))
            $hdr["Content-Type"] = "application/json; charset=utf-8"
            $r = Invoke-WebRequest $url -Method $Method -Headers $hdr -Body $bytes -UseBasicParsing -TimeoutSec $Timeout
        }
        $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + " | " + $_.ErrorDetails.Message }
        $script:LastError = $msg
        return $null
    }
}

function Get-Path($obj, [string]$dotted) {
    $cur = $obj
    foreach ($seg in ($dotted -split '\.')) {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$seg]
        if (-not $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}

# ------------------------------------------------------------------ 定位
if (-not $Base) {
    $setFile = Join-Path $env:APPDATA "MinglingWorkbench\settings.json"
    if (Test-Path $setFile) {
        $raw = Get-Content $setFile -Raw -Encoding UTF8
        if ($raw -match '"base"\s*:\s*"((?:[^"\\]|\\.)*)"') { $Base = ($matches[1] -replace '\\\\', '\') }
    }
}
if (-not $Base) { $Base = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Base = $Base.Trim().Trim('"')
while ($Base.Length -gt 2 -and ($Base.EndsWith('\') -or $Base.EndsWith('/'))) { $Base = $Base.Substring(0, $Base.Length - 1) }
if ($Base.Length -eq 2 -and $Base[1] -eq ':') { $Base = $Base + '\' }
if (-not (Test-Path $Base)) { Check "机器人根" $false $Base; Done 0 1 "机器人根不存在" }

# 配置包：优先按脚本位置找（工作台装在哪都行），最后才看机器人根下面
$packFile = ""
foreach ($c in @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) "pack\mingling-pack\pack.json"),
    (Join-Path $PSScriptRoot "pack\mingling-pack\pack.json"),
    (Join-Path $Base "pack\mingling-pack\pack.json")
)) { if (Test-Path $c) { $packFile = $c; break } }
$pk = $null
if ($packFile) { try { $pk = Get-Content $packFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $pk = $null } }

$ans = @{}
$ansFile = Join-Path $Base "answers.json"
if (Test-Path $ansFile) { try { $ans = Get-Content $ansFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $ans = @{} } }

$port = 6185
if ($ans.base_url -and ([string]$ans.base_url) -match ":(\d+)") { $port = [int]$matches[1] }
$script:ApiRoot = "http://127.0.0.1:$port/api/v1"

$bad = 0
Say ("后台 " + $script:ApiRoot)

# ------------------------------------------------------------------ 登录
$kv = Join-Path $Base "private\backend.txt"
$user = Read-Kv $kv "username"; if (-not $user) { $user = "astrbot" }
$pass = Read-Kv $kv "password"
$tok = Read-Kv $kv "token"
if ($tok) { $script:Token = $tok }
if (-not $script:Token -and $pass) {
    foreach ($tryPw in @($pass, (Get-Md5 $pass))) {
        $r = Api "POST" "/auth/login" @{ username = $user; password = $tryPw } 15
        if ($r -and $r.data -and $r.data.token) { $script:Token = $r.data.token; break }
    }
}
if (-not $script:Token) {
    Check "后台在线" $false ("登录失败：" + $script:LastError)
    Done 0 1 "后台没连上"
}
Check "后台在线" $true $script:ApiRoot

$cfg = $null
# 平台 id 与档案同名时，那个平台用的是那份档案（冥零平台 → 冥零档案）；没有同名才落回 default
$profId = "default"
$wantProf = ""
if ($pk -and $pk.platform -and $pk.platform.id) { $wantProf = [string]$pk.platform.id }
$rp = Api "GET" "/config-profiles" $null 20
if ($rp -and $rp.data -and $rp.data.info_list) {
    foreach ($x in $rp.data.info_list) { if ($wantProf -and ([string]$x.name) -eq $wantProf) { $profId = [string]$x.id } }
}
$r = Api "GET" ("/config-profiles/" + $profId) $null 30
if ($r -and $r.data -and $r.data.config) { $cfg = $r.data.config }
if ($null -eq $cfg) {
    $bad++
    Check "后台配置" $false ("读不到 config-profiles/" + $profId + "：" + $script:LastError)
} else {
    Check "后台配置" $true ("读得到（档案 " + $profId + "）")
}

# ------------------------------------------------------------------ 对话模型
$itemId = ""
if ($cfg) { $itemId = [string](Get-Path $cfg "agent_runner.config.model.provider_id") }
if (-not $itemId) {
    $bad++
    Check "对话模型" $false "没设默认模型（agent_runner.config.model.provider_id 是空的）"
} else {
    $p = Api "GET" ("/providers/by-id?provider_id=" + [uri]::EscapeDataString($itemId)) $null 30
    $has = ($p -and $p.data -and ($p.data.id -or $p.data.provider))
    if (-not $has) { $bad++ }
    Check "对话模型" $has $(if ($has) { $itemId } else { "默认指向 " + $itemId + "，但后台里找不到这个模型" })
    if ($has -and -not $Quick) {
        $t = Api "POST" "/providers/test" @{ provider_id = $itemId } 120
        $st = ""
        if ($t) { $st = [string]$t.status; if (-not $st -and $t.data) { $st = [string]$t.data.status } }
        $okT = ($null -ne $t) -and ($st -notmatch 'error|unavailable|failed|timeout')
        if (-not $okT) { $bad++ }
        Check "模型能用" $okT $(if ($okT) { "测试通过" } else { "测试没过（" + $st + "）：" + $script:LastError })
    }
}

# ------------------------------------------------------------------ QQ 平台
$plat = ""
$packId = "冥零"
if ($pk -and $pk.platform.id) { $packId = [string]$pk.platform.id }
$r = Api "GET" "/bots" $null 30
$bots = @()
if ($r -and $r.data) { if ($r.data -is [array]) { $bots = $r.data } elseif ($r.data.bots) { $bots = $r.data.bots } }
$qq = @($bots | Where-Object { $_.type -eq "aiocqhttp" })
$exact = @($qq | Where-Object { [string]$_.id -eq $packId })
if ($exact.Count -gt 0) {
    $plat = $packId
    Check "QQ 平台" $true ("平台「" + $plat + "」" + $(if ($exact[0].enable -eq $false) { "（现在是关着的）" } else { "" }))
} elseif ($qq.Count -eq 1) {
    $plat = [string]$qq[0].id
    Check "QQ 平台" $true ("平台「" + $plat + "」（不是「" + $packId + "」，白名单按它的名字算）")
} elseif ($qq.Count -eq 0) {
    $bad++
    Check "QQ 平台" $false "还没有 OneBot v11 平台（去接 QQ 小号）"
} else {
    $bad++
    Check "QQ 平台" $false ("后台里有 " + $qq.Count + " 个 QQ 平台（" + (($qq | ForEach-Object { $_.id }) -join "、") + "），分不清该接哪个")
}

# ------------------------------------------------------------------ 白名单
if ($cfg -and $plat) {
    $wl = Get-Path $cfg "platform_settings.id_whitelist"
    $owner = ""
    $of = Join-Path $Base "private\owner-qq.txt"
    if (Test-Path $of) { $owner = ((Get-Content $of -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim() -split "`r?`n")[0] }
    if (-not $owner -and $ans.owner_qq) { $owner = [string]$ans.owner_qq }
    $want = $plat + ":FriendMessage:" + $owner
    $has = $false
    if ($owner) {
        if ($wl) { foreach ($e in $wl) { if ("$e" -eq $want) { $has = $true } } }
    } elseif ($wl) {
        foreach ($e in $wl) { if ("$e" -match ([regex]::Escape($plat) + ":FriendMessage:\d{5,12}")) { $has = $true } }
    }
    if (-not $has) { $bad++ }
    Check "白名单" $has $(if ($has) { "有「" + $want + "」" } else { "没有「" + $want + "」；她不会回主人私聊" })
}

# ------------------------------------------------------------------ 人设
$personaId = "冥零"
if ($pk -and $pk.persona.id) { $personaId = [string]$pk.persona.id }
$per = Api "GET" ("/personas/" + [uri]::EscapeDataString($personaId)) $null 30
$hasPersona = ($per -and $per.data -and $per.data.persona_id -eq $personaId)
if (-not $hasPersona) { $bad++ }
Check "人设" $hasPersona $(if ($hasPersona) { ("「" + $personaId + "」在") } else { ("后台里没有「" + $personaId + "」") })
if ($cfg -and $hasPersona) {
    $dp = [string](Get-Path $cfg "agent_runner.config.persona.persona_id")
    $same = ($dp -eq $personaId)
    if (-not $same) { $bad++ }
    Check "默认人设" $same $(if ($same) { "指向「" + $personaId + "」" } else { "指向「" + $dp + "」，不是冥零" })
}

# ------------------------------------------------------------------ 插件
$items = @()
if ($pk -and $pk.plugins) { $items = @($pk.plugins.items) }
if ($items.Count -eq 0) {
    $bad++
    Check "插件" $false "配置包里没有 plugins.items"
} else {
    $r = Api "GET" "/plugins" $null 60
    $act = @{}
    if ($r -and $r.data) {
        foreach ($x in @($r.data)) {
            if ($x -and $x.name) { $act[[string]$x.name] = ([bool]$x.activated) }
        }
    }
    $missing = @(); $offNames = @(); $onN = 0
    foreach ($it in $items) {
        $name = [string]$it.name
        if (-not $name) { continue }
        if (-not $act.ContainsKey($name)) { $missing += $name; continue }
        $want = $true
        if ($null -ne $it.enable) { $want = [bool]$it.enable }
        if (-not $want) { continue }
        $onN++
        if (-not $act[$name]) { $offNames += $name }
    }
    $okP = ($missing.Count -eq 0) -and ($offNames.Count -eq 0)
    if (-not $okP) { $bad++ }
    $detail = if ($okP) {
        ("插件 " + $items.Count + " 个都在位，开了 " + $onN + " 个")
    } else {
        $w = @()
        if ($missing.Count -gt 0) { $w += ("没装：" + ($missing -join "、")) }
        if ($offNames.Count -gt 0) { $w += ("该开没开：" + ($offNames -join "、")) }
        ($w -join "；")
    }
    Check "插件" $okP $detail
}

# ------------------------------------------------------------------ 记忆
$memMode = ""
if ($ans -and $ans.memory) { $memMode = ([string]$ans.memory).Trim() }
if (-not $memMode) { $f = Join-Path $Base "private\memory-mode.txt"; if (Test-Path $f) { $memMode = (Get-Content $f -Raw -Encoding UTF8).Trim() } }
if (-not $memMode -and $pk -and $pk.memory) { $memMode = [string]$pk.memory.default_mode }
if ($memMode -eq "1" -or $memMode -eq "2") {
    $lmName = "astrbot_plugin_livingmemory"
    if ($pk -and $pk.memory -and $pk.memory.plugin) { $lmName = [string]$pk.memory.plugin.name }
    $act2 = @{}
    $r2 = Api "GET" "/plugins" $null 60
    if ($r2 -and $r2.data) { foreach ($x in @($r2.data)) { if ($x -and $x.name) { $act2[[string]$x.name] = [bool]$x.activated } } }
    $lmOn = $act2.ContainsKey($lmName) -and $act2[$lmName]
    $wantId = ""
    if ($pk.memory.modes.$memMode) { $wantId = [string]$pk.memory.modes.$memMode.id }
    $curId = ""
    $r3 = Api "GET" ("/plugins/config?plugin_id=" + [uri]::EscapeDataString($lmName)) $null 30
    if ($r3 -and $r3.data -and $r3.data.config) { $curId = [string](Get-Path $r3.data.config "provider_settings.embedding_provider_id") }
    $okM = $lmOn -and ($wantId -ne "") -and ($curId -eq $wantId)
    if (-not $okM) { $bad++ }
    if ($okM) { $md = "记忆开着，用 " + $curId }
    else { $md = "记忆插件" + $(if ($lmOn) { "开着" } else { "没开" }) + "，记忆模型指向「" + $curId + "」，要「" + $wantId + "」" }
    Check "记忆" $okM $md
} else {
    Check "记忆" $true ("没开（memory=" + $memMode + "），不验")
}

# ------------------------------------------------------------------ 语音
$voMode = ""
if ($ans -and $ans.voice) { $voMode = ([string]$ans.voice).Trim() }
if (-not $voMode) { $f = Join-Path $Base "private\voice-mode.txt"; if (Test-Path $f) { $voMode = (Get-Content $f -Raw -Encoding UTF8).Trim() } }
if (-not $voMode -and $pk -and $pk.voice) { $voMode = [string]$pk.voice.default_mode }
if ($voMode -ne "0" -and $voMode -ne "") {
    $ourIds = @()
    if ($pk -and $pk.voice) { foreach ($k in @("edge", "doubao", "breeze", "breeze_online")) { if ($pk.voice.$k) { $ourIds += [string]$pk.voice.$k.id } } }
    $ttsId = [string](Get-Path $cfg "provider_tts_settings.provider_id")
    $ttsOn = [bool](Get-Path $cfg "provider_tts_settings.enable")
    $provOn = $false
    foreach ($p in @($cfg.provider)) { if ($p -and [string]$p.id -eq $ttsId -and $p.enable) { $provOn = $true } }
    $okV = ($ourIds -contains $ttsId) -and ($ttsOn -or $provOn)
    if (-not $okV) { $bad++ }
    if ($okV) { $vd = "语音开着，用「" + $ttsId + "」" + $(if (-not $ttsOn) { "（整条合成）" } else { "" }) }
    else {
        if (-not $ttsId) { $vd = "全局语音没指向任何提供商" }
        elseif ($ourIds -notcontains $ttsId) { $vd = "全局语音指向「" + $ttsId + "」，不是配置包里那几路" }
        else { $vd = "全局语音指向「" + $ttsId + "」，但它没启用" }
    }
    Check "语音" $okV $vd
} else {
    Check "语音" $true ("没开（voice=" + $voMode + "），不验")
}
# ------------------------------------------------------------------ 结论
if ($bad -eq 0) { Done 1 0 "配置都验过了，能聊" }
Done 0 $bad ("有 " + $bad + " 项没通过")
