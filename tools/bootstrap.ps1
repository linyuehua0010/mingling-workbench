#requires -Version 5.1
<#
  冥零工作台 · 组件安装引擎（V3.1.0）

  一份清单（tools\components.json）驱动：检测 → 安装 → 验证，可重复跑。
  工作台「一键自动配置」、安装器、mingling-install 技能都调这一个脚本，不另写一套。

  常用：
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1 -Check
        只检测。必需组件全齐退出码 0，否则 2；脚本自身出错 1。
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap.ps1
        按 requires 拓扑序补齐默认组件。
    powershell ... -Component node,ffmpeg -Offline
        只补指定组件；离线只用本地缓存（缓存必须通过 sha256 校验）。
    powershell ... -Proxy http://127.0.0.1:7890 -LogFile D:\logs\bootstrap.log

  输出给调用方解析的协议行（其余是给人看的）：
    ##STEP <0-100>|<正在做什么>
    ##OK <id>|<已满足或已装好>
    ##FAIL <id>|<缺什么或为什么失败>
    ##RESULT ok=<0|1> fixed=<n> satisfied=<n> manual=<n> missing=<n> failed=<n>

  参数与清单格式见 docs\setup-automation.md。
#>
[CmdletBinding()]
param(
    [string]$Base = '',
    [string]$Workspace = '',
    [string]$Bots = '',
    [string[]]$Component = @(),
    [string[]]$Exclude = @(),
    [switch]$Check,
    [switch]$Offline,
    [string]$Proxy = '',
    [switch]$IncludeOptional,
    [switch]$Force,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'

$script:Repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'components.json'))) {
    Write-Host '缺少 tools\components.json，无法继续。'
    exit 1
}
$common = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host '缺少 tools\common.ps1（下载与公共函数），无法继续。'
    exit 1
}
. $common

# ---------------------------------------------------------------- 全局状态

$script:Stat = @{ fixed = 0; satisfied = 0; manual = 0; missing = 0; failed = 0; skipped = 0 }
$script:Results = New-Object System.Collections.ArrayList
$script:LogPath = ''
$script:StatePath = ''
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:Dirty = $false
$script:ExplicitLog = [bool]$LogFile
$script:ProxyHost = ''
$script:CheckMode = [bool]$Check
$script:OfflineMode = [bool]$Offline
$script:Manifest = $null
# 不要在这里把 $script:Base/$script:Workspace/$script:Bots 置空：脚本顶层 $script: 就是参数所在作用域，
# 置空会把 -Base/-Workspace/-Bots 传进来的值抹掉（10-09 踩过，参数被 settings.json 悄悄顶掉）。
$script:Sidecar = ''
$script:AstrbotData = ''

function Normalize-Dir([string]$p) {
    if (-not $p) { return '' }
    $p = $p.Trim().Trim('"')
    try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}

function Read-WorkbenchSettings {
    $p = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MinglingWorkbench\settings.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    foreach ($enc in @([Text.Encoding]::UTF8, [Text.Encoding]::Default)) {
        try { return ([IO.File]::ReadAllText($p, $enc) | ConvertFrom-Json) } catch { }
    }
    return $null
}

# 只隐藏密钥，不改普通路径/中文。日志、协议行、state.json 都过这一层。
function Redact-Text([string]$text) {
    if (-not $text) { return '' }
    $t = $text
    $t = [regex]::Replace($t, '(?i)(sk-[A-Za-z0-9_\-]{8,})', 'sk-***')
    $t = [regex]::Replace($t, '(?i)(Bearer\s+)[A-Za-z0-9_\-\.=]{6,}', '$1***')
    $t = [regex]::Replace($t, '(?i)\b(api[_-]?key|access[_-]?key|token|secret|password|passwd|pwd)\b(\s*[=:：]\s*)("?)[^"\s,;]{3,}\3', '$1$2***')
    $t = [regex]::Replace($t, '(?i)([?&](?:key|token|access_token|api_key)=)[^&\s]+', '$1***')
    $t = [regex]::Replace($t, '(?i)\b(gh[pousr]_[A-Za-z0-9]{20,})\b', 'gh*_***')
    $t = [regex]::Replace($t, '(?i)(https?://)[^/\s@]+:[^/\s@]+@', '$1***@')
    $t = [regex]::Replace($t, '(?i)(qq|uin|QQ号|账号)(\s*[=:：]\s*)\d{5,12}', '$1$2***')
    return $t
}

function Write-LogLine([string]$line) {
    if (-not $script:LogPath) { return }
    $safe = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), (Redact-Text $line)
    [void]$script:LogBuffer.Add($safe)
    # 真正开始改动前只缓冲；全部满足的重复运行不创建日志、不改 state.json。
    if (-not $script:Dirty) { return }
    try {
        $parent = Split-Path -Parent $script:LogPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value $safe -Encoding UTF8
    } catch { }
}

# 同时打到控制台（工作台/安装器会抓 stdout）和日志文件。
function Emit([string]$line) {
    $safe = Redact-Text $line
    Write-Host $safe
    Write-LogLine $safe
}

function Step([int]$pct, [string]$msg) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    Emit ('##STEP {0}|{1}' -f $pct, $msg)
}

# ---------------------------------------------------------------- 路径与清单

$settings = Read-WorkbenchSettings
$baseFromSettings = ''
if ($settings -and $settings.PSObject.Properties['base']) { $baseFromSettings = [string]$settings.base }
$wsFromSettings = ''
if ($settings -and $settings.PSObject.Properties['workspace']) { $wsFromSettings = [string]$settings.workspace }
$botsFromSettings = ''
if ($settings -and $settings.PSObject.Properties['botRoot']) { $botsFromSettings = [string]$settings.botRoot }

if (-not $Base) {
    if ($env:MINGLING_BASE) { $Base = $env:MINGLING_BASE }
    elseif ($baseFromSettings) { $Base = $baseFromSettings }
    else { $Base = $script:Repo }
}
$script:Base = Normalize-Dir $Base

if (-not $Workspace) {
    if ($env:MINGLING_WORKSPACE) { $Workspace = $env:MINGLING_WORKSPACE }
    elseif ($wsFromSettings) { $Workspace = $wsFromSettings }
    else { $Workspace = $script:Base }
}
$script:Workspace = Normalize-Dir $Workspace

