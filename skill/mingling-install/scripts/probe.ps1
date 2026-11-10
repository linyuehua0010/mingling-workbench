param([string]$Base = "")

# 冥零工作台体检：找工作台、工作区、组件、端口、这份 Skill 的版本，最后给一句结论。
# 只读，不改任何东西。用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1 [-Base <工作区>]

$ErrorActionPreference = 'SilentlyContinue'
$rows = New-Object System.Collections.ArrayList
function Line([string]$k, [string]$v) { [void]$rows.Add("$k $v") }

function PortOpen([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $ok = $c.ConnectAsync('127.0.0.1', $port).Wait(400) } catch { $ok = $false }
    $c.Dispose()
    return $ok
}

function ReadJson([string]$p) {
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw -Encoding UTF8) | ConvertFrom-Json } catch { return $null }
}

# --- 1. 候选工作区：命令行 > 两个状态目录的 settings.json > 桌面快捷方式 > 正在跑的进程
$cands = New-Object System.Collections.ArrayList
if ($Base) { [void]$cands.Add([pscustomobject]@{ ws = $Base; from = '命令行 -Base'; base = '' }) }

foreach ($d in @((Join-Path $env:APPDATA 'MinglingWorkbench'),
                 (Join-Path $env:APPDATA 'MinglingWorkbench\snapshot'))) {
    $p = Join-Path $d 'settings.json'
    if (-not (Test-Path $p)) { continue }
    $j = ReadJson $p
    if ($j -and $j.workspace) {
        [void]$cands.Add([pscustomobject]@{ ws = [string]$j.workspace; from = "settings.json ($p)"; base = [string]$j.base })
    }
}

$program = (& (Join-Path $PSScriptRoot 'resolve-program-root.ps1') -Quiet 2>$null | Out-String).Trim()

# 工作区只从 settings.json / -Base 认；安装目录不是工作区，不能再用 exe 往上两级猜。
# 程序目录已由 resolve-program-root.ps1 统一解析，供下面的版本检查复用。

# 挑第一个「像工作区」的：有 bots\ 或 answers.json 或 private\
$pick = $null
foreach ($c in $cands) {
    if (-not $c.ws) { continue }
    if ((Test-Path (Join-Path $c.ws 'bots')) -or (Test-Path (Join-Path $c.ws 'answers.json')) -or
        (Test-Path (Join-Path $c.ws 'private'))) { $pick = $c; break }
}
if (-not $pick -and $cands.Count -gt 0) { $pick = $cands[0] }

if (-not $pick) {
    Line '##工作台' '没找到（既没装、也没在跑）'
    Line '##工作区' '没找到'
    Line '##结论' '没装过：让他跑一次 MinglingWorkbench-<版本>-setup.exe，装哪个盘由他挑'
    $rows | ForEach-Object { $_ }
    exit 0
}

$ws = $pick.ws
$exe = if ($program) { Join-Path $program 'MinglingWorkbench.exe' } else { '' }
$ver = ''
if ($exe -and (Test-Path $exe)) {
    try { $ver = (Get-Item $exe).VersionInfo.FileVersion } catch {}
    Line '##工作台' "$exe  版本 $([string]$ver)（来源：程序根目录解析）"
} else {
    Line '##工作台' "没找到程序目录里的 MinglingWorkbench.exe"
}
Line '##工作区' $ws

# --- 2. 机器人根对不对：settings 的 base 必须等于工作区
$baseFromSettings = $pick.base
if (-not $baseFromSettings) {
    foreach ($c in $cands) { if ($c.ws -eq $ws -and $c.base) { $baseFromSettings = $c.base } }
}
$rootOk = $true
if ($baseFromSettings) {
    $b = $baseFromSettings.TrimEnd('\', '/')
    $w = $ws.TrimEnd('\', '/')
    if ($b -ne $w) { $rootOk = $false }
}
$backend = Join-Path $ws 'private\backend.txt'
Line '##根' ("base=" + $(if ($baseFromSettings) { $baseFromSettings } else { '（settings 里没写）' }) +
             "；private\backend.txt=" + $(if (Test-Path $backend) { '在' } else { '不在' }) +
             "；一致=" + $(if ($rootOk) { '是' } else { '否' }))

# --- 3. 组件
$bots = Join-Path $ws 'bots'
$comp = New-Object System.Collections.ArrayList
foreach ($n in @('uv', 'AstrBot', 'SnowLuma', 'ffmpeg', 'asr', 'Ollama', 'ollama-models', 'Breeze')) {
    [void]$comp.Add("$n=" + $(if (Test-Path (Join-Path $bots $n)) { '有' } else { '缺' }))
}
if (-not (Test-Path $bots)) {
    Line '##组件' '没有 bots\ 目录（组件都没装，或者工作区选错了）'
} else {
    Line '##组件' ($comp -join '  ')
}

# --- 4. 端口
$svc = New-Object System.Collections.ArrayList
foreach ($it in @(@(6185, 'AstrBot 后台'), @(6199, 'AstrBot 连接'), @(5099, 'SnowLuma'), @(8137, 'Breeze'), @(11434, 'Ollama'))) {
    [void]$svc.Add("$($it[1])=" + $(if (PortOpen $it[0]) { '在听' } else { '没听' }))
}
Line '##服务' ((($svc -join '  ') -replace '=', ':'))

# --- 5. 这份 Skill 认没认上
$sv = ReadJson (Join-Path $ws 'tools\skill-version.json')
$sh = ''
$shFile = Join-Path $ws 'tools\skill-home.txt'
if (Test-Path $shFile) { $sh = (Get-Content $shFile -Raw -Encoding UTF8).Trim() }
$skillVer = ''
if ($sv -and $sv.version) { $skillVer = [string]$sv.version }
if (-not $skillVer) {
    $alt = Join-Path $env:USERPROFILE '.agents\skills\mingling-install\version.json'
    $aj = ReadJson $alt
    if ($aj -and $aj.version) { $skillVer = [string]$aj.version; if (-not $sh) { $sh = Split-Path $alt -Parent } }
}
Line '##技能' ("版本=" + $(if ($skillVer) { $skillVer } else { '没认上' }) +
              "；skill-home=" + $(if ($sh -and (Test-Path $sh)) { $sh } elseif ($sh) { "$sh（目录不在）" } else { '没写' }))

# --- 6. 结论
$caps = Join-Path $bots 'AstrBot\data\config'
$why = ''
if (-not (Test-Path (Join-Path $bots 'AstrBot'))) {
    $why = '装了但组件缺：用 skill 的 scripts\bootstrap.ps1（维护页「一键自动配置」同一入口），把 bots 补齐'
} elseif (-not (Test-Path $backend)) {
    $why = '工作区里没有 private\backend.txt：机器人根多半算错了，先把这个文件补上或把 base 改回工作区'
} elseif (-not $rootOk) {
    $why = "机器人根跟设置不一致：settings 的 base 是 $baseFromSettings，工作区是 $ws；自设定会去 base 下找 private\backend.txt，然后报「后台没连上」"
} elseif (-not (PortOpen 6185)) {
    $why = '工作台在，AstrBot 后台没开：先启动她（总览页「全部启动」或 start-astrbot.cmd）'
} elseif (-not $skillVer) {
    $why = '都装齐了，但工作台还不认识这份 Skill：跑 scripts\finish.ps1 -Dir "' + $ws + '"'
} else {
    $why = "看着都齐了：工作台 $([string]$ver)，组件齐，后台在听，Skill $skillVer。哪一样不对，按 SKILL.md 第 4 步对着症状查"
}
Line '##结论' $why

$rows | ForEach-Object { $_ }
