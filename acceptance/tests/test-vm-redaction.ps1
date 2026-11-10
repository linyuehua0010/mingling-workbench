param([string]$OutPath = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Capture.ps1')
. (Join-Path $PSScriptRoot '..\lib\Evidence.ps1')
$rows = @()
$fakeVm = 'synthetic-vmx-secret'
$fakeGuest = 'synthetic guest secret'
$argsForTest = @('-T','ws','-vp',$fakeVm,'-gu','fixture-user','-gp',$fakeGuest,'list')
$safeArgs = @(Get-MwRedactedArgList -Arguments $argsForTest)
$rows += @{id='array-vp-gp';ok=($safeArgs[3] -eq '***' -and $safeArgs[7] -eq '***')}
$cmd = 'vmrun.exe -vp ' + $fakeVm + ' -gp "' + $fakeGuest + '" list'
$redacted = Get-RedactedText $cmd
$rows += @{id='quoted-command-line';ok=(-not $redacted.Contains($fakeVm) -and -not $redacted.Contains($fakeGuest) -and -not $redacted.Contains('guest secret'))}
$rec = New-CaptureRecord -Label 'redaction-fixture' -Kind exe -File 'vmrun.exe' -Exe 'vmrun.exe' -Arguments $argsForTest -CommandLine $cmd
$json = ConvertTo-MwSafeObject -InputObject $rec | ConvertTo-Json -Depth 10
$rows += @{id='serialized-safe-record';ok=(-not $json.Contains($fakeVm) -and -not $json.Contains($fakeGuest) -and -not $json.Contains('_argumentsRaw'))}
$leading = Get-RedactedText ('-vp ' + $fakeVm + ' list')
$rows += @{id='leading-flag';ok=(-not $leading.Contains($fakeVm))}
if ($OutPath) { Save-MwJson -Path $OutPath -Object @{fixtureOnly=$true;results=$rows;psVersion=$PSVersionTable.PSVersion.ToString()} }
$failures = @($rows | Where-Object { -not $_.ok }).Count
Write-Host ('##RESULT vm-redaction ' + ($rows.Count-$failures) + '/' + $rows.Count + ' fixture-only')
if ($failures) { exit 11 }
exit 0