if (-not $Bots) {
    if ($env:MINGLING_BOTS -and (Test-Path -LiteralPath $env:MINGLING_BOTS)) { $Bots = $env:MINGLING_BOTS }
    elseif ($botsFromSettings) { $Bots = $botsFromSettings }
    else { $Bots = Join-Path $script:Workspace 'bots' }
}
$script:Bots = Normalize-Dir $Bots

if ($env:MINGLING_SIDECAR) { $script:Sidecar = Normalize-Dir $env:MINGLING_SIDECAR }
else { $script:Sidecar = Normalize-Dir (Join-Path $script:Base 'sidecar') }

$script:AstrbotData = Join-Path $script:Bots 'AstrBot\data'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $script:Base 'logs\setup'
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
if ($LogFile) {
    $script:LogPath = Normalize-Dir $LogFile
    $parent = Split-Path -Parent $script:LogPath
    if ($parent) { try { New-Item -ItemType Directory -Force -Path $parent | Out-Null } catch { } }
} else {
    $script:LogPath = Join-Path $logDir ('bootstrap-{0}.log' -f $stamp)
}
$script:StatePath = Join-Path $logDir 'state.json'

if (-not $script:CheckMode) {
    try { New-Item -ItemType Directory -Force -Path (Join-Path $logDir 'dl') | Out-Null } catch { }
    try { New-Item -ItemType Directory -Force -Path (Join-Path $logDir 'tmp') | Out-Null } catch { }
}

$manifestPath = Join-Path $PSScriptRoot 'components.json'
try {
    $script:Manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Write-Host ('components.json 解析失败：' + $_.Exception.Message)
    exit 1
}
if (-not $script:Manifest.components -or @($script:Manifest.components).Count -eq 0) {
    Write-Host 'components.json 里没有组件。'
    exit 1
}

# 代理只记主机，避免把带账号的 URL 打进日志。
if ($Proxy) {
    if ($Proxy -notmatch '^(https?|socks5)://') { Write-Host '代理要写成 http://主机:端口 或 socks5://主机:端口'; exit 1 }
    try { $u = [uri]$Proxy; $script:ProxyHost = $u.Host + ':' + $u.Port } catch { $script:ProxyHost = '已设置' }
    $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy; $env:ALL_PROXY = $Proxy
    $env:http_proxy = $Proxy; $env:https_proxy = $Proxy; $env:all_proxy = $Proxy
}

Emit '==== 冥零工作台 · 组件安装 ===='
Emit ('模式：{0}；离线：{1}；代理：{2}' -f $(if ($script:CheckMode) { '只检测（不安装）' } else { '检测 + 安装' }), $(if ($script:OfflineMode) { '是' } else { '否' }), $(if ($script:ProxyHost) { $script:ProxyHost } else { '无' }))
Emit ('Base={0}' -f $script:Base)
Emit ('Workspace={0}' -f $script:Workspace)
Emit ('Bots={0}' -f $script:Bots)
Emit ('Sidecar={0}' -f $script:Sidecar)
Emit ('日志={0}' -f $script:LogPath)

# ---------------------------------------------------------------- 基础工具

function Expand-Tokens([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $r = $s
    $r = $r.Replace('{base}', $script:Base)
    $r = $r.Replace('{workspace}', $script:Workspace)
    $r = $r.Replace('{bots}', $script:Bots)
    $r = $r.Replace('{sidecar}', $script:Sidecar)
    $r = $r.Replace('{repo}', $script:Repo)
    $r = $r.Replace('{astrbot_data}', $script:AstrbotData)
    return $r
}

function Expand-Text([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return [Environment]::ExpandEnvironmentVariables((Expand-Tokens $s))
}

function Resolve-Exe([string]$Name) {
    if (-not $Name) { return '' }
    $n = Expand-Text $Name
    if ($n -match '[\\/]') {
        if (Test-Path -LiteralPath $n) { return (Get-Item -LiteralPath $n -Force).FullName }
        return ''
    }
    $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return ''
}

function Quote-Arg([string]$a) {
    if ($null -eq $a -or $a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Get-TextTail([string]$Out, [string]$Err) {
    $t = @()
    if ($Out) { $t += @($Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) }
    if ($Err) { $t += @($Err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) }
    $s = ($t -join ' / ')
    if ($s.Length -gt 240) { $s = $s.Substring(0, 240) + '…' }
    return (Redact-Text $s)
}

# 跑一个外部程序并拿回退出码/输出；.cmd 必须经 cmd.exe，不能直接 CreateProcess。
function Invoke-Capture {
    param(
        [string]$Exe,
        [object[]]$Argv = @(),
        [int]$Timeout = 600,
        [string]$WorkDir = '',
        [hashtable]$EnvMap = @{}
    )
    $isScript = $Exe -match '\.(cmd|bat)$'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $argLine = (@($Argv) | ForEach-Object { Quote-Arg ([string]$_) }) -join ' '
    if ($isScript) {
        $comspec = $env:ComSpec
        if (-not $comspec) { $comspec = Join-Path $env:SystemRoot 'System32\cmd.exe' }
        $psi.FileName = $comspec
        $psi.Arguments = '/d /c ""' + $Exe + '" ' + $argLine + '"'
    } else {
        $psi.FileName = $Exe
        $psi.Arguments = $argLine
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($k in $EnvMap.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvMap[$k] }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $finished = $p.WaitForExit($Timeout * 1000)
    if (-not $finished) {
        try { $p.Kill() } catch { }
        try { [void]$p.WaitForExit(5000) } catch { }
        return @{ code = -1; out = ''; err = ('超时（{0} 秒）' -f $Timeout) }
    }
    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }
    return @{ code = $p.ExitCode; out = $out; err = $err }
}

# 递归复制目录内容（不是把源目录本身塞进目标）。
function Copy-Tree {
    param([string]$Src, [string]$Dst, [string[]]$Exclude = @())
    if (-not (Test-Path -LiteralPath $Src)) { throw ('源目录不存在：' + $Src) }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Src -Force)) {
        if ($Exclude -contains $item.Name) { continue }
        $target = Join-Path $Dst $item.Name
        if ($item.PSIsContainer) { Copy-Tree -Src $item.FullName -Dst $target -Exclude $Exclude }
        else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force }
    }
}

function Copy-TreeMissing {
    param([string]$Src, [string]$Dst, [string[]]$Exclude = @())
    if (-not (Test-Path -LiteralPath $Src)) { throw ('源目录不存在：' + $Src) }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Src -Force)) {
        if ($Exclude -contains $item.Name) { continue }
        $target = Join-Path $Dst $item.Name
        if ($item.PSIsContainer) { Copy-TreeMissing -Src $item.FullName -Dst $target -Exclude $Exclude }
        elseif (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $item.FullName -Destination $target }
    }
}

