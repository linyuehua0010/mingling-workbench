#requires -Version 5.1
<#
  acceptance\v2\host\VmChannel.ps1 — VMware 来宾执行通道（宿主机侧）

  为什么需要这一层：旧通道用 vm-type.py 往 VMware 控制台窗口里粘贴/敲键，焦点一丢就错行，
  且拿不到退出码。这里改用 vmrun 的来宾接口（runProgramInGuest / copyFile*Guest），
  控制台输入只作为无法用接口时的兜底（本文件不实现，见 report 的兜底说明）。

  每条 vmrun 调用都走 acceptance\lib\Capture.ps1 的 Invoke-Capture：
  开始/结束 UTC、耗时、脱敏命令行、退出码、超时、stdout/stderr 全部落盘并带 SHA256。

  参数一律显式：-VmExe -VmxPath -GuestUser -GuestRoot -EvidenceUrl -RunId -EvidenceDir。
  口令从 DPAPI 文件读（acceptance\Store-VmSecrets.ps1 生成），也可直接传 -VmxPassword/-GuestPassword。
#>

. (Join-Path $PSScriptRoot '..\..\lib\Capture.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\Evidence.ps1')

$script:MwVm = @{
    Exe             = 'E:\VMware\vmrun.exe'
    Path            = 'E:\Windows 11 x64\Windows 11 x64.vmx'
    VmxPassword     = ''
    GuestUser       = ''
    GuestPassword   = ''
    GuestRoot       = 'C:\Users\Public\MWAcceptance'
    RunId           = ''
    EvidenceDir     = ''
    EvidenceUrl     = ''
    SecretsDir      = (Join-Path $env:LOCALAPPDATA 'MinglingWorkbench\acceptance')
    DefaultTimeout  = 600
}

# AppContainer may redirect LOCALAPPDATA. Prefer the existing CurrentUser store;
# never copy decrypted secrets or persist a plaintext fallback.
$profileSecrets = Join-Path $env:USERPROFILE 'AppData\Local\MinglingWorkbench\acceptance'
if (-not (Test-Path -LiteralPath $script:MwVm.SecretsDir) -and (Test-Path -LiteralPath $profileSecrets)) {
    $script:MwVm.SecretsDir = $profileSecrets
}

