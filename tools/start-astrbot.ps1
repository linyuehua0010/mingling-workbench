#requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$Base = '',
    [int]$Port = 6185,
    [int]$TimeoutSeconds = 180,
    [switch]$Restart
)
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
if (-not $Base) { $Base = Split-Path -Parent (Split-Path -Parent $Root) }
$Base = [IO.Path]::GetFullPath($Base)
$verify = Join-Path $PSScriptRoot 'verify-astrbot.ps1'
$exe = Join-Path $Root 'bin\astrbot.exe'
# Key 只在进程环境里，供 AstrBot 的 "$MINGLING_DEEPSEEK_KEY" 引用；不写用户环境、不复制到配置。
$keyFile = Join-Path $Base 'secrets\deepseek-key.txt'
if (-not (Test-Path -LiteralPath $keyFile)) { $keyFile = Join-Path $Base 'private\deepseek-key.txt' }
if (Test-Path -LiteralPath $keyFile) {
    $key = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
    if ($key) { $env:MINGLING_DEEPSEEK_KEY = $key }
}

function Test-Ready {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verify -Root $Root -Port $Port -RequireRunning -Quiet
    return ($LASTEXITCODE -eq 0)
}
if (-not $Restart -and (Test-Ready)) { Write-Output 'AstrBot 已在运行'; exit 0 }
if ($Restart) {
    $rootPrefix = $Root.TrimEnd('\') + '\'
    foreach ($conn in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction SilentlyContinue
        if ($proc -and (($proc.ExecutablePath -and $proc.ExecutablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
            ($proc.CommandLine -and $proc.CommandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    for ($i = 0; $i -lt 40 -and (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
}
if (-not (Test-Path -LiteralPath $exe)) { throw "找不到 AstrBot CLI：$exe" }
if (-not (Test-Path -LiteralPath (Join-Path $Root '.astrbot'))) {
    $initOut = & $exe init --yes 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "AstrBot init 失败：$initOut" }
}
$startCmd = Join-Path $Root 'start.cmd'
if (-not (Test-Path -LiteralPath $startCmd)) { throw "找不到启动命令：$startCmd" }
$proc = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$startCmd`"" -WorkingDirectory $Root -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Milliseconds 800
    if (Test-Ready) { Write-Output 'AstrBot 后台已启动并通过实际 HTTP 校验'; exit 0 }
    if ($proc.HasExited) { break }
} while ((Get-Date) -lt $deadline)
$log = Join-Path $Root 'data\run.log'
$tail = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' / ' } else { '无 run.log' }
throw "AstrBot 后台启动失败：$tail"