function Expand-ZipTo([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        & $tar -xf $Zip -C $Dest 2>$null
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
}

# ---------------------------------------------------------------- 检测/验证

function Test-ProbeRaw($Probe) {
    if ($null -eq $Probe) { return @{ ok = $false; detail = '清单里没有检测规则' } }
    $kind = [string]$Probe.kind
    $min = 0
    try { if ($Probe.min_bytes) { $min = [long]$Probe.min_bytes } } catch { }

    switch ($kind) {
        'file' {
            foreach ($raw in @($Probe.paths)) {
                if (-not $raw) { continue }
                $p = Expand-Text $raw
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $it = Get-Item -LiteralPath $p -Force
                if ($it.PSIsContainer) { return @{ ok = $true; detail = $p } }
                if ($min -gt 0 -and $it.Length -lt $min) { continue }
                return @{ ok = $true; detail = $p }
            }
            return @{ ok = $false; detail = ('没找到：' + (@($Probe.paths) -join ' 或 ')) }
        }
        'file_glob' {
            foreach ($raw in @($Probe.patterns)) {
                if (-not $raw) { continue }
                $pat = Expand-Text $raw
                $dir = Split-Path -Parent $pat
                $leaf = Split-Path -Leaf $pat
                if (-not $dir) { continue }
                if (-not (Test-Path -Path $dir)) { continue }
                $hit = Get-ChildItem -Path $dir -Filter $leaf -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) { return @{ ok = $true; detail = $hit.FullName } }
            }
            return @{ ok = $false; detail = ('没找到匹配：' + (@($Probe.patterns) -join ' 或 ')) }
        }
        'file_recursive' {
            $dir = Expand-Text ([string]$Probe.dir)
            if (-not (Test-Path -LiteralPath $dir)) { return @{ ok = $false; detail = ('目录不存在：' + $dir) } }
            $hit = Get-ChildItem -LiteralPath $dir -Recurse -Filter ([string]$Probe.filter) -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return @{ ok = $true; detail = $hit.FullName } }
            return @{ ok = $false; detail = ('目录里没有 {0}：{1}' -f $Probe.filter, $dir) }
        }
        'registry_value' {
            $root = [string]$Probe.root
            $key = [string]$Probe.key
            if ($root -match ':') { $path = $root + '\' + $key } else { $path = $root + ':\' + $key }
            try {
                $v = Get-ItemPropertyValue -LiteralPath $path -Name ([string]$Probe.name) -ErrorAction Stop
            } catch {
                return @{ ok = $false; detail = ('注册表没有 {0}\{1} 的 {2}' -f $root, $key, $Probe.name) }
            }
            if ($Probe.expect_regex -and ("$v" -notmatch [string]$Probe.expect_regex)) {
                return @{ ok = $false; detail = ('{0}={1} 不匹配 {2}' -f $Probe.name, $v, $Probe.expect_regex) }
            }
            return @{ ok = $true; detail = ('{0}={1}' -f $Probe.name, $v) }
        }
        'command' {
            $exe = Resolve-Exe ([string]$Probe.exe)
            if (-not $exe) { return @{ ok = $false; detail = ('找不到命令：' + $Probe.exe) } }
            $argv = @()
            foreach ($a in @($Probe.args)) { if ($null -ne $a) { $argv += (Expand-Text ([string]$a)) } }
            $to = 60
            try { if ($Probe.timeout) { $to = [int]$Probe.timeout } } catch { }
            $r = Invoke-Capture -Exe $exe -Argv $argv -Timeout $to -WorkDir (Expand-Text ([string]$Probe.workdir))
            $text = (([string]$r.out) + "`n" + ([string]$r.err)).Trim()
            $expect = 0
            try { if ($null -ne $Probe.expect_exit) { $expect = [int]$Probe.expect_exit } } catch { }
            if ($r.code -ne $expect) {
                return @{ ok = $false; detail = ('退出码 {0}：{1}' -f $r.code, (Get-TextTail $r.out $r.err)) }
            }
            if ($Probe.expect_regex -and ($text -notmatch [string]$Probe.expect_regex)) {
                return @{ ok = $false; detail = ('输出不匹配：{0}' -f (Get-TextTail $r.out $r.err)) }
            }
            $tail = Get-TextTail $r.out $r.err
            if ($Probe.expect_regex) {
                $hitLine = @($text -split "`r?`n" | Where-Object { $_ -match [string]$Probe.expect_regex } | Select-Object -First 1)
                if ($hitLine) { $tail = ([string]$hitLine).Trim() }
            }
            if (-not $tail) { $tail = $exe }
            return @{ ok = $true; detail = $tail }
        }
        'any' {
            $last = '没有可用的检测规则'
            foreach ($p in @($Probe.probes)) {
                if ($null -eq $p) { continue }
                $r = Test-Probe $p
                if ($r.ok) { return $r }
                $last = $r.detail
            }
            return @{ ok = $false; detail = $last }
        }
        'all' {
            $details = @()
            foreach ($p in @($Probe.probes)) {
                if ($null -eq $p) { continue }
                $r = Test-Probe $p
                if (-not $r.ok) { return $r }
                $details += $r.detail
            }
            return @{ ok = $true; detail = ($details -join '；') }
        }
        default { return @{ ok = $false; detail = ('未知检测类型：' + $kind) } }
    }
}

# ---------------------------------------------------------------- 安装步骤

function Test-Probe($Probe) {
    $r = Test-ProbeRaw $Probe
    if ($r -and $r.detail) { $r.detail = Expand-Text ([string]$r.detail) }
    return $r
}

function Assert-Online($StepObj) {
    $needs = $false
    try { if ($StepObj.needs_network) { $needs = $true } } catch { }
    if ($needs -and $script:OfflineMode) {
        throw ('离线模式：跳过需要联网的步骤（' + [string]$StepObj.kind + '）')
    }
}

