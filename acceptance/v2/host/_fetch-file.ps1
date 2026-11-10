param([Parameter(Mandatory = $true)][string]$GuestPath, [string]$OutName = '')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $acceptanceRoot 'lib\Capture.ps1')
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $here 'VmChannel.ps1')
$pw = Read-MwDpapiSecret 'std-user-password.dpapi'
$ev = Join-Path $acceptanceRoot 'evidence\_peek'
New-Item -ItemType Directory -Force -Path $ev | Out-Null
Initialize-MwVmChannel -GuestUser 'MWAcceptance' -GuestPassword $pw -GuestRoot 'C:\Users\MWAcceptance\MWAcceptance' -EvidenceUrl 'http://192.168.206.1:8000' -RunId 'fetch' -EvidenceDir $ev | Out-Null
if (-not $OutName) { $OutName = Split-Path -Leaf $GuestPath }
$host_path = Join-Path $ev $OutName
if (Test-Path -LiteralPath $host_path) { Remove-Item -LiteralPath $host_path -Force }
Copy-MwFileFromGuest -GuestPath $GuestPath -HostPath $host_path -TimeoutSeconds 180
Write-Output ("fetched bytes={0} sha={1}" -f (Get-Item -LiteralPath $host_path).Length, (Get-MwSha256 $host_path))
