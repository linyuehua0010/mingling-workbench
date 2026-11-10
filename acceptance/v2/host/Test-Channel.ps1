#requires -Version 5.1
<#
  acceptance\v2\host\Test-Channel.ps1 — 来宾通道小规模验收（长任务之前的闸门）

  覆盖（对应用户第 二 步的 6 条）：
    T1 当前用户 + 令牌权限（是否管理员、是否提升、SID）
    T2 普通命令 + 真实退出码（exit 7 是否原样回到宿主机）
    T3 中文 + 空格路径的读写（创建、写入、回读、SHA256）
    T4 超时与进程清理（来宾侧长任务被终止后无残留；宿主机侧 vmrun 超时后被结束）
    T5 上传/下载文件并比对哈希（宿主机→来宾→宿主机，双向 SHA256）
    T6 证据上传通道（来宾 POST 到宿主机，宿主机核 HTTP 状态 + 落盘字节 + SHA256）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\host\Test-Channel.ps1 `
      [-VmExe E:\VMware\vmrun.exe] [-VmxPath 'E:\Windows 11 x64\Windows 11 x64.vmx'] `
      [-GuestUser 冥零] [-GuestRoot 'C:\Users\Public\MWAcceptance'] [-EvidenceUrl http://192.168.206.1:8000] `
      [-RunId <id>]

  退出码：0 全部通过；1 有子项失败；2 通道不可用（缺凭据/缺 vmrun）；3 夹具自身错误。
#>
param(
    [string]$VmExe = 'E:\VMware\vmrun.exe',
    [string]$VmxPath = 'E:\Windows 11 x64\Windows 11 x64.vmx',
    [string]$GuestUser = '',
    [string]$GuestRoot = 'C:\Users\Public\MWAcceptance',
    [string]$EvidenceUrl = 'http://192.168.206.1:8000',
    [string]$RunId = '',
    [switch]$SkipBoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'VmChannel.ps1')
. (Join-Path $here 'GuestScript.ps1')
. (Join-Path $here '..\..\lib\Check.ps1')

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $RunId) { $RunId = 'channel-' + $stamp }
$evidenceRoot = Join-Path $here ('..\..\evidence\' + $RunId)
$evidenceDir = Join-Path $evidenceRoot 'channel'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$init = Initialize-MwVmChannel -VmExe $VmExe -VmxPath $VmxPath -GuestUser $GuestUser -GuestRoot $GuestRoot `
    -EvidenceUrl $EvidenceUrl -RunId $RunId -EvidenceDir $evidenceDir
$results = New-Object System.Collections.ArrayList
$stage = New-Object System.Collections.ArrayList
function Add-Result($obj) { [void]$results.Add([pscustomobject]$obj); [void]$stage.Add([pscustomobject]$obj) }

if (-not $init.ok) {
    # 通道缺失：如实记 blocked-env，不假装通过，也不继续往下跑
    foreach ($m in $init.missing) { Write-Host ('[BLOCKED] ' + $m) }
    $payload = [ordered]@{
        runId = $RunId; phase = 'channel'; ok = $false; status = 'blocked-env'
        missing = $init.missing; checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
        checks = @(); channel = $init
    }
    Save-MwJson -Path (Join-Path $evidenceDir 'channel.json') -Object $payload
    Write-MwManifest -Root $evidenceDir | Out-Null
    Write-Host ('##RESULT channel blocked missing=' + $init.missing.Count)
    exit 2
}

$guestRunDir = $init.guestRoot + '\run\' + $RunId
$guestChanDir = $guestRunDir + '\channel'

function Invoke-ChannelGuest {
    <# 统一走来宾脚本模板：模板负责 $R、落盘、POST 回执、异常兜底、exit 0；代码本身也落盘成证据。 #>
    param([string]$Name, [string]$Body, [int]$TimeoutSeconds = 300)
    try {
        return (Invoke-MwGuestScript -Name $Name -Body $Body -GuestDir $guestChanDir -EvidenceDir $evidenceDir `
            -EvidenceUrl $EvidenceUrl -RunId $RunId -Phase 'channel' -TimeoutSeconds $TimeoutSeconds)
    } catch {
        $errFile = Join-Path $evidenceDir ($Name + '.fixture-error.txt')
        [IO.File]::WriteAllText($errFile, $_.Exception.ToString(), (New-Object Text.UTF8Encoding($true)))
        return [pscustomobject]@{ name = $Name; record = $null; fetched = $false; file = $errFile; obj = $null
            codePath = ''; exitCode = $null; stdoutText = ''; stderrText = ''; error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- 0. 启动来宾
$vmState = $null
if (-not $SkipBoot) {
    $vmState = Get-MwVmState
    if ($vmState.text -notmatch [regex]::Escape($VmxPath)) {
        Write-Host '[vm] 启动虚拟机 ...'
        try { Start-MwVm -TimeoutSeconds 600 | Out-Null } catch { Write-Host ('[vm] 启动失败：' + $_.Exception.Message) }
    } else {
        Write-Host '[vm] 虚拟机已在运行'
    }
    # 等 VMware Tools 可用：listProcessesInGuest 能返回即视为就绪
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        $probe = Invoke-MwVm -Action 'listProcessesInGuest' -Label ('vm-wait-tools-' + $i) -TimeoutSeconds 120 -AllowFailure
        if ($probe.exitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    Add-Result ([ordered]@{ id = 'T0.tools-ready'; ok = $ready; detail = $(if ($ready) { 'VMware Tools 就绪，来宾接口可用' } else { 'VMware Tools 60 次探测仍不可用' }); evidence = $evidenceDir })
    if (-not $ready) {
        $payload = [ordered]@{ runId = $RunId; phase = 'channel'; ok = $false; status = 'blocked-env'; checks = $results; checkedUtc = (Get-Date).ToUniversalTime().ToString('o') }
        Save-MwJson -Path (Join-Path $evidenceDir 'channel.json') -Object $payload
        Write-MwManifest -Root $evidenceDir | Out-Null
        Write-Host '##RESULT channel blocked tools-unavailable'
        exit 2
    }
}

try { New-MwGuestDir -GuestPath ($guestRunDir + '\channel') | Out-Null } catch { }

# ---------------------------------------------------------------- T1 用户与令牌
$t1 = Invoke-ChannelGuest -Name 't1-identity' -Body @"
`$id = [Security.Principal.WindowsIdentity]::GetCurrent()
`$p = New-Object Security.Principal.WindowsPrincipal -ArgumentList (`$id)
`$admin = `$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
`$who = (whoami) -join ' '
`$groups = (whoami /groups) -join "``n"
`$elev = if (`$groups -match 'S-1-16-8192') { 'high-or-system' } elseif (`$groups -match 'S-1-16-12288') { 'system' } elseif (`$groups -match 'S-1-16-16384') { 'protected' } else { 'medium-or-low' }
`$R.data.identity = `$id.Name
`$R.data.whoami = `$who
`$R.data.isAdminRole = `$admin
`$R.data.integrity = `$elev
`$R.data.userSid = `$id.User.Value
`$R.data.groupsShort = (whoami /groups | Select-String -Pattern 'S-1-5-32-544|S-1-16-') -join '; '
`$R.ok = `$true
"@
$t1ok = ($t1.obj -and $t1.obj.ok -and $t1.obj.data.identity)
Add-Result ([ordered]@{
    id = 'T1.identity'; ok = [bool]$t1ok
    detail = if ($t1ok) { '来宾身份：' + $t1.obj.data.identity + '，管理员角色=' + $t1.obj.data.isAdminRole + '，完整性=' + $t1.obj.data.integrity } else { '未取得来宾身份（取回=' + $t1.fetched + '）' }
    data = $t1.obj.data; evidence = $t1.file
})

# ---------------------------------------------------------------- T2 退出码
$exitCodeFile = $guestChanDir + '\t2-exit.txt'
$code = "exit 7"
$rec2 = Invoke-MwGuestPowerShellText -Code $code -TimeoutSeconds 120 -Label 'guest-t2-exit7'
$vmrunExit = $rec2.exitCode
# vmrun 的退出码语义单独核对：来宾脚本自己把退出码写进文件，作为对照
$code2 = "`$c = 7; `$dir = '$guestChanDir'; New-Item -ItemType Directory -Force -Path `$dir | Out-Null; Set-Content -LiteralPath (Join-Path `$dir 't2-exit.txt') -Value `$c -Encoding ASCII; exit `$c"
$rec2b = Invoke-MwGuestPowerShellText -Code $code2 -TimeoutSeconds 120 -Label 'guest-t2-exit7-recorded'
$hostFile2 = Join-Path $evidenceDir 't2-exit.txt'
$gotGuest = ''
try { Copy-MwFileFromGuest -GuestPath $exitCodeFile -HostPath $hostFile2 | Out-Null; $gotGuest = (Get-Content -LiteralPath $hostFile2 -Raw).Trim() } catch { }
Add-Result ([ordered]@{
    id = 'T2.exit-code'; ok = ($vmrunExit -eq 7 -and $gotGuest -eq '7')
    detail = 'vmrun 返回 ' + $vmrunExit + '，来宾自记 ' + $gotGuest + '（期望 7/7）'
    data = [ordered]@{ vmrunExit = $vmrunExit; guestRecorded = $gotGuest; record2Status = $rec2b.status }
    evidence = $rec2.stderrPath
})

# ---------------------------------------------------------------- T3 中文 + 空格路径
$t3 = Invoke-ChannelGuest -Name 't3-paths' -Body @"
`$base = '$guestChanDir' + '\中文 目录\第二层 空格'
New-Item -ItemType Directory -Force -Path `$base | Out-Null
`$f1 = Join-Path `$base '结果 文件.txt'
`$text = '中文内容 ✓ 行二' + "``r``n" + 'tail\'
[IO.File]::WriteAllText(`$f1, `$text, (New-Object Text.UTF8Encoding(`$false)))
`$back = [IO.File]::ReadAllText(`$f1, [Text.Encoding]::UTF8)
`$R.data.path = `$f1
`$R.data.contentMatch = (`$back -ceq `$text)
`$R.data.sha256 = (Get-FileHash -LiteralPath `$f1 -Algorithm SHA256).Hash.ToLower()
`$R.data.exists = (Test-Path -LiteralPath `$f1)
`$R.data.cwd = (Get-Location).Path
`$R.ok = `$R.data.exists -and `$R.data.contentMatch
"@
$t3ok = ($t3.obj -and $t3.obj.ok -and $t3.obj.data.contentMatch)
Add-Result ([ordered]@{
    id = 'T3.chinese-path'; ok = [bool]$t3ok
    detail = if ($t3ok) { '中文/空格路径读写一致：' + $t3.obj.data.path } else { '中文/空格路径读写失败（取回=' + $t3.fetched + '）' }
    data = $t3.obj.data; evidence = $t3.file
})

# ---------------------------------------------------------------- T4 超时与进程清理
# 4a 来宾侧长任务：-noWait 启动，确认存活后由我们主动结束整棵进程树，再确认无残留
$pidFile = $guestChanDir + '\t4-child.pid'
$code4a = @"
`$dir = '$guestChanDir'; New-Item -ItemType Directory -Force -Path `$dir | Out-Null
`$p = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 600' -PassThru
Set-Content -LiteralPath (Join-Path `$dir 't4-child.pid') -Value `$p.Id -Encoding ASCII
"@
$sw = [Diagnostics.Stopwatch]::StartNew()
$rec4a = Invoke-MwGuestPowerShellText -Code $code4a -TimeoutSeconds 60 -Label 'guest-t4-spawn'
Start-Sleep -Seconds 3
$guestPid = ''
$hostPidFile = Join-Path $evidenceDir 't4-child.pid'
try { Copy-MwFileFromGuest -GuestPath $pidFile -HostPath $hostPidFile | Out-Null; $guestPid = (Get-Content -LiteralPath $hostPidFile -Raw).Trim() } catch { }
$code4b = @"
`$pid2 = [int]('$guestPid')
`$alive = [bool](Get-Process -Id `$pid2 -ErrorAction SilentlyContinue)
`$killed = `$false
if (`$alive) { & taskkill.exe /PID `$pid2 /T /F | Out-Null; `$killed = (`$LASTEXITCODE -eq 0) }
Start-Sleep -Seconds 2
`$still = [bool](Get-Process -Id `$pid2 -ErrorAction SilentlyContinue)
`$dir = '$guestChanDir'
`$R.data.aliveBefore = `$alive
`$R.data.killedTree = `$killed
`$R.data.aliveAfter = `$still
`$R.ok = (`$alive -and -not `$still)
"@
$t4b = Invoke-MwGuestScript -Name 't4-kill' -Body $code4b -GuestDir $guestChanDir -EvidenceDir $evidenceDir `
    -EvidenceUrl $EvidenceUrl -RunId $RunId -Phase 'channel' -TimeoutSeconds 120
$hostFile4 = $t4b.file
$obj4 = $t4b.obj
# 4b 宿主机侧超时：给 vmrun 一个很小的超时，确认记录为 timeout 且没有遗留 vmrun 进程
$rec4c = Invoke-MwVm -Action 'runProgramInGuest' -Extra @(
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
) -Label 'guest-t4-host-timeout' -TimeoutSeconds 5 -AllowFailure
$vmrunLeft = @(Get-Process -Name vmrun -ErrorAction SilentlyContinue).Count
$t4ok = ($obj4 -and $obj4.ok -and $rec4c.status -eq 'timeout' -and $vmrunLeft -eq 0)
Add-Result ([ordered]@{
    id = 'T4.timeout-cleanup'; ok = [bool]$t4ok
    detail = '来宾子进程 ' + $guestPid + ' 启动/结束=' + $(if ($obj4) { [string]$obj4.data.aliveBefore + '/' + (-not $obj4.data.aliveAfter) } else { 'n/a' }) +
             '；宿主机超时状态=' + $rec4c.status + '；残留 vmrun=' + $vmrunLeft
    data = [ordered]@{ guest = $obj4.data; hostTimeoutStatus = $rec4c.status; hostTimedOut = $rec4c.timedOut; vmrunLeft = $vmrunLeft }
    evidence = $hostFile4
})

# ---------------------------------------------------------------- T5 双向文件传输 + 哈希
$srcLocal = Join-Path $evidenceDir 't5-upload-src.bin'
$srcBytes = New-Object byte[] (256 * 1024)
(New-Object Random 42).NextBytes($srcBytes)
[IO.File]::WriteAllBytes($srcLocal, $srcBytes)
$srcSha = Get-MwBytesSha256 -Bytes $srcBytes
$guestT5 = $guestChanDir + '\t5-up.bin'
Copy-MwFileToGuest -HostPath $srcLocal -GuestPath $guestT5 | Out-Null
$code5 = @"
`$f = '$guestT5'
`$R.data.uploadedSha256 = if (Test-Path -LiteralPath `$f) { (Get-FileHash -LiteralPath `$f -Algorithm SHA256).Hash.ToLower() } else { '' }
`$R.data.uploadedBytes = if (Test-Path -LiteralPath `$f) { (Get-Item -LiteralPath `$f).Length } else { 0 }
`$down = Join-Path '$guestChanDir' 't5-down.bin'
[IO.File]::WriteAllBytes(`$down, [byte[]](1..255))
`$R.data.downloadSha256 = (Get-FileHash -LiteralPath `$down -Algorithm SHA256).Hash.ToLower()
`$R.data.downloadBytes = (Get-Item -LiteralPath `$down).Length
`$R.ok = `$true
"@
$t5 = Invoke-ChannelGuest -Name 't5-transfer' -Body $code5 -TimeoutSeconds 300
$downLocal = Join-Path $evidenceDir 't5-down.bin'
$downSha = ''
try {
    Copy-MwFileFromGuest -GuestPath ($guestChanDir + '\t5-down.bin') -HostPath $downLocal | Out-Null
    $downSha = (Get-FileHash -LiteralPath $downLocal -Algorithm SHA256).Hash.ToLower()
} catch { }
$upOk = ($t5.obj -and $t5.obj.data.uploadedSha256 -eq $srcSha)
$downOk = ($t5.obj -and $downSha -ne '' -and $downSha -eq $t5.obj.data.downloadSha256)
Add-Result ([ordered]@{
    id = 'T5.transfer-hash'; ok = [bool]($upOk -and $downOk)
    detail = '上行哈希一致=' + $upOk + '，下行哈希一致=' + $downOk + '（本地 ' + $srcSha.Substring(0, 12) + '…）'
    data = [ordered]@{ hostSrcSha256 = $srcSha; guestUploadedSha256 = $t5.obj.data.uploadedSha256; guestDownSha256 = $t5.obj.data.downloadSha256; hostDownSha256 = $downSha }
    evidence = $downLocal
})

# ---------------------------------------------------------------- T6 证据上传通道
$t6 = Invoke-ChannelGuest -Name 't6-evidence-post' -Body @"
`$dir = '$guestChanDir'
`$f = Join-Path `$dir 't6-payload.json'
`$payload = @{ hello = '中文证据'; runId = '$RunId'; at = (Get-Date).ToUniversalTime().ToString('o'); filler = ('x' * 1024) }
(`$payload | ConvertTo-Json) | Set-Content -LiteralPath `$f -Encoding UTF8
`$bytes = [IO.File]::ReadAllBytes(`$f)
`$R.data.payloadSha256 = (Get-FileHash -LiteralPath `$f -Algorithm SHA256).Hash.ToLower()
`$R.data.payloadBytes = `$bytes.Length
try {
  `$resp = Invoke-WebRequest -Uri '$EvidenceUrl/upload/$RunId/channel/t6-payload.json' -Method Post -Body `$bytes -ContentType 'application/json' -TimeoutSec 30 -UseBasicParsing
  `$R.data.httpStatus = [int]`$resp.StatusCode
  `$R.data.ackBody = `$resp.Content
  `$R.ok = (`$resp.StatusCode -eq 200)
} catch {
  `$R.data.httpStatus = 0
  `$R.data.ackBody = `$_.Exception.Message
  `$R.ok = `$false
}
"@
$posted = Join-Path $here ('..\..\evidence\' + $RunId + '\channel\t6-payload.json')
$ackOk = $false; $ackSha = ''; $ackBytes = 0
if (Test-Path -LiteralPath $posted) {
    $b = [IO.File]::ReadAllBytes($posted)
    $ackBytes = $b.Length
    $ackSha = Get-MwBytesSha256 -Bytes $b
    $ackOk = $t6.obj -and $t6.obj.data.payloadSha256 -eq $ackSha
}
Add-Result ([ordered]@{
    id = 'T6.evidence-upload'; ok = [bool]($t6.obj -and $t6.obj.data.httpStatus -eq 200 -and $ackOk)
    detail = '来宾 POST HTTP=' + $(if ($t6.obj) { $t6.obj.data.httpStatus } else { 'n/a' }) + '，落盘字节=' + $ackBytes + '，SHA256 一致=' + $ackOk
    data = [ordered]@{ guest = $t6.obj.data; hostBytes = $ackBytes; hostSha256 = $ackSha }
    evidence = $posted
})

# ---------------------------------------------------------------- 汇总
$checks = @($results)
$passed = @($checks | Where-Object { $_.ok }).Count
$failed = $checks.Count - $passed
$payload = [ordered]@{
    runId = $RunId
    phase = 'channel'
    ok = ($failed -eq 0)
    status = $(if ($failed -eq 0) { 'pass' } else { 'fail-fixture' })
    checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
    guest = [ordered]@{ root = $guestRunDir; user = $init.guestUser }
    vm = [ordered]@{ exe = $init.vmExe; vmx = $init.vmxPath; evidenceUrl = $init.evidenceUrl }
    counts = [ordered]@{ total = $checks.Count; passed = $passed; failed = $failed }
    checks = $checks
}
$jsonPath = Join-Path $evidenceDir 'channel.json'
Save-MwJson -Path $jsonPath -Object $payload
Write-MwManifest -Root $evidenceDir | Out-Null
Write-Host ''
Write-Host ('##RESULT channel total=' + $checks.Count + ' passed=' + $passed + ' failed=' + $failed)
Write-Host ('report: ' + $jsonPath)
if ($failed -eq 0) { exit 0 } else { exit 1 }
