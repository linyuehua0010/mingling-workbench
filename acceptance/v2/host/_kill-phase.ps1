$ErrorActionPreference='Stop'
$here=$PSScriptRoot;$acceptanceRoot=Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $acceptanceRoot 'lib\Capture.ps1'); . (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $here 'VmChannel.ps1'); . (Join-Path $here 'GuestScript.ps1')
$pw=Read-MwDpapiSecret 'std-user-password.dpapi'
$ev=Join-Path $acceptanceRoot 'evidence\_kill'
New-Item -ItemType Directory -Force -Path $ev | Out-Null
Initialize-MwVmChannel -GuestUser 'MWAcceptance' -GuestPassword $pw -GuestRoot 'C:\Users\MWAcceptance\MWAcceptance' -EvidenceUrl 'http://192.168.206.1:8000' -RunId 'kill' -EvidenceDir $ev | Out-Null
$body=@'
$killed=@()
$procs=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'Invoke-Phase|bootstrap\.ps1') })
foreach ($p in $procs) { $killed += $p.ProcessId; try { & taskkill /PID $p.ProcessId /T /F 2>&1 | Out-Null } catch { } }
Start-Sleep -Seconds 2
$left=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'Invoke-Phase|bootstrap\.ps1') } | ForEach-Object { $_.ProcessId })
$R.data=[ordered]@{killed=$killed;remaining=$left}
'@
$r=Invoke-MwGuestScript -Name 'killphase' -Body $body -GuestDir 'C:\Users\MWAcceptance\MWAcceptance' -EvidenceDir $ev -EvidenceUrl 'http://192.168.206.1:8000' -RunId 'kill' -Phase 'probe' -TimeoutSeconds 120
$r.obj | ConvertTo-Json -Depth 4
