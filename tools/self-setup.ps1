# 冥零 · 自设定（配置包驱动的一键配置）
#
# 谁调：工作台「一键自动配置」第三段（her::Configure），维护页「只跑自设定」（op:selfsetup），
#       命令行 MinglingWorkbench.exe --selfsetup，也可以手跑：
#   powershell -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Base F:\dafeiyu\bili -DryRun
#   powershell -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Only provider,persona
#   powershell -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Restore <快照路径>
#   powershell -ExecutionPolicy Bypass -File tools\self-setup.ps1 -Verify（只核对八块，不写任何东西）
#
# 分八块，按依赖排：provider（接 DeepSeek）→ platform（QQ 平台 + 白名单）→ chat（聊天设置）
# → plugins（大肥鱼那 10 个插件）→ memory（长期记忆）→ voice（语音）→ persona（人设，交给 import-mingling.ps1）
# → verify（diag-config.ps1 验收）。
# 改之前先存快照（private\snapshots），改坏了能退回去。
#
# 输出协议（C++ 只认这几行）：
#   ##STEP <0-100>|<在做什么>
#   ##OK <块>|<结果>
#   ##FAIL <块>|<为什么 + 怎么办>
#   RESULT ok=<0|1> done=<块数> fail=<块数> [mode=verify] why=<一句话> next=<下一步>
# -Verify 只核对：不 PUT 配置、不拍快照、不写文件（diag-config 也只读）。不加 = 真改（-Apply 同义）。
param(
    [string]$Base = "",
    [string]$Pack = "",
    [string]$Only = "",
    [string]$Restore = "",
    [string]$Answers = "",
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoSnapshot,
    [switch]$Verify,
    [switch]$Apply,
    [switch]$Offline
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}

function Say($m) { Write-Host "[self] $m" }
function Step([int]$pct, [string]$what) { Write-Host ("##STEP " + $pct + "|" + $what) }
function OkLine([string]$blk, [string]$detail) { Write-Host ("##OK " + $blk + "|" + $detail) }
function FailLine([string]$blk, [string]$why) { Write-Host ("##FAIL " + $blk + "|" + $why) }
function Done([int]$ok, [int]$done, [int]$fail, [string]$why, [string]$next) {
    # 前缀 ## 是跟工作台 / 一键自动配置约定的协议（BotsSetup/Configure 都只认 ##RESULT 行）
    $modeTxt = ""
    if ($script:VerifyMode) { $modeTxt = " mode=verify" }
    Write-Host ("##RESULT ok=" + $ok + " done=" + $done + " fail=" + $fail + $modeTxt + " why=" + $why + " next=" + $next)
    if ($ok -ne 1) { exit 1 } else { exit 0 }
}

$script:VerifyMode = $false
if ($Verify -and ($DryRun -or $Restore -or $Apply)) {
    Say "参数冲突：-Verify 是只读核对，不能和 -DryRun / -Restore / -Apply 一起用"
    FailLine "参数" "-Verify 只核对、不改东西；想看会改什么用 -DryRun，想真改用 -Apply（或什么都不加）"
    Done 0 0 1 "参数组合不对" "去掉 -DryRun / -Restore / -Apply 里的写操作开关，再单独跑 -Verify"
}
if ($Apply -and $DryRun) {
    Say "参数冲突：-Apply（真改）和 -DryRun（只看不改）不能一起用"
    FailLine "参数" "-Apply 表示真改，-DryRun 表示只看；二选一"
    Done 0 0 1 "参数组合不对" "去掉 -Apply 或 -DryRun 再跑"
}
$script:VerifyMode = [bool]$Verify

$script:LastError = ""
$script:Token = ""
$script:ApiRoot = ""

# ------------------------------------------------------------------ 路径与配置包
if (-not $Pack) {
    $cand = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) "pack\mingling-pack\pack.json"),
        (Join-Path $PSScriptRoot "pack\mingling-pack\pack.json")
    )
    foreach ($c in $cand) { if (Test-Path $c) { $Pack = $c; break } }
}
if (-not $Pack -or -not (Test-Path $Pack)) { Done 0 0 0 "找不到配置包 pack\mingling-pack\pack.json" "确认工作台这一版带了 pack\，或者用 -Pack 指过去" }
$packRaw = Get-Content $Pack -Raw -Encoding UTF8 | ConvertFrom-Json
$PackDir = Split-Path -Parent $Pack
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PackDir)

