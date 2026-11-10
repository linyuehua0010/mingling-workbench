#requires -Version 5.1
<#
  acceptance\lib\Capture.ps1 — 验收用进程调用与参数编码（Windows PowerShell 5.1）

  为什么单独一层：旧 acceptance\guest-acceptance.ps1 把 exe / PowerShell / cmd 三种调用方式
  混成一套字符串替换，并且连续两次 -match 覆盖了 $Matches，导致 "/DIR=C:\中文 目录" 被替换成
  空串（实测：参数整个消失）。这里按调用方式分别编码，并为每一种规则提供可执行自测
  （acceptance\tests\test-capture.ps1 会用真实 powershell.exe / cmd.exe / node.exe 回读实际收到的 argv）。

  编码规则（均已在本机 PS 5.1 + cmd + 原生 exe 上实测）：
    exe         : MSVCRT / CommandLineToArgvW 规则：空格才加引号；引号前反斜杠成对加倍；
                  引号内结尾反斜杠加倍；空串编码为 ""。
    powershell  : powershell.exe -File 的解析器与 MSVCRT 不完全一致（反斜杠不是转义符），
                  因此 PowerShell 分支单独用 ConvertTo-PsFileArg：加引号，内部 " 用 \" 表示，
                  结尾反斜杠保持原样；自测断言实际 $args 完全一致。
    cmd         : 走 cmd.exe /d /s /c ""<脚本>" <参数>""，参数用 ConvertTo-CmdArg（只加引号、
                  不引入反斜杠转义），批处理里 %~1 得到原值。

  ⚠ 源码必须以 UTF-8 BOM 保存：Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI(936) 解码，
    脚本里的中文常量会被悄悄拆坏（实测会变成 “涓枃” 一类乱码）。acceptance\tools\Ensure-Utf8Bom.ps1 负责统一。

  调用记录（机器可读）字段见 New-CaptureRecord：label/kind/file/arguments/commandLine/脱敏版命令/
  开始与结束 UTC/耗时/退出码/超时/被杀/工作目录/stdout 与 stderr 的落盘路径、字节数、SHA256。
#>

$script:MwCaptureVersion = '3.1.0-harness2'

# ---------------------------------------------------------------- 参数编码

function ConvertTo-MsvcrtArg {
    <# 原生 exe 的单个参数编码（MSVCRT 规则）。空串 → ""。 #>
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Value = '')

    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[ \t"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', (2 * $backslashes + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', (2 * $backslashes)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-PsFileArg {
    <#
     powershell.exe -File 的单个参数编码。
     实测（acceptance/tests/_probe-ps-enc.ps1，14 例含：纯引号、尾反斜杠、全空格、中文、/DIR=… 形态）
     PS 5.1 的 -File 解析器与原生 exe 的 MSVCRT 规则一致：MSVCRT 编码 14/14 逐值回读一致；
     `\"…\"` 双引号折叠加反斜杠不动、单引号包裹、反引号转义 三种候选均有参数丢失/变形（11~23 个参数）。
     因此这里直接复用 MSVCRT 规则，而不是另写一套。
    #>
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Value = '')

    return (ConvertTo-MsvcrtArg $Value)
}

function ConvertTo-CmdArg {
    <#
     cmd.exe /d /s /c ""<script>" <args>"" 里单个参数的编码（批处理 %~N 取值）。
     实测（acceptance/tests/_probe-cmd-enc.ps1，8 例）：含空格 / 中文 / & ( ) 的值加引号后原样还原，
     尾反斜杠在加引号时也能还原（`"C:\dir with space\"` 回读一致）；若再补一个反斜杠（bs2）会多出一个；
     用 ^ 转义则会把 ^ 留在值里。故：按需加引号，不做反斜杠处理。
     引号字符本身在 cmd 批处理参数里没有可靠编码（"" 折叠会改变值），遇到即报错，由调用方转成 fail-fixture，
     不允许“悄悄改值”。换行同样无法编码。
    #>
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Value = '')

    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -match '[\r\n]') { throw ("ConvertTo-CmdArg: cmd 参数不能包含换行（值长度 {0}）" -f $Value.Length) }
    if ($Value.Contains('"')) { throw ("ConvertTo-CmdArg: cmd 批处理参数不能包含双引号，无法无损编码（值：{0}）" -f $Value) }
    if ($Value -notmatch '[ \t&|<>^()]') { return $Value }
    return '"' + $Value + '"'
}

