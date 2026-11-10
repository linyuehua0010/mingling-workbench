#requires -Version 5.1
<#
  acceptance\v2\host\Test-NetworkCut.ps1 — 真实断网验证（宿主机切网，来宾证明不可达）

  为什么这样做：来宾里的 MWAcceptance 是普通用户，禁不了网卡；而验收要求在「外网真的不可达」
  的前提下验证安装器的正常模式必须失败、离线模式按缓存给结果，同时保留来宾控制与证据回收通道。
  做法：宿主机停掉 VMware NAT 服务 → 来宾失去外网，但 vmrun（VMCI）控制与 copyFile 取证不受影响
  → 来宾内探测两个独立目标 + DNS，并跑一次正常模式安装 → 宿主恢复 NAT 服务并验证恢复。

  前置：宿主进程有停止服务的权限；VM 正在运行；VMware Tools 就绪。
  退出码：0 通过；10 产品失败；11 夹具失败；12 前置条件缺失；13 环境阻塞；14 证据不完整。
#>
param(
    [string]$RunId = '',
    [int]$ServerPort = 8000,
    [string]$NatService = 'VMware NAT Service',
    [int]$BootstrapTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $acceptanceRoot 'lib\Capture.ps1')
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $acceptanceRoot 'lib\Check.ps1')
. (Join-Path $here 'VmChannel.ps1')
. (Join-Path $here 'GuestScript.ps1')

function Quote-Ps([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

if (-not $RunId) { $RunId = New-MwRunId -Prefix 'netcut' }
$evidenceDir = Join-Path $acceptanceRoot ('evidence\' + $RunId)
if (Test-Path -LiteralPath $evidenceDir) { throw ('证据目录已存在，拒绝覆盖：' + $evidenceDir) }
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$guestRoot = 'C:\Users\MWAcceptance\MWAcceptance'
$stdPw = Read-MwDpapiSecret 'std-user-password.dpapi'
if (-not $stdPw) { Write-Host '[BLOCKED] 标准用户口令缺失'; exit 12 }
$ch = Initialize-MwVmChannel -GuestUser 'MWAcceptance' -GuestPassword $stdPw -GuestRoot $guestRoot `
    -EvidenceUrl ("http://192.168.206.1:$ServerPort") -RunId $RunId -EvidenceDir $evidenceDir `
    -SecretsDir $script:MwVm.SecretsDir
if (-not $ch.ok) { Write-Host ('[BLOCKED] ' + ($ch.missing -join '；')); exit 13 }

$state = Get-MwVmState
$listRecord = Invoke-MwVm -Action 'list' -Label 'netcut-channel-preflight' -TimeoutSeconds 60 -AllowFailure
if ($listRecord.exitCode -ne 0 -or $listRecord.status -ne 'completed') {
    Save-MwBlockedRun -RunDir $evidenceDir -RunId $RunId -Phases @('netcut') `
        -Message '宿主 vmrun list 不可用；未执行来宾探测，未停止 NAT 服务。' -CommandRecord $listRecord
    Write-Host '##RESULT netcut status=blocked-env guestStarted=false natChanged=false'
    exit 13
}
if ($state.text -notmatch [regex]::Escape($ch.vmxPath)) {
    Write-Host '启动 VM …'
    Start-MwVm | Out-Null
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5; if ((Get-MwVmState).text -match [regex]::Escape($ch.vmxPath)) { break } }
    Start-Sleep -Seconds 15
}
$toolsDeadline = (Get-Date).AddMinutes(8)
$toolsOk = $false
while ((Get-Date) -lt $toolsDeadline) {
    $probeRec = Invoke-MwVm -Action 'listProcessesInGuest' -Label 'netcut-tools-wait' -TimeoutSeconds 60 -AllowFailure
    if ($probeRec.exitCode -eq 0) { $toolsOk = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $toolsOk) {
    Save-MwJson -Path (Join-Path $evidenceDir 'netcut.json') -Object @{ ok = $false; status = 'blocked-env'; missing = @('VMware Tools 8 分钟内未就绪') }
    Write-Host '[BLOCKED] VMware Tools 未就绪。'
    exit 13
}

$checks = New-Object System.Collections.ArrayList
function Add-Nc([string]$Id, [string]$Status, [string]$Detail, $Data, [string[]]$Evidence) {
    [void]$checks.Add((New-MwCheck -Id $Id -Criterion 8 -Requirement '真实阻断外网：正常模式必须失败，离线模式按缓存给结果，控制与取证通道保留' `
                -Preconditions @('VM 运行中；VMware Tools 就绪；宿主可停 NAT 服务；来宾为标准用户') `
                -Steps @('宿主停 NAT；来宾探测外网；来宾跑正常模式安装；宿主恢复 NAT') `
                -Assertion '见 Id' -Evidence $Evidence -Status $Status -Detail $Detail -Data $Data))
}

$probeBody = @'
$targets = @(
  @{ name = '1.1.1.1:443'; host = '1.1.1.1'; port = 443 },
  @{ name = '223.5.5.5:53'; host = '223.5.5.5'; port = 53 },
  @{ name = 'www.baidu.com:443'; host = 'www.baidu.com'; port = 443 }
)
$rows = @()
foreach ($t in $targets) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ok = $false; $err = ''
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($t.host, $t.port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(4000, $false) -and $c.Connected
    if (-not $ok) { $err = 'connect-timeout-or-refused' }
    try { $c.Close() } catch { }
  } catch { $err = $_.Exception.Message }
  $sw.Stop()
  $rows += [ordered]@{ name = $t.name; reachable = $ok; ms = [int]$sw.ElapsedMilliseconds; error = $err }
}
try { $dns = [bool](Resolve-DnsName -Name 'www.baidu.com' -Type A -ErrorAction Stop) ; $dnsErr = '' } catch { $dns = $false; $dnsErr = $_.Exception.Message }
$R.data = [ordered]@{ targets = $rows; dnsResolves = $dns; dnsError = $dnsErr }
$R.ok = $true
'@

