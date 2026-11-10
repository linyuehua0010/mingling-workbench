#requires -Version 5.1
param([string]$RunId = '')
$ErrorActionPreference = 'Stop'
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $acceptanceRoot 'lib\Capture.ps1')
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
if (-not $RunId) { $RunId = New-MwRunId -Prefix 'host-access' }
if ($RunId -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid run-id' }
$dir = Join-Path $acceptanceRoot ('evidence\' + $RunId)
if (Test-Path -LiteralPath $dir) { throw 'Evidence directory already exists' }
New-Item -ItemType Directory -Path $dir | Out-Null
$result = [ordered]@{
    runId=$RunId; at=(Get-Date).ToUniversalTime().ToString('o'); status='blocked-env'; exitCode=13
    guestStarted=$false; productAcceptance=$false; vmrunExit=$null; targetVmListed=$false
    loopback=$false; loopbackError=''; serviceQuery=$false; serviceQueryError=''
    redirectedLocalAppData=($env:LOCALAPPDATA -match '\\Packages\\sandbox\.')
}
$listener = $null; $client = $null; $accepted = $null
try {
    # Bind and connect an ephemeral loopback port. Does not change firewall or services.
    try {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $client = New-Object Net.Sockets.TcpClient
        $pending = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw 'Loopback connect timeout' }
        $client.EndConnect($pending)
        $accepted = $listener.AcceptTcpClient()
        $result.loopback = $true
    } catch { $result.loopbackError = $_.Exception.ToString() }
    finally {
        if ($accepted) { $accepted.Close() }
        if ($client) { $client.Close() }
        if ($listener) { $listener.Stop() }
    }
    # No credentials are needed to list VMs. Do not launch or stop a VM here.
    $capture = Invoke-Capture -Label 'vmrun-list' -FilePath 'E:\VMware\vmrun.exe' `
        -Arguments @('-T','ws','list') -Kind exe -EvidenceDir $dir -RunId $RunId -TimeoutSeconds 30
    Add-MwJsonLine -Path (Join-Path $dir 'commands.jsonl') -Object $capture.Record
    $result.vmrunExit = $capture.Record.exitCode
    $output = [IO.File]::ReadAllText($capture.Record.stdoutPath)
    $result.targetVmListed = ($result.vmrunExit -eq 0 -and $output -match [regex]::Escape('E:\Windows 11 x64\Windows 11 x64.vmx'))
    try { Get-Service -Name 'VMware NAT Service' -ErrorAction Stop | Out-Null; $result.serviceQuery=$true }
    catch { $result.serviceQueryError=$_.Exception.Message }
    # A service query is diagnostic only: it does not prove permission to stop NAT.
    if ($result.loopback -and $result.targetVmListed) { $result.status='ready-for-channel-test'; $result.exitCode=0 }
} finally {
    Save-MwJson -Path (Join-Path $dir 'host-access.json') -Object $result
    Write-MwManifest -Root $dir | Out-Null
}
Write-Host ('##RESULT host-access status=' + $result.status + ' loopback=' + $result.loopback + ' vmrunExit=' + $result.vmrunExit + ' targetVmListed=' + $result.targetVmListed + ' evidence=' + $dir)
exit $result.exitCode
