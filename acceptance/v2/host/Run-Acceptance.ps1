#requires -Version 5.1
<#
  acceptance\v2\host\Run-Acceptance.ps1 — V3.1.0 端到端验收主调度（宿主机侧）

  职责：
    1. 每次运行生成独立 run-id（不接受宿主机上已有目录，绝不覆盖旧证据）。
    2. 校验/准备 stage（安装包、组件清单、夹具），核对 SHA256。
    3. 把新库与来宾阶段脚本部署进来宾，按 pre/full/recovery/upgrade/final 逐阶段执行。
    4. 长任务不盲等：每 20 秒取一次来宾 progress.json，打印阶段/当前命令/已耗时/最近日志。
    5. 阶段结束先回收证据（来宾 POST + 目录取回），校验 HTTP 状态与 SHA256，再允许回滚快照。
    6. 最后写 manifest + SHA256、打包 zip、打印汇总；退出码按最严重状态。

  用法示例：
    powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Run-Acceptance.ps1 `
      -Phases pre,full,recovery,upgrade,final -StartServer -RevertSnapshot '快照 1'

  退出码：0 全通过；10 有产品失败；11 有夹具失败；12 缺前置；13 环境阻塞；14 证据不完整。
#>
param(
    [string[]]$Phases = @('pre', 'full', 'recovery', 'upgrade', 'final'),
    [string]$RunId = '',
    [string]$VmExe = 'E:\VMware\vmrun.exe',
    [string]$VmxPath = 'E:\Windows 11 x64\Windows 11 x64.vmx',
    [string]$GuestUser = '',
    [ValidateSet('admin', 'standard')][string]$Tier = 'admin',
    [string]$GuestRoot = '',
    [string]$StageUrl = 'http://192.168.206.1:8000/stage',
    [string]$EvidenceUrl = 'http://192.168.206.1:8000',
    [string]$ServerPort = '8000',
    [string]$RevertSnapshot = '',
    [switch]$StartServer,
    [switch]$SkipDeploy,
    [int]$PollSeconds = 20,
    [hashtable]$PhaseTimeoutMinutes = @{ pre = 90; full = 180; recovery = 120; upgrade = 120; final = 45 }
)

# powershell.exe -File 传数组只能给一个逗号串：'-Phases pre,full'，这里展开。
$Phases = @($Phases | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
$repo = Split-Path -Parent $acceptanceRoot
. (Join-Path $here 'VmChannel.ps1')
. (Join-Path $here 'GuestScript.ps1')
. (Join-Path $here '..\..\lib\Check.ps1')

# 两种验收身份：admin（提升令牌，装系统级组件）与 standard（普通用户，断言 administratorToken=false）。
# standard 走 DPAPI 里的 std-user 口令；GuestRoot 默认落在该用户自己的目录下，避免 Public 写权限不确定。
$guestPw = ''
if ($Tier -eq 'standard') {
    if (-not $GuestUser) { $GuestUser = 'MWAcceptance' }
    if (-not $GuestRoot) { $GuestRoot = 'C:\Users\' + $GuestUser + '\MWAcceptance' }
    $guestPw = Read-MwDpapiSecret 'std-user-password.dpapi'
    if (-not $guestPw) { throw '标准用户口令缺失：先跑 acceptance\v2\host\New-GuestStandardUser.ps1（管理员通道）建立 MWAcceptance' }
} else {
    if (-not $GuestRoot) { $GuestRoot = 'C:\Users\Public\MWAcceptance' }
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $RunId) { $RunId = 'v310-' + $stamp }
$runDir = Join-Path $acceptanceRoot ('evidence\' + $RunId)
if (Test-Path -LiteralPath $runDir) { throw "run 目录已存在，拒绝覆盖旧证据：$runDir（换一个 -RunId）" }
foreach ($d in @('host', 'guest', 'phases')) { New-Item -ItemType Directory -Force -Path (Join-Path $runDir $d) | Out-Null }

$init = Initialize-MwVmChannel -VmExe $VmExe -VmxPath $VmxPath -GuestUser $GuestUser -GuestPassword $guestPw -GuestRoot $GuestRoot `
    -EvidenceUrl $EvidenceUrl -RunId $RunId -EvidenceDir (Join-Path $runDir 'host')
if (-not $init.ok) {
    $bad = [ordered]@{ runId = $RunId; ok = $false; status = 'blocked-env'; missing = $init.missing; utc = (Get-Date).ToUniversalTime().ToString('o') }
    Save-MwJson -Path (Join-Path $runDir 'run.json') -Object $bad
    Write-Host ('[BLOCKED] ' + ($init.missing -join '；'))
    exit 13
}