if (-not $Base) {
    $setFile = Join-Path $env:APPDATA "MinglingWorkbench\settings.json"
    if (Test-Path $setFile) {
        $raw = Get-Content $setFile -Raw -Encoding UTF8
        if ($raw -match '"base"\s*:\s*"((?:[^"\\]|\\.)*)"') { $Base = ($matches[1] -replace '\\\\', '\') }
    }
}
if (-not $Base) { $Base = $RepoRoot }
$Base = $Base.Trim().Trim('"')
while ($Base.Length -gt 2 -and ($Base.EndsWith('\') -or $Base.EndsWith('/'))) { $Base = $Base.Substring(0, $Base.Length - 1) }
if ($Base.Length -eq 2 -and $Base[1] -eq ':') { $Base = $Base + '\' }
if (-not (Test-Path $Base)) { Done 0 0 0 ("机器人根不存在：" + $Base) "在工作台里设一下机器人根（维护页 → 打开工作区）" }

if (-not $Answers) { $Answers = Join-Path $Base "answers.json" }
$ans = @{}
if (Test-Path $Answers) {
    try { $ans = Get-Content $Answers -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $ans = @{} }
}

$script:SnapDir = Join-Path $Base "private\snapshots"

# ------------------------------------------------------------------ 小工具
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

function Read-Secret([string]$RelOrPath) {
    if (-not $RelOrPath) { return "" }
    $p = $RelOrPath
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $Base $p }
    if (-not (Test-Path $p)) {
        # 敏感项放 <Base>\secrets\；旧版放 <Base>\private\——两个位置都认。
        $alt = ""
        if ($RelOrPath -match '^(?i)private[\\/](.+)$') { $alt = Join-Path (Join-Path $Base 'secrets') $Matches[1] }
        elseif ($RelOrPath -match '^(?i)secrets[\\/](.+)$') { $alt = Join-Path (Join-Path $Base 'private') $Matches[1] }
        if ($alt -and (Test-Path $alt)) { $p = $alt } else { return "" }
    }
    $t = (Get-Content $p -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    $t = $t -replace '^\s*["'']', '' -replace '["'']\s*$', ''
    $t = ($t -split "`r?`n")[0].Trim()
    return $t
}

function Get-Md5([string]$Text) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
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

function Set-Path($obj, [string]$dotted, $val) {
    $segs = $dotted -split '\.'
    $cur = $obj
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        $seg = $segs[$i]
        $p = $cur.PSObject.Properties[$seg]
        $needNew = $true
        if ($p -and $null -ne $p.Value -and $p.Value -is [System.Management.Automation.PSCustomObject]) { $needNew = $false }
        if ($needNew) { $cur | Add-Member -NotePropertyName $seg -NotePropertyValue ([pscustomobject]@{}) -Force }
        $cur = $cur.PSObject.Properties[$seg].Value
    }
    $cur | Add-Member -NotePropertyName $segs[$segs.Count - 1] -NotePropertyValue $val -Force
}

function Api([string]$Method, [string]$Path, $Body = $null, [int]$Timeout = 60) {
    $script:LastError = ""
    $url = $script:ApiRoot + $Path
    $hdr = @{}
    if ($script:Token) { $hdr["Authorization"] = "Bearer " + $script:Token }
    try {
        if ($null -eq $Body) {
            $r = Invoke-WebRequest $url -Method $Method -Headers $hdr -UseBasicParsing -TimeoutSec $Timeout
        } else {
            $json = $Body | ConvertTo-Json -Depth 40
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $hdr["Content-Type"] = "application/json; charset=utf-8"
            $r = Invoke-WebRequest $url -Method $Method -Headers $hdr -Body $bytes -UseBasicParsing -TimeoutSec $Timeout
        }
        $raw = $r.RawContentStream.ToArray()
        $text = [System.Text.Encoding]::UTF8.GetString($raw)
        if (-not $text) { return $null }
        return $text | ConvertFrom-Json
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + " | " + $_.ErrorDetails.Message }
        $script:LastError = $msg
        return $null
    }
}

# AstrBot 的「配置档案」：平台 id 与档案同名时，这个平台用的是那份档案（比如「冥零」平台 → 「冥零」档案），
# 没有同名档案才落回 default。写错档案等于改了别的机器人，所以每次跑都要先问一下后台。
function Get-ActiveProfile {
    if ($script:ProfileId) { return $script:ProfileId }
    $want = ""
    if ($packRaw -and $packRaw.platform -and $packRaw.platform.id) { $want = [string]$packRaw.platform.id }
    $r = Api "GET" "/config-profiles" $null 30
    if ($r -and $r.data -and $r.data.info_list) {
        foreach ($x in $r.data.info_list) {
            if ($want -and ([string]$x.name) -eq $want) { $script:ProfileId = [string]$x.id; return $script:ProfileId }
        }
    }
    $script:ProfileId = "default"
    return $script:ProfileId
}

function Get-Config {
    $r = Api "GET" ("/config-profiles/" + (Get-ActiveProfile)) $null 30
    if ($r -and $r.data -and $r.data.config) { return $r.data.config }
    return $null
}

function Save-Config($cfg) {
    if ($DryRun) { Say "  （dry-run，不写配置）"; return $true }
    $r = Api "PUT" ("/config-profiles/" + (Get-ActiveProfile)) $cfg 60
    if ($null -eq $r) { Say ("  保存失败：" + $script:LastError) ; return $false }
    return $true
}

# ------------------------------------------------------------------ 登录
function Login {
    $port = 6185
    $bu = ""
    if ($ans.backend_url) { $bu = [string]$ans.backend_url }
    if ($bu -match ":(\d+)") { $port = [int]$matches[1] }
    $script:ApiRoot = "http://127.0.0.1:$port/api/v1"

    $kv = Join-Path $Base "private\backend.txt"
    $user = Read-Kv $kv "username"; if (-not $user) { $user = "astrbot" }
    $pass = Read-Kv $kv "password"
    $tok = Read-Kv $kv "token"
    if ($tok) { $script:Token = $tok; Say ("用 backend.txt 里的令牌连 " + $script:ApiRoot); return $true }
    if (-not $pass) { return $false }
    foreach ($tryPw in @($pass, (Get-Md5 $pass))) {
        $r = Api "POST" "/auth/login" @{ username = $user; password = $tryPw } 20
        if ($r -and $r.data -and $r.data.token) { $script:Token = $r.data.token; Say ("已登录 " + $script:ApiRoot); return $true }
    }
    return $false
}

# ------------------------------------------------------------------ 快照 / 退回
function Take-Snapshot([string]$label) {
    if ($Verify) { Say "  （verify，只读核对，不拍快照）"; return "" }
    if ($DryRun -or $NoSnapshot) { return "" }
    $cfg = Get-Config
    if ($null -eq $cfg) { Say "  快照没存成：读不到配置"; return "" }
    $personas = (Api "GET" "/personas" $null 30)
    $bots = (Api "GET" "/bots" $null 30)
    $snap = @{
        version = 1
        time    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        label   = $label
        base    = $Base
        config  = $cfg
        personas = $(if ($personas -and $personas.data) { $personas.data } else { @() })
        bots    = $(if ($bots -and $bots.data) { $bots.data } else { @() })
    }
    $path = Join-Path $script:SnapDir ("before-" + $label + "-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".json")
    $orig = Join-Path $script:SnapDir "original.json"
    try {
        New-Item -ItemType Directory -Force -Path $script:SnapDir | Out-Null
        ($snap | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $path -Encoding UTF8
        if (-not (Test-Path $orig)) { Copy-Item -LiteralPath $path -Destination $orig }
    } catch {
        Say ("  快照写不进 " + $script:SnapDir + "：" + $_.Exception.Message)
        return ""
    }
    $olds = @(Get-ChildItem -Path $script:SnapDir -Filter "before-*.json" | Sort-Object LastWriteTime)
    if ($olds.Count -gt 20) {
        $olds | Select-Object -First ($olds.Count - 20) | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    Say ("  改之前存了快照：" + $path)
    return $path
}

function Do-Restore([string]$path) {
    if (-not (Test-Path $path)) { Done 0 0 0 ("快照不在：" + $path) "去 private\snapshots 里挑一份" }
    $snap = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $bad = @()
    Step 20 "退回全局设置"
    $cur = Get-Config
    if ($null -eq $cur) { Done 0 0 0 "读不到后台配置" "先让 AstrBot 跑起来" }
    $new = $snap.config
    if ($cur.PSObject.Properties["dashboard"]) { $new | Add-Member -NotePropertyName dashboard -NotePropertyValue $cur.dashboard -Force }
    if (-not (Save-Config $new)) { $bad += "config" }
    Step 45 "退回人格"
    if ($snap.personas) {
        $now = (Api "GET" "/personas" $null 30)
        $nowMap = @{}
        if ($now -and $now.data) { foreach ($x in $now.data) { $nowMap[[string]$x.persona_id] = $x } }
        foreach ($x in $snap.personas) {
            $itemId = [string]$x.persona_id
            if (-not $itemId) { continue }
            $body = @{ system_prompt = $x.system_prompt; begin_dialogs = $x.begin_dialogs; tools = $x.tools }
            $q = [uri]::EscapeDataString($itemId)
            if ($nowMap.ContainsKey($itemId)) { $r = Api "PUT" "/personas/$q" $body 60 }
            else { $body["persona_id"] = $itemId; $r = Api "POST" "/personas" $body 60 }
            if ($null -eq $r) { $bad += ("persona:" + $itemId) }
        }
    }
    Step 75 "退回 QQ 平台"
    if ($snap.bots) {
        $curBots = (Api "GET" "/bots" $null 30)
        $ids = @()
        if ($curBots -and $curBots.data) { foreach ($b in $curBots.data) { $ids += [string]$b.id } }
        foreach ($b in $snap.bots) {
            $bid = [string]$b.id
            if (-not $bid) { continue }
            $r = Api "PUT" "/bots/by-id" @{ bot_id = $bid; config = $b } 60
            if ($null -eq $r) { $bad += ("bot:" + $bid) }
        }
    }
    $why = if ($bad.Count -eq 0) { "退回好了" } else { "有没退成的：" + ($bad -join ",") }
    if ($bad.Count -eq 0) { Done 1 1 0 $why "重启 AstrBot 再聊一句看看" }
    Done 0 1 $bad.Count $why "没退成的几样在后台手动改"
}

# ------------------------------------------------------------------ 各块的取值
function Get-DeepSeekKey {
    $k = Read-Secret $packRaw.provider.key_file
    if ($k) { return $k }
    if ($ans.deepseek_key_file) { $k = Read-Secret ([string]$ans.deepseek_key_file); if ($k) { return $k } }
    if ($ans.deepseek_key) { return ([string]$ans.deepseek_key).Trim() }
    if ($env:DEEPSEEK_API_KEY) { return $env:DEEPSEEK_API_KEY.Trim() }
    return ""
}

function Get-OwnerQq {
    $q = Read-Secret $packRaw.owner_file
    if ($q -notmatch '^\d{5,12}$') { $q = "" }
    if (-not $q -and $ans.owner_qq) { $q = ([string]$ans.owner_qq).Trim() }
    if ($q -notmatch '^\d{5,12}$' -and $ans.owner_qq_file) {
        $q = Read-Secret ([string]$ans.owner_qq_file)
    }
    if ($q -match '^\d{5,12}$') { return $q }
    return ""
}

function Get-Groups {
    $t = Read-Secret $packRaw.group_file
    $list = @()
    foreach ($g in ($t -split "[\s,，、;；]+")) { if ($g -match '^\d{5,12}$') { $list += $g } }
    return $list
}

# ------------------------------------------------------------------ 块：provider
function Do-Provider {
    $p = $packRaw.provider
    $sid = [string]$p.source_id
    Step 8 "检查 DeepSeek key"
    $key = Get-DeepSeekKey
    if (-not $key) {
        FailLine "provider" ("没找到 key。把 sk-... 粘进 " + (Join-Path $Base $p.key_file) + " 再跑一次")
        return $false
    }
    # AstrBot 4.13+ 支持 $ENV 引用。真实 Key 只留在 secrets，配置写变量名；
    # 已运行的旧后台进程没有该变量，正式应用前用固定启动脚本重启并重新登录。
    if (-not $script:VerifyMode -and -not $script:DryRun) {
        $starter = Join-Path $PSScriptRoot 'start-astrbot.ps1'
        $astrRoot = Join-Path $Base 'bots\AstrBot'
        if ((Test-Path -LiteralPath $starter) -and (Test-Path -LiteralPath $astrRoot)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $starter -Root $astrRoot -Base $Base -Restart
            if ($LASTEXITCODE -ne 0) { FailLine "provider" "AstrBot 重启以加载密钥环境变量失败"; return $false }
            $script:Token = ''
            if (-not (Login)) { FailLine "provider" "AstrBot 重启后无法重新登录后台"; return $false }
        }
    }
    $src = @{
        id = $sid; provider = [string]$p.provider; type = [string]$p.type; provider_type = [string]$p.provider_type
        enable = $true; key = @('$MINGLING_DEEPSEEK_KEY'); api_base = $(if ($ans.base_url) { [string]$ans.base_url } else { [string]$p.api_base }); timeout = [int]$p.timeout
        proxy = ""; custom_headers = @{}
    }
    Step 14 "接入 DeepSeek 提供商"
    $have = Api "GET" "/provider-sources" $null 30
    $ids = @()
    if ($have -and $have.data) {
        if ($have.data -is [array]) { foreach ($s in $have.data) { $ids += [string]$s.id } }
        elseif ($have.data.provider_sources) { foreach ($s in $have.data.provider_sources) { $ids += [string]$s.id } }
    }
    $r = if ($ids -contains $sid) { Api "PUT" ("/provider-sources/" + $sid) @{ config = $src } 60 }
         else { Api "POST" "/provider-sources" @{ config = $src } 60 }
    if ($null -eq $r) {
        FailLine "provider" ("提供商没写进去：" + $script:LastError + "。看后台在不在、backend.txt 对不对")
        return $false
    }

    Step 22 "挑一个对话模型"
    $model = ""
    $m = Api "GET" ("/provider-sources/" + $sid + "/models") $null 40
    $names = @()
    if ($m -and $m.data) {
        $txt = $m.data | ConvertTo-Json -Depth 6
        $names = [regex]::Matches($txt, '"([^"]*deepseek[a-z0-9./\-]*)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    }
    foreach ($want in $p.prefer_models) { if ($names -contains $want) { $model = $want; break } }
    if (-not $model) {
        $flash = $names | Where-Object { $_ -match 'flash' } | Select-Object -First 1
        if ($flash) { $model = $flash } elseif ($names.Count -gt 0) { $model = $names[0] } else { $model = [string]$p.prefer_models[0] }
    }
    $itemId = $sid + "/" + $model
    $q = [uri]::EscapeDataString($itemId)
    $exist = Api "GET" ("/providers/by-id?provider_id=" + $q) $null 40
    $hasProv = $false
    if ($exist -and $exist.data) { if ($exist.data.id -eq $itemId -or $exist.data.provider) { $hasProv = $true } }
    if (-not $hasProv) {
        $prov = @{
            id = $itemId; enable = $true; provider_source_id = $sid; model = $model
            modalities = @($p.modalities); custom_extra_body = $p.custom_extra_body; max_context_tokens = 0
        }
        Step 26 ("建模型 " + $model)
        $r = Api "POST" ("/provider-sources/" + $sid + "/providers") @{ config = $prov } 60
        if ($null -eq $r) {
            FailLine "provider" ("模型没建成：" + $script:LastError)
            return $false
        }
    }

    Step 30 "测一下这个模型"
    $t = Api "POST" "/providers/test" @{ provider_id = $itemId } 120
    $tst = ""
    if ($t) { $tst = [string]$t.status; if (-not $tst -and $t.data) { $tst = [string]$t.data.status } }
    $testOk = ($null -ne $t) -and ($tst -notmatch 'error|unavailable|failed|timeout')

    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "provider" "模型好了，但读不到配置，默认模型没切"; return $false }
    $cur = [string](Get-Path $cfg "agent_runner.config.model.provider_id")
    if (-not $cur -or $Force) {
        Set-Path $cfg "agent_runner.config.model.provider_id" $itemId
        if (-not (Get-Path $cfg "provider_settings.default_image_caption_provider_id")) {
            Set-Path $cfg "provider_settings.default_image_caption_provider_id" $itemId
        }
        Set-Path $cfg "provider_settings.computer_use_runtime" "none"
        if (-not (Save-Config $cfg)) { FailLine "provider" "默认模型没存上（配置保存失败）"; return $false }
    } else {
        Say ("  默认模型已经是他自己配的 " + $cur + "，不动（要强制换就加 -Force）")
    }
    if (-not $testOk) {
        FailLine "provider" ("模型接口没通过测试（" + $tst + "）：" + $script:LastError + "。key 对不对？余额够不够？改好再跑 --only provider")
        return $false
    }
    OkLine "provider" ("DeepSeek " + $model + " 接好了，测试通过")
    return $true
}

# ------------------------------------------------------------------ 块：platform
function Do-Platform {
    $p = $packRaw.platform
    Step 34 "看 QQ 平台"
    $r = Api "GET" "/bots" $null 30
    $bots = @()
    if ($r -and $r.data) { if ($r.data -is [array]) { $bots = $r.data } elseif ($r.data.bots) { $bots = $r.data.bots } }
    $qq = @($bots | Where-Object { $_.type -eq "aiocqhttp" })
    $wantId = [string]$p.id
    $exact = @($qq | Where-Object { [string]$_.id -eq $wantId })
    $platId = ""
    if ($exact.Count -gt 0) {
        $platId = $wantId
        Say ("  已经有平台「" + $platId + "」，沿用它")
    } elseif ($qq.Count -eq 1) {
        $platId = [string]$qq[0].id
        Say ("  已经有平台「" + $platId + "」，沿用它（不是「" + $wantId + "」；白名单按它的名字写）")
    } elseif ($qq.Count -gt 1) {
        FailLine "platform" ("后台里有 " + $qq.Count + " 个 QQ 平台（" + (($qq | ForEach-Object { $_.id }) -join "、") + "），分不清该接哪个；先在后台删掉多余的，或把 pack.json 里的 platform.id 改成想用的那个")
        return $false
    } else {
        $token = Read-Secret $p.token_file
        if (-not $token) {
            $token = [guid]::NewGuid().ToString("N").Substring(0, 16)
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $Base $p.token_file)) | Out-Null
                Set-Content -LiteralPath (Join-Path $Base $p.token_file) -Value $token -Encoding ASCII
                Say ("  生成了一个连接令牌，写在 " + $p.token_file)
            } catch { Say ("  令牌存不进 private\：" + $_.Exception.Message) }
        }
        $plat = @{
            id = [string]$p.id; type = "aiocqhttp"; enable = $true
            ws_reverse_host = [string]$p.ws_reverse_host; ws_reverse_port = [int]$p.ws_reverse_port
            ws_reverse_token = $token
        }
        Step 38 ("建平台「" + $plat.id + "」")
        if ($DryRun) { Say "  （dry-run，不建平台）" }
        else {
            $w = Api "POST" "/bots" @{ config = $plat } 60
            if ($null -eq $w) { FailLine "platform" ("平台没建成：" + $script:LastError); return $false }
        }
        $platId = [string]$p.id
    }

    $owner = Get-OwnerQq
    $groups = Get-Groups
    if (-not $owner) {
        FailLine "platform" ("平台「" + $platId + "」在位，但还不知道主人是谁：把大号 QQ 号写进 " + (Join-Path $Base $packRaw.owner_file) + " 再跑 --only platform")
        return $false
    }
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "platform" "平台好了，但读不到配置"; return $false }
    # 白名单是并集：别人已经加的条目（别的平台/别的群）一条都不能丢
    $wl = @()
    $curWl = Get-Path $cfg "platform_settings.id_whitelist"
    if ($curWl) { foreach ($e in $curWl) { $wl += [string]$e } }
    $before = $wl.Count
    $want = @($platId + ":FriendMessage:" + $owner)
    foreach ($g in $groups) { $want += ($platId + ":GroupMessage:" + $g) }
    foreach ($e in $want) { if ($wl -notcontains $e) { $wl += $e } }
    $added = $wl.Count - $before
    Set-Path $cfg "platform_settings.enable_id_white_list" $true
    Set-Path $cfg "platform_settings.id_whitelist" $wl
    Set-Path $cfg "platform_settings.wl_ignore_admin_on_group" $false
    Set-Path $cfg "platform_settings.wl_ignore_admin_on_friend" $false
    Set-Path $cfg "platform_settings.id_whitelist_log" $true
    $admins = @()
    $curAdm = Get-Path $cfg "admins_id"
    if ($curAdm) { foreach ($a in $curAdm) { $admins += [string]$a } }
    if (-not ($admins -contains $owner)) { $admins += $owner }
    Set-Path $cfg "admins_id" $admins
    if (-not (Save-Config $cfg)) { FailLine "platform" "白名单没存上（配置保存失败）"; return $false }
    $what = "主人"
    if ($groups.Count -gt 0) { $what = "主人和 " + $groups.Count + " 个群" }
    OkLine "platform" ("平台「" + $platId + "」在位，白名单 " + $wl.Count + " 条（新加 " + $added + " 条，" + $what + "）")
    return $true
}

# ------------------------------------------------------------------ 块：chat
function Do-Chat {
    Step 52 "写聊天设置"
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "chat" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $n = 0
    foreach ($k in $packRaw.chat.PSObject.Properties.Name) {
        if ($k -eq "说明") { continue }
        Set-Path $cfg $k $packRaw.chat.$k
        $n++
    }
    if (-not (Save-Config $cfg)) { FailLine "chat" "聊天设置没存上"; return $false }
    OkLine "chat" ("分段回复、记 " + (Get-Path $cfg "agent_runner.config.compression.max_turns") + " 轮对话、安全模式这些写好了（" + $n + " 项）")
    return $true
}

# ------------------------------------------------------------------ 块：plugins
function Get-FfmpegPath {
    if ($ans.ffmpeg_path -and (Test-Path ([string]$ans.ffmpeg_path))) { return [string]$ans.ffmpeg_path }
    foreach ($rel in @("bots\ffmpeg\bin\ffmpeg.exe", "bots\ffmpeg\ffmpeg.exe", "ffmpeg\bin\ffmpeg.exe")) {
        $p = Join-Path $Base $rel
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $hit = Get-ChildItem -Path (Join-Path $Base "bots") -Filter "ffmpeg.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Get-SiliconKey {
    $k = Read-Secret "private\siliconflow-key.txt"
    if ($k) { return $k }
    if ($ans.siliconflow_key) { return ([string]$ans.siliconflow_key).Trim() }
    return ""
}

function Get-OwnerSession {
    $r = Api "GET" "/bots" $null 30
    $bots = @()
    if ($r -and $r.data) { if ($r.data -is [array]) { $bots = $r.data } elseif ($r.data.bots) { $bots = $r.data.bots } }
    $qq = @($bots | Where-Object { $_.type -eq "aiocqhttp" })
    $wantId = [string]$packRaw.platform.id
    $platId = ""
    $exact = @($qq | Where-Object { [string]$_.id -eq $wantId })
    if ($exact.Count -gt 0) { $platId = $wantId }
    elseif ($qq.Count -eq 1) { $platId = [string]$qq[0].id }
    $owner = Get-OwnerQq
    if ($platId -and $owner) { return ($platId + ":FriendMessage:" + $owner) }
    return ""
}

function Resolve-Placeholder([string]$v) {
    if ($v -notmatch '^\{.+\}$') { return $v }
    $key = $v.Substring(1, $v.Length - 2)
    if ($key -eq "主人会话") { $s = Get-OwnerSession; if ($s) { return $s }; return $null }
    if ($key -eq "ffmpeg") { $f = Get-FfmpegPath; if ($f) { return $f }; return $null }
    if ($key -eq "asr_dir") { if ($ans.asr_dir -and (Test-Path ([string]$ans.asr_dir))) { return [string]$ans.asr_dir }; return $null }
    if ($key -eq "硅基流动key") { $k = Get-SiliconKey; if ($k) { return $k }; return $null }
    return $v
}

function Zip-Folder([string]$Dir, [string]$ZipPath) {
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch {}
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Dir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    return (Test-Path $ZipPath)
}

function ApiUploadZip([string]$Path, [string]$ZipPath, [int]$Timeout = 600) {
    $script:LastError = ""
    $boundary = [guid]::NewGuid().ToString("N")
    $name = [System.IO.Path]::GetFileName($ZipPath)
    $head = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$name`"`r`nContent-Type: application/zip`r`n`r`n"
    $tail = "`r`n--$boundary--`r`n"
    $hb = [System.Text.Encoding]::UTF8.GetBytes($head)
    $tb = [System.Text.Encoding]::UTF8.GetBytes($tail)
    $zip = [System.IO.File]::ReadAllBytes($ZipPath)
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($hb, 0, $hb.Length)
    $ms.Write($zip, 0, $zip.Length)
    $ms.Write($tb, 0, $tb.Length)
    $body = $ms.ToArray()
    $ms.Dispose()
    $hdr = @{ "Authorization" = ("Bearer " + $script:Token); "Content-Type" = ("multipart/form-data; boundary=" + $boundary) }
    try {
        $r = Invoke-WebRequest ($script:ApiRoot + $Path) -Method POST -Headers $hdr -Body $body -UseBasicParsing -TimeoutSec $Timeout
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

# 工作台「功能」页写的覆盖：private\features.txt 里一行一个 "<插件名>=1/0"。
# 有这行就以它为准（用户在界面上去开了），没这行才用配置包的 enable。
function Get-Feature([string]$name) {
    $f = Join-Path $Base "private\features.txt"
    if (-not (Test-Path $f)) { return $null }
    foreach ($line in (Get-Content $f -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        $c = $t.IndexOf("=")
        if ($c -lt 1) { continue }
        if ($t.Substring(0, $c).Trim() -ne $name) { continue }
        $v = $t.Substring($c + 1).Trim().ToLower()
        if ($v -eq "1" -or $v -eq "true" -or $v -eq "on") { return $true }
        return $false
    }
    return $null
}

function Do-Plugins {
    # 工作台配置界面的持久覆盖；保持 pack 本身可分发，用户选择不被自设定盖回去。
    $featureFile = Join-Path $Base 'private\feature-settings.json'
    $featureSettings = $null
    if (Test-Path -LiteralPath $featureFile) {
        try { $featureSettings = Get-Content -LiteralPath $featureFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { FailLine 'plugins' '功能配置文件读不了，未修改插件'; return $false }
    }
    foreach ($pluginItem in @($packRaw.plugins.items)) {
        if ($pluginItem.name -eq 'astrbot_plugin_dafeiyu_sing') {
            if (-not $pluginItem.config) { $pluginItem | Add-Member config ([pscustomobject]@{}) }
            if ($featureSettings.sing) {
                Set-Path $pluginItem.config 'backend' ([string]$featureSettings.sing.backend)
                Set-Path $pluginItem.config 'server_url' ([string]$featureSettings.sing.server_url)
                Set-Path $pluginItem.config 'doubao_tries' ([int]$featureSettings.sing.tries)
            }
            $cloudAppFile = Join-Path $Base 'private\volc-app-id.txt'
            $cloudTokenFile = Join-Path $Base 'private\volc-token.txt'
            if ((Test-Path -LiteralPath $cloudAppFile) -and (Test-Path -LiteralPath $cloudTokenFile)) {
                $cloudApp = (Get-Content -LiteralPath $cloudAppFile -Raw -Encoding UTF8).Trim()
                $cloudToken = (Get-Content -LiteralPath $cloudTokenFile -Raw -Encoding UTF8).Trim()
                if ($cloudApp -and $cloudToken) {
                    Set-Path $pluginItem.config 'doubao_app_id' $cloudApp
                    Set-Path $pluginItem.config 'doubao_access_token' $cloudToken
                }
            }
        }
        if ($pluginItem.name -eq 'astrbot_plugin_dafeiyu_petlink' -and $featureSettings.pet) {
            if (-not $pluginItem.config) { $pluginItem | Add-Member config ([pscustomobject]@{}) }
            foreach ($settingName in @('recent_count','recent_hours','redirect_reminders')) {
                Set-Path $pluginItem.config $settingName $featureSettings.pet.$settingName
            }
        }
    }
    $items = @($packRaw.plugins.items)
    if ($items.Count -eq 0) { FailLine "plugins" "配置包里 plugins.items 是空的"; return $false }
    Step 56 "看现在装了哪些插件"
    $r = Api "GET" "/plugins" $null 60
    if ($null -eq $r) { FailLine "plugins" ("读不到插件列表：" + $script:LastError); return $false }
    $have = @()
    foreach ($x in @($r.data)) { if ($x -and $x.name) { $have += [string]$x.name } }
    $pluginDir = Join-Path $PackDir "plugins"
    $newCount = 0; $cfgCount = 0; $on = 0; $off = 0
    $missed = @(); $changed = @(); $applyFailed = @()
    $i = 0
    foreach ($it in $items) {
        $i++
        $name = [string]$it.name
        if (-not $name) { continue }
        $pct = 56 + [int](8 * $i / $items.Count)
        if ($have -notcontains $name) {
            Step $pct ("装插件 " + $name)
            $dir = Join-Path $pluginDir $name
            if (-not (Test-Path $dir)) { $missed += $name; Say ("  配置包里没有 " + $name); continue }
            if ($DryRun) { Say ("  （dry-run，不传 " + $name + "）"); $newCount++; continue }
            $zip = Join-Path ([System.IO.Path]::GetTempPath()) ($name + ".zip")
            if (-not (Zip-Folder $dir $zip)) { $missed += $name; continue }
            $w = ApiUploadZip "/plugins/install/upload" $zip 600
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            if ($null -eq $w) { $missed += $name; FailLine "plugins" ("装不上 " + $name + "：" + $script:LastError); continue }
            $newCount++
            $changed += $name
            $have += $name
        }
        if ($it.config) {
            $conf = $null
            $g = Api "GET" ("/plugins/config?plugin_id=" + [uri]::EscapeDataString($name)) $null 30
            if ($null -eq $g) { $applyFailed += $name; FailLine 'plugins' ('读不到插件配置，未覆盖：' + $name); continue }
            if ($g -and $g.data) { $conf = $g.data.config }
            if ($null -eq $conf) { $conf = [pscustomobject]@{} }
            $dirty = $false
            foreach ($k in $it.config.PSObject.Properties.Name) {
                $sourceValue = $it.config.$k
                $v = if ($sourceValue -is [string]) { Resolve-Placeholder $sourceValue } else { $sourceValue }
                if ($null -eq $v) { continue }
                if ([string](Get-Path $conf $k) -eq $v) { continue }
                Set-Path $conf $k $v
                $dirty = $true
            }
            if ($dirty) {
                if ($DryRun) { Say ("  （dry-run，不写 " + $name + " 的设置）") }
                else {
                    $w = Api "PUT" "/plugins/config" @{ plugin_id = $name; config = $conf } 60
                    if ($null -eq $w) { $applyFailed += $name; FailLine "plugins" ("设置没写进去 " + $name + "：" + $script:LastError) }
                    else { $cfgCount++; if ($changed -notcontains $name) { $changed += $name } }
                }
            }
        }
    }
    Step 65 "按配置包开关插件"
    $inPlace = 0
    foreach ($it in $items) {
        $name = [string]$it.name
        if (-not $name) { continue }
        if ($have -notcontains $name) { continue }
        $inPlace++
        $want = $true
        if ($null -ne $it.enable) { $want = [bool]$it.enable }
        $ov = Get-Feature $name
        if ($null -ne $ov) { $want = $ov }
        if ($want) { $on++ } else { $off++ }
        if ($DryRun) { Say ("  （dry-run，" + $name + " → " + $(if ($want) { "开" } else { "关" }) + "）"); continue }
        $w = Api "PATCH" "/plugins/enabled" @{ plugin_id = $name; enabled = $want } 60
        if ($null -eq $w) { $applyFailed += $name; FailLine "plugins" ("开关没设上 " + $name + "：" + $script:LastError) }
    }
    if ($changed.Count -gt 0 -and -not $DryRun) {
        Step 66 "重载改过的插件"
        foreach ($name in $changed) { $reload = Api "POST" "/plugins/reload" @{ plugin_id = $name } 180; if ($null -eq $reload) { $applyFailed += $name } }
    }
    if ($missed.Count -gt 0) {
        FailLine "plugins" ("有 " + $missed.Count + " 个没装上：" + ($missed -join "、") + "。看后台版本认不认这个 zip，或者手工在后台装")
        return $false
    }
    if ($applyFailed.Count -gt 0) { FailLine 'plugins' ('部分插件配置未生效：' + (($applyFailed | Select-Object -Unique) -join '、')); return $false }
    $tailTxt = ""
    if ($newCount -gt 0) { $tailTxt = "（这次新装 " + $newCount + " 个）" }
    OkLine "plugins" ("插件 " + $items.Count + " 个：在位 " + $inPlace + " 个，开了 " + $on + " 个、关了 " + $off + " 个" + $tailTxt)
    return $true
}

# ------------------------------------------------------------------ 小件：提供商 / 回答问题
function Get-Answer([string]$key) {
    if ($null -eq $ans) { return "" }
    $prop = $ans.PSObject.Properties[$key]
    if ($null -eq $prop) { return "" }
    return ([string]$prop.Value).Trim()
}

function Get-ModeSetting([string]$answerKey, [string]$fileRel, [string]$def) {
    $m = Get-Answer $answerKey
    if (-not $m) {
        $f = Join-Path $Base $fileRel
        if (Test-Path $f) { $m = (Get-Content $f -Raw -Encoding UTF8).Trim() }
    }
    if ($m -eq "") { $m = $def }
    return $m
}

function Get-ProviderConf([string]$providerId) {
    $q = [uri]::EscapeDataString($providerId)
    $r = Api "GET" ("/providers/" + $q) $null 30
    if ($null -eq $r -or $null -eq $r.data) { return $null }
    $d = $r.data
    if ($d.provider) { $d = $d.provider }
    if ([string]$d.id -eq $providerId) { return $d }
    return $null
}

function Save-ProviderConf($conf) {
    $itemId = [string]$conf.id
    $q = [uri]::EscapeDataString($itemId)
    $old = Get-ProviderConf $itemId
    if ($old) {
        $merged = [ordered]@{}
        foreach ($k in $old.PSObject.Properties.Name) { $merged[$k] = $old.$k }
        foreach ($k in $conf.Keys) { $merged[$k] = $conf[$k] }
        return Api "PUT" ("/providers/" + $q) @{ config = $merged } 60
    }
    return Api "POST" "/providers" @{ config = $conf } 60
}

function Test-ProviderId([string]$providerId) {
    $t = Api "POST" "/providers/test" @{ provider_id = $providerId } 150
    $st = ""
    if ($t) { $st = [string]$t.status; if (-not $st -and $t.data) { $st = [string]$t.data.status } }
    $okT = ($null -ne $t) -and ($st -notmatch 'error|unavailable|failed|timeout')
    return @{ ok = $okT; status = $st; err = $script:LastError }
}

function Get-InstalledPlugins {
    $r = Api "GET" "/plugins" $null 60
    $names = @()
    if ($r) { foreach ($x in @($r.data)) { if ($x -and $x.name) { $names += [string]$x.name } } }
    return $names
}

# ------------------------------------------------------------------ 块：memory
function Do-Memory {
    $m = $packRaw.memory
    $mode = Get-ModeSetting "memory" "private\memory-mode.txt" ([string]$m.default_mode)
    $lm = [string]$m.plugin.name
    if ($mode -eq "0" -or $mode -eq "") {
        Step 68 "记忆：这次不开"
        $have = Get-InstalledPlugins
        if ($have -contains $lm) {
            if ($DryRun) { Say ("  （dry-run，不动 " + $lm + "）") }
            else { $null = Api "PATCH" "/plugins/enabled" @{ plugin_id = $lm; enabled = $false } 60 }
        }
        OkLine "memory" ("记忆没开（memory=" + $mode + "）；以前记住的不动。想开把 answers.json 的 memory 改成 1（本机）或 2（硅基流动）再跑 --only memory")
        return $true
    }
    $spec = $m.modes.$mode
    if ($null -eq $spec) {
        FailLine "memory" ("不认识的 memory=" + $mode + "（0 不要 / 1 本机 Ollama / 2 硅基流动）")
        return $false
    }

    Step 68 ("记忆：看 " + $lm + " 装没装")
    $have = Get-InstalledPlugins
    if ($have -notcontains $lm) {
        if ($DryRun) { Say ("  （dry-run，不装 " + $lm + "）") }
        else {
            $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'components.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
            $comp = @($manifest.components | Where-Object { $_.id -eq 'memory-plugin' }) | Select-Object -First 1
            if (-not $comp -or [string]$comp.source.sha256 -notmatch '^[0-9a-fA-F]{64}$') { FailLine "memory" "清单缺长期记忆插件的固定 SHA256，拒绝从市场盲装"; return $false }
            $sha = ([string]$comp.source.sha256).ToLowerInvariant()
            $url = [string]$comp.source.url
            $cacheDir = Join-Path $Base 'logs\setup\dl'
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            $cache = Join-Path $cacheDir ('memory-plugin-' + $sha.Substring(0, 12) + '.tar.gz')
            $valid = (Test-Path -LiteralPath $cache) -and ((Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sha)
            if (-not $valid) {
                if ($Offline) { FailLine "memory" "离线模式没有校验通过的长期记忆插件缓存：$cache"; return $false }
                if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }
                Say ("  下载固定提交的 " + $lm + "，校验 SHA256…")
                & curl.exe -L -f -sS --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 300 -o $cache $url
                if ($LASTEXITCODE -ne 0) { FailLine "memory" ("下载长期记忆插件失败（curl 退出码 " + $LASTEXITCODE + "）"); return $false }
                if ((Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
                    Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
                    FailLine "memory" "长期记忆插件 SHA256 校验失败，已删除缓存并拒绝安装"
                    return $false
                }
            }
            $tmp = Join-Path $Base ('logs\setup\tmp\memory-plugin-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            try {
                New-Item -ItemType Directory -Force -Path $tmp | Out-Null
                & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $cache -C $tmp
                if ($LASTEXITCODE -ne 0) { FailLine "memory" "解压长期记忆插件归档失败"; return $false }
                $main = @(Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'main.py' -File | Where-Object { Test-Path (Join-Path $_.DirectoryName 'metadata.yaml') } | Select-Object -First 1)
                if ($main.Count -eq 0) { FailLine "memory" "插件归档里没有 metadata.yaml + main.py"; return $false }
                $uploadRoot = Join-Path $tmp $lm
                if ($main[0].DirectoryName -ne $uploadRoot) { Move-Item -LiteralPath $main[0].DirectoryName -Destination $uploadRoot }
                $zip = Join-Path $tmp ($lm + '.zip')
                if (-not (Zip-Folder $uploadRoot $zip)) { FailLine "memory" "打包长期记忆插件失败"; return $false }
                $w = ApiUploadZip "/plugins/install/upload" $zip 600
                if ($null -eq $w) { FailLine "memory" ("装不上固定版本 " + $lm + "：" + $script:LastError); return $false }
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
            $have = Get-InstalledPlugins
            if ($have -notcontains $lm) { FailLine "memory" ("固定归档上传后没看到 " + $lm); return $false }
        }
    }

    $conf = @{
        id = [string]$spec.id; type = [string]$spec.type; provider = [string]$spec.provider
        provider_type = [string]$spec.provider_type; enable = $true
        api_base = [string]$spec.api_base; embedding_model = [string]$spec.model
        embedding_dimensions = [int]$m.embedding_dimensions; embedding_dimensions_mode = "auto"
        timeout = 20; proxy = ""
    }
    if ($spec.api_key) { $conf.embedding_api_key = [string]$spec.api_key }
    if ($spec.key_file) {
        $sf = Get-SiliconKey
        if (-not $sf) {
            FailLine "memory" ("硅基流动 key 是空的：把 key 粘进 " + (Join-Path $Base ([string]$spec.key_file)) + " 再跑 --only memory；不用在线记忆就把 memory 改成 1（本机）或 0（不开）")
            return $false
        }
        $conf.embedding_api_key = $sf
    }

    Step 70 "接入记忆模型"
    if ($DryRun) { Say ("  （dry-run，不写提供商 " + $conf.id + "）") }
    else {
        $w = Save-ProviderConf $conf
        if ($null -eq $w) { FailLine "memory" ("记忆模型没写进去：" + $script:LastError); return $false }
    }

    Step 72 "测一下记忆模型"
    $tt = if ($DryRun) { @{ ok = $true; status = "dry-run"; err = "" } } else { Test-ProviderId ([string]$spec.id) }
    if (-not $tt.ok) {
        if (-not $DryRun) { $null = Save-ProviderConf (@{ id = [string]$spec.id; enable = $false }) }
        FailLine "memory" ("记忆模型测试没通过（" + $tt.status + "）：" + $tt.err + "。本机模式先起 Ollama 并拉 bge-m3；在线模式看 key 和余额。改好再跑 --only memory")
        return $false
    }

    Step 74 "把记忆插件指过去、写好范围"
    if ($DryRun) { OkLine "memory" ("记忆会开：" + [string]$spec."说明" + "（dry-run，没写）"); return $true }
    $r = Api "GET" ("/plugins/config?plugin_id=" + [uri]::EscapeDataString($lm)) $null 30
    $lconf = $null
    if ($r -and $r.data) { $lconf = $r.data.config }
    if ($null -eq $lconf) { $lconf = [pscustomobject]@{} }
    Set-Path $lconf "provider_settings.embedding_provider_id" ([string]$spec.id)
    foreach ($k in $m.plugin_config.PSObject.Properties.Name) { Set-Path $lconf $k $m.plugin_config.$k }
    $plat = [string]$packRaw.platform.id
    $owner = Get-OwnerQq
    $groups = @(Get-Groups)
    $ids = @()
    if ($owner) {
        $ids += ($plat + ":FriendMessage:" + $owner)
        if ($m.scope.include_pet) { $ids += ("webchat:FriendMessage:webchat!" + $owner + "!desk-pet") }
    }
    foreach ($g in $groups) { $ids += ($plat + ":GroupMessage:" + $g) }
    $oldIds = [string](Get-Path $lconf "access_control.allowed_ids")
    foreach ($x in ($oldIds -split "[`r`n,;，；]+")) {
        $x = $x.Trim()
        if (-not $x) { continue }
        if ($x -match '^\d+$') { continue }
        if ($x.StartsWith($plat + ":") -or $x.StartsWith("webchat:")) { continue }
        if ($ids -notcontains $x) { $ids += $x }
    }
    Set-Path $lconf "filtering_settings.memory_scope_mode" "global"
    Set-Path $lconf "filtering_settings.isolated_sessions" ((@($groups | ForEach-Object { $plat + ":GroupMessage:" + $_ })) -join "`n")
    Set-Path $lconf "access_control.whitelist_enabled" $true
    Set-Path $lconf "access_control.allowed_ids" ($ids -join "`n")
    $w = Api "PUT" "/plugins/config" @{ plugin_id = $lm; config = $lconf } 60
    if ($null -eq $w) { FailLine "memory" ("记忆插件的设置没写进去：" + $script:LastError); return $false }
    $null = Api "PATCH" "/plugins/enabled" @{ plugin_id = $lm; enabled = $true } 60
    $null = Api "POST" "/plugins/reload" @{ plugin_id = $lm } 180
    $gn = if ($groups.Count -gt 0) { "，和 " + $groups.Count + " 个群各记各的" } else { "" }
    $pet = if ($m.scope.include_pet) { "和桌宠" } else { "" }
    OkLine "memory" ("记忆开了：" + [string]$spec."说明" + "；范围：主人私聊" + $pet + "共用一份" + $gn)
    return $true
}

# ------------------------------------------------------------------ 块：voice
function Ensure-PluginOn([string]$name) {
    if (-not $name) { return $false }
    if ($DryRun) { Say ("  （dry-run，开 " + $name + "）"); return $true }
    $w = Api "PATCH" "/plugins/enabled" @{ plugin_id = $name; enabled = $true } 60
    if ($null -eq $w) { Say ("  插件开不上 " + $name + "：" + $script:LastError); return $false }
    return $true
}

function Do-Voice {
    $v = $packRaw.voice
    $mode = Get-ModeSetting "voice" "private\voice-mode.txt" ([string]$v.default_mode)
    $prob = [double]$v.trigger_probability
    $ourIds = @([string]$v.edge.id, [string]$v.doubao.id, [string]$v.breeze.id, [string]$v.breeze_online.id)

    if ($mode -eq "0" -or $mode -eq "") {
        Step 76 "语音：这次不开"
        foreach ($id in $ourIds) {
            $old = Get-ProviderConf $id
            if ($old -and $old.enable) {
                if ($DryRun) { Say ("  （dry-run，不关 " + $id + "）") }
                else { $null = Save-ProviderConf (@{ id = $id; enable = $false }) }
            }
        }
        OkLine "voice" ("语音没开（voice=" + $mode + "）。要开改成 1 Edge / 3 豆包 / 4 本机 Breeze / 5 Breeze 在线，再跑 --only voice")
        return $true
    }

    $conf = $null; $ttsOn = $true; $label = ""

    if ($mode -eq "1") {
        $e = $v.edge
        Step 76 "语音：Edge（安装带哈希锁的 edge-tts / pyffmpeg）"
        if (-not $DryRun) {
            $boot = Join-Path $PSScriptRoot 'bootstrap.ps1'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $boot -Base $Base -Workspace $Base -Bots (Join-Path $Base 'bots') -Component edge-tts
            if ($LASTEXITCODE -ne 0) {
                FailLine "voice" "edge-tts / pyffmpeg 没装上（依赖锁或缓存校验失败）；语音设置未改动"
                return $false
            }
        }
        $conf = @{ id = [string]$e.id; type = "edge_tts"; provider = "microsoft"; provider_type = "text_to_speech"; enable = $true
                   voice = [string]$e.voice; rate = "+0%"; volume = "+0%"; pitch = "+0Hz"; timeout = 20; proxy = "" }
        $label = "Edge（" + [string]$e.voice + "）"
    }
    elseif ($mode -eq "3") {
        $d = $v.doubao
        Step 76 "语音：豆包 Seed Audio"
        $have = Get-InstalledPlugins
        if ($have -notcontains [string]$d.plugin) {
            FailLine "voice" ("豆包语音要插件 " + $d.plugin + "，还没装。先跑 --only plugins（它会装上、只是不开），再跑 --only voice")
            return $false
        }
        $null = Ensure-PluginOn ([string]$d.plugin)
        $appId = Get-Answer "volc_app_id"
        if (-not $appId) { $f = Join-Path $Base ([string]$d.app_id_file); if (Test-Path $f) { $appId = (Get-Content $f -Raw -Encoding UTF8).Trim() } }
        $tok = Get-Answer "volc_token"
        if (-not $tok) { $f = Join-Path $Base ([string]$d.token_file); if (Test-Path $f) { $tok = (Get-Content $f -Raw -Encoding UTF8).Trim() } }
        if (-not $appId -or -not $tok) {
            FailLine "voice" ("豆包语音缺火山凭证：app id 写进 " + (Join-Path $Base ([string]$d.app_id_file)) + "、token 写进 " + (Join-Path $Base ([string]$d.token_file)) + "（或 answers.json 的 volc_app_id / volc_token），再跑 --only voice")
            return $false
        }
        $conf = @{ id = [string]$d.id; type = "seed_audio_tts"; provider = "volcengine"; provider_type = "text_to_speech"; enable = $true
                   app_id = $appId; access_key = $tok; credentials_file = ""; api_base = [string]$d.api_base
                   resource_id = [string]$d.resource_id; model = [string]$d.model
                   seed_audio_persona = [string]$d.persona; seed_audio_prompt_template = [string]$d.prompt_template
                   seed_audio_format = [string]$d.format; seed_audio_sample_rate = [int]$d.sample_rate
                   seed_audio_max_attempts = [int]$d.max_attempts; seed_audio_whole_reply = [bool]$d.whole_reply
                   seed_audio_reply_probability = $prob; timeout = [int]$d.timeout }
        $ttsOn = -not [bool]$d.whole_reply
        $label = "豆包（整条合成）"
    }
    elseif ($mode -eq "4") {
        $b = $v.breeze
        Step 76 "语音：看本机 Breeze"
        $have = $null
        try { $r = Invoke-RestMethod -Uri ([string]$b.api_base + "/voices") -TimeoutSec 8; $have = @($r | ForEach-Object { [string]$_.id }) } catch { $have = $null }
        $voice = Get-Answer "breeze_voice"
        if (-not $voice) { $voice = [string]$b.voice }
        if ($null -eq $have) {
            FailLine "voice" ("连不上本机 Breeze（" + $b.api_base + "）：先双击桌面「启动Breeze语音」，开好再跑 --only voice。你现在的语音设置一点没动")
            return $false
        }
        if ($have -notcontains $voice) {
            FailLine "voice" ("Breeze 里还没有叫 " + $voice + " 的声音（现有：" + ($have -join "、") + "）：先双击「做声音.bat」按冥零的声音做一个；或把 answers.json 的 breeze_voice 写成已有的名字，再跑 --only voice。现有语音设置没动")
            return $false
        }
        $conf = @{ id = [string]$b.id; type = "openai_tts_api"; provider = "openai"; provider_type = "text_to_speech"; enable = $true
                   api_key = "unused"; api_base = [string]$b.api_base; model = "tts-1"; "openai-tts-voice" = $voice
                   timeout = 180; proxy = "" }
        $label = "本机 Breeze（" + $voice + "）"
    }
    elseif ($mode -eq "5") {
        $o = $v.breeze_online
        Step 76 "语音：Breeze 在线版"
        $have = Get-InstalledPlugins
        if ($have -notcontains "astrbot_plugin_breeze_online_tts") {
            FailLine "voice" "Breeze 在线语音插件还没装：先跑 --only plugins，再跑 --only voice"
            return $false
        }
        $null = Ensure-PluginOn "astrbot_plugin_breeze_online_tts"
        $keyFile = Get-Answer "breeze_api_key_file"
        if (-not $keyFile) { $keyFile = Join-Path $Base ([string]$o.key_file) }
        $vid = Get-Answer "breeze_voice_id"
        if (-not $vid) { $vid = [string]$o.voice_id }
        if (-not (Test-Path $keyFile)) {
            FailLine "voice" ("缺 Breeze 线上密钥：把密钥存进 " + $keyFile + "（或写 answers.json 的 breeze_api_key_file），再跑 --only voice")
            return $false
        }
        if ($vid -notmatch '^voc_[A-Za-z0-9_-]+$') {
            FailLine "voice" ("Breeze 音色 ID 不对（" + $vid + "）：应是网页上 voc_ 开头的 ID，写进 answers.json 的 breeze_voice_id")
            return $false
        }
        $conf = @{ id = [string]$o.id; type = "breeze_online_tts"; provider = "breeze"; provider_type = "text_to_speech"; enable = $true
                   credentials_file = $keyFile; api_key = ""; api_base = [string]$o.api_base; model = [string]$o.model
                   "elevenlabs-tts-voice-id" = $vid; "elevenlabs-tts-output-format" = "mp3_24000_128"
                   breeze_online_whole_reply = $true; breeze_online_reply_probability = $prob
                   breeze_online_max_chars = [int]$o.max_chars; timeout = [int]$o.timeout; proxy = "" }
        $ttsOn = $false
        $label = "Breeze 在线版"
    }
    else {
        FailLine "voice" ("不认识的 voice=" + $mode + "（0 不要 / 1 Edge / 3 豆包 / 4 本机 Breeze / 5 在线）")
        return $false
    }

    Step 78 ("接入语音 " + $label)
    if ($DryRun) { Say ("  （dry-run，不写 " + $conf.id + "）") }
    else {
        $w = Save-ProviderConf $conf
        if ($null -eq $w) { FailLine "voice" ("语音提供商没写进去：" + $script:LastError); return $false }
    }

    Step 80 "测一下语音"
    $tt = if ($DryRun) { @{ ok = $true; status = "dry-run"; err = "" } } else { Test-ProviderId ([string]$conf.id) }
    if (-not $tt.ok) {
        if (-not $DryRun) { $null = Save-ProviderConf (@{ id = [string]$conf.id; enable = $false }) }
        FailLine "voice" ("语音测试没通过（" + $tt.status + "）：" + $tt.err + "。先关着，改好再跑 --only voice")
        return $false
    }

    if (-not $DryRun) {
        foreach ($id in $ourIds) {
            if ($id -eq [string]$conf.id) { continue }
            $old = Get-ProviderConf $id
            if ($old -and $old.enable) { $null = Save-ProviderConf (@{ id = $id; enable = $false }) }
        }
        $cfg = Get-Config
        if ($null -eq $cfg) { FailLine "voice" "语音提供商好了，但读不到配置，全局语音开关没动"; return $false }
        Set-Path $cfg "provider_tts_settings.enable" $ttsOn
        Set-Path $cfg "provider_tts_settings.provider_id" ([string]$conf.id)
        Set-Path $cfg "provider_tts_settings.trigger_probability" $prob
        if (-not (Save-Config $cfg)) { FailLine "voice" "全局语音开关没存上"; return $false }
    }
    $line = "语音开了：" + $label + "；三条回复里大约一条发语音"
    if ($ttsOn) { $line = $line + "（按段转语音）" } else { $line = $line + "（整条由插件合成，AstrBot 自己的按段语音已关，免得转两遍）" }
    OkLine "voice" $line
    return $true
}
# ------------------------------------------------------------------ 块：persona
function Do-Persona {
    Step 84 "导入冥零人设"
    $inject = Join-Path $RepoRoot ([string]$packRaw.persona.injector)
    if (-not (Test-Path $inject)) {
        $alt = Join-Path $PSScriptRoot ([string]$packRaw.persona.injector)
        if (Test-Path $alt) { $inject = $alt }
    }
    if (-not (Test-Path $inject)) { FailLine "persona" ("没找到 " + $packRaw.persona.injector); return $false }
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $inject, "-Base", $Base)
    if ($DryRun) { $psArgs += "-DryRun" }
    $out = & powershell.exe @psArgs 2>&1 | ForEach-Object { [string]$_ }
    $last = ($out | Where-Object { $_ -match '^RESULT ' } | Select-Object -Last 1)
    if (-not $last) {
        FailLine "persona" ("人设脚本没给出结果：" + (($out | Select-Object -Last 1) -replace '\s+', ' '))
        return $false
    }
    if ($last -notmatch 'ok=1') {
        FailLine "persona" ("人设没导入：" + ($last -replace '^RESULT\s+', ''))
        return $false
    }
    $itemId = [string]$packRaw.persona.id
    OkLine "persona" ("人设「" + $itemId + "」已写入并切成默认")
    return $true
}

# ------------------------------------------------------------------ 块：verify
function Do-Verify {
    Step 88 "验收"
    if ($DryRun) { OkLine "verify" "干跑：不动现场，跳过核对（真跑时才逐项 CHECK）"; return $true }
    $diag = Join-Path $RepoRoot ([string]$packRaw.tools.diag)
    if (-not (Test-Path $diag)) { $alt = Join-Path $PSScriptRoot "diag-config.ps1"; if (Test-Path $alt) { $diag = $alt } }
    if (-not (Test-Path $diag)) { FailLine "verify" "没找到 tools\diag-config.ps1"; return $false }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diag -Base $Base 2>&1 | ForEach-Object { [string]$_ }
    $bad = 0
    foreach ($line in $out) {
        if ($line -match '^CHECK\s+(\S+)\s+(ok|bad)\s*(.*)$') {
            $name = $matches[1]; $st = $matches[2]; $detail = $matches[3]
            if ($st -eq "ok") { Say ("  [ok] " + $name + "  " + $detail) } else { $bad++; Say ("  [!!] " + $name + "  " + $detail) }
        }
    }
    if ($bad -gt 0) { FailLine "verify" ("还有 " + $bad + " 项没通过，看上面 [!!] 的行"); return $false }
    OkLine "verify" "后台、模型、平台、白名单、插件、记忆、语音、人设都对上了"
    return $true
}

# ------------------------------------------------------------------ 块：verify（只读核对）
# -Verify 走这一组：只用 GET 和 /providers/test 这类不改配置的接口，
# 绝不 PUT / PATCH、不拍快照、不写任何文件（diag-config.ps1 也只读）。
function Test-SameJson($a, $b) {
    if ($null -eq $a -and $null -eq $b) { return $true }
    if ($null -eq $a -or $null -eq $b) { return $false }
    $ja = ConvertTo-Json -InputObject $a -Compress -Depth 10
    $jb = ConvertTo-Json -InputObject $b -Compress -Depth 10
    return ([string]$ja -eq [string]$jb)
}

function Get-PluginRows {
    $r = Api "GET" "/plugins" $null 60
    if ($null -eq $r) { return $null }
    return @($r.data)
}

function Verify-Provider {
    Step 8 "核对 DeepSeek 提供商（只读）"
    $p = $packRaw.provider
    $sid = [string]$p.source_id
    if (-not (Get-DeepSeekKey)) {
        FailLine "provider" ("缺 DeepSeek key：应在 " + (Join-Path $Base $p.key_file) + "；补上再跑 -Only provider")
        return $false
    }
    $have = Api "GET" "/provider-sources" $null 30
    if ($null -eq $have) { FailLine "provider" ("读不到提供商列表：" + $script:LastError); return $false }
    $ids = @()
    if ($have.data) {
        if ($have.data -is [array]) { foreach ($s in $have.data) { $ids += [string]$s.id } }
        elseif ($have.data.provider_sources) { foreach ($s in $have.data.provider_sources) { $ids += [string]$s.id } }
    }
    if ($ids -notcontains $sid) {
        FailLine "provider" ("后台里没有提供商「" + $sid + "」；跑 -Only provider 接一下（会写配置）")
        return $false
    }
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "provider" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $cur = [string](Get-Path $cfg "agent_runner.config.model.provider_id")
    if (-not $cur) {
        FailLine "provider" "提供商在，但默认对话模型没设（agent_runner.config.model.provider_id 是空的）；跑 -Only provider"
        return $false
    }
    $tt = Test-ProviderId $cur
    if (-not $tt.ok) {
        FailLine "provider" ("默认模型 " + $cur + " 测不通（" + $tt.status + "）：" + $tt.err + "；看 key / 余额 / 网络")
        return $false
    }
    OkLine "provider" ("DeepSeek 提供商在位，默认模型 " + $cur + " 测试通过")
    return $true
}

function Verify-Platform {
    Step 34 "核对 QQ 平台和白名单（只读）"
    $p = $packRaw.platform
    $wantId = [string]$p.id
    $r = Api "GET" "/bots" $null 30
    if ($null -eq $r) { FailLine "platform" ("读不到平台列表：" + $script:LastError); return $false }
    $bots = @()
    if ($r.data) { if ($r.data -is [array]) { $bots = $r.data } elseif ($r.data.bots) { $bots = $r.data.bots } }
    $qq = @($bots | Where-Object { $_.type -eq "aiocqhttp" })
    if ($qq.Count -eq 0) { FailLine "platform" ("还没加 QQ 平台「" + $wantId + "」；跑 -Only platform（会写配置）"); return $false }
    $platId = ""
    $exact = @($qq | Where-Object { [string]$_.id -eq $wantId })
    if ($exact.Count -gt 0) { $platId = $wantId }
    elseif ($qq.Count -eq 1) { $platId = [string]$qq[0].id }
    else { FailLine "platform" ("有 " + $qq.Count + " 个 QQ 平台，但没有叫「" + $wantId + "」的；在后台删掉多余的或改回这个名"); return $false }
    $owner = Get-OwnerQq
    if (-not $owner) { FailLine "platform" ("平台「" + $platId + "」在位，但没填主人 QQ：写进 " + (Join-Path $Base $packRaw.owner_file)); return $false }
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "platform" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $miss = @()
    $wlArr = @()
    $wl = Get-Path $cfg "platform_settings.id_whitelist"
    if ($wl) { foreach ($e in $wl) { $wlArr += [string]$e } }
    $sess = $platId + ":FriendMessage:" + $owner
    if ($wlArr -notcontains $sess) { $miss += ("白名单里没有 " + $sess) }
    foreach ($g in (Get-Groups)) {
        $gs = $platId + ":GroupMessage:" + $g
        if ($wlArr -notcontains $gs) { $miss += ("白名单里没有 " + $gs) }
    }
    if (-not [bool](Get-Path $cfg "platform_settings.enable_id_white_list")) { $miss += "白名单开关没开（platform_settings.enable_id_white_list）" }
    $admArr = @()
    $adm = Get-Path $cfg "admins_id"
    if ($adm) { foreach ($a in $adm) { $admArr += [string]$a } }
    if ($admArr -notcontains $owner) { $miss += ("管理员里没有主人 " + $owner) }
    if ($miss.Count -gt 0) {
        FailLine "platform" ("平台「" + $platId + "」在位，但：" + ($miss -join "；") + "。跑 -Only platform 补")
        return $false
    }
    OkLine "platform" ("平台「" + $platId + "」在位，白名单 " + $wlArr.Count + " 条（主人在），管理员对")
    return $true
}

function Verify-Chat {
    Step 52 "核对聊天设置（只读）"
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "chat" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $bad = @(); $n = 0
    foreach ($k in $packRaw.chat.PSObject.Properties.Name) {
        if ($k -eq "说明") { continue }
        $n++
        $want = $packRaw.chat.$k
        $got = Get-Path $cfg $k
        if (-not (Test-SameJson $want $got)) {
            $gv = ConvertTo-Json -InputObject $got -Compress -Depth 6
            $bad += ($k + "（现在是 " + $gv + "）")
        }
    }
    if ($bad.Count -gt 0) {
        $show = @($bad | Select-Object -First 4) -join "、"
        if ($bad.Count -gt 4) { $show = $show + " 等" }
        FailLine "chat" ("有 " + $bad.Count + "/" + $n + " 项和配置包不一样：" + $show + "。跑 -Only chat 补齐")
        return $false
    }
    OkLine "chat" ("分段回复、记 " + (Get-Path $cfg "agent_runner.config.compression.max_turns") + " 轮对话、安全模式这些都对上了（" + $n + " 项）")
    return $true
}

function Verify-Plugins {
    Step 56 "核对插件（只读）"
    $items = @($packRaw.plugins.items)
    if ($items.Count -eq 0) { FailLine "plugins" "配置包里 plugins.items 是空的"; return $false }
    $rows = Get-PluginRows
    if ($null -eq $rows) {
        if ($script:LastError) { FailLine "plugins" ("读不到插件列表：" + $script:LastError); return $false }
        $rows = @()
    } else {
        $rows = @($rows)
    }
    $state = @{}
    foreach ($x in $rows) { if ($x -and $x.name) { $state[[string]$x.name] = [bool]$x.activated } }
    $missing = @(); $wrong = @(); $on = 0; $off = 0; $ov = 0
    foreach ($it in $items) {
        $name = [string]$it.name
        if (-not $name) { continue }
        if (-not $state.ContainsKey($name)) { $missing += $name; continue }
        $want = $true
        if ($null -ne $it.enable) { $want = [bool]$it.enable }
        $o = Get-Feature $name
        if ($null -ne $o) { $want = $o; $ov++ }
        if ($want) { $on++ } else { $off++ }
        if ($state[$name] -ne $want) {
            $nowTxt = if ($state[$name]) { "开着" } else { "关着" }
            $wantTxt = if ($want) { "该开" } else { "该关" }
            $wrong += ($name + "（现在" + $nowTxt + "，" + $wantTxt + "）")
        }
    }
    if ($missing.Count -gt 0) {
        FailLine "plugins" ("有 " + $missing.Count + " 个没装：" + (($missing | Select-Object -First 6) -join "、") + "。跑 -Only plugins 装上")
        return $false
    }
    if ($wrong.Count -gt 0) {
        FailLine "plugins" ("插件都在，但开关不对：" + (($wrong | Select-Object -First 6) -join "、") + "。跑 -Only plugins 按配置包开关")
        return $false
    }
    $tail = ""
    if ($ov -gt 0) { $tail = "（features.txt 覆盖 " + $ov + " 个）" }
    OkLine "plugins" ("插件 " + $items.Count + " 个都在位，开 " + $on + " 关 " + $off + " 和配置包一致" + $tail)
    return $true
}

function Verify-Memory {
    $m = $packRaw.memory
    $mode = Get-ModeSetting "memory" "private\memory-mode.txt" ([string]$m.default_mode)
    $lm = [string]$m.plugin.name
    if ($mode -eq "0" -or $mode -eq "") {
        Step 68 "记忆：这次不开"
        OkLine "memory" ("记忆没开（memory=" + $mode + "），不用核对；想开把 answers.json 的 memory 改成 1 或 2 再跑 -Only memory")
        return $true
    }
    Step 68 ("核对记忆（mode=" + $mode + "）")
    $spec = $m.modes.$mode
    if ($null -eq $spec) { FailLine "memory" ("不认识的 memory=" + $mode + "（0 不要 / 1 本机 / 2 硅基流动）"); return $false }
    $rows = Get-PluginRows
    if ($null -eq $rows) { FailLine "memory" ("读不到插件列表：" + $script:LastError); return $false }
    $row = @($rows | Where-Object { $_ -and [string]$_.name -eq $lm }) | Select-Object -First 1
    if ($null -eq $row) { FailLine "memory" ("记忆插件 " + $lm + " 还没装；跑 -Only memory 或 -Only plugins"); return $false }
    if (-not [bool]$row.activated) { FailLine "memory" ("记忆插件 " + $lm + " 装了但没开；跑 -Only memory"); return $false }
    $r = Api "GET" ("/plugins/config?plugin_id=" + [uri]::EscapeDataString($lm)) $null 30
    $cur = ""
    if ($r -and $r.data -and $r.data.config) { $cur = [string](Get-Path $r.data.config "provider_settings.embedding_provider_id") }
    $want = [string]$spec.id
    if ($cur -ne $want) { FailLine "memory" ("记忆插件指的 embedding provider 是「" + $cur + "」，应为「" + $want + "」；跑 -Only memory"); return $false }
    $tt = Test-ProviderId $want
    if (-not $tt.ok) { FailLine "memory" ("记忆模型「" + $want + "」测不通（" + $tt.status + "）：" + $tt.err); return $false }
    OkLine "memory" ("记忆开着：" + [string]$spec."说明" + "，插件已开、embedding 指向对、测试通过")
    return $true
}

function Verify-Voice {
    $v = $packRaw.voice
    $mode = Get-ModeSetting "voice" "private\voice-mode.txt" ([string]$v.default_mode)
    if ($mode -eq "0" -or $mode -eq "") {
        Step 76 "语音：这次不开"
        OkLine "voice" ("语音没开（voice=" + $mode + "），不用核对；想开把 answers.json 的 voice 改成 1/3/4/5 再跑 -Only voice")
        return $true
    }
    Step 76 ("核对语音（mode=" + $mode + "）")
    $spec = $null; $label = ""; $ttsOn = $true; $need = ""
    if ($mode -eq "1") { $spec = $v.edge; $label = "Edge"; $ttsOn = $true }
    elseif ($mode -eq "3") { $spec = $v.doubao; $label = "豆包"; $ttsOn = (-not [bool]$v.doubao.whole_reply); $need = [string]$v.doubao.plugin }
    elseif ($mode -eq "4") { $spec = $v.breeze; $label = "本机 Breeze"; $ttsOn = $true }
    elseif ($mode -eq "5") { $spec = $v.breeze_online; $label = "Breeze 在线"; $ttsOn = $false; $need = "astrbot_plugin_breeze_online_tts" }
    else { FailLine "voice" ("不认识的 voice=" + $mode + "（0 / 1 Edge / 3 豆包 / 4 本机 Breeze / 5 在线）"); return $false }
    $wantId = [string]$spec.id
    if ($need) {
        $rows = Get-PluginRows
        if ($null -eq $rows) { FailLine "voice" ("读不到插件列表：" + $script:LastError); return $false }
        $row = @($rows | Where-Object { $_ -and [string]$_.name -eq $need }) | Select-Object -First 1
        if ($null -eq $row) { FailLine "voice" ("语音插件 " + $need + " 还没装；先跑 -Only plugins"); return $false }
        if (-not [bool]$row.activated) { FailLine "voice" ("语音插件 " + $need + " 装了但没开；跑 -Only voice"); return $false }
    }
    if ($mode -eq "5") {
        $keyFile = Get-Answer "breeze_api_key_file"
        if (-not $keyFile) { $keyFile = Join-Path $Base ([string]$v.breeze_online.key_file) }
        if (-not (Test-Path $keyFile)) { FailLine "voice" ("缺 Breeze 线上密钥文件 " + $keyFile + "；存进去再跑 -Only voice"); return $false }
    }
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "voice" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $curId = [string](Get-Path $cfg "provider_tts_settings.provider_id")
    if ($curId -ne $wantId) { FailLine "voice" ("全局语音 provider 是「" + $curId + "」，应为「" + $wantId + "」；跑 -Only voice"); return $false }
    $en = [bool](Get-Path $cfg "provider_tts_settings.enable")
    if ($en -ne $ttsOn) {
        $wantTxt = if ($ttsOn) { "开着" } else { "关着" }
        FailLine "voice" ("全局按段语音应" + $wantTxt + "（provider_tts_settings.enable=" + $en + "）；跑 -Only voice")
        return $false
    }
    $conf = Get-ProviderConf $wantId
    if ($null -eq $conf -or -not $conf.enable) { FailLine "voice" ("语音提供商「" + $wantId + "」没配或没启用；跑 -Only voice"); return $false }
    $tt = Test-ProviderId $wantId
    if (-not $tt.ok) { FailLine "voice" ("语音「" + $label + "」测不通（" + $tt.status + "）：" + $tt.err + "；看服务/凭证"); return $false }
    OkLine "voice" ("语音开着：" + $label + "，provider 指向对、全局开关对、测试通过")
    return $true
}

function Verify-Persona {
    Step 84 "核对人设（只读）"
    $itemId = [string]$packRaw.persona.id
    $r = Api "GET" ("/personas/" + [uri]::EscapeDataString($itemId)) $null 30
    if ($null -eq $r) { FailLine "persona" ("读不到人设：" + $script:LastError); return $false }
    $has = ($r -and $r.data -and ([string]$r.data.persona_id -eq $itemId))
    if (-not $has) { FailLine "persona" ("人设「" + $itemId + "」还没导入；跑 -Only persona（会写配置）"); return $false }
    $cfg = Get-Config
    if ($null -eq $cfg) { FailLine "persona" "读不到后台配置（AstrBot 没跑？）"; return $false }
    $cur = [string](Get-Path $cfg "agent_runner.config.persona.persona_id")
    if ($cur -ne $itemId) { FailLine "persona" ("人设「" + $itemId + "」在，但默认人设是「" + $cur + "」；跑 -Only persona 切过来"); return $false }
    OkLine "persona" ("人设「" + $itemId + "」在，且是默认")
    return $true
}

function Verify-SelfCheck {
    Step 88 "跑 diag-config.ps1 全面核对（只读）"
    $diag = Join-Path $RepoRoot ([string]$packRaw.tools.diag)
    if (-not (Test-Path $diag)) { $alt = Join-Path $PSScriptRoot "diag-config.ps1"; if (Test-Path $alt) { $diag = $alt } }
    if (-not (Test-Path $diag)) { FailLine "verify" "没找到 tools\diag-config.ps1"; return $false }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diag -Base $Base 2>&1 | ForEach-Object { [string]$_ }
    $diagExit = $LASTEXITCODE
    $bad = 0; $checked = 0
    foreach ($line in $out) {
        if ($line -match '^CHECK\s+(\S+)\s+(ok|bad)\s*(.*)$') {
            $checked++
            $name = $matches[1]; $st = $matches[2]; $detail = $matches[3]
            if ($st -eq "ok") { Say ("  [ok] " + $name + "  " + $detail) } else { $bad++; Say ("  [!!] " + $name + "  " + $detail) }
        }
    }
    if ($diagExit -ne 0) { FailLine "verify" ("diag-config.ps1 没有正常完成（退出码 " + $diagExit + "）；检查诊断脚本或后台后重试"); return $false }
    if ($checked -eq 0) { FailLine "verify" "diag-config.ps1 没有返回任何 CHECK 检查结果，无法确认配置；检查诊断脚本后重试"; return $false }
    if ($bad -gt 0) { FailLine "verify" ("还有 " + $bad + " 项没通过，看上面 [!!] 的行"); return $false }
    OkLine "verify" "后台、模型、平台、白名单、插件、记忆、语音、人设都对上了"
    return $true
}

# ------------------------------------------------------------------ 主流程
Say ("冥零 · 自设定")
Say ("  根   : " + $Base)
Say ("  包   : " + $Pack)
Say ("  模式 : " + $(if ($Verify) { "verify（只读核对，不改任何东西）" } elseif ($DryRun) { "dry-run（只看不改）" } elseif ($Restore) { "退回快照" } else { "真改" }))

if (-not (Login)) {
    Step 0 "连后台"
    FailLine "后台" ("没登录上 " + $script:ApiRoot + "（" + $script:LastError + "）")
    Done 0 0 1 "后台没连上" "先把 AstrBot 跑起来；登录信息写在 private\backend.txt（username / password 或 token）"
}

if ($Restore) { Do-Restore $Restore }

$all = @{ provider = ${function:Do-Provider}; platform = ${function:Do-Platform}; chat = ${function:Do-Chat}; plugins = ${function:Do-Plugins}; memory = ${function:Do-Memory}; voice = ${function:Do-Voice}; persona = ${function:Do-Persona}; verify = ${function:Do-Verify} }
$blocks = $all
if ($Verify) {
    $blocks = @{ provider = ${function:Verify-Provider}; platform = ${function:Verify-Platform}; chat = ${function:Verify-Chat}; plugins = ${function:Verify-Plugins}; memory = ${function:Verify-Memory}; voice = ${function:Verify-Voice}; persona = ${function:Verify-Persona}; verify = ${function:Verify-SelfCheck} }
}
$order = @("provider", "platform", "chat", "plugins", "memory", "voice", "persona", "verify")
$wanted = $order
if ($Only) {
    $wanted = @()
    foreach ($x in ($Only -split '[,，\s]+')) {
        $t = $x.Trim().ToLower()
        if (-not $t) { continue }
        if ($all.ContainsKey($t)) { $wanted += $t } else { Say ("  不认识的块：" + $x + "（可选 provider/platform/chat/plugins/memory/voice/persona/verify）") }
    }
    if ($wanted.Count -eq 0) { Done 0 0 0 ("-Only 里没有能跑的块：" + $Only) "写成 provider,platform,chat,plugins,memory,voice,persona,verify 里的一串" }
}

if (-not $Restore -and -not $Verify) { Take-Snapshot "selfsetup" | Out-Null }

$done = 0; $fail = 0
foreach ($b in $wanted) {
    try {
        $okB = & $blocks[$b]
        if ($okB) { $done++ } else { $fail++ }
    } catch {
        $fail++
        FailLine $b ("这一块出错了（" + $_.Exception.GetType().Name + "：" + $_.Exception.Message + "），别的块照常跑")
    }
}

$why = if ($fail -eq 0) { if ($Verify) { if ($done -eq 8) { "核对完了，八块都对上了" } else { ("核对完了，这 " + $done + " 块都对上了") } } else { "自设定跑完了，都成了" } } elseif ($Verify) { ("有 " + $fail + " 块没通过核对") } else { ("有 " + $fail + " 块没成") }
$next = if ($Verify) { "想真改就去掉 -Verify 跑同一命令（或 -Only 某块）" } elseif ($fail -eq 0) { "去 QQ 上发 /reset 清掉旧对话，再发「在吗」" } else { "看上面 ##FAIL 的行，改好再跑一次（只补没成的块：--only provider,persona 之类）" }
if ($fail -eq 0) { Done 1 $done $fail $why $next }
Done 0 $done $fail $why $next
