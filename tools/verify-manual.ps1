#requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('qq', 'bili', 'api-key')][string]$Kind,
    [Parameter(Mandatory)][string]$Base,
    [string]$Bots = ''
)
$ErrorActionPreference = 'Stop'
$Base = [IO.Path]::GetFullPath($Base)
$ProgramRoot = Split-Path -Parent $PSScriptRoot
if (-not $Bots) { $Bots = Join-Path $Base 'bots' }
$Bots = [IO.Path]::GetFullPath($Bots)

function Exit-State([int]$Code, [string]$Message) {
    if ($Message) { [Console]::Error.WriteLine($Message) }
    exit $Code
}

if ($Kind -eq 'qq') {
    $cfgPath = Join-Path $Bots 'AstrBot\data\cmd_config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { Exit-State 3 'AstrBot 配置不存在，无法确认 QQ 登录态' }
    try { $cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Exit-State 3 'AstrBot 配置无法解析' }
    $port = 6199
    foreach ($p in @($cfg.platform)) { if ($p -and "$($p.type)" -eq 'aiocqhttp') { $port = [int]$p.ws_reverse_port; break } }
    $side = @(Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue)
    if ($side.Count -eq 0) { Exit-State 3 "QQ 未登录：AstrBot 的 OneBot 端口 $port 没有已建立连接" }
    $qqRoot = (Join-Path $Bots 'SnowLuma').TrimEnd('\') + '\'
    $napRoot = (Join-Path $Bots 'NapCat').TrimEnd('\') + '\'
    foreach ($conn in $side) {
        foreach ($peer in @(Get-NetTCPConnection -RemotePort $port -State Established -ErrorAction SilentlyContinue)) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($peer.OwningProcess)" -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $image = [string]$proc.ExecutablePath
            $cmd = [string]$proc.CommandLine
            if (($image -and ($image.StartsWith($qqRoot, [StringComparison]::OrdinalIgnoreCase) -or $image.StartsWith($napRoot, [StringComparison]::OrdinalIgnoreCase))) -or
                ($cmd -and ($cmd.IndexOf($Bots + '\SnowLuma', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $cmd.IndexOf($Bots + '\NapCat', [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                Write-Output "QQ 已登录：OneBot 端口 $port 存在来自本工作区 SnowLuma/NapCat 的双向连接"
                exit 0
            }
        }
    }
    Exit-State 3 "QQ 未登录：端口 $port 的连接不属于本工作区登录端"
}

if ($Kind -eq 'bili') {
    $cred = Join-Path $env:USERPROFILE '.bili-ai\credentials.json'
    if (-not (Test-Path -LiteralPath $cred)) { Exit-State 3 'B 站未登录：没有本机凭据文件' }
    $node = Join-Path $ProgramRoot 'sidecar\node\node.exe'
    $bot = Join-Path $Bots 'bili-whale'
    if (-not (Test-Path -LiteralPath $node)) { Exit-State 3 '找不到随包 Node' }
    $js = @'
const fs=require('fs'),path=require('path');
(async()=>{try{
 const p=path.join(process.env.USERPROFILE||process.env.HOME||'', '.bili-ai','credentials.json');
 const c=JSON.parse(fs.readFileSync(p,'utf8'));
 if(!c.sessdata||!c.bili_jct){process.exit(3)}
 const r=await fetch('https://api.bilibili.com/x/web-interface/nav',{headers:{'user-agent':'Mozilla/5.0','referer':'https://www.bilibili.com/',cookie:`SESSDATA=${c.sessdata}; bili_jct=${c.bili_jct}; buvid3=${c.buvid3||''}`}});
 const j=await r.json();
 process.exit(j&&j.code===0&&j.data&&j.data.isLogin&&Number(j.data.mid)>0?0:4);
}catch(e){process.exit(5)}})();
'@
    & $node -e $js 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Output 'B 站已登录：真实 nav 会话校验通过'; exit 0 }
    if ($LASTEXITCODE -eq 3) { Exit-State 3 'B 站未登录：凭据文件缺少 sessdata/bili_jct' }
    if ($LASTEXITCODE -eq 5) { Exit-State 5 'B 站登录态无法验证：网络不可用' }
    Exit-State 4 'B 站未登录：Cookie 已失效'
}

if ($Kind -eq 'api-key') {
    $keyFile = Join-Path $Base 'secrets\deepseek-key.txt'
    if (-not (Test-Path -LiteralPath $keyFile)) { $keyFile = Join-Path $Base 'private\deepseek-key.txt' }
    if (-not (Test-Path -LiteralPath $keyFile)) { Exit-State 3 '模型 API Key 未配置' }
    $key = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
    if (-not $key -or $key.Length -lt 8) { Exit-State 3 '模型 API Key 为空或格式无效' }
    $cfgPath = Join-Path $Bots 'AstrBot\data\cmd_config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { Exit-State 3 'AstrBot 配置不存在，Key 尚未接入 provider' }
    try { $cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Exit-State 3 'AstrBot 配置无法解析' }
    $matched = $false
    foreach ($p in @($cfg.provider)) {
        if (-not $p) { continue }
        foreach ($entry in @($p.key)) { if ([string]$entry -eq '$MINGLING_DEEPSEEK_KEY') { $matched = $true; break } }
        if ($matched) { break }
    }
    if (-not $matched) { Exit-State 3 '模型 API Key 已存在但尚未以环境变量引用接入 AstrBot provider' }
    Write-Output '模型 API Key 已通过 secrets + 进程环境变量接入 AstrBot provider'
    exit 0
}