# 1) 断网前基线：外网应当可达（否则这台 VM 本来就没网，结论无效）
$before = Invoke-MwGuestScript -Name 'netcut-before' -GuestDir $guestRoot -EvidenceDir $evidenceDir -RunId $RunId -Phase 'netcut' -TimeoutSeconds 120 -Body $probeBody
$beforeOk = $true
$beforeTargets = @()
if ($before.obj -and $before.obj.ok) {
    $beforeTargets = @($before.obj.data.targets)
    $beforeOk = @($beforeTargets | Where-Object { $_.reachable }).Count -ge 2
}
Add-Nc 'netcut-baseline-online' $(if ($beforeOk) { 'pass' } else { 'blocked-env' }) ('断网前可达目标数=' + @($beforeTargets | Where-Object { $_.reachable }).Count + '/3') $beforeTargets @($before.file)
if (-not $beforeOk) {
    Save-MwPhase -RunDir $evidenceDir -Phase 'netcut' -Summary ([ordered]@{ runId = $RunId; phase = 'netcut'; status = 'blocked-env'; note = '断网前外网就不可达，真实断网测试无意义' }) -Results $checks -Commands @()
    Write-MwManifest -Root $evidenceDir | Out-Null
    Write-Host '##RESULT netcut status=blocked-env'
    exit 13
}

$svc = Get-Service -Name $NatService -ErrorAction SilentlyContinue
if (-not $svc) {
    Save-MwJson -Path (Join-Path $evidenceDir 'netcut-error.json') -Object @{ ok = $false; error = ('找不到服务：' + $NatService) }
    Write-Host ('##RESULT netcut status=blocked-env（找不到服务 ' + $NatService + '）')
    exit 13
}
$svcWasRunning = $svc.Status -eq 'Running'
Write-Host ('停止服务：' + $NatService)
try { Stop-Service -Name $NatService -Force -ErrorAction Stop } catch {
    Save-MwJson -Path (Join-Path $evidenceDir 'netcut-error.json') -Object @{ ok = $false; error = ('停服务失败：' + $_.Exception.Message); need = '宿主进程需要管理员权限' }
    Write-Host ('##RESULT netcut status=blocked-env（停服务失败：' + $_.Exception.Message + '）')
    exit 13
}
Start-Sleep -Seconds 3
$natStopped = ((Get-Service -Name $NatService).Status -ne 'Running')

