#requires -Version 5.1
<#
  acceptance\v2\host\Test-InstallSmoke.ps1 — 小规模安装冒烟：只验证「装完之后主程序真的在、版本对、目录分离」。

  为什么单独一条：完整 pre 阶段要跑十几项检查、动十来分钟；产品改了安装器之后，先用这条
  2-5 分钟级的冒烟确认「装完有 exe」这一条，再去跑完整阶段，避免拿一个坏包浪费整轮 VM 时间。

  覆盖：
  - 用 /DIR /WORKSPACE 指定中文 + 空格路径，静默安装（普通用户令牌）；
  - 安装器退出码；Inno 日志里的 Administrative install mode；
  - 程序目录里 MinglingWorkbench.exe 是否存在、FileVersion 是否等于包的 AppVer；
  - 工作区与程序目录是否真的分离（工作区里不出现主程序）；
  - .new 临时文件是否已被消费掉（finish-update 真的跑到 0）。

  退出码：0 通过；10 产品失败；11 夹具失败；12 前置条件缺失；13 环境阻塞；14 证据不完整。
#>
param(
    [string]$RunId = '',
    [ValidateSet('admin', 'standard')][string]$Tier = 'standard',
    [int]$ServerPort = 8000,
    [string]$InstallerName = 'MinglingWorkbench-3.1.0-setup.exe',
    [int]$InstallTimeoutSeconds = 1500
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
$repo = Split-Path -Parent $acceptanceRoot
. (Join-Path $acceptanceRoot 'lib\Capture.ps1')
. (Join-Path $acceptanceRoot 'lib\Evidence.ps1')
. (Join-Path $acceptanceRoot 'lib\Check.ps1')
. (Join-Path $here 'VmChannel.ps1')
. (Join-Path $here 'GuestScript.ps1')

function Quote-Ps([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

if (-not $RunId) { $RunId = New-MwRunId -Prefix 'smoke' }
$evidenceDir = Join-Path $acceptanceRoot ('evidence\' + $RunId)
if (Test-Path -LiteralPath $evidenceDir) { throw ('证据目录已存在，拒绝覆盖：' + $evidenceDir) }
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$stageDir = Join-Path $acceptanceRoot 'v2\stage'
$installerHost = Join-Path $stageDir $InstallerName
$checksumsPath = Join-Path $stageDir 'checksums.json'
if (-not (Test-Path -LiteralPath $installerHost)) { throw ('stage 里没有安装包：' + $installerHost) }
$checksums = Get-Content -LiteralPath $checksumsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expect = $checksums.files | Where-Object { $_.name -eq $InstallerName } | Select-Object -First 1
if (-not $expect) { throw 'checksums.json 里没有该包' }
$installerSha = (Get-FileHash -LiteralPath $installerHost -Algorithm SHA256).Hash.ToLowerInvariant()
$installerBytes = (Get-Item -LiteralPath $installerHost).Length
if ($installerSha -ne ([string]$expect.sha256).ToLowerInvariant()) { throw ('stage 包哈希与 checksums.json 不符：' + $installerSha) }
$versionHeader = Join-Path $repo 'win32\src\version.h'
$expectVersion = ''
if (Test-Path -LiteralPath $versionHeader) {
    $vh = Get-Content -LiteralPath $versionHeader -Raw -Encoding UTF8
    $m = [regex]::Match($vh, '#define\s+APP_VERSION_STR\s+"([^"]+)"')
    if ($m.Success) { $expectVersion = $m.Groups[1].Value }
}
if (-not $expectVersion) { throw '无法从 win32\src\version.h 读到 APP_VERSION_STR' }

$guestRoot = 'C:\Users\Public\MWAcceptance'
$guestUser = ''
$guestPassword = ''
if ($Tier -eq 'standard') {
    $guestRoot = 'C:\Users\MWAcceptance\MWAcceptance'
    $guestUser = 'MWAcceptance'
    $guestPassword = Read-MwDpapiSecret 'std-user-password.dpapi'
    if (-not $guestPassword) {
        $r = [ordered]@{ ok = $false; status = 'blocked-precondition'; missing = @('标准用户口令缺失：std-user-password.dpapi（先跑 New-GuestStandardUser.ps1）'); tier = $Tier; runId = $RunId }
        Save-MwJson -Path (Join-Path $evidenceDir 'smoke.json') -Object $r
        Write-Host '[BLOCKED] 标准用户口令缺失，无法用普通用户令牌安装。'
        exit 12
    }
}

$ch = Initialize-MwVmChannel -GuestUser $guestUser -GuestPassword $guestPassword -GuestRoot $guestRoot `
    -EvidenceUrl ("http://192.168.206.1:$ServerPort") -RunId $RunId -EvidenceDir $evidenceDir -SecretsDir (Join-Path $env:LOCALAPPDATA 'MinglingWorkbench\acceptance')
if (-not $ch.ok) {
    $r = [ordered]@{ ok = $false; status = 'blocked-env'; missing = $ch.missing; tier = $Tier; runId = $RunId }
    Save-MwJson -Path (Join-Path $evidenceDir 'smoke.json') -Object $r
    Write-Host ('[BLOCKED] ' + ($ch.missing -join '；'))
    exit 13
}

$checks = New-Object System.Collections.ArrayList
function Add-Smoke([string]$Id, [string]$Status, [string]$Detail, $Data, [string[]]$Evidence = @()) {
    if (@($Evidence).Count -eq 0) { $Evidence = @($installerHost) }
    [void]$checks.Add((New-MwCheck -Id $Id -Criterion 0 -Requirement '安装冒烟（装完主程序真的在、版本对、目录分离）' -Preconditions @('通道可用；stage 包哈希与 checksums.json 一致') -Steps @('静默安装后用来宾探针读取真实文件') -Assertion '见 Id' -Evidence $Evidence -Status $Status -Detail $Detail -Data $Data))
}

$state = Get-MwVmState
Write-Host ('VM 状态：' + $state)
if ($state -notmatch 'running') {
    Write-Host '启动 VM …'
    Start-MwVm -Label 'smoke-start' | Out-Null
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if ((Get-MwVmState) -match 'running') { break }
    }
    Start-Sleep -Seconds 15
}
# 等 VMware Tools 真的能执行来宾命令（runProgramInGuest 在未就绪时直接报错）。
$toolsDeadline = (Get-Date).AddMinutes(8)
$toolsOk = $false
while ((Get-Date) -lt $toolsDeadline) {
    $probeRec = Invoke-MwVm -Action 'listProcessesInGuest' -Label 'smoke-tools-wait' -TimeoutSeconds 60 -AllowFailure
    if ($probeRec.exitCode -eq 0) { $toolsOk = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $toolsOk) {
    $r = [ordered]@{ ok = $false; status = 'blocked-env'; missing = @('VMware Tools 8 分钟内未就绪（listProcessesInGuest 一直失败）'); tier = $Tier; runId = $RunId }
    Save-MwJson -Path (Join-Path $evidenceDir 'smoke.json') -Object $r
    Write-Host '[BLOCKED] VMware Tools 未就绪。'
    exit 13
}

$app = Join-Path $guestRoot '冥零 验收\程序 3.1'
$ws = Join-Path $guestRoot '冥零 验收\工作区 3.1'
$logDir = Join-Path $guestRoot 'smoke-logs'
foreach ($d in @($app, $ws, $logDir)) {
    $rm = Remove-MwGuestDir -GuestPath $d
    if ((Test-MwGuestDir -GuestPath $d)) { throw ('来宾目录删不掉（夹具失败）：' + $d + '；vmrun exit=' + $rm.exitCode) }
}
New-MwGuestDir -GuestPath $app | Out-Null
New-MwGuestDir -GuestPath $ws | Out-Null
New-MwGuestDir -GuestPath $logDir | Out-Null

$guestInstaller = Join-Path $logDir 'setup.exe'
Write-Host '拷贝安装包到来宾 …'
Copy-MwFileToGuest -HostPath $installerHost -GuestPath $guestInstaller | Out-Null
$hashBody = @"
`$R.data = [ordered]@{ sha = (Get-FileHash -LiteralPath $(Quote-Ps $guestInstaller) -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $(Quote-Ps $guestInstaller)).Length }
`$R.ok = `$true
"@
$hashCheck = Invoke-MwGuestScript -Name 'smoke-hash' -GuestDir $logDir -EvidenceDir $evidenceDir -RunId $RunId -Phase 'smoke' -TimeoutSeconds 120 -Body $hashBody
$guestSha = $null; $guestBytes = 0
if ($hashCheck.obj -and $hashCheck.obj.ok) { $guestSha = [string]$hashCheck.obj.data.sha; $guestBytes = [int64]$hashCheck.obj.data.bytes }
Add-Smoke 'smoke-installer-hash' $(if ($guestSha -eq $installerSha -and $guestBytes -eq $installerBytes) { 'pass' } else { 'evidence-incomplete' }) ('宿主=' + $installerSha + '/' + $installerBytes + '；来宾=' + $guestSha + '/' + $guestBytes) $null

Write-Host '静默安装（普通用户 + 中文空格路径）…'
$installBody = @"
`$setup = $(Quote-Ps $guestInstaller)
`$app = $(Quote-Ps $app)
`$ws = $(Quote-Ps $ws)
`$log = Join-Path $(Quote-Ps $logDir) 'install.inno.log'
`$sw = [Diagnostics.Stopwatch]::StartNew()
`$argv = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', ('/DIR=' + `$app), ('/WORKSPACE=' + `$ws), ('/LOG=' + `$log))
`$psi = New-Object Diagnostics.ProcessStartInfo
`$psi.FileName = `$setup
`$psi.Arguments = (`$argv | ForEach-Object { if (`$_ -match '\s') { '"' + `$_ + '"' } else { `$_ } }) -join ' '
`$psi.UseShellExecute = `$false
`$p = [Diagnostics.Process]::Start(`$psi)
`$exited = `$p.WaitForExit($($InstallTimeoutSeconds * 1000))
if (-not `$exited) { try { `$p.Kill() } catch { } }
`$sw.Stop()
`$R.data = [ordered]@{
  exitCode = `$(if (`$exited) { `$p.ExitCode } else { `$null })
  timedOut = (-not `$exited)
  durationMs = [int]`$sw.ElapsedMilliseconds
  argv = `$argv
  logExists = (Test-Path -LiteralPath `$log)
  logBytes = `$(if (Test-Path -LiteralPath `$log) { (Get-Item -LiteralPath `$log).Length } else { 0 })
}
`$R.ok = `$exited
"@
$inst = Invoke-MwGuestScript -Name 'smoke-install' -GuestDir $logDir -EvidenceDir $evidenceDir -RunId $RunId -Phase 'smoke' -TimeoutSeconds ($InstallTimeoutSeconds + 180) -Body $installBody
$installData = $null
if ($inst.obj) { $installData = $inst.obj.data }
$installExit = $null
if ($installData) { $installExit = $installData.exitCode }
Add-Smoke 'smoke-installer-exit' $(if ($installExit -eq 0) { 'pass' } elseif ($installExit -eq $null) { 'evidence-incomplete' } else { 'fail-product' }) ('安装器退出码=' + $installExit + '；耗时=' + $(if ($installData) { $installData.durationMs } else { '?' }) + 'ms；超时=' + $(if ($installData) { $installData.timedOut } else { '?' })) $installData

$probeBody = @"
`$app = $(Quote-Ps $app)
`$ws = $(Quote-Ps $ws)
`$log = Join-Path $(Quote-Ps $logDir) 'install.inno.log'
`$exe = Join-Path `$app 'MinglingWorkbench.exe'
`$d = [ordered]@{
  exeExists = (Test-Path -LiteralPath `$exe)
  exeBytes = 0
  exeVersion = ''
  newFileLeft = (Test-Path -LiteralPath (Join-Path `$app 'MinglingWorkbench.new.exe'))
  exeNewExeLeft = (Test-Path -LiteralPath (Join-Path `$app 'MinglingWorkbench.exe.new.exe'))
  appFiles = @()
  wsFiles = @()
  modeLine = ''
  finishLog = ''
}
if (`$d.exeExists) { `$d.exeBytes = (Get-Item -LiteralPath `$exe).Length; `$d.exeVersion = (Get-Item -LiteralPath `$exe).VersionInfo.FileVersion }
if (Test-Path -LiteralPath `$app) { `$d.appFiles = @(Get-ChildItem -LiteralPath `$app -File | ForEach-Object { `$_.Name }) }
if (Test-Path -LiteralPath `$ws) { `$d.wsFiles = @(Get-ChildItem -LiteralPath `$ws -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { `$_.FullName.Substring(`$ws.Length) }) }
if (Test-Path -LiteralPath `$log) {
  `$d.modeLine = (Select-String -LiteralPath `$log -Pattern 'Administrative install mode:' -SimpleMatch | Select-Object -First 1).Line
  `$d.finishLog = (Select-String -LiteralPath `$log -Pattern 'finish-update.ps1' -SimpleMatch | Select-Object -Last 2 | ForEach-Object { `$_.Line }) -join ' | '
}
`$R.data = `$d
`$R.ok = `$true
"@
$probe = Invoke-MwGuestScript -Name 'smoke-probe' -GuestDir $logDir -EvidenceDir $evidenceDir -RunId $RunId -Phase 'smoke' -TimeoutSeconds 180 -Body $probeBody
$pd = $null
if ($probe.obj) { $pd = $probe.obj.data }
$exeOk = ($pd -and [bool]$pd.exeExists)
Add-Smoke 'smoke-exe-present' $(if ($exeOk) { 'pass' } else { 'fail-product' }) ('exeExists=' + $(if ($pd) { $pd.exeExists } else { '?' }) + '；bytes=' + $(if ($pd) { $pd.exeBytes } else { '?' })) $pd @($probe.file)
$verOk = ($pd -and $pd.exeVersion -and $expectVersion -and ([string]$pd.exeVersion).StartsWith($expectVersion))
Add-Smoke 'smoke-exe-version' $(if ($verOk) { 'pass' } else { 'fail-product' }) ('期望=' + $expectVersion + '；实际=' + $(if ($pd) { $pd.exeVersion } else { '?' })) $null @($probe.file)
$modeOk = ($pd -and ([string]$pd.modeLine -match 'Administrative install mode:\s*No'))
Add-Smoke 'smoke-normal-user-mode' $(if ($modeOk) { 'pass' } else { 'fail-product' }) ('Inno 模式行=' + $(if ($pd) { $pd.modeLine } else { '?' })) $null @($probe.file)
$sepOk = ($pd -and ([bool]$pd.exeExists) -and -not (@($pd.wsFiles) | Where-Object { $_ -match 'MinglingWorkbench\.exe$' }))
Add-Smoke 'smoke-program-workspace-separate' $(if ($sepOk) { 'pass' } else { 'fail-product' }) ('工作区文件数=' + @($pd.wsFiles).Count) $null @($probe.file)
$cleanOk = ($pd -and -not [bool]$pd.newFileLeft -and -not [bool]$pd.exeNewExeLeft)
Add-Smoke 'smoke-new-file-consumed' $(if ($cleanOk) { 'pass' } else { 'fail-product' }) ('new=' + $(if ($pd) { $pd.newFileLeft } else { '?' }) + '；exe.new=' + $(if ($pd) { $pd.exeNewExeLeft } else { '?' })) $null @($probe.file)

$counts = Get-MwCounts -Results $checks
$status = 'pass'
if ($counts['fail-product'] -gt 0) { $status = 'fail-product' }
elseif ($counts['evidence-incomplete'] -gt 0) { $status = 'evidence-incomplete' }
$summary = [ordered]@{
    runId = $RunId; phase = 'smoke'; tier = $Tier; status = $status
    counts = $counts; installer = [ordered]@{ name = $InstallerName; bytes = $installerBytes; sha256 = $installerSha }
    app = $app; ws = $ws
    at = (Get-Date).ToUniversalTime().ToString('o')
}
Save-MwPhase -RunDir $evidenceDir -Phase 'smoke' -Summary $summary -Results $checks -Commands @()
Write-MwManifest -Root $evidenceDir | Out-Null
Write-Host ('##RESULT smoke status=' + $status + ' pass=' + $counts['pass'] + ' fail=' + $counts['fail-product'] + ' evidence=' + $evidenceDir)
exit (Get-MwPhaseExitCode -Results $checks)
