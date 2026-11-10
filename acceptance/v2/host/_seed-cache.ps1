param(
    [Parameter(Mandatory = $true)][string]$HostFile,
    [Parameter(Mandatory = $true)][string]$GuestPath
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $acceptanceRoot 'lib\Capture.ps1')
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $here 'VmChannel.ps1')
$pw = Read-MwDpapiSecret 'std-user-password.dpapi'
$seedRunId = New-MwRunId -Prefix 'seed'
$ev = Join-Path $acceptanceRoot ('evidence\' + $seedRunId)
New-Item -ItemType Directory -Force -Path $ev | Out-Null
$channel = Initialize-MwVmChannel -GuestUser 'MWAcceptance' -GuestPassword $pw -GuestRoot 'C:\Users\MWAcceptance\MWAcceptance' -EvidenceUrl 'http://192.168.206.1:8000' -RunId $seedRunId -EvidenceDir $ev
. (Join-Path $acceptanceRoot 'lib\Check.ps1')
$probe = Invoke-MwVm -Action 'list' -Label 'seed-channel-preflight' -TimeoutSeconds 60 -AllowFailure
if ($probe.exitCode -ne 0) {
    Save-MwBlockedRun -RunDir $ev -RunId $seedRunId -Phases @('seed') `
        -Message '宿主 vmrun list 不可用；缓存尚未复制到来宾。' -CommandRecord $probe
    Write-Host ('##RESULT seed status=blocked-env evidence=' + $ev)
    exit 13
}
$dir = Split-Path -Parent $GuestPath
New-MwGuestDir -GuestPath $dir | Out-Null
Remove-MwGuestFile -GuestPath $GuestPath | Out-Null
$t0 = Get-Date
Copy-MwFileToGuest -HostPath $HostFile -GuestPath $GuestPath -TimeoutSeconds 1800 | Out-Null
$sec = [int]((Get-Date) - $t0).TotalSeconds
$local = Get-Item -LiteralPath $HostFile
Write-Output ("seeded bytes={0} sha={1} seconds={2} -> {3}" -f $local.Length, (Get-MwSha256 $HostFile), $sec, $GuestPath)