# ---------------------------------------------------------------- 脱敏

$script:MwSecretPatterns = @(
    @{ re = '(?i)(--?password[= ]+)(\S+)'; rep = '$1***' }
    @{ re = '(?i)(--?token[= ]+)(\S+)'; rep = '$1***' }
    @{ re = '(?i)(--?api[-_]?key[= ]+)(\S+)'; rep = '$1***' }
    @{ re = '(?i)(/PASSWORD=)("?[^"\s]*"?)'; rep = '$1***' }
    @{ re = '(?i)((?:^|\s)-(?:vp|gp)\s+)("(?:\\.|[^"\\])*"|\S+)'; rep = '$1***' }
    @{ re = '(?i)(/PASS(?:WORD)?=)([^\s"]+)'; rep = '$1***' }
    @{ re = '(?i)(authorization:\s*bearer\s+)(\S+)'; rep = '$1***' }
    @{ re = '(?i)(sk-[A-Za-z0-9]{8})[A-Za-z0-9_\-]+'; rep = '$1***' }
    @{ re = '(?i)((?:qq|bili)[_-]?(?:password|token|key)[=:]\s*)(\S+)'; rep = '$1***' }
    @{ re = '(?i)("(?:password|token|api_?key|apiKey|passwordHash)"\s*:\s*")([^"]+)(")'; rep = '$1***$3' }
)

function Get-MwRedactedArgList {
    <#
      参数列表脱敏：单个参数里的 --token=abc / /PASSWORD=abc 由 Get-RedactedText 处理；
      但 "--token" "abc" 这种“标志 + 独立值”只有在列表层面才看得出来，这里补上。
    #>
    param([string[]]$Arguments = @())

    $flagRe = '(?i)^--?(password|passwd|pwd|token|api[-_]?key|apikey|secret|client[-_]?secret|vp|gp)$|(?i)^/PASSWORD$'
    $out = New-Object System.Collections.ArrayList
    $prevIsFlag = $false
    foreach ($a in @($Arguments)) {
        $s = [string]$a
        if ($prevIsFlag -and $s) { [void]$out.Add('***') }
        else { [void]$out.Add((Get-RedactedText -Text $s)) }
        $prevIsFlag = ($s -match $flagRe)
    }
    return @($out)
}

function Get-RedactedText {
    <# 把命令行/日志里的口令类片段替换成 ***。仅用于落盘与回报，不改变实际执行。 #>
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = $Text
    foreach ($p in $script:MwSecretPatterns) { $s = [regex]::Replace($s, $p.re, $p.rep) }
    return $s
}

# ---------------------------------------------------------------- 解码

function ConvertFrom-MwProcessBytes {
    <# 子进程输出可能是 UTF-8（node/curl）或控制台 ANSI/936（PowerShell 重定向），按严格 UTF-8 优先回退。 #>
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $strictUtf8.GetString($Bytes) } catch { }
    try { return [System.Text.Encoding]::GetEncoding(936).GetString($Bytes) } catch { }
    return [System.Text.Encoding]::ASCII.GetString($Bytes)
}

# ---------------------------------------------------------------- 启动 / 完成

function Resolve-MwCommandKind {
    param([string]$FilePath, [string]$Kind = 'auto')

    if ($Kind -ne 'auto') { return $Kind }
    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    switch ($ext) {
        '.ps1' { return 'powershell' }
        '.cmd' { return 'cmd' }
        '.bat' { return 'cmd' }
        default { return 'exe' }
    }
}