function Resolve-Urls([string[]]$Urls) {
    $out = New-Object System.Collections.ArrayList
    foreach ($u in @($Urls)) {
        if (-not $u) { continue }
        $uri = $null
        try { $uri = [uri]$u } catch { }
        if ($uri -and $uri.Host -match '(^|\.)github\.com$') {
            foreach ($px in @($script:Manifest.mirrors.github)) {
                $cand = if ($px) { $px + $u } else { $u }
                if (-not $out.Contains($cand)) { [void]$out.Add($cand) }
            }
        } else {
            if (-not $out.Contains($u)) { [void]$out.Add($u) }
        }
    }
    return @($out)
}

function Invoke-DownloadStep($StepObj, $Comp) {
    $sha = [string]$StepObj.sha256
    if (-not $sha -or $sha.Length -ne 64) {
        throw ('清单里 {0} 的下载没有有效 sha256，拒绝盲下' -f $Comp.id)
    }
    $sha = $sha.ToUpper()
    $dest = Expand-Text ([string]$StepObj.dest)
    $cacheDir = Expand-Text ([string]$script:Manifest.defaults.download_dir)
    if (-not $cacheDir) { $cacheDir = Join-Path $script:Base 'logs\setup\dl' }
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $urls = Resolve-Urls @($StepObj.urls)
    if (-not $urls -or $urls.Count -eq 0) { throw ('{0} 没有下载地址' -f $Comp.id) }
    $name = ''
    try { $name = [IO.Path]::GetFileName(([uri]$urls[0]).AbsolutePath) } catch { }
    if (-not $name) { $name = $Comp.id + '.zip' }
    $zip = Join-Path $cacheDir ($Comp.id + '-' + $name)

    $cacheOk = $false
    if (Test-Path -LiteralPath $zip) {
        try { $cacheOk = ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $sha) } catch { $cacheOk = $false }
    }
    if ($script:OfflineMode) {
        if (-not $cacheOk) { throw ('离线模式：本机没有校验通过的缓存 {0}' -f (Split-Path -Leaf $zip)) }
    } else {
        $expected = 0
        try { if ($StepObj.size) { $expected = [long]$StepObj.size } } catch { }
        $min = 1
        if ($expected -gt 0) { $min = $expected }
        Emit ('  下载 {0}（{1}）' -f $name, $(if ($expected -gt 0) { '{0:N1} MB' -f ($expected / 1MB) } else { '大小未知' }))
        Get-File -Urls $urls -OutFile $zip -MinBytes $min -Sha256 $sha -ExpectedBytes $expected | Out-Null
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $sha) {
            throw ('SHA256 校验失败：' + $name)
        }
    }

    $layout = [string]$StepObj.layout
    if (-not $layout) { $layout = 'flatten' }
    if ($layout -eq 'file') {
        $parent = Split-Path -Parent $dest
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if ($zip -ne $dest) { Copy-Item -LiteralPath $zip -Destination $dest -Force }
        Write-LogLine ('下载文件 {0} → {1}' -f $Comp.id, $dest)
        return
    }
    $tmpRoot = Expand-Text ([string]$script:Manifest.defaults.temp_dir)
    if (-not $tmpRoot) { $tmpRoot = Join-Path $script:Base 'logs\setup\tmp' }
    $tmp = Join-Path $tmpRoot ($Comp.id + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        if ($layout -eq 'direct') {
            Expand-ZipTo $zip $dest
        } else {
            Expand-ZipTo $zip $tmp
            $src = $tmp
            if ($layout -eq 'flatten') {
                $top = @(Get-ChildItem -LiteralPath $tmp -Force)
                if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }
            } elseif ($layout -eq 'find_parent') {
                $find = [string]$StepObj.find
                if (-not $find) { throw 'layout=find_parent 但没写 find' }
                $hit = Get-ChildItem -LiteralPath $tmp -Recurse -Filter $find -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $hit) { throw ('解压后找不到 {0}（发布包结构可能变了）' -f $find) }
                $src = Split-Path -Parent $hit.FullName
            } else {
                throw ('未知解压方式：' + $layout)
            }
            Copy-Tree -Src $src -Dst $dest
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-LogLine ('下载并解压 {0} → {1}' -f $Comp.id, $dest)
}

