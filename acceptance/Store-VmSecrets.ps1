#requires -Version 5.1
# DPAPI-protected VM credentials for local acceptance only.
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'MinglingWorkbench\acceptance'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$vm = Read-Host 'VMware password (input hidden)' -AsSecureString
$guest = Read-Host 'Windows guest password (input hidden)' -AsSecureString
$user = Read-Host 'Windows guest user name (default: press Enter)'
if (-not $user) { $user = "$([char]0x51A5)$([char]0x96F6)" }
ConvertFrom-SecureString $vm | Set-Content -LiteralPath (Join-Path $dir 'vm-password.dpapi') -Encoding ASCII
ConvertFrom-SecureString $guest | Set-Content -LiteralPath (Join-Path $dir 'guest-password.dpapi') -Encoding ASCII
[IO.File]::WriteAllText((Join-Path $dir 'guest-user.txt'), $user, (New-Object Text.UTF8Encoding($false)))
Write-Host "Saved to $dir (DPAPI, current Windows user only)"