function Save-MwBlockedRun {
    param([string]$RunDir, [string]$RunId, [string[]]$Phases, [string]$Message, $CommandRecord)
    $summaries = @()
    foreach ($phase in $Phases) {
        $phaseDir = Join-Path $RunDir ('phases\' + $phase)
        $check = New-MwCheck -Id ('c0-' + $phase + '-host-channel') -Criterion 0 `
            -Requirement '宿主控制与证据通道可用，才能执行来宾端到端验收' `
            -Preconditions @('指定测试 VM；CurrentUser DPAPI；vmrun 与本地证据服务可访问') `
            -Steps @($CommandRecord.commandLine, '前置失败即停止；未部署或启动来宾阶段') `
            -Assertion '宿主通道命令 exit=0；本条仅为环境门禁，不是产品通过' `
            -Expected 0 -Actual $CommandRecord.exitCode -Status 'blocked-env' -Detail $Message `
            -Evidence @($CommandRecord.stdoutPath, $CommandRecord.stderrPath)
        $counts = Get-MwCounts -Results @($check)
        $summary = [ordered]@{ runId=$RunId; phase=$phase; guestStarted=$false; guestStatus='blocked-env';
            guestExitCode=$null; status='blocked-env'; exitCode=13; counts=$counts;
            durationSeconds=0; checks=1; detail=$Message }
        Save-MwPhase -RunDir $RunDir -Phase $phase -Summary $summary -Results @($check) -Commands @($CommandRecord) | Out-Null
        Save-MwJson -Path (Join-Path $phaseDir ('checks\' + $check.id + '.json')) -Object $check
        Write-MwManifest -Root $phaseDir | Out-Null
        $summaries += $summary
    }
    Save-MwJson -Path (Join-Path $RunDir 'run.json') -Object ([ordered]@{
        runId=$RunId; ok=$false; status='blocked-env'; exitCode=13; guestStarted=$false;
        phases=$summaries; detail=$Message; at=(Get-Date).ToUniversalTime().ToString('o') })
    Write-MwManifest -Root $RunDir | Out-Null
}

function Read-MwDpapiSecret {
    param([Parameter(Mandatory)][string]$Name)
    $p = Join-Path $script:MwVm.SecretsDir $Name
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $enc = (Get-Content -LiteralPath $p -Raw).Trim()
    if (-not $enc) { return '' }
    $sec = ConvertTo-SecureString $enc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Initialize-MwVmChannel {
    <# 解析通道参数：显式参数优先，其次 DPAPI 文件；缺失即记录缺什么，不猜口令。 #>
    param(
        [string]$VmExe,
        [string]$VmxPath,
        [string]$GuestUser,
        [AllowEmptyString()][string]$VmxPassword,
        [AllowEmptyString()][string]$GuestPassword,
        [string]$GuestRoot,
        [string]$EvidenceUrl,
        [string]$RunId,
        [string]$EvidenceDir,
        [string]$SecretsDir
    )

    if ($VmExe) { $script:MwVm.Exe = $VmExe }
    if ($VmxPath) { $script:MwVm.Path = $VmxPath }
    if ($GuestRoot) { $script:MwVm.GuestRoot = $GuestRoot }
    if ($EvidenceUrl) { $script:MwVm.EvidenceUrl = $EvidenceUrl }
    if ($RunId) { $script:MwVm.RunId = $RunId }
    if ($EvidenceDir) { $script:MwVm.EvidenceDir = $EvidenceDir }
    if ($SecretsDir) { $script:MwVm.SecretsDir = $SecretsDir }

    if ($PSBoundParameters.ContainsKey('VmxPassword')) { $script:MwVm.VmxPassword = $VmxPassword }
    elseif (-not $script:MwVm.VmxPassword) { $script:MwVm.VmxPassword = Read-MwDpapiSecret 'vm-password.dpapi' }

    if ($PSBoundParameters.ContainsKey('GuestPassword')) { $script:MwVm.GuestPassword = $GuestPassword }
    elseif (-not $script:MwVm.GuestPassword) { $script:MwVm.GuestPassword = Read-MwDpapiSecret 'guest-password.dpapi' }

    if ($GuestUser) { $script:MwVm.GuestUser = $GuestUser }
    elseif (-not $script:MwVm.GuestUser) {
        $u = Join-Path $script:MwVm.SecretsDir 'guest-user.txt'
        if (Test-Path -LiteralPath $u) { $script:MwVm.GuestUser = (Get-Content -LiteralPath $u -Raw -Encoding UTF8).Trim() }
    }
    if (-not $script:MwVm.GuestUser) { $script:MwVm.GuestUser = [string]([char]0x51A5 + [char]0x96F6) }

    $missing = @()
    if (-not (Test-Path -LiteralPath $script:MwVm.Exe)) { $missing += 'vmrun.exe 不存在：' + $script:MwVm.Exe }
    if (-not (Test-Path -LiteralPath $script:MwVm.Path)) { $missing += 'vmx 不存在：' + $script:MwVm.Path }
    if (-not $script:MwVm.VmxPassword) { $missing += 'VMware 加密口令缺失（%LOCALAPPDATA%\MinglingWorkbench\acceptance\vm-password.dpapi）' }
    if (-not $script:MwVm.GuestPassword) { $missing += '来宾口令缺失（%LOCALAPPDATA%\MinglingWorkbench\acceptance\guest-password.dpapi）' }

    return [pscustomobject]@{
        ok            = ($missing.Count -eq 0)
        missing       = $missing
        vmExe         = $script:MwVm.Exe
        vmxPath       = $script:MwVm.Path
        guestUser     = $script:MwVm.GuestUser
        guestRoot     = $script:MwVm.GuestRoot
        runId         = $script:MwVm.RunId
        evidenceDir   = $script:MwVm.EvidenceDir
        evidenceUrl   = $script:MwVm.EvidenceUrl
        secretsDir    = $script:MwVm.SecretsDir
    }
}

function Get-MwVmAuthArguments {
    $a = @('-T', 'ws')
    if ($script:MwVm.VmxPassword) { $a += @('-vp', $script:MwVm.VmxPassword) }
    $a += @('-gu', $script:MwVm.GuestUser)
    if ($script:MwVm.GuestPassword) { $a += @('-gp', $script:MwVm.GuestPassword) }
    return $a
}

function Invoke-MwVm {
    <# 执行一条 vmrun 命令并留证据。返回 Capture 记录（含 exitCode / stdout / stderr）。 #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [string[]]$Extra = @(),
        [int]$TimeoutSeconds = 0,
        [string]$Label = '',
        [switch]$AllowFailure
    )

    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:MwVm.DefaultTimeout }
    $hostOnly = @('list', 'listHostTypes')
    if ($hostOnly -contains $Action) { $argsAll = @(Get-MwVmAuthArguments) + @($Action) + @($Extra) }
    else { $argsAll = @(Get-MwVmAuthArguments) + @($Action, $script:MwVm.Path) + @($Extra) }
    $label = if ($Label) { $Label } else { 'vmrun-' + ($Action -replace '[^A-Za-z]', '-') }
    $ev = $script:MwVm.EvidenceDir
    $rid = $script:MwVm.RunId
    $r = Invoke-Capture -Label $label -FilePath $script:MwVm.Exe -Arguments $argsAll -Kind 'exe' `
        -EvidenceDir $ev -RunId $rid -TimeoutSeconds $TimeoutSeconds
    $rec = $r.Record
    if (-not $AllowFailure -and ($rec.status -ne 'completed' -or $rec.exitCode -ne 0)) {
        $msg = 'vmrun ' + $Action + ' 失败：status=' + $rec.status + ' exit=' + $rec.exitCode
        if ($rec.stderrText) { $msg += ' stderr=' + ($rec.stderrText.Trim() -split "`r?`n" | Select-Object -First 3 | Out-String).Trim() }
        throw $msg
    }
    return $rec
}

function Get-MwVmState {
    <# list 不需要打开 vmx，因此即使加密口令错也能用来判断是否有 VM 在跑。 #>
    $rec = Invoke-MwVm -Action 'list' -Label 'vmrun-list' -TimeoutSeconds 60 -AllowFailure
    return [pscustomobject]@{ exitCode = $rec.exitCode; text = ($rec.stdoutText + $rec.stderrText).Trim() }
}

function Start-MwVm {
    param([string]$GuiMode = 'nogui', [int]$TimeoutSeconds = 300)
    $rec = Invoke-MwVm -Action 'start' -Extra @($GuiMode) -Label 'vm-start' -TimeoutSeconds $TimeoutSeconds
    return $rec
}

function Stop-MwVm {
    param([switch]$Hard, [int]$TimeoutSeconds = 300)
    $extra = if ($Hard) { @('hard') } else { @('soft') }
    return (Invoke-MwVm -Action 'stop' -Extra $extra -Label 'vm-stop' -TimeoutSeconds $TimeoutSeconds)
}

function Get-MwVmSnapshots {
    return (Invoke-MwVm -Action 'listSnapshots' -Label 'vm-list-snapshots' -TimeoutSeconds 120 -AllowFailure)
}

function Restore-MwVmSnapshot {
    <# 回滚快照前必须先回收证据：调用方负责先把 evidence 上传/取回并校验 SHA256。 #>
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 600)
    return (Invoke-MwVm -Action 'revertToSnapshot' -Extra @($Name) -Label 'vm-revert-snapshot' -TimeoutSeconds $TimeoutSeconds)
}

function Copy-MwFileToGuest {
    param([Parameter(Mandatory)][string]$HostPath, [Parameter(Mandatory)][string]$GuestPath, [int]$TimeoutSeconds = 600)
    return (Invoke-MwVm -Action 'copyFileFromHostToGuest' -Extra @($HostPath, $GuestPath) -Label 'vm-copy-to-guest' -TimeoutSeconds $TimeoutSeconds)
}

function Copy-MwFileFromGuest {
    param([Parameter(Mandatory)][string]$GuestPath, [Parameter(Mandatory)][string]$HostPath, [int]$TimeoutSeconds = 600)
    return (Invoke-MwVm -Action 'copyFileFromGuestToHost' -Extra @($GuestPath, $HostPath) -Label 'vm-copy-from-guest' -TimeoutSeconds $TimeoutSeconds)
}

function Test-MwGuestDir {
    <# 来宾目录是否还存在（vmrun directoryExistsInGuest 的退出码就是答案）。 #>
    param([Parameter(Mandatory)][string]$GuestPath)
    $r = Invoke-MwVm -Action 'directoryExistsInGuest' -Extra @($GuestPath) -Label 'vm-dir-exists' -AllowFailure
    return ($r.exitCode -eq 0)
}

function New-MwGuestDir {
    param([Parameter(Mandatory)][string]$GuestPath)
    return (Invoke-MwVm -Action 'createDirectoryInGuest' -Extra @($GuestPath) -Label 'vm-mkdir-guest' -AllowFailure)
}

function Remove-MwGuestDir {
    param([Parameter(Mandatory)][string]$GuestPath, [int]$TimeoutSeconds = 300)
    return (Invoke-MwVm -Action 'deleteDirectoryInGuest' -Extra @($GuestPath, '-r') -Label 'vm-rmdir-guest' -TimeoutSeconds $TimeoutSeconds -AllowFailure)
}

function Remove-MwGuestFile {
    <# 来宾删单个文件（vmrun deleteFileInGuest）；不存在时 vmrun 会报错，这里按 AllowFailure 记录。 #>
    param([Parameter(Mandatory)][string]$GuestPath, [int]$TimeoutSeconds = 300)
    return (Invoke-MwVm -Action 'deleteFileInGuest' -Extra @($GuestPath) -Label 'vm-rm-guest-file' -TimeoutSeconds $TimeoutSeconds -AllowFailure)
}

function Invoke-MwGuestPowerShellText {
    <#
      在来宾里跑一段 PowerShell（UTF-16LE base64 -EncodedCommand，中文不会被控制台代码页改写）。
      返回 vmrun 记录；来宾脚本自己的退出码由脚本写入文件/上传，不依赖 vmrun 的退出码语义。
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [int]$TimeoutSeconds = 1800,
        [string]$Label = 'guest-ps',
        [switch]$NoWait
    )
    $exec = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $extra = @()
    if ($NoWait) { $extra += '-noWait' }
    $extra += @($exec, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    return (Invoke-MwVm -Action 'runProgramInGuest' -Extra $extra -Label $Label -TimeoutSeconds $TimeoutSeconds -AllowFailure)
}

function Invoke-MwGuestPowerShellFile {
    <# 跑来宾里的 .ps1 文件（路径含中文/空格时由 MSVCRT 编码处理）。 #>
    param(
        [Parameter(Mandatory)][string]$GuestScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 1800,
        [string]$Label = 'guest-ps-file',
        [switch]$NoWait
    )
    $exec = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $extra = @()
    if ($NoWait) { $extra += '-noWait' }
    $extra += @($exec, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $GuestScriptPath) + @($Arguments)
    return (Invoke-MwVm -Action 'runProgramInGuest' -Extra $extra -Label $Label -TimeoutSeconds $TimeoutSeconds -AllowFailure)
}

function Copy-MwDirToGuest {
    param([Parameter(Mandatory)][string]$HostPath, [Parameter(Mandatory)][string]$GuestPath, [int]$TimeoutSeconds = 900)
    return (Invoke-MwVm -Action 'copyDirectoryFromHostToGuest' -Extra @($HostPath, $GuestPath) -Label 'vm-copydir-to-guest' -TimeoutSeconds $TimeoutSeconds)
}

function Copy-MwDirFromGuest {
    param([Parameter(Mandatory)][string]$GuestPath, [Parameter(Mandatory)][string]$HostPath, [int]$TimeoutSeconds = 900)
    return (Invoke-MwVm -Action 'copyDirectoryFromGuestToHost' -Extra @($GuestPath, $HostPath) -Label 'vm-copydir-from-guest' -TimeoutSeconds $TimeoutSeconds)
}

function Send-MwGuestTree {
    <#
      把宿主机目录逐文件送到来宾，并让来宾算回 SHA256 逐个核对。

      为什么不用 vmrun copyDirectoryFromHostToGuest：本机 vmrun 17.0.0 对目录复制
      两个方向都返回 exit=-1（无错误文本），只有单文件复制可靠。部署库/来宾脚本时
      文件不多（<20 个），逐文件送 + 来宾端哈希回执足够，而且顺带成为证据。
    #>
    param(
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestPath,
        [string]$Label = 'send',
        [int]$TimeoutSeconds = 900,
        [string]$EvidenceDir = ''
    )
    $root = (Resolve-Path -LiteralPath $HostPath).Path
    $hostFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
    $rows = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
    $bytes = [int64]0
    foreach ($f in $hostFiles) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $guestFile = Join-Path $GuestPath $rel
        $guestDir = Split-Path -Parent $guestFile
        $ok = $false
        $err = ''
        try {
            New-MwGuestDir -GuestPath $guestDir | Out-Null
            Copy-MwFileToGuest -GuestPath $guestFile -HostPath $f.FullName | Out-Null
            $ok = $true
        } catch { $err = $_.Exception.Message }
        $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $bytes += $f.Length
        if (-not $ok) { [void]$bad.Add($rel + ': ' + $err) }
        [void]$rows.Add([ordered]@{ rel = $rel; bytes = $f.Length; sha256 = $sha; copied = $ok; error = $err })
    }

    # 核对：用「复制回来再核对」而不是让来宾写回执脚本。
    # 原因：来宾回执脚本要二次踩引号/编码坑，而单文件复制两个方向都可靠；
    # 库与来宾脚本只有几百 KB，回传验字节最直接，也顺带留下证据。
    $verifyDir = Join-Path ([IO.Path]::GetTempPath()) ('mw-send-verify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
    $back = Receive-MwGuestTree -GuestPath $GuestPath -HostPath $verifyDir -Label ('send-' + $Label) -TimeoutSeconds $TimeoutSeconds
    $backMap = @{}
    foreach ($it in @($back.items)) { if ($it.rel) { $backMap[[string]$it.rel] = $it } }
    foreach ($row in $rows) {
        if (-not $row.copied) { continue }
        $g = $backMap[[string]$row.rel]
        if (-not $g) { $row.copied = $false; [void]$bad.Add($row.rel + ': 回传清单里没有该文件'); continue }
        if ([string]$g.status -ne 'ok') { $row.copied = $false; [void]$bad.Add($row.rel + ': 回传失败 ' + [string]$g.error); continue }
        if ([int64]$g.bytes -ne [int64]$row.bytes) { $row.copied = $false; [void]$bad.Add($row.rel + (': 字节不符 ' + $g.bytes + ' != ' + $row.bytes)); continue }
        if ([string]$g.sha256 -ne [string]$row.sha256) { $row.copied = $false; [void]$bad.Add($row.rel + ': SHA256 不符'); continue }
        if ([string]$g.hostSha256 -ne [string]$row.sha256) { $row.copied = $false; [void]$bad.Add($row.rel + ': 回传落盘 SHA256 不符') }
    }
    $report = [ordered]@{ label = $Label; host = $root; guest = $GuestPath; total = $rows.Count; ok = @($rows | Where-Object { $_.copied }).Count; bad = [string[]]@($bad.ToArray()); badCount = $bad.Count; bytes = $bytes; items = @($rows.ToArray()); utc = (Get-Date).ToUniversalTime().ToString('o') }
    if ($EvidenceDir) {
        if (-not (Test-Path -LiteralPath $EvidenceDir)) { New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null }
        Save-MwJson -Path (Join-Path $EvidenceDir ('send-' + $Label + '.json')) -Object $report -Depth 6
    }
    [pscustomobject]$report
}

function Receive-MwGuestTree {
    <#
      把来宾目录逐文件取回宿主机，并逐文件核对 SHA256/字节数。

      为什么不用 vmrun copyDirectoryFromGuestToHost：本机 vmrun 17.0.0 对该动作一律返回
      exit=-1（无错误文本），空目录、目标是否存在、纯 ASCII 路径都试过，全部失败。
      copyFileFromGuestToHost 正常，因此改为「来宾端生成带哈希的清单 → 取回清单 → 逐文件取回并核对」。
      这样做同时满足“证据清单 + 每个文件 SHA256”的要求，也避免了目录级复制失败后整段证据丢失。
    #>
    param(
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$HostPath,
        [string]$Label = 'tree',
        [int]$TimeoutSeconds = 900
    )
    $listingGuest = Join-Path $GuestPath ('_tree-' + $Label + '.json')
    $code = @"
`$ErrorActionPreference = 'Stop'
`$root = '$GuestPath'
`$out = '$listingGuest'
`$items = @(Get-ChildItem -LiteralPath `$root -Recurse -File -Force -ErrorAction Stop | Where-Object { `$_.FullName -ne `$out } | ForEach-Object {
  [ordered]@{ rel = `$_.FullName.Substring(`$root.Length).TrimStart('\'); bytes = `$_.Length; sha256 = (Get-FileHash -LiteralPath `$_.FullName -Algorithm SHA256).Hash.ToLower() }
})
(`$items | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath `$out -Encoding UTF8
"@
    Invoke-MwGuestPowerShellText -Code $code -TimeoutSeconds 300 -Label ('tree-list-' + $Label) | Out-Null
    $listingHost = Join-Path $HostPath ('_tree-' + $Label + '.json')
    New-Item -ItemType Directory -Force -Path $HostPath | Out-Null
    Copy-MwFileFromGuest -GuestPath $listingGuest -HostPath $listingHost -TimeoutSeconds 120 | Out-Null
    $raw = Get-Content -LiteralPath $listingHost -Raw -Encoding UTF8
    # PS 5.1 的 ConvertFrom-Json 走管道时会把顶层数组当成“一个对象”嵌套，
    # 这里用 -InputObject 直接取回数组，再统一包成 @()。
    $parsed = $null
    if ($raw.Trim()) { $parsed = ConvertFrom-Json -InputObject $raw }
    $items = @($parsed)
    $rows = New-Object System.Collections.ArrayList
    $bytes = 0; $okCount = 0; $bad = New-Object System.Collections.ArrayList
    foreach ($it in $items) {
        $rel = [string]$it.rel
        $dst = Join-Path $HostPath $rel
        $dir = Split-Path -Parent $dst
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $st = 'ok'; $err = ''; $hostSha = ''; $hostBytes = 0
        try {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
            Copy-MwFileFromGuest -GuestPath (Join-Path $GuestPath $rel) -HostPath $dst -TimeoutSeconds 300 | Out-Null
            $hostBytes = (Get-Item -LiteralPath $dst).Length
            $hostSha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
            if ($hostBytes -ne [int64]$it.bytes -or $hostSha -ne [string]$it.sha256) { $st = 'mismatch' }
        } catch { $st = 'error'; $err = $_.Exception.Message }
        if ($st -eq 'ok') { $okCount++ } else { [void]$bad.Add($rel) }
        $bytes += $hostBytes
        [void]$rows.Add([ordered]@{ rel = $rel; bytes = [int64]$it.bytes; sha256 = [string]$it.sha256; hostBytes = $hostBytes; hostSha256 = $hostSha; status = $st; error = $err })
    }
    $report = [ordered]@{
        guestPath = $GuestPath; hostPath = $HostPath; label = $Label
        total = $items.Count; ok = $okCount; bad = [string[]]@($bad.ToArray()); badCount = $bad.Count; bytes = $bytes
        listing = $listingHost; items = @($rows); at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-MwJson -Path (Join-Path $HostPath ('tree-' + $Label + '.json')) -Object $report -Depth 8
    return ([pscustomobject]$report)
}

function Stop-MwGuestProcess {
    <# 结束来宾里指定 pid 的整棵进程树（阶段超时/失控时用）。 #>
    param([Parameter(Mandatory)][int]$GuestPid, [int]$TimeoutSeconds = 120)
    $code = "& taskkill.exe /PID $GuestPid /T /F | Out-Null; exit 0"
    return (Invoke-MwGuestPowerShellText -Code $code -TimeoutSeconds $TimeoutSeconds -Label 'guest-kill-tree')
}
