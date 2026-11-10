#requires -Version 5.1
<# Interactive, user-run only. Never pass passwords on this script's command line. #>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmChannel.ps1')
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rid = New-MwRunId -Prefix 'vm-secret-check'
$ev = Join-Path $acceptanceRoot ('evidence\' + $rid)
New-Item -ItemType Directory -Path $ev | Out-Null
$secretDir = Join-Path $env:USERPROFILE 'AppData\Local\MinglingWorkbench\acceptance'
$secure = Read-Host 'VM encryption password (not the Windows account password)' -AsSecureString
$ptr = [IntPtr]::Zero
$plain = $null
try {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    Initialize-MwVmChannel -VmxPassword $plain -RunId $rid -EvidenceDir $ev -SecretsDir $secretDir | Out-Null
    # listSnapshots opens the encrypted VM; vmrun list does not validate this password.
    $record = Invoke-MwVm -Action 'listSnapshots' -Label 'verify-vm-encryption' -TimeoutSeconds 60 -AllowFailure
    Save-MwJson -Path (Join-Path $ev 'verification.json') -Object $record
    if ($record.exitCode -ne 0 -or $record.timedOut) {
        Write-Host 'VM verification failed. Existing DPAPI secret was NOT changed. See verification evidence.'
        exit 13
    }
    New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
    $dest = Join-Path $secretDir 'vm-password.dpapi'
    if (Test-Path -LiteralPath $dest) {
        Copy-Item -LiteralPath $dest -Destination ($dest + '.' + $rid + '.bak')
    }
    # ConvertFrom-SecureString uses CurrentUser DPAPI on Windows. No plaintext file.
    $encrypted = ConvertFrom-SecureString -SecureString $secure
    [IO.File]::WriteAllText($dest, $encrypted, (New-Object Text.UTF8Encoding($false)))
    Save-MwJson -Path (Join-Path $ev 'result.json') -Object ([ordered]@{
        status='verified-and-updated'; secret='vm-password.dpapi'; plaintextPersisted=$false;
        vmx='E:\Windows 11 x64\Windows 11 x64.vmx'; at=(Get-Date).ToUniversalTime().ToString('o')
    })
    Write-Host ('VM encryption credential verified and saved with DPAPI. Evidence: ' + $ev)
} finally {
    if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    $plain=$null; $script:MwVm.VmxPassword=''; $secure.Dispose()
    Write-MwManifest -Root $ev | Out-Null
}