$logLines = New-Object System.Collections.ArrayList
function Write-RunLog {
    param([string]$Message, [string]$Level = 'info')
    $line = ('[{0}] {1} {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message)
    Write-Host $line
    [void]$logLines.Add($line)
    Add-Content -LiteralPath (Join-Path $runDir 'host\run.log') -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- 证据服务
$serverProc = $null
if ($StartServer) {
    $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
    if (-not $py) { throw '找不到 python，无法启动证据服务' }
    $serverScript = Join-Path $here 'EvidenceServer.py'
    $serverOut = Join-Path $runDir 'host\server.out.log'
    $serverErr = Join-Path $runDir 'host\server.err.log'
    $serverProc = Start-Process -FilePath $py -ArgumentList @($serverScript, $ServerPort) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    Write-RunLog ('证据服务启动 pid=' + $serverProc.Id + ' port=' + $ServerPort)
    Start-Sleep -Seconds 2
    try {
        $h = Invoke-WebRequest -Uri ($EvidenceUrl + '/health') -TimeoutSec 10 -UseBasicParsing
        Write-RunLog ('证据服务 /health HTTP ' + [int]$h.StatusCode)
    } catch {
        Write-RunLog ('证据服务 /health 失败：' + $_.Exception.Message) 'warn'
    }
}

try {
    # ---------------------------------------------------------------- stage 校验
    $stageDir = Join-Path $here '..\stage'
    $sumFile = Join-Path $stageDir 'checksums.json'
    $stageCheck = [ordered]@{ ok = $true; files = @(); problems = @() }
    if (-not (Test-Path -LiteralPath $sumFile)) {
        $stageCheck.ok = $false
        $stageCheck.problems += "缺少 $sumFile（先运行 acceptance\v2\host\Prepare-Stage.ps1）"
    } elseif ($true) {
        $manifest = Get-Content -LiteralPath $sumFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($manifest.files)) {
            $name = [string]$e.name
            $want = [string]$e.sha256
            $p = Join-Path $stageDir $name
            if (-not (Test-Path -LiteralPath $p)) { $stageCheck.ok = $false; $stageCheck.problems += "stage 缺文件：$name"; continue }
            $got = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
            $ok = ($got -eq $want)
            if (-not $ok) { $stageCheck.ok = $false; $stageCheck.problems += "SHA256 不符：$name want=$want got=$got" }
            $stageCheck.files += [ordered]@{ name = $name; bytes = (Get-Item -LiteralPath $p).Length; sha256 = $got; expected = $want; ok = $ok }
        }
    } else {
        foreach ($line in Get-Content -LiteralPath $sumFile) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $parts = $line -split '\s+', 2
            if ($parts.Count -ne 2) { continue }
            $want = $parts[0].ToLower()
            $name = $parts[1].Trim()
            $p = Join-Path $stageDir $name
            if (-not (Test-Path -LiteralPath $p)) { $stageCheck.ok = $false; $stageCheck.problems += "stage 缺文件：$name"; continue }
            $got = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            $ok = ($got -eq $want)
            if (-not $ok) { $stageCheck.ok = $false; $stageCheck.problems += "SHA256 不符：$name want=$want got=$got" }
            $stageCheck.files += [ordered]@{ name = $name; bytes = (Get-Item -LiteralPath $p).Length; sha256 = $got; expected = $want; ok = $ok }
        }
    }
    Save-MwJson -Path (Join-Path $runDir 'host\stage.json') -Object $stageCheck
    Write-RunLog ('stage 校验 ok=' + $stageCheck.ok + ' files=' + @($stageCheck.files).Count)
    if (-not $stageCheck.ok) { foreach ($p in $stageCheck.problems) { Write-RunLog $p 'error' } }

    # ---------------------------------------------------------------- 部署到来宾
    $hostChannel = Invoke-MwVm -Action 'list' -Label 'host-channel-preflight' -TimeoutSeconds 60 -AllowFailure
    if ($hostChannel.exitCode -ne 0 -or $hostChannel.status -ne 'completed') {
        $why = '宿主 vmrun list 不可用；来宾阶段未启动。' + $hostChannel.stdoutText + $hostChannel.stderrText
        Write-RunLog $why 'error'
        Save-MwBlockedRun -RunDir $runDir -RunId $RunId -Phases $Phases -Message $why -CommandRecord $hostChannel
        exit 13
    }
    $guestRun = $GuestRoot + '\run\' + $RunId
    $guestLib = $GuestRoot + '\lib'
    if (-not $SkipDeploy) {
        Write-RunLog '向来宾部署库与阶段脚本 ...'
        # 目录级复制（copyDirectoryFromHostToGuest）在本机 vmrun 17.0.0 一律 exit=-1，
        # 因此逐文件送 + 回传校验（Send-MwGuestTree），任何一个字节/哈希不符都算部署失败。
        $libSend = Send-MwGuestTree -HostPath (Join-Path $acceptanceRoot 'lib') -GuestPath $guestLib `
            -Label 'lib' -EvidenceDir (Join-Path $runDir 'host') -TimeoutSeconds 600
        Write-RunLog ('  库部署：' + $libSend.ok + '/' + $libSend.total + ' 个文件校验一致')
        if ($libSend.badCount -gt 0) { throw ('库部署校验失败：' + (@($libSend.bad) -join '; ')) }
        $phaseScript = (Resolve-Path -LiteralPath (Join-Path $here '..\guest\Invoke-Phase.ps1')).ProviderPath
        $one = @{ host = $null }
        New-MwGuestDir -GuestPath $GuestRoot | Out-Null
        Copy-MwFileToGuest -HostPath $phaseScript -GuestPath ($GuestRoot + '\Invoke-Phase.ps1') | Out-Null
        $gsSha = (Get-FileHash -LiteralPath $phaseScript -Algorithm SHA256).Hash.ToLowerInvariant()
        $gsBody = @"
`$p = '$GuestRoot\Invoke-Phase.ps1'
`$R.data.exists = Test-Path -LiteralPath `$p
if (`$R.data.exists) {
  `$R.data.bytes = (Get-Item -LiteralPath `$p).Length
  `$R.data.sha256 = (Get-FileHash -LiteralPath `$p -Algorithm SHA256).Hash.ToLower()
}
`$R.ok = `$true
"@
        $gsProbe = Invoke-MwGuestScript -Name 'phase-script-hash' -Body $gsBody -GuestDir ($guestRun + '\probe') `
            -EvidenceDir (Join-Path $runDir 'host') -RunId $RunId -Phase 'deploy' -TimeoutSeconds 180
        if (-not $gsProbe.fetched -or -not $gsProbe.obj -or -not $gsProbe.obj.data.exists) { throw '来宾阶段脚本不存在或无法取回哈希' }
        if ([string]$gsProbe.obj.data.sha256 -ne $gsSha) { throw ('来宾阶段脚本 SHA256 不符：want=' + $gsSha + ' got=' + $gsProbe.obj.data.sha256) }
        Write-RunLog ('  阶段脚本部署：SHA256 ' + $gsSha.Substring(0, 12) + '… 一致（venv 字节 ' + $gsProbe.obj.data.bytes + '）')
        New-MwGuestDir -GuestPath ($guestRun + '\progress') | Out-Null
        Write-RunLog '部署完成'
    }

    # ---------------------------------------------------------------- 快照回滚（只在本 run 开始前）
    if ($RevertSnapshot) {
        Write-RunLog ('回滚快照：' + $RevertSnapshot + '（回滚前本 run 尚无证据可取回）')
        $state = Get-MwVmState
        if ($state.text -match [regex]::Escape($init.vmxPath)) {
            Write-RunLog '虚拟机在运行，先关机再回滚' 'warn'
            try { Stop-MwVm -TimeoutSeconds 300 | Out-Null } catch { Write-RunLog ('关机失败：' + $_.Exception.Message) 'warn' }
            Start-Sleep -Seconds 10
        }
        Restore-MwVmSnapshot -Name $RevertSnapshot -TimeoutSeconds 900 | Out-Null
        Write-RunLog '快照已回滚'
    }

    # ---------------------------------------------------------------- 启动来宾 + 等 Tools
    $state2 = Get-MwVmState
    if ($state2.text -notmatch [regex]::Escape($init.vmxPath)) {
        Write-RunLog '启动虚拟机 ...'
        Start-MwVm -TimeoutSeconds 900 | Out-Null
    }
    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        $probe = Invoke-MwVm -Action 'listProcessesInGuest' -Label ('vm-wait-tools-' + $i) -TimeoutSeconds 120 -AllowFailure
        if ($probe.exitCode -eq 0) { $ready = $true; break }
        if ($i % 6 -eq 0) { Write-RunLog ('等 VMware Tools ... (' + ($i * 5) + 's)') }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { throw 'VMware Tools 不可用，来宾接口无法使用' }

    # ---------------------------------------------------------------- 逐阶段执行
    $phaseSummaries = New-Object System.Collections.ArrayList
    foreach ($phase in $Phases) {
        $phaseDirHost = Join-Path $runDir ('phases\' + $phase)
        New-Item -ItemType Directory -Force -Path $phaseDirHost | Out-Null
        $guestPhaseDir = $guestRun + '\' + $phase
        $timeoutMin = if ($PhaseTimeoutMinutes.ContainsKey($phase)) { $PhaseTimeoutMinutes[$phase] } else { 90 }
        $started = Get-Date
        Write-RunLog ('==== 阶段 ' + $phase + ' 开始（超时 ' + $timeoutMin + ' 分钟）====')

        $args = @('-Phase', $phase, '-RunId', $RunId, '-LibDir', $guestLib, '-GuestRoot', $GuestRoot,
            '-StageUrl', $StageUrl, '-EvidenceUrl', ($EvidenceUrl + '/upload'))
        $launch = Invoke-MwGuestPowerShellFile -GuestScriptPath ($GuestRoot + '\Invoke-Phase.ps1') `
            -Arguments $args -Label ('phase-' + $phase + '-launch') -NoWait -TimeoutSeconds 120
        Write-RunLog ('已启动来宾阶段（vmrun exit=' + $launch.exitCode + '）')

        $doneHost = Join-Path $phaseDirHost 'done.json'
        $progressHost = Join-Path $phaseDirHost 'progress.json'
        $timeline = New-Object System.Collections.ArrayList
        $deadline = $started.AddMinutes($timeoutMin)
        $done = $null
        $lastStep = ''
        $pollCount = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            $pollCount++
            # 每 5 次轮询确认一次来宾电源还在：客户机休眠/崩溃时不能盲等整个超时预算。
            if (($pollCount % 5) -eq 0) {
                $vmState = Get-MwVmState
                if ($vmState.exitCode -ne 0 -or ([string]$vmState.text) -notmatch 'Total running VMs:\s*[1-9]') {
                    Write-RunLog ('来宾电源已断开（' + (($vmState.text -split "`r?`n") -join ' ') + '），阶段 ' + $phase + ' 判夹具失败') 'error'
                    $done = [pscustomobject]@{ status = 'fail-fixture'; exitCode = 11; detail = '来宾电源在阶段执行中关闭/挂起（vmrun list 已不含该 VM）'; checks = @() }
                    break
                }
            }
            # 取进度（失败不致命：文件还没生成/正在替换）
            try {
                Copy-MwFileFromGuest -GuestPath ($guestRun + '\progress\progress.json') -HostPath $progressHost -TimeoutSeconds 60 | Out-Null
                $pr = Get-Content -LiteralPath $progressHost -Raw -Encoding UTF8 | ConvertFrom-Json
                $stepKey = [string]$pr.step
                # 步骤名里带“（已运行 N 秒）”，只比较去掉耗时后的主体，避免每次都刷一行
                $stepKey = ($stepKey -replace '（已运行 \d+ 秒）', '').Trim()
                if ($stepKey -and $stepKey -ne $lastStep) {
                    $lastStep = $stepKey
                    Write-RunLog ('  [' + $phase + '] ' + $pr.elapsedSeconds + 's ' + $pr.step + $(if ($pr.command) { ' :: ' + $pr.command } else { '' }))
                }
                [void]$timeline.Add([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); elapsed = $pr.elapsedSeconds; step = $pr.step; status = $pr.status; tail = $pr.tail })
            } catch { }
            try {
                Copy-MwFileFromGuest -GuestPath ($guestPhaseDir + '\done.json') -HostPath $doneHost -TimeoutSeconds 60 | Out-Null
                if (Test-Path -LiteralPath $doneHost) {
                    $done = Get-Content -LiteralPath $doneHost -Raw -Encoding UTF8 | ConvertFrom-Json
                    break
                }
            } catch { }
        }
        $ended = Get-Date
        $elapsedSec = [int]($ended - $started).TotalSeconds

        if (-not $done) {
            Write-RunLog ('阶段 ' + $phase + ' 超时（' + $elapsedSec + 's），结束来宾进程树') 'error'
            try {
                if (Test-Path -LiteralPath $progressHost) {
                    $pr = Get-Content -LiteralPath $progressHost -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($pr.pid) { Stop-MwGuestProcess -GuestPid ([int]$pr.pid) | Out-Null }
                }
            } catch { }
            $done = [pscustomobject]@{ status = 'fail-fixture'; exitCode = 11; detail = ('阶段超时 ' + $elapsedSec + 's，被宿主端终止'); checks = @() }
        }

        # 回收证据：逐文件取回（本机 vmrun 的 copyDirectoryFromGuestToHost 一律 exit=-1，
        # 所以用带 SHA256 清单的逐文件通道；每个文件都核对字节与哈希），失败也留现场。
        $guestCopy = Join-Path $phaseDirHost 'guest'
        try {
            $tree = Receive-MwGuestTree -GuestPath $guestPhaseDir -HostPath $guestCopy -Label ('phase-' + $phase) -TimeoutSeconds 1800
            $script:LastTree = $tree
            Write-RunLog ('  证据取回：' + $tree.ok + '/' + $tree.total + ' 个文件，' + $tree.bytes + ' 字节，不符 ' + $tree.badCount)
            if ($tree.badCount -gt 0) { Write-RunLog ('  取回不符：' + (@($tree.bad) -join '; ')) 'warn' }
        } catch {
            Write-RunLog ('  证据取回失败：' + $_.Exception.Message) 'warn'
        }
        $receipts = $null
        try {
            $r = Invoke-WebRequest -Uri ($EvidenceUrl + '/receipts/' + $RunId) -TimeoutSec 20 -UseBasicParsing
            $receipts = $r.Content | ConvertFrom-Json
        } catch { Write-RunLog ('  取回执失败：' + $_.Exception.Message) 'warn' }

        $failedUploads = @()
        if ($receipts -and $receipts.receipts) {
            $failedUploads = @($receipts.receipts | Where-Object { $_.status -ne 200 })
            if ($failedUploads.Count) { Write-RunLog ('  上传回执异常 ' + $failedUploads.Count + ' 条') 'warn' }
        }
        Save-MwJson -Path (Join-Path $phaseDirHost 'timeline.json') -Object @($timeline)
        if ($receipts) { Save-MwJson -Path (Join-Path $phaseDirHost 'receipts.json') -Object $receipts }

        $summary = [ordered]@{
            phase = $phase; runId = $RunId; startedUtc = $started.ToUniversalTime().ToString('o'); endedUtc = $ended.ToUniversalTime().ToString('o')
            durationSeconds = $elapsedSec; guestStatus = $done.status; guestExitCode = $done.exitCode
            counts = $done.counts; receiptFailed = @($failedUploads).Count; checks = $done.checks
        }
        Save-MwJson -Path (Join-Path $phaseDirHost 'phase.json') -Object $summary
        [void]$phaseSummaries.Add($summary)
        Write-RunLog ('==== 阶段 ' + $phase + ' 结束 status=' + $done.status + ' exit=' + $done.exitCode + ' 用时 ' + $elapsedSec + 's ====')
    }

    # ---------------------------------------------------------------- 收尾
    # 先停证据服务：它打开的 server.out/err.log 在 Windows 上无法计算 SHA256，
    # 直接写 manifest 会因文件占用失败（上一 run 就是这样丢掉收尾证据的）。
    if ($serverProc -and -not $serverProc.HasExited) {
        try { $serverProc.Kill(); $serverProc.WaitForExit(5000) | Out-Null } catch { }
        Start-Sleep -Milliseconds 300
        Write-RunLog '证据服务已停止（收尾哈希前）'
    }
    $manifest = Write-MwManifest -Root $runDir
    $zip = Join-Path $runDir ('..\' + $RunId + '-evidence.zip')
    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -Force
        Write-RunLog ('证据包：' + (Resolve-Path -LiteralPath $zip).ProviderPath + ' ' + (Get-Item -LiteralPath $zip).Length + ' bytes')
    } catch { Write-RunLog ('打包失败：' + $_.Exception.Message) 'warn' }

    # 汇总必须逐阶段累加 counts；phase.json 里的 checks 只是数量，不是检查对象。
    # （v310-20261109-212348 的教训：把 int 当检查列表喂给 Get-MwCounts，结果 total=1/not-run，
    #  于是 pre 明明 fail-fixture=1，run.json 却记 exitCode=0 —— 失败的阶段被当成通过。）
    $countKeys = @('total','pass','fail-product','fail-fixture','blocked-precondition','blocked-env','manual-pending','not-run','evidence-incomplete')
    $counts = [ordered]@{}
    foreach ($k in $countKeys) { $counts[$k] = 0 }
    foreach ($p in $phaseSummaries) {
        if (-not $p.counts) { continue }
        # phase.json 读回来是 PSCustomObject（没有 .Keys），必须逐属性转成字典再累加，
        # 否则合计永远 total=0（v310-20261109-214405 的教训：阶段 exit=14 但汇总显示 0）。
        $cd = @{}
        if ($p.counts -is [System.Collections.IDictionary]) {
            foreach ($k in $p.counts.Keys) { $cd[[string]$k] = $p.counts[$k] }
        } else {
            foreach ($pr in $p.counts.PSObject.Properties) { $cd[$pr.Name] = $pr.Value }
        }
        foreach ($k in $countKeys) {
            if ($cd.ContainsKey($k)) { $counts[$k] = [int]$counts[$k] + [int]$cd[$k] }
        }
    }
    # 退出码取最严重者：夹具 11 > 产品 10 > 前置 12 > 环境 13 > 证据 14
    $sev = @{ 11 = 5; 10 = 4; 12 = 3; 13 = 2; 14 = 1 }
    $overallExit = 0
    foreach ($p in $phaseSummaries) {
        $e = [int]$p.guestExitCode
        if ($e -eq 0) { continue }
        if ($overallExit -eq 0 -or [int]$sev[$e] -gt [int]$sev[$overallExit]) { $overallExit = $e }
    }
    $overall = [ordered]@{
        runId = $RunId; ok = $false; startedUtc = $stamp; endedUtc = (Get-Date).ToUniversalTime().ToString('o')
        vmx = $init.vmxPath; guest = $init.guestUser; guestRoot = $GuestRoot
        evidenceUrl = $EvidenceUrl; stageChecked = $stageCheck.ok
        phases = @($phaseSummaries); counts = $counts; exitCode = $overallExit
        serverPid = if ($serverProc) { $serverProc.Id } else { 0 }
        hostLog = (Join-Path $runDir 'host\run.log')
    }
    $overall.ok = ([int]$counts['total'] -gt 0 -and [int]$counts['fail-product'] -eq 0 -and [int]$counts['fail-fixture'] -eq 0 -and [int]$counts['blocked-precondition'] -eq 0 -and [int]$counts['blocked-env'] -eq 0 -and [int]$counts['evidence-incomplete'] -eq 0)
    Save-MwJson -Path (Join-Path $runDir 'run.json') -Object $overall
    Write-MwManifest -Root $runDir | Out-Null

    Write-Host ''
    Write-Host '================ 汇总 ================'
    foreach ($p in $phaseSummaries) {
        $c = $p.counts
        $cpass = 0; $cfail = 0
        if ($c) {
            if ($c -is [System.Collections.IDictionary]) { $cpass = [int]$c['pass']; $cfail = [int]$c['fail-product'] + [int]$c['fail-fixture'] }
            else { $cpass = [int]$c.pass; $cfail = [int]$c.'fail-product' + [int]$c.'fail-fixture' }
        }
        Write-Host ('  {0,-9} {1,-14} exit={2,-3} 用时 {3,5}s  通过 {4}  失败 {5}' -f $p.phase, $p.guestStatus, $p.guestExitCode, $p.durationSeconds, $cpass, $cfail)
    }
    Write-Host ('  合计：total=' + $counts['total'] + ' pass=' + $counts['pass'] + ' fail-product=' + $counts['fail-product'] + ' fail-fixture=' + $counts['fail-fixture'] + ' blocked=' + ([int]$counts['blocked-precondition'] + [int]$counts['blocked-env']) + ' manual=' + $counts['manual-pending'] + ' evidence-incomplete=' + $counts['evidence-incomplete'])
    Write-Host ('  run.json: ' + (Join-Path $runDir 'run.json'))
    $code = [int]$overall.exitCode
    exit $code
}
catch {
    Write-RunLog ('调度器异常：' + $_.Exception.Message + ' / ' + $_.ScriptStackTrace) 'error'
    Save-MwJson -Path (Join-Path $runDir 'host\harness-error.json') -Object ([ordered]@{
        utc = (Get-Date).ToUniversalTime().ToString('o'); message = $_.Exception.Message
        stack = $_.ScriptStackTrace; phase = $null
    })
    Write-MwManifest -Root $runDir | Out-Null
    exit 11
}
finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        try { $serverProc.Kill() } catch { }
    }
}
