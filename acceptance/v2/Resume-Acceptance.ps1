#requires -Version 5.1
<# Run in an explicitly authorized host session. Never changes execution permissions. #>
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$acceptanceRoot = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $acceptanceRoot
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
$batch = New-MwRunId -Prefix 'resume'
$dir = Join-Path $acceptanceRoot ('evidence\' + $batch)
New-Item -ItemType Directory -Path $dir | Out-Null
$summary = [ordered]@{ runId=$batch; status='running'; acceptanceComplete=$false; runs=@(); exitCode=0 }
function Run-Entry([string]$Name, [string]$Script, [string[]]$EntryArgs) {
    $started = (Get-Date).ToUniversalTime().ToString('o')
    $log = Join-Path $dir ($Name + '.log')
    Write-Host ('Running ' + $Name + '; log=' + $log)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @EntryArgs 2>&1 | Tee-Object -FilePath $log | Out-Host
    $code = $LASTEXITCODE
    $summary.runs += [ordered]@{ name=$Name; script=$Script; arguments=$EntryArgs; startedUtc=$started; endedUtc=(Get-Date).ToUniversalTime().ToString('o'); exitCode=$code; log=$log }
    Save-MwJson -Path (Join-Path $dir 'resume-summary.json') -Object $summary
    return $code
}
$code = 13
Push-Location $repo
try {
    $gate = Run-Entry 'host-access' (Join-Path $PSScriptRoot 'host\Test-HostAccess.ps1') @('-RunId', ($batch + '-host'))
    if ($gate -ne 0) {
        $summary.status='blocked-env'; $summary.exitCode=13
        Write-Host 'Host access is blocked. No cache transfer or guest phase started. See host-access.json.'
    } elseif ($CheckOnly) {
        $summary.status='host-access-ready'; $summary.exitCode=0
    } else {
        $seed = Run-Entry 'seed' (Join-Path $PSScriptRoot 'host\_seed-cache.ps1') @(
            '-HostFile', (Join-Path $acceptanceRoot 'cache\SnowLuma-v2.4.2-win-x64.zip'),
            '-GuestPath', 'C:\Users\MWAcceptance\MWAcceptance\冥零 验收\工作区 3.1\logs\setup\dl\snowluma-SnowLuma-v2.4.2-win-x64.zip')
        if ($seed -ne 0) {
            $summary.status='seed-failed'; $summary.exitCode=$seed
        } else {
            $runIds = @()
            foreach ($phase in @('full','recovery','upgrade','final')) {
                $rid = $batch + '-' + $phase
                $runIds += $rid
                $phaseCode = Run-Entry $phase (Join-Path $PSScriptRoot 'Run-All.ps1') @('-Phases',$phase,'-Tier','standard','-SkipNetCut','-RunId',$rid)
                if ($phaseCode -gt $summary.exitCode) { $summary.exitCode=$phaseCode }
            }
            $netId = $batch + '-netcut'
            $runIds += $netId
            $netCode = Run-Entry 'netcut' (Join-Path $PSScriptRoot 'host\Test-NetworkCut.ps1') @('-RunId',$netId)
            if ($netCode -gt $summary.exitCode) { $summary.exitCode=$netCode }
            $factArgs = @()
            foreach ($rid in $runIds) {
                $factArgs += @('--run',$rid)
                & python (Join-Path $PSScriptRoot 'host\collect-findings.py') $rid --json (Join-Path $dir ($rid + '.json')) --md (Join-Path $dir ($rid + '.md'))
                if ($LASTEXITCODE -ne 0) { $summary.exitCode=14 }
            }
            & python (Join-Path $PSScriptRoot 'host\report-data.py') @factArgs --out (Join-Path $dir 'report-data.json') | Out-Null
            if ($LASTEXITCODE -ne 0) { $summary.exitCode=14 }
            $summary.status='collected-needs-review'
            # Exit 0 is not an acceptance verdict: external dependencies still require review.
        }
    }
    $code=$summary.exitCode
} catch {
    $summary.status='runner-error'; $summary.exitCode=11; $code=11
    $summary['error']=$_.Exception.Message
} finally {
    Save-MwJson -Path (Join-Path $dir 'resume-summary.json') -Object $summary
    Write-MwManifest -Root $dir | Out-Null
    Pop-Location
}
Write-Host ('##RESULT resume status=' + $summary.status + ' exitCode=' + $code + ' evidence=' + $dir)
exit $code