function Start-MwCommand {
    <#
      启动一条被记录的进程，返回可轮询的状态对象（供长任务展示“当前命令/耗时/最近日志”）。
      用 Start-MwCommand + Complete-MwCommand 而不是同步等待，才能在不阻塞的情况下持续落盘进度。
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateSet('auto', 'exe', 'powershell', 'cmd')][string]$Kind = 'auto',
        [string]$WorkDir = '',
        [hashtable]$Environment = @{},
        [string]$EvidenceDir = '',
        [string]$RunId = ''
    )

    $kindResolved = Resolve-MwCommandKind -FilePath $FilePath -Kind $Kind
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "找不到要执行的程序/脚本：$FilePath"
    }
    $FilePath = (Resolve-Path -LiteralPath $FilePath).ProviderPath

    $argv = @()
    $argLine = ''
    $exe = $FilePath
    switch ($kindResolved) {
        'powershell' {
            $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $Arguments
            $argLine = (($argv | ForEach-Object { ConvertTo-PsFileArg $_ }) -join ' ')
        }
        'cmd' {
            $exe = $env:ComSpec
            $inner = (($Arguments | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
            $argLine = '/d /s /c ""' + $FilePath + '" ' + $inner + '"'
            $argv = @('/d', '/s', '/c', '""' + $FilePath + '" ' + $inner + '"')
        }
        default {
            $argv = @($Arguments)
            $argLine = (($Arguments | ForEach-Object { ConvertTo-MsvcrtArg $_ }) -join ' ')
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }

    $record = New-CaptureRecord -Label $Label -Kind $kindResolved -File $FilePath -Exe $exe `
        -Arguments $Arguments -CommandLine ($exe + ' ' + $argLine) -WorkDir $psi.WorkingDirectory
    $record.runId = $RunId
    $record.evidenceDir = $EvidenceDir

    $state = New-Object psobject -Property @{
        Record    = $record
        Process   = $null
        StartTime = $null
        MsOut     = $null
        MsErr     = $null
        TaskOut   = $null
        TaskErr   = $null
        Started   = $false
        LaunchError = ''
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        $state.StartTime = Get-Date
        [void]$p.Start()
        $state.Started = $true
    } catch {
        $state.LaunchError = $_.Exception.Message
        $state.Process = $p
        return $state
    }
    $state.Process = $p
    $state.MsOut = New-Object System.IO.MemoryStream
    $state.MsErr = New-Object System.IO.MemoryStream
    $state.TaskOut = $p.StandardOutput.BaseStream.CopyToAsync($state.MsOut)
    $state.TaskErr = $p.StandardError.BaseStream.CopyToAsync($state.MsErr)
    return $state
}

function Get-MwCommandTail {
    <# 读取某个运行中命令的最近输出（不结束进程），供长任务进度展示。 #>
    param([Parameter(Mandatory)]$State, [int]$Bytes = 4000)

    $parts = @()
    foreach ($pair in @(@{ ms = $State.MsOut; name = 'stdout' }, @{ ms = $State.MsErr; name = 'stderr' })) {
        $ms = $pair.ms
        if ($null -eq $ms) { continue }
        $len = [int]$ms.Length
        if ($len -le 0) { continue }
        $buf = $ms.ToArray()
        $take = [Math]::Min($Bytes, $buf.Length)
        $slice = New-Object byte[] $take
        [Array]::Copy($buf, $buf.Length - $take, $slice, 0, $take)
        $parts += ('--- ' + $pair.name + ' ---' + "`n" + (ConvertFrom-MwProcessBytes -Bytes $slice))
    }
    return ($parts -join "`n")
}

function Stop-MwProcessTree {
    <# 结束整棵进程树（安装器会派生 bootstrap/msiexec/uv/python，只杀父进程会留下半装状态）。 #>
    param([Parameter(Mandatory)][int]$ProcessId, [int]$WaitMs = 15000)

    $killed = $false
    try {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>&1 | Out-Null
        $killed = ($LASTEXITCODE -eq 0)
    } catch { }
    if (-not $killed) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($proc) { $proc.Kill(); $killed = $true }
        } catch { }
    }
    return $killed
}

