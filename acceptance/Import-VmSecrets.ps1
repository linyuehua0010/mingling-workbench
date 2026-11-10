#requires -Version 5.1
# 把 acceptance\vm-secrets-input.txt 里的两行口令转成 DPAPI 文件，然后尽力抹掉明文。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$inFile = Join-Path $here 'vm-secrets-input.txt'
if (-not (Test-Path -LiteralPath $inFile)) { throw "缺少 $inFile" }
$lines = @(Get-Content -LiteralPath $inFile -Encoding UTF8 | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } | ForEach-Object { $_.TrimEnd("`r", "`n") })
if ($lines.Count -lt 2 -or -not $lines[0] -or -not $lines[1]) { throw '需要两个非空行：第 1 行 vmx 口令，第 2 行来宾口令' }
$dir = Join-Path $env:LOCALAPPDATA 'MinglingWorkbench\acceptance'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function To-Dpapi([string]$plain) { ConvertFrom-SecureString (ConvertTo-SecureString $plain -AsPlainText -Force) }
[IO.File]::WriteAllText((Join-Path $dir 'vm-password.dpapi'), (To-Dpapi $lines[0]) + "`r`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $dir 'guest-password.dpapi'), (To-Dpapi $lines[1]) + "`r`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $dir 'guest-user.txt'), ([string]([char]0x51A5 + [char]0x96F6)), (New-Object Text.UTF8Encoding($false)))
# 覆盖明文：先随机写满同长度，再删除
$len = (Get-Item -LiteralPath $inFile).Length
$rnd = New-Object byte[] ([Math]::Max(64, $len))
(New-Object Random 7).NextBytes($rnd)
[IO.File]::WriteAllBytes($inFile, $rnd)
Remove-Item -LiteralPath $inFile -Force
Write-Host ('saved: ' + $dir)
Get-ChildItem -LiteralPath $dir | ForEach-Object { Write-Host ('  ' + $_.Name + '  ' + $_.Length + ' bytes') }
# 自检：能否解回非空口令（不回显内容）
foreach ($n in 'vm-password.dpapi', 'guest-password.dpapi') {
    $enc = (Get-Content -LiteralPath (Join-Path $dir $n) -Raw).Trim()
    $sec = ConvertTo-SecureString $enc
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); Write-Host ('  ' + $n + ' 解密长度=' + $plain.Length) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