function Invoke-WingetStep($StepObj) {
    $wg = Resolve-Exe 'winget'
    if (-not $wg) {
        throw '没找到 winget（应用安装程序）。可以在 Microsoft Store 更新「应用安装程序」，或按组件说明手动装。'
    }
    $argv = @('install', '--id', [string]$StepObj.id, '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($StepObj.scope) { $argv += @('--scope', [string]$StepObj.scope) }
    $r = Invoke-Capture -Exe $wg -Argv $argv -Timeout 1800
    if ($r.code -ne 0) {
        throw ('winget 装 {0} 失败（退出码 {1}）：{2}' -f $StepObj.id, $r.code, (Get-TextTail $r.out $r.err))
    }
}

function Invoke-UvToolStep($StepObj) {
    $uv = Resolve-Exe ([string]$StepObj.uv_exe)
    if (-not $uv) { $uv = Resolve-Exe 'uv' }
    if (-not $uv) { throw '找不到 uv.exe，先装 uv 组件' }
    $toolDir = Expand-Text ([string]$StepObj.tool_dir)
    $binDir = Expand-Text ([string]$StepObj.bin_dir)
    $pyDir = Expand-Text ([string]$StepObj.python_dir)
    foreach ($d in @($toolDir, $binDir, $pyDir)) { if ($d) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    $pkg = [string]$StepObj.package
    $exeName = $pkg + '.exe'
    if ($StepObj.exe_name) { $exeName = [string]$StepObj.exe_name }
    $target = Join-Path $binDir $exeName
    $cache = Expand-Text '{base}\logs\setup\uv-cache'
    $envMap = @{ UV_TOOL_DIR = $toolDir; UV_TOOL_BIN_DIR = $binDir; UV_PYTHON_INSTALL_DIR = $pyDir; UV_CACHE_DIR = $cache; UV_PYTHON_DOWNLOADS = 'never' }
    if ($StepObj.python_version) { $envMap['UV_PYTHON'] = [string]$StepObj.python_version }

    # 带锁文件时安装到固定 venv，并对主包及全部传递依赖逐包强制哈希。
    $requirements = Expand-Text ([string]$StepObj.requirements)
    if ($requirements) {
        if (-not (Test-Path -LiteralPath $requirements)) { throw ('依赖锁不存在：' + $requirements) }
        $expectedLock = [string]$StepObj.requirements_sha256
        if ($expectedLock -notmatch '^[0-9a-fA-F]{64}$') { throw '依赖锁缺少有效 SHA256' }
        if ((Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash -ne $expectedLock) { throw '依赖锁 SHA256 校验失败' }
        $pythonExe = Expand-Text ([string]$StepObj.python_exe)
        if (-not (Test-Path -LiteralPath $pythonExe)) { throw ('固定 Python 不存在：' + $pythonExe) }
        $venvPython = Join-Path $toolDir 'Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $venvPython)) {
            $rv = Invoke-Capture -Exe $uv -Argv @('venv', $toolDir, '--python', $pythonExe, '--no-python-downloads') -Timeout 300 -EnvMap $envMap
            if ($rv.code -ne 0) { throw ('创建 AstrBot venv 失败：' + (Get-TextTail $rv.out $rv.err)) }
        }
        $last = ''
        foreach ($idx in @(@($script:Manifest.mirrors.pip) + @(''))) {
            $argv = @('pip', 'install', '--python', $venvPython, '--requirements', $requirements, '--require-hashes', '--no-build', '--no-python-downloads', '--cache-dir', $cache, '--find-links', (Join-Path $script:Repo 'pack\mingling-vendor\wheels'))
            if ($script:OfflineMode) { $argv += '--offline' }
            if ($idx) { $argv += @('--index-url', [string]$idx) }
            $r = Invoke-Capture -Exe $uv -Argv $argv -Timeout 3600 -EnvMap $envMap
            $entry = Join-Path $toolDir ('Scripts\' + $exeName)
            if ($r.code -eq 0 -and (Test-Path -LiteralPath $entry)) {
                Copy-Item -LiteralPath $entry -Destination $target -Force
                Write-LogLine ('uv 锁定安装 {0} 成功（源：{1}）' -f $pkg, $(if ($idx) { $idx } else { '默认' }))
                return
            }
            $last = Get-TextTail $r.out $r.err
            Write-LogLine ('uv 源 {0} 失败：{1}' -f $(if ($idx) { $idx } else { '默认' }), $last)
            if ($script:OfflineMode) { break }
        }
        throw ('uv 锁定安装 {0} 失败：{1}' -f $pkg, $last)
    }

    throw ('{0} 未提供带哈希的依赖锁，拒绝执行不固定版本的 uv 安装' -f $pkg)
}

function Invoke-UvPythonStep($StepObj) {
    $uv = Resolve-Exe ([string]$StepObj.uv_exe)
    if (-not $uv) { $uv = Resolve-Exe 'uv' }
    if (-not $uv) { throw '找不到 uv.exe，先装 uv 组件' }
    $dir = Expand-Text ([string]$StepObj.install_dir)
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $envMap = @{}
    if ($dir) { $envMap['UV_PYTHON_INSTALL_DIR'] = $dir }
    $mirrors = @($script:Manifest.mirrors.uv_python)
    if ($mirrors.Count -gt 0 -and $mirrors[0]) { $envMap['UV_PYTHON_INSTALL_MIRROR'] = [string]$mirrors[0] }
    $argv = @('python', 'install', [string]$StepObj.version)
    $r = Invoke-Capture -Exe $uv -Argv $argv -Timeout 1800 -EnvMap $envMap
    if ($r.code -ne 0) {
        throw ('uv python install {0} 失败：{1}' -f $StepObj.version, (Get-TextTail $r.out $r.err))
    }
}

function Invoke-NpmStep($StepObj) {
    $dir = Expand-Text ([string]$StepObj.dir)
    if (-not (Test-Path -LiteralPath $dir)) { throw ('目录不存在：' + $dir) }
    $npm = Resolve-Exe 'npm'
    if (-not $npm) {
        $node = Resolve-Exe 'node'
        if (-not $node) {
            $node = Expand-Text '{sidecar}\node\node.exe'
            if (-not (Test-Path -LiteralPath $node)) { $node = '' }
        }
        if ($node) {
            $cand = Join-Path (Split-Path -Parent $node) 'npm.cmd'
            if (Test-Path -LiteralPath $cand) { $npm = $cand }
        }
    }
    if (-not $npm) { throw '找不到 npm（Node.js 组件没装好）' }

    $missing = @()
    foreach ($pkg in @($StepObj.packages)) {
        if (-not $pkg) { continue }
        $probe = Join-Path $dir ('node_modules\' + $pkg + '\package.json')
        if (-not (Test-Path -LiteralPath $probe)) { $missing += [string]$pkg }
    }
    if ($missing.Count -eq 0) { return }

    $last = ''
    $npmCache = Expand-Text '{base}\logs\setup\npm-cache'
    $envMap = @{ npm_config_cache = $npmCache }
    foreach ($reg in @(@($script:Manifest.mirrors.npm) + @(''))) {
        $argv = @('install', '--omit=dev', '--no-audit', '--no-fund', '--ignore-scripts')
        if ($script:OfflineMode) { $argv += '--offline' }
        if ($reg) { $argv += @('--registry', [string]$reg) }
        $argv += $missing
        $r = Invoke-Capture -Exe $npm -Argv $argv -Timeout 1800 -WorkDir $dir -EnvMap $envMap
        if ($r.code -eq 0) {
            $node = Expand-Text '{sidecar}\node\node.exe'
            foreach ($pkg in $missing) {
                # require.resolve 只认模块名，不认 'qrcode@1.5.4' 这种带版本的写法（会当成不存在的包名）。
                $modName = [string]$pkg
                if ($modName -match '^(@[^/]+/[^@]+)') { $modName = [string]$Matches[1] }
                elseif ($modName -match '^([^@]+)@') { $modName = [string]$Matches[1] }
                $check = Invoke-Capture -Exe $node -Argv @('-e', "require.resolve('$modName')") -Timeout 60 -WorkDir $dir
                if ($check.code -ne 0) { throw ("npm 返回成功但 require.resolve('$pkg') 仍失败：" + (Get-TextTail $check.out $check.err)) }
            }
            Write-LogLine ('npm install 成功（源：{0}）' -f $(if ($reg) { $reg } else { '默认' }))
            return
        }
        $last = Get-TextTail $r.out $r.err
        Write-LogLine ('npm 源 {0} 失败：{1}' -f $(if ($reg) { $reg } else { '默认' }), $last)
        if ($script:OfflineMode) { break }
    }
    throw ('npm install {0} 失败：{1}' -f ($missing -join ','), $last)
}

function Invoke-CommandStep($StepObj) {
    $exe = Resolve-Exe ([string]$StepObj.exe)
    if (-not $exe) { throw ('找不到可执行文件：' + $StepObj.exe) }
    $argv = @()
    foreach ($a in @($StepObj.args)) { if ($null -ne $a) { $argv += (Expand-Text ([string]$a)) } }
    $to = 600
    try { if ($StepObj.timeout) { $to = [int]$StepObj.timeout } } catch { }
    if ($script:Manifest.defaults.command_timeout_seconds -and -not $StepObj.timeout) {
        try { $to = [int]$script:Manifest.defaults.command_timeout_seconds } catch { }
    }
    $wd = Expand-Text ([string]$StepObj.workdir)
    $r = Invoke-Capture -Exe $exe -Argv $argv -Timeout $to -WorkDir $wd
    $accepted = @(0)
    if ($StepObj.accept_exit) { $accepted = @($StepObj.accept_exit | ForEach-Object { [int]$_ }) }
    if ($accepted -notcontains [int]$r.code) {
        throw ('{0} 退出码 {1}：{2}' -f $StepObj.exe, $r.code, (Get-TextTail $r.out $r.err))
    }
}

function Invoke-Step($StepObj, $Comp) {
    if ($null -eq $StepObj) { return }
    $kind = [string]$StepObj.kind
    switch ($kind) {
        'download' { Invoke-DownloadStep $StepObj $Comp }
        'copy_tree' {
            $from = Expand-Text ([string]$StepObj.from)
            $to = Expand-Text ([string]$StepObj.to)
            if (-not (Test-Path -LiteralPath $from)) { throw ('源目录不存在：{0}（安装包可能没带 sidecar）' -f $from) }
            if ($StepObj.manifest) {
                $manifestPath = Join-Path $script:Repo ([string]$StepObj.manifest)
                $verifier = Join-Path $PSScriptRoot 'source-manifest.ps1'
                if (-not (Test-Path -LiteralPath $manifestPath)) { throw ('源码哈希清单不存在：' + $manifestPath) }
                $vr = Invoke-Capture -Exe 'powershell.exe' -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifier, '-Root', $from, '-Verify', '-Manifest', $manifestPath) -Timeout 300
                $actual = ([string]$vr.out).Trim()
                if ($vr.code -ne 0 -or $actual -ne [string]$StepObj.sha256) {
                    throw ('源码树 SHA256 校验失败：' + (Get-TextTail $vr.out $vr.err))
                }
            }
            if ($StepObj.only_if_missing) {
                Copy-TreeMissing -Src $from -Dst $to -Exclude @($StepObj.exclude)
            } else {
                Copy-Tree -Src $from -Dst $to -Exclude @($StepObj.exclude)
            }
        }
        'copy_file' {
            $from = Expand-Text ([string]$StepObj.from)
            $to = Expand-Text ([string]$StepObj.to)
            if (-not (Test-Path -LiteralPath $from)) { throw ('源文件不存在：' + $from) }
            $onlyMissing = $false
            try { if ($StepObj.only_if_missing) { $onlyMissing = $true } } catch { }
            if ($onlyMissing -and (Test-Path -LiteralPath $to)) { return }
            $parent = Split-Path -Parent $to
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Copy-Item -LiteralPath $from -Destination $to -Force
        }
        'mkdir' {
            foreach ($p in @($StepObj.paths)) {
                if (-not $p) { continue }
                New-Item -ItemType Directory -Force -Path (Expand-Text ([string]$p)) | Out-Null
            }
        }
        'write_file' {
            $path = Expand-Text ([string]$StepObj.path)
            $content = Expand-Tokens ([string]$StepObj.content)
            $encName = [string]$StepObj.encoding
            $enc = New-Object System.Text.UTF8Encoding($false)
            if ($encName -eq 'ansi') { $enc = [Text.Encoding]::Default }
            elseif ($encName -eq 'utf8bom') { $enc = New-Object System.Text.UTF8Encoding($true) }
            $parent = Split-Path -Parent $path
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $write = $true
            if (Test-Path -LiteralPath $path) {
                try {
                    $old = [IO.File]::ReadAllText($path, $enc)
                    if ($old -eq $content) { $write = $false }
                } catch { }
            }
            if ($write) {
                [IO.File]::WriteAllText($path, $content, $enc)
                Write-LogLine ('写入 {0}' -f $path)
            }
        }
        'winget' { Assert-Online $StepObj; Invoke-WingetStep $StepObj }
        'uv_tool' { Assert-Online $StepObj; Invoke-UvToolStep $StepObj }
        'uv_python' { Assert-Online $StepObj; Invoke-UvPythonStep $StepObj }
        'npm_install' { Assert-Online $StepObj; Invoke-NpmStep $StepObj }
        'command' { Assert-Online $StepObj; Invoke-CommandStep $StepObj }
        'env_user' {
            $name = [string]$StepObj.name
            $value = Expand-Text ([string]$StepObj.value)
            try {
                [Environment]::SetEnvironmentVariable($name, $value, 'User')
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
                Write-LogLine ('用户环境变量 {0}={1}' -f $name, $value)
            } catch {
                Write-LogLine ('用户环境变量 {0} 没写进去：{1}' -f $name, $_.Exception.Message)
            }
        }
        'manual' { throw ('这一步只能人工完成：' + (@($StepObj.steps) -join '；')) }
        'none' { }
        default { throw ('未知安装步骤：' + $kind) }
    }
}

function Install-Component($Comp) {
    $lastErr = ''
    try {
        foreach ($s in @($Comp.install.steps)) { Invoke-Step $s $Comp }
        return @{ ok = $true; detail = '装好了' }
    } catch {
        $lastErr = $_.Exception.Message
    }
    foreach ($fb in @($Comp.install.fallbacks)) {
        if ($null -eq $fb) { continue }
        try {
            Invoke-Step $fb $Comp
            return @{ ok = $true; detail = ('备选方式（{0}）装好了' -f $fb.kind) }
        } catch {
            $lastErr = $lastErr + '；备选也失败：' + $_.Exception.Message
        }
    }
    return @{ ok = $false; detail = $lastErr }
}

# ---------------------------------------------------------------- 选组件 / 拓扑排序

try {
$allComps = @($script:Manifest.components)
$byId = @{}
$allIds = New-Object System.Collections.ArrayList
foreach ($c in $allComps) {
    if (-not $c.id) { throw 'components.json 有组件没写 id' }
    if ($byId.ContainsKey([string]$c.id)) { throw ('components.json 里 id 重复：' + $c.id) }
    $byId[[string]$c.id] = $c
    [void]$allIds.Add([string]$c.id)
}

function Split-IdList([string[]]$Values) {
    $out = New-Object System.Collections.ArrayList
    foreach ($v in @($Values)) {
        if (-not $v) { continue }
        foreach ($p in ($v -split '[,，;\s]+')) {
            $p = $p.Trim()
            if ($p -and -not $out.Contains($p)) { [void]$out.Add($p) }
        }
    }
    return @($out)
}

$explicit = @(Split-IdList $Component)
$excludeIds = @(Split-IdList $Exclude)

$selectedIds = New-Object System.Collections.ArrayList
if ($explicit.Count -gt 0) {
    $unknown = @($explicit | Where-Object { -not $byId.ContainsKey($_) })
    if ($unknown.Count -gt 0) { throw ('清单里没有这些组件：' + ($unknown -join ', ')) }
    $seen = @{}
    $q = New-Object System.Collections.Queue
    foreach ($id in $explicit) { $q.Enqueue($id) }
    while ($q.Count -gt 0) {
        $cur = [string]$q.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($r in @($byId[$cur].requires)) {
            if (-not $r) { continue }
            if ($excludeIds -contains $r) { throw ('组件 {0} 依赖 {1}，但 {1} 在 -Exclude 里' -f $cur, $r) }
            $q.Enqueue([string]$r)
        }
    }
    # 人工状态是独立组件（如 snowluma -> qq-login）。点名安装/检测某个组件时，
    # 一并带上依附于它的 manual 项，避免软件装好后 manual=0、把登录误报成完成。
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($c in $allComps) {
            if (-not $c.manual -or $seen.ContainsKey([string]$c.id)) { continue }
            foreach ($r in @($c.requires)) {
                if ($r -and $seen.ContainsKey([string]$r)) {
                    $seen[[string]$c.id] = $true
                    $changed = $true
                    break
                }
            }
        }
    }
    foreach ($id in $allIds) { if ($seen.ContainsKey($id)) { [void]$selectedIds.Add($id) } }
} else {
    foreach ($c in $allComps) {
        $id = [string]$c.id
        if ($excludeIds -contains $id) { continue }
        if (-not $c.default_install -and -not $IncludeOptional) { continue }
        [void]$selectedIds.Add($id)
    }
    foreach ($id in $selectedIds) {
        foreach ($r in @($byId[$id].requires)) {
            if ($r -and ($excludeIds -contains $r)) { throw ('组件 {0} 依赖 {1}，但 {1} 在 -Exclude 里' -f $id, $r) }
            if ($r -and -not $selectedIds.Contains($r)) { throw ('组件 {0} 依赖 {1}，但 {1} 不在本次选择里' -f $id, $r) }
        }
    }
}

# 选中组件的下载必须带 sha256，缺了直接失败（不盲下）。
foreach ($id in $selectedIds) {
    $comp = $byId[$id]
    $steps = @()
    $steps += @($comp.install.steps)
    $steps += @($comp.install.fallbacks)
    foreach ($s in $steps) {
        if ($null -eq $s) { continue }
        if ([string]$s.kind -ne 'download') { continue }
        $sha = [string]$s.sha256
        if (-not $sha -or $sha.Length -ne 64) { throw ('清单里 {0} 的下载缺少 sha256，拒绝安装' -f $id) }
    }
}

function Sort-Topo([string[]]$Ids) {
    $indeg = @{}
    $dependents = @{}
    foreach ($id in $Ids) { $indeg[$id] = 0; $dependents[$id] = @() }
    foreach ($id in $Ids) {
        foreach ($r in @($byId[$id].requires)) {
            if (-not $r) { continue }
            if (-not $indeg.ContainsKey($r)) { continue }
            $indeg[$id] = $indeg[$id] + 1
            $dependents[$r] = @($dependents[$r]) + $id
        }
    }
    $queue = New-Object System.Collections.ArrayList
    foreach ($id in $Ids) { if ($indeg[$id] -eq 0) { [void]$queue.Add($id) } }
    $out = New-Object System.Collections.ArrayList
    while ($queue.Count -gt 0) {
        $cur = [string]$queue[0]
        $queue.RemoveAt(0)
        [void]$out.Add($cur)
        foreach ($n in @($dependents[$cur])) {
            $indeg[$n] = $indeg[$n] - 1
            if ($indeg[$n] -eq 0) { [void]$queue.Add($n) }
        }
    }
    if ($out.Count -ne @($Ids).Count) {
        $cycle = @($Ids | Where-Object { $indeg[$_] -gt 0 })
        throw ('组件依赖有环：' + ($cycle -join ' → '))
    }
    return @($out)
}

$order = @(Sort-Topo @($selectedIds))
} catch {
    Emit ('[错误] ' + $_.Exception.Message)
    Emit ('##RESULT ok=0 error=' + (Redact-Text $_.Exception.Message))
    exit 1
}

function Save-State {
    if (-not $script:StatePath) { return }
    # 没发生任何变化时保持 state.json 原样（内容、大小、修改时间都不动）。
    if (-not $script:Dirty -and (Test-Path -LiteralPath $script:StatePath)) { return }
    # 只检测模式不覆盖已有 state.json：升级/复跑时的 -Check 是只读探测，不该改写上次安装记录。
    if ($script:CheckMode -and (Test-Path -LiteralPath $script:StatePath)) { return }
    try {
        $obj = [ordered]@{
            schema    = 1
            at        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            mode      = $(if ($script:CheckMode) { 'check' } else { 'install' })
            offline   = [bool]$script:OfflineMode
            base      = $script:Base
            workspace = $script:Workspace
            bots      = $script:Bots
            sidecar   = $script:Sidecar
            log       = $script:LogPath
            summary   = @{
                fixed     = $script:Stat.fixed
                satisfied = $script:Stat.satisfied
                manual    = $script:Stat.manual
                missing   = $script:Stat.missing
                failed    = $script:Stat.failed
                skipped   = $script:Stat.skipped
            }
            components = @($script:Results)
        }
        $json = $obj | ConvertTo-Json -Depth 8
        $tmp = $script:StatePath + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
    } catch {
        Write-LogLine ('state.json 写入失败：' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 主循环

$exitCode = 1
try {
    $explicitSet = @{}
    foreach ($eid in $explicit) { $explicitSet[$eid] = $true }
    Emit ('本次处理 {0} 个组件：{1}' -f $order.Count, ($order -join ' → '))

    $i = 0
    foreach ($id in $order) {
        $i++
        $c = $byId[$id]
        $pct = [int](2 + (($i - 1) * 93 / [math]::Max(1, $order.Count)))
        Step $pct ('检查 ' + $c.name)

        $optional = $false
        try { if ($c.optional) { $optional = $true } } catch { }
        $manual = $false
        try { if ($c.manual) { $manual = $true } } catch { }

        $det = if ($manual) { Test-Probe $c.detect } else { Test-Probe $c.verify }
        if ($manual) {
            if ($det.ok) {
                $script:Stat.satisfied++
                [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'ok'; detail = $det.detail; optional = $optional; manual = $true; at = (Get-Date).ToString('s') })
                Emit ('##OK {0}|已满足：{1}' -f $id, $det.detail)
            } else {
                $steps = (@($c.manual_steps) -join '；')
                if (-not $steps) { $steps = '见组件说明' }
                $script:Stat.manual++
                [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'manual'; detail = $det.detail; optional = $optional; manual = $true; at = (Get-Date).ToString('s') })
                Emit ('[人工] {0}：未完成。{1}' -f $id, $steps)
                Write-LogLine ('{0} 检测结果：{1}' -f $id, $det.detail)
            }
            continue
        }

        if ($det.ok -and -not $Force) {
            $script:Stat.satisfied++
            [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'ok'; detail = $det.detail; optional = $optional; manual = $false; at = (Get-Date).ToString('s') })
            Emit ('##OK {0}|已满足：{1}' -f $id, $det.detail)
            continue
        }

        if ($script:CheckMode) {
            $script:Dirty = $true
            $script:Stat.missing++
            [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'missing'; detail = $det.detail; optional = $optional; manual = $false; at = (Get-Date).ToString('s') })
            Emit ('##FAIL {0}|缺：{1}' -f $id, $det.detail)
            if ($c.notes) { Write-LogLine ('说明：' + $c.notes) }
            continue
        }

        Step $pct ('安装 ' + $c.name)
        $script:Dirty = $true
        Emit ('[安装] {0}（{1}）' -f $c.name, $c.version)
        $inst = Install-Component $c
        if (-not $inst.ok) {
            $script:Stat.failed++
            [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'failed'; detail = $inst.detail; optional = $optional; manual = $false; at = (Get-Date).ToString('s') })
            Emit ('##FAIL {0}|装失败：{1}' -f $id, $inst.detail)
            if ($c.notes) { Write-LogLine ('说明：' + $c.notes) }
            continue
        }

        Step $pct ('验证 ' + $c.name)
        $ver = Test-Probe $c.verify
        if (-not $ver.ok) {
            $script:Stat.failed++
            [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'failed'; detail = ('装完验证没过：' + $ver.detail); optional = $optional; manual = $false; at = (Get-Date).ToString('s') })
            Emit ('##FAIL {0}|装完验证没过：{1}' -f $id, $ver.detail)
            continue
        }
        $script:Stat.fixed++
        [void]$script:Results.Add(@{ id = $id; name = [string]$c.name; version = [string]$c.version; status = 'fixed'; detail = $ver.detail; optional = $optional; manual = $false; at = (Get-Date).ToString('s') })
        Emit ('##OK {0}|装好了：{1}' -f $id, $ver.detail)
    }

    $blocking = 0
    foreach ($r in $script:Results) {
        if ($r.manual) { continue }
        if (($r.status -eq 'missing' -or $r.status -eq 'failed') -and ((-not $r.optional) -or $explicitSet.ContainsKey([string]$r.id))) { $blocking++ }
    }

    Step 99 '收尾'
    Emit ''
    Emit '==== 结果 ===='
    Emit ('已满足 {0}，补装 {1}，待人工 {2}，缺 {3}，失败 {4}' -f $script:Stat.satisfied, $script:Stat.fixed, $script:Stat.manual, $script:Stat.missing, $script:Stat.failed)
    if ($script:CheckMode) {
        Emit ('必需组件：' + $(if ($blocking -eq 0) { '全部满足' } else { ('还缺 {0} 项' -f $blocking) }))
    } else {
        Emit ('必需组件：' + $(if ($blocking -eq 0) { '都在位' } else { ('{0} 项没装成' -f $blocking) }))
    }
    Emit ('日志：{0}' -f $script:LogPath)
    Emit ('状态：{0}' -f $script:StatePath)

    if ($script:CheckMode) {
        if ($blocking -eq 0) { $exitCode = 0 } else { $exitCode = 2 }
    } else {
        if ($blocking -eq 0) { $exitCode = 0 } else { $exitCode = 2 }
    }
    if (-not $script:Dirty -and -not $script:ExplicitLog) {
        Emit '没有改动：未创建日志，state.json 保持原样。'
    }
} catch {
    Emit ('[错误] ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-LogLine $_.ScriptStackTrace }
    Emit ('##RESULT ok=0 error=' + (Redact-Text $_.Exception.Message))
    $exitCode = 1
} finally {
    Save-State
}

if ($exitCode -ne 1) {
    $okFlag = 0
    if ($exitCode -eq 0) { $okFlag = 1 }
    Emit ('##RESULT ok={0} fixed={1} satisfied={2} manual={3} missing={4} failed={5}' -f $okFlag, $script:Stat.fixed, $script:Stat.satisfied, $script:Stat.manual, $script:Stat.missing, $script:Stat.failed)
}

exit $exitCode