function Complete-MwCommand {
    <# 等待进程结束（或超时后杀进程树），把 stdout/stderr、退出码、时间戳、SHA256 写成证据记录。 #>
    param(
        [Parameter(Mandatory)]$State,
        [int]$TimeoutSeconds = 1800,
        [string]$EvidenceDir = '',
        [switch]$KeepRaw
    )

    $rec = $State.Record
    if (-not $State.Started) {
        $rec.status = 'launch-error'
        $rec.exitCode = $null
        $rec.errorText = $State.LaunchError
        $rec.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $rec.durationMs = 0
        return $rec
    }

    $p = $State.Process
    $timedOut = $false
    try {
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $rec.killedTree = Stop-MwProcessTree -ProcessId $p.Id
            [void]$p.WaitForExit(15000)
        }
        # 二次等待确保异步读流结束（.NET 文档要求：带超时的 WaitForExit 之后必须无参再等一次）
        $p.WaitForExit()
    } catch {
        $rec.errorText = $_.Exception.Message
    }

    foreach ($t in @($State.TaskOut, $State.TaskErr)) {
        if ($null -ne $t) { try { [void]$t.Wait(15000) } catch { } }
    }

    $outBytes = @()
    $errBytes = @()
    if ($State.MsOut) { $outBytes = $State.MsOut.ToArray() }
    if ($State.MsErr) { $errBytes = $State.MsErr.ToArray() }
    $outText = ConvertFrom-MwProcessBytes -Bytes $outBytes
    $errText = ConvertFrom-MwProcessBytes -Bytes $errBytes

    $ended = Get-Date
    if ($null -ne $State.StartTime) { $rec.startedUtc = $State.StartTime.ToUniversalTime().ToString('o') }
    $rec.endedUtc = $ended.ToUniversalTime().ToString('o')
    $rec.durationMs = [int](($ended - $State.StartTime).TotalMilliseconds)
    $rec.timedOut = $timedOut
    $rec.status = if ($timedOut) { 'timeout' } elseif ($p.HasExited) { 'completed' } else { 'unknown' }
    try { $rec.exitCode = $p.ExitCode } catch { $rec.exitCode = $null }
    $rec.stdoutBytes = $outBytes.Length
    $rec.stderrBytes = $errBytes.Length
    $rec.stdoutSha256 = Get-MwBytesSha256 -Bytes $outBytes
    $rec.stderrSha256 = Get-MwBytesSha256 -Bytes $errBytes
    $rec.stdoutText = Get-RedactedText -Text $outText
    $rec.stderrText = Get-RedactedText -Text $errText

    $dir = if ($EvidenceDir) { $EvidenceDir } else { $rec.evidenceDir }
    if ($dir) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $base = ($rec.runId + '-' + $rec.label) -replace '[^\w\.\-]', '_'
        $rec.stdoutPath = Join-Path $dir ($base + '.stdout.txt')
        $rec.stderrPath = Join-Path $dir ($base + '.stderr.txt')
        [IO.File]::WriteAllBytes($rec.stdoutPath, $outBytes)
        [IO.File]::WriteAllBytes($rec.stderrPath, $errBytes)
    } else {
        $rec.stdoutPath = ''
        $rec.stderrPath = ''
    }
    return $rec
}

function Get-MwBytesSha256 {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function New-CaptureRecord {
    <# 命令记录的唯一构造点：字段名固定，host/guest 两侧共用，便于机器读取。 #>
    param(
        [string]$Label, [string]$Kind, [string]$File, [string]$Exe,
        [string[]]$Arguments = @(), [string]$CommandLine = '', [string]$WorkDir = ''
    )

    return [ordered]@{
        label            = $Label
        kind             = $Kind
        file             = $File
        exe              = $Exe
        # 返回记录只含脱敏参数；真实参数仅在进程启动对象中使用，避免控制台格式化泄漏。
        arguments        = @(Get-MwRedactedArgList -Arguments $Arguments)
        # commandLine 落盘用的就是脱敏版；下划线开头的字段由证据层丢弃，只在内存里保留原值供调试。
        commandLine      = Get-RedactedText -Text $CommandLine
        workDir          = $WorkDir
        runId            = ''
        startedUtc       = ''
        endedUtc         = ''
        durationMs       = 0
        exitCode         = $null
        timedOut         = $false
        killedTree       = $false
        status           = 'not-started'
        errorText        = ''
        stdoutPath       = ''
        stderrPath       = ''
        stdoutBytes      = 0
        stderrBytes      = 0
        stdoutSha256     = ''
        stderrSha256     = ''
        stdoutText       = ''
        stderrText       = ''
    }
}

function Invoke-Capture {
    <# 同步执行并落盘（= Start-MwCommand + 等待 + Complete-MwCommand）。默认 30 分钟超时。 #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateSet('auto', 'exe', 'powershell', 'cmd')][string]$Kind = 'auto',
        [int]$TimeoutSeconds = 1800,
        [string]$WorkDir = '',
        [hashtable]$Environment = @{},
        [string]$EvidenceDir = '',
        [string]$RunId = ''
    )

    $state = Start-MwCommand -Label $Label -FilePath $FilePath -Arguments $Arguments -Kind $Kind `
        -WorkDir $WorkDir -Environment $Environment -EvidenceDir $EvidenceDir -RunId $RunId
    $rec = Complete-MwCommand -State $state -TimeoutSeconds $TimeoutSeconds -EvidenceDir $EvidenceDir
    $state.Record = $rec
    return [pscustomobject]@{ Record = $rec; State = $state }
}