try {
    # 2) 断网后：三个目标都不可达、DNS 解析失败
    $cut = Invoke-MwGuestScript -Name 'netcut-cut' -GuestDir $guestRoot -EvidenceDir $evidenceDir -RunId $RunId -Phase 'netcut' -TimeoutSeconds 120 -Body $probeBody
    $cutTargets = @(); $cutDns = $null
    if ($cut.obj -and $cut.obj.ok) { $cutTargets = @($cut.obj.data.targets); $cutDns = [bool]$cut.obj.data.dnsResolves }
    $reachable = @($cutTargets | Where-Object { $_.reachable }).Count
    $cutOk = ($natStopped -and (Test-Path -LiteralPath $cut.file) -and $reachable -eq 0 -and -not $cutDns)
    Add-Nc 'netcut-external-unreachable' $(if ($cutOk) { 'pass' } else { 'evidence-incomplete' }) ('服务已停=' + $natStopped + '；可达目标=' + $reachable + '/3；DNS=' + $cutDns) ([ordered]@{ targets = $cutTargets; natStopped = $natStopped; dnsResolves = $cutDns }) @($cut.file)

    # 3) 正常模式（不带 -Offline）必须失败：缺组件不能判成已满足
    # 注意：Start-Process -ArgumentList 传数组不会自动加引号，含空格/中文的路径会被拆开，
    # 实测会让 powershell.exe 直接以 -196608（-File 不存在）退出 —— 必须先证明脚本存在，
    # 再用 MSVCRT 引号拼参数，并回收子进程 stdout/stderr，避免把"根本没跑起来"当成产品失败。
    $runBody = @"
`$bootstrap = Join-Path $(Quote-Ps $guestRoot) '冥零 验收\程序 3.1\tools\bootstrap.ps1'
`$base = Join-Path $(Quote-Ps $guestRoot) 'netcut-ws'
New-Item -ItemType Directory -Force -Path `$base | Out-Null
`$exists = Test-Path -LiteralPath `$bootstrap -PathType Leaf
`$bsha = ''; `$bbytes = 0
if (`$exists) { `$bsha = (Get-FileHash -LiteralPath `$bootstrap -Algorithm SHA256).Hash.ToLowerInvariant(); `$bbytes = (Get-Item -LiteralPath `$bootstrap).Length }
`$out = Join-Path `$base 'normal-mode.log'
`$so = Join-Path `$base 'child.stdout.txt'
`$se = Join-Path `$base 'child.stderr.txt'
`$sw = [Diagnostics.Stopwatch]::StartNew()
`$exit = `$null
`$argString = ''
if (`$exists) {
  function Arg([string]`$s) {
    if (`$s -match '[\s"]') { return '"' + (`$s -replace '(\\+)$', '$1$1') + '"' }
    return `$s
  }
  `$argString = ((@('-NoProfile','-ExecutionPolicy','Bypass','-File',`$bootstrap,'-Base',`$base,'-Workspace',`$base,'-Bots',(Join-Path `$base 'bots'),'-Component','node','-LogFile',`$out)) | ForEach-Object { Arg `$_ }) -join ' '
  `$p = Start-Process -FilePath 'powershell.exe' -ArgumentList `$argString -Wait -PassThru -NoNewWindow -RedirectStandardOutput `$so -RedirectStandardError `$se
  `$exit = `$p.ExitCode
}
`$sw.Stop()
`$tail = ''; `$etxt = ''
function Tail8([string]`$p) {
  if (-not (Test-Path -LiteralPath `$p)) { return '' }
  `$bytes = [IO.File]::ReadAllBytes(`$p)
  `$u = [Text.Encoding]::UTF8.GetString(`$bytes)
  if (`$u.Contains([char]0xFFFD)) { `$u = [Text.Encoding]::GetEncoding(936).GetString(`$bytes) }
  `$lines = @(`$u -split "`r?`n" | Where-Object { `$_ -ne '' })
  if (`$lines.Count -gt 8) { `$lines = `$lines[(`$lines.Count - 8)..(`$lines.Count - 1)] }
  return (`$lines -join ' | ')
}
`$tail = Tail8 `$out
if (-not `$tail) { `$etxt = Tail8 `$se }
`$R.data = [ordered]@{ bootstrapExists = `$exists; bootstrapSha = `$bsha; bootstrapBytes = `$bbytes; argString = `$argString; exitCode = `$exit; durationMs = [int]`$sw.ElapsedMilliseconds; tail = `$tail; stderrTail = `$etxt; nodeExe = (Test-Path -LiteralPath (Join-Path `$base 'sidecar\node\node.exe')) }
`$R.ok = `$true
"@
    $run = Invoke-MwGuestScript -Name 'netcut-normal-mode' -GuestDir $guestRoot -EvidenceDir $evidenceDir -RunId $RunId -Phase 'netcut' -TimeoutSeconds ($BootstrapTimeoutSeconds + 120) -Body $runBody
    $rd = $null
    if ($run.obj -and $run.obj.ok) { $rd = $run.obj.data }
    $preOk = ($rd -and [bool]$rd.bootstrapExists)
    if (-not $preOk) {
        Add-Nc 'netcut-normal-mode-fails' 'fail-fixture' '夹具前置不成立：来宾里找不到 bootstrap.ps1，无法判断正常模式是否因断网失败' $rd @($run.file)
    } else {
        $suspicious = ($rd.exitCode -eq -196608 -or ([string]$rd.stderrTail) -match '-File parameter does not exist')
        if ($suspicious) {
            Add-Nc 'netcut-normal-mode-fails' 'fail-fixture' ('参数编码/路径缺失（-196608），不是产品失败；exit=' + $rd.exitCode + '；stderr=' + $rd.stderrTail) $rd @($run.file)
        } else {
            $failedCleanly = ($rd.exitCode -ne $null -and $rd.exitCode -ne 0)
            $notInstalled = -not [bool]$rd.nodeExe
            Add-Nc 'netcut-normal-mode-fails' $(if ($failedCleanly -and $notInstalled) { 'pass' } else { 'fail-product' }) ('退出码=' + $rd.exitCode + '；耗时=' + $rd.durationMs + 'ms；node 未装=' + $notInstalled + '；尾部=' + $rd.tail + ' ' + $rd.stderrTail) $rd @($run.file)
        }
    }
}
finally {
    Write-Host ('恢复服务：' + $NatService)
    try { Start-Service -Name $NatService -ErrorAction Stop } catch { Write-Host ('恢复服务失败：' + $_.Exception.Message) }
    Start-Sleep -Seconds 3
}

