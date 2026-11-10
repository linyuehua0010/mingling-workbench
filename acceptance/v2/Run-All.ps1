#requires -Version 5.1
<#
  acceptance\v2\Run-All.ps1 — 可重复执行的验收总入口（宿主机侧）

  一条命令跑完：准备 stage → 确认证据服务在线 → pre/full/recovery/upgrade/final 逐阶段
  → 真实断网专项 → 汇总 JSON + 证据清单。每轮独立 run-id，绝不覆盖旧证据。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Run-All.ps1 `
      -Phases pre,full,recovery,upgrade,final -Tier standard -RevertSnapshot '快照 1'

  退出码：0 全通过；10 产品失败；11 夹具失败；12 前置缺失；13 环境阻塞；14 证据不完整。
#>
param(
    [string[]]$Phases = @('pre', 'full', 'recovery', 'upgrade', 'final'),
    [ValidateSet('admin', 'standard')][string]$Tier = 'standard',
    [string]$RunId = '',
    [string]$RevertSnapshot = '',
    [int]$ServerPort = 8000,
    [switch]$SkipNetCut,
    [switch]$SkipPrepareStage
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$acceptanceRoot = Split-Path -Parent $here
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $acceptanceRoot 'lib\Check.ps1')
. (Join-Path $here 'host\VmChannel.ps1')

if (-not $RunId) { $RunId = New-MwRunId -Prefix 'v310' }
$runDir = Join-Path $acceptanceRoot ('evidence\' + $RunId)
if (Test-Path -LiteralPath $runDir) { throw ('证据目录已存在，拒绝覆盖：' + $runDir) }

function Test-Port([int]$p) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false) -and $c.Connected
        try { $c.Close() } catch { }
        return $ok
    } catch { return $false }
}

$log = Join-Path $acceptanceRoot ('evidence\' + ('runall-' + $RunId + '.log'))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
function Say([string]$m) { $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $line; Add-Content -LiteralPath $log -Value $line -Encoding UTF8 }

Say ('run-id = ' + $RunId)
# powershell.exe -File 只按空格切分参数，'pre,full' 会作为一个字符串传进来；这里做一次展开。
$Phases = @($Phases | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$valid = @('pre', 'full', 'recovery', 'upgrade', 'final')
foreach ($p in $Phases) {
    if ($valid -notcontains $p) { throw ('未知阶段：' + $p + '（可用：' + ($valid -join ',') + '）') }
}
Say ('阶段 = ' + ($Phases -join ', ') + '；身份 = ' + $Tier)

if (-not $SkipPrepareStage) {
    Say '准备 stage …'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'host\Prepare-Stage.ps1')
    if ($LASTEXITCODE -ne 0) { Say ('[BLOCKED] prepare-stage 失败：' + $LASTEXITCODE); exit 12 }
}

$serverProc = $null
if (-not (Test-Port $ServerPort)) {
    Say ('启动证据服务 :' + $ServerPort)
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { Say '[BLOCKED] 找不到 python，无法启动证据服务'; exit 13 }
    $serverProc = Start-Process -FilePath $py.Source -ArgumentList @((Join-Path $here 'host\EvidenceServer.py'), [string]$ServerPort) `
        -WorkingDirectory $acceptanceRoot -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (-not (Test-Port $ServerPort)) {
        Say '[BLOCKED] 本地证据服务不可访问，收集实际 socket 错误；来宾阶段未启动'
        $probeCode = "import socket; s=socket.create_connection(('127.0.0.1'," + $ServerPort + "),5); print('connected'); s.close()"
        $probe = Invoke-Capture -Label 'evidence-service-connect' -FilePath $py.Source `
            -Arguments @('-c', $probeCode) -Kind exe -EvidenceDir (Join-Path $runDir 'host') -RunId $RunId -TimeoutSeconds 15
        if ($serverProc -and -not $serverProc.HasExited) { $serverProc.Kill(); $serverProc.WaitForExit(5000) | Out-Null }
        $why = '本地证据服务不可访问；详情见 socket stderr。未启动来宾阶段、未操作 NAT。'
        Save-MwBlockedRun -RunDir $runDir -RunId $RunId -Phases $Phases -Message $why -CommandRecord $probe.Record
        Copy-Item -LiteralPath $log -Destination (Join-Path $runDir 'host\runall.log')
        Save-MwJson -Path (Join-Path $runDir 'run-summary.json') -Object ([ordered]@{
            runId=$RunId; tier=$Tier; phases=$Phases; phaseExit=13; netcutExit=$null; worstExit=13;
            guestStarted=$false; reason=$why; at=(Get-Date).ToUniversalTime().ToString('o') })
        Write-MwManifest -Root $runDir | Out-Null
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath (Join-Path $acceptanceRoot ('evidence\' + $RunId + '-evidence.zip'))
        Say ('##RESULT run-all runId=' + $RunId + ' worstExit=13 guestStarted=false')
        exit 13
    }
} else {
    Say ('复用已在监听 :' + $ServerPort + ' 的证据服务（stage 目录就是 v2\stage）')
}

$phaseExit = 0
try {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'host\Run-Acceptance.ps1'), '-Phases', ($Phases -join ','))
    $args += @('-RunId', $RunId, '-Tier', $Tier, '-ServerPort', [string]$ServerPort)
    if ($RevertSnapshot) { $args += @('-RevertSnapshot', $RevertSnapshot) }
    Say '开始阶段执行 …'
    & powershell.exe @args
    $phaseExit = $LASTEXITCODE
    Say ('阶段执行退出码 = ' + $phaseExit)
} finally {
    if ($serverProc -and -not $serverProc.HasExited) { try { $serverProc.Kill() } catch { } }
}

$netcutExit = 0
if (-not $SkipNetCut) {
    Say '真实断网专项 …'
    $netcutRunId = $RunId + '-netcut'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'host\Test-NetworkCut.ps1') -RunId $netcutRunId -ServerPort $ServerPort
    $netcutExit = $LASTEXITCODE
    Say ('断网专项退出码 = ' + $netcutExit)
}

# 汇总：把每个阶段的 phase.json 与断网专项归到一份 run-summary.json
$phasesSummary = @()
foreach ($p in $Phases) {
    $f = Join-Path $runDir ('phases\' + $p + '\phase.json')
    if (Test-Path -LiteralPath $f) {
        try { $phasesSummary += (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
}
$netcutSummary = $null
$nf = Join-Path $acceptanceRoot ('evidence\' + $RunId + '-netcut\netcut\phase.json')
if (Test-Path -LiteralPath $nf) { try { $netcutSummary = Get-Content -LiteralPath $nf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

$codes = @($phaseExit, $netcutExit) | Where-Object { $_ -ne 0 }
$worst = 0
foreach ($c in $codes) { if ($c -gt $worst) { $worst = $c } }  # 10/11/12/13/14 单调，取最大即最严重
$summary = [ordered]@{
    runId = $RunId
    tier = $Tier
    phases = $Phases
    phaseExit = $phaseExit
    netcutExit = $netcutExit
    worstExit = $worst
    phasesSummary = $phasesSummary
    netcut = $netcutSummary
    evidenceDir = $runDir
    netcutDir = (Join-Path $acceptanceRoot ('evidence\' + $RunId + '-netcut'))
    at = (Get-Date).ToUniversalTime().ToString('o')
    log = $log
}
Save-MwJson -Path (Join-Path $runDir 'run-summary.json') -Object $summary
Say ('汇总写入 ' + (Join-Path $runDir 'run-summary.json'))
Say ('##RESULT run-all runId=' + $RunId + ' worstExit=' + $worst)
# Seal after run-summary and the final log line, including blocked runs.
Write-MwManifest -Root $runDir | Out-Null
$finalZip = Join-Path $acceptanceRoot ('evidence\' + $RunId + '-evidence.zip')
Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $finalZip -Force
exit $worst
