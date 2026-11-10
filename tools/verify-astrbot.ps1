#requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$Root,
    [int]$Port = 6185,
    [switch]$RequireRunning,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) {
    if (-not $Quiet) { [Console]::Error.WriteLine($Message) }
    exit 2
}
try {
    $Root = [IO.Path]::GetFullPath($Root)
    $marker = Join-Path $Root '.astrbot'
    $exe = Join-Path $Root 'bin\astrbot.exe'
    $python = Join-Path $Root 'python\python.exe'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { Fail "AstrBot 根目录未初始化（缺 .astrbot）：$Root" }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Fail "缺少 AstrBot CLI：$exe" }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { Fail "缺少固定 Python：$python" }
    $version = (& $python --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Python 3\.12\.16') { Fail "Python 版本不符合固定值：$version" }

    if ($RequireRunning) {
        $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($listener.Count -eq 0) { Fail "AstrBot 后台未监听 127.0.0.1:$Port" }
        $rootPrefix = $Root.TrimEnd('\') + '\'
        $owned = $false
        foreach ($conn in $listener) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction SilentlyContinue
            if ($proc -and $proc.ExecutablePath -and $proc.ExecutablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $owned = $true; break }
            if ($proc -and $proc.CommandLine -and $proc.CommandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $owned = $true; break }
        }
        if (-not $owned) { Fail "端口 $Port 的监听进程不属于 $Root" }

        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $request = [Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.0`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
            $stream.Write($request, 0, $request.Length)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
            $first = $reader.ReadLine()
            if (-not $first -or $first -notmatch '^HTTP/\d\.\d\s+\d{3}') { Fail 'AstrBot 端口没有返回有效 HTTP 响应' }
        } finally { $client.Dispose() }
    }
    if (-not $Quiet) { Write-Output "AstrBot 根目录、固定 Python 3.12.16、后台端口 $Port 均有效" }
    exit 0
} catch {
    if (-not $Quiet) { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 2
}