# 4) 恢复后：外网可达（证明前面的「不可达」确实是切网造成的）
$after = Invoke-MwGuestScript -Name 'netcut-after' -GuestDir $guestRoot -EvidenceDir $evidenceDir -RunId $RunId -Phase 'netcut' -TimeoutSeconds 120 -Body $probeBody
$afterTargets = @()
if ($after.obj -and $after.obj.ok) { $afterTargets = @($after.obj.data.targets) }
$afterOk = @($afterTargets | Where-Object { $_.reachable }).Count -ge 2
Add-Nc 'netcut-restored' $(if ($afterOk) { 'pass' } else { 'evidence-incomplete' }) ('恢复后可达目标数=' + @($afterTargets | Where-Object { $_.reachable }).Count + '/3') $afterTargets @($after.file)

$counts = Get-MwCounts -Results $checks
$status = 'pass'
if ($counts['fail-product'] -gt 0) { $status = 'fail-product' }
elseif ($counts['blocked-env'] -gt 0) { $status = 'blocked-env' }
elseif ($counts['evidence-incomplete'] -gt 0) { $status = 'evidence-incomplete' }
Save-MwPhase -RunDir $evidenceDir -Phase 'netcut' -Summary ([ordered]@{ runId = $RunId; phase = 'netcut'; status = $status; counts = $counts; natService = $NatService; natWasRunning = $svcWasRunning }) -Results $checks -Commands @()
Write-MwManifest -Root $evidenceDir | Out-Null
Write-Host ('##RESULT netcut status=' + $status + ' pass=' + $counts['pass'] + ' fail=' + $counts['fail-product'] + ' evidence=' + $evidenceDir)
exit (Get-MwPhaseExitCode -Results $checks)
