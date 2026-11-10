#requires -Version 5.1
<#
  acceptance\tests\test-capture.ps1 — Invoke-Capture 参数编码与执行记录自测（真实 Windows PowerShell 5.1 / cmd / 原生 exe）。

  为什么必须实测：旧夹具用字符串替换拼参数，连续 -match 覆盖 $Matches，"/DIR=C:\中文 目录" 变成 ""（参数消失）。
  本脚本用三个真实探针回读“进程实际收到什么”，逐值断言，不检查拼接出来的字符串。

  覆盖：中文、空格、空参数、尾部反斜杠、程序目录含 (x86)、值内含引号、/DIR /WORKSPACE /LOG 形态、
        退出码透传、超时后整棵进程树被杀、stdout/stderr 落盘与 SHA256、命令行脱敏。
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\tests\test-capture.ps1 [-ReportPath <json>]
  退出码：0 全部通过；1 有断言失败；2 夹具自身出错。
#>
param(
    [string]$ReportPath = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib = Join-Path $here '..\lib\Capture.ps1'
. $lib
. (Join-Path $here '..\lib\Evidence.ps1')

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$runId = 'selftest-capture-' + $stamp
if (-not $ReportPath) { $ReportPath = Join-Path $here ('..\evidence\self-test\' + $runId + '.json') }
$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$work = Join-Path $env:TEMP ('mw-capture-test-' + $stamp)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$evidenceDir = Join-Path $reportDir $runId
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$checks = New-Object System.Collections.ArrayList
function Assert-Check([string]$Id, [bool]$Ok, [string]$Detail, $Expected = $null, $Actual = $null, $Evidence = $null) {
    [void]$checks.Add([ordered]@{
        id = $Id; ok = $Ok; detail = $Detail; expected = $Expected; actual = $Actual; evidence = $Evidence
    })
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $tag, $Id, $Detail)
}

function Get-ArgDiff([string[]]$Want, [string[]]$Got) {
    $diffs = New-Object System.Collections.ArrayList
    $n = [Math]::Max($Want.Count, $Got.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $w = if ($i -lt $Want.Count) { $Want[$i] } else { '<missing>' }
        $g = if ($i -lt $Got.Count) { $Got[$i] } else { '<missing>' }
        if ($w -cne $g) { [void]$diffs.Add([ordered]@{ index = $i; want = $w; got = $g }) }
    }
    return $diffs
}

# ---------------------------------------------------------------- 探针与样例

$probeDir = Join-Path $here '..\lib\probe'
$recPs = (Resolve-Path -LiteralPath (Join-Path $probeDir 'args-recorder.ps1')).ProviderPath
$recCmd = (Resolve-Path -LiteralPath (Join-Path $probeDir 'args-recorder.cmd')).ProviderPath
$recJs = (Resolve-Path -LiteralPath (Join-Path $probeDir 'args-recorder.js')).ProviderPath
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) {
    # 没有 node 时用 powershell 自身当“原生 exe”不成立（它是 PS 规则），此处明确判定夹具不可用
    Assert-Check 'fixture.node' $false '缺少 node.exe，无法做原生 exe 参数基准测试' '' ''
    Write-Host 'FIXTURE-MISSING: node.exe'
    exit 2
}

# 把探针复制到“中文 目录”下，顺带验证脚本路径本身含中文与空格
$zhDir = Join-Path $work '中文 目录 (x86)'
New-Item -ItemType Directory -Force -Path $zhDir | Out-Null
$recPsZh = Join-Path $zhDir '探针 脚本.ps1'
Copy-Item -LiteralPath $recPs -Destination $recPsZh -Force
$recCmdZh = Join-Path $zhDir '探针 脚本.cmd'
Copy-Item -LiteralPath $recCmd -Destination $recCmdZh -Force

$commonCases = @(
    'plain',
    '中文 路径',
    '',
    'tail\',
    'C:\dir with space\',
    'he said "hi"',
    '/DIR=C:\安装 目录\程序 3.1',
    'C:\a\\b',
    'a&b',
    'C:\Program Files (x86)\',
    '   '
)

function Invoke-Probe {
    param([string]$Kind, [string]$Label, [string[]]$Cases, [string]$File, [string]$ProbeOut, [hashtable]$Env = @{}, [int]$Timeout = 120)
    if (Test-Path -LiteralPath $ProbeOut) { Remove-Item -LiteralPath $ProbeOut -Force }
    $env2 = @{ MW_PROBE_OUT = $ProbeOut }
    foreach ($k in $Env.Keys) { $env2[$k] = $Env[$k] }
    $argsList = @()
    if ($Kind -eq 'exe') {
        $argsList = @($File) + $Cases
        $r = Invoke-Capture -Label $Label -FilePath $node -Arguments $argsList -Kind 'exe' `
            -Environment $env2 -EvidenceDir $evidenceDir -RunId $runId -TimeoutSeconds $Timeout
    } else {
        $argsList = $Cases
        $r = Invoke-Capture -Label $Label -FilePath $File -Arguments $argsList -Kind $Kind `
            -Environment $env2 -EvidenceDir $evidenceDir -RunId $runId -TimeoutSeconds $Timeout
    }
    $probe = $null
    if ($Kind -ne 'cmd' -and (Test-Path -LiteralPath $ProbeOut)) {
        $probe = Get-Content -LiteralPath $ProbeOut -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return [pscustomobject]@{ Result = $r.Record; Probe = $probe }
}

# ---------------------------------------------------------------- 1. 原生 exe（MSVCRT 规则）
$p1 = Join-Path $work 'probe-exe.json'
$r1 = Invoke-Probe -Kind 'exe' -Label 'exe-argv' -Cases $commonCases -File $recJs -ProbeOut $p1
$got1 = @()
if ($r1.Probe) { $got1 = @($r1.Probe.args) }
$diff1 = Get-ArgDiff -Want $commonCases -Got $got1
$d1 = if (@($diff1).Count -gt 0) { '，存在差异' } else { '，逐值一致' }
Assert-Check 'exe.exit' ($r1.Result.exitCode -eq 0) ('exe 退出码 ' + $r1.Result.exitCode) 0 $r1.Result.exitCode $r1.Result.stdoutPath
Assert-Check 'exe.argv-exact' (@($diff1).Count -eq 0) ('原生 exe 收到 ' + $got1.Count + '/' + $commonCases.Count + ' 个参数' + $d1) $commonCases $got1 $p1
if (@($diff1).Count) { $diff1 | ConvertTo-Json -Depth 4 | Write-Host }

# ---------------------------------------------------------------- 2. PowerShell -File（真实 powershell.exe 5.1）
$p2 = Join-Path $work 'probe-ps.json'
$r2 = Invoke-Probe -Kind 'powershell' -Label 'ps-file-argv' -Cases $commonCases -File $recPsZh -ProbeOut $p2
$got2 = @()
if ($r2.Probe) { $got2 = @($r2.Probe.args) }
$diff2 = Get-ArgDiff -Want $commonCases -Got $got2
$d2 = if (@($diff2).Count -gt 0) { '，存在差异' } else { '，逐值一致' }
Assert-Check 'ps.exit' ($r2.Result.exitCode -eq 0) ('powershell 退出码 ' + $r2.Result.exitCode) 0 $r2.Result.exitCode $r2.Result.stderrPath
Assert-Check 'ps.argv-exact' (@($diff2).Count -eq 0) ('PowerShell 5.1 -File 收到 ' + $got2.Count + '/' + $commonCases.Count + ' 个参数' + $d2) $commonCases $got2 $p2
if (@($diff2).Count) { $diff2 | ConvertTo-Json -Depth 4 | Write-Host }
Assert-Check 'ps.script-path-chinese' ($r2.Probe -and $r2.Probe.scriptPath -eq $recPsZh) '脚本自身路径含中文与空格时 $PSCommandPath 与传入一致' $recPsZh ($r2.Probe.scriptPath)

# ---------------------------------------------------------------- 3. cmd 批处理（/d /s /c 包裹）
$cmdCases = @(
    'plain',
    '中文 路径',
    '',
    'tail\',
    'C:\dir with space\',
    '/DIR=C:\安装 目录\程序 3.1',
    'a&b',
    'C:\Program Files (x86)\'
)
$p3 = Join-Path $work 'probe-cmd.txt'
$r3 = Invoke-Probe -Kind 'cmd' -Label 'cmd-argv' -Cases $cmdCases -File $recCmdZh -ProbeOut $p3
$cmdText = if (Test-Path -LiteralPath $p3) { Get-Content -LiteralPath $p3 -Raw -Encoding Default } else { '' }
$cmdSlots = @()
foreach ($line in ($cmdText -split "`r?`n")) {
    if ($line -match '^A(\d+)=\[(.*)\]$') {
        $idx = [int]$Matches[1]
        while ($cmdSlots.Count -lt $idx) { $cmdSlots += '' }
        $cmdSlots[$idx - 1] = $Matches[2]
    }
}
# 探针固定输出 A1..A9：前 N 个是真实参数，其余必须为空（证明没有多余/被拆开的参数）
$cmdGot = @()
for ($i = 0; $i -lt $cmdCases.Count; $i++) { $cmdGot += $(if ($i -lt $cmdSlots.Count) { $cmdSlots[$i] } else { '<missing>' }) }
$cmdExtra = @()
for ($i = $cmdCases.Count; $i -lt $cmdSlots.Count; $i++) { if ($cmdSlots[$i] -ne '') { $cmdExtra += ('A' + ($i + 1) + '=' + $cmdSlots[$i]) } }
Assert-Check 'cmd.exit' ($r3.Result.exitCode -eq 0) ('cmd 退出码 ' + $r3.Result.exitCode) 0 $r3.Result.exitCode $r3.Result.stderrPath
$diff3 = Get-ArgDiff -Want $cmdCases -Got $cmdGot
$d3 = if (@($diff3).Count -gt 0) { '，存在差异' } else { '，逐值一致' }
Assert-Check 'cmd.argv-exact' (@($diff3).Count -eq 0 -and @($cmdExtra).Count -eq 0) ('cmd 批处理收到 ' + $cmdGot.Count + '/' + $cmdCases.Count + ' 个参数' + $d3 + $(if (@($cmdExtra).Count) { '；多余：' + ($cmdExtra -join ',') } else { '' })) $cmdCases $cmdGot $p3
if (@($diff3).Count) { $diff3 | ConvertTo-Json -Depth 4 | Write-Host }
if (@($diff3).Count) { $diff3 | ConvertTo-Json -Depth 4 | Write-Host }

# cmd 无法无损编码的值必须显式报错，而不是改值后照常执行
$cmdRefused = $false
$cmdRefuseMsg = ''
try { [void](ConvertTo-CmdArg 'he said "hi"') } catch { $cmdRefused = $true; $cmdRefuseMsg = $_.Exception.Message }
Assert-Check 'cmd.quote-refused' $cmdRefused 'cmd 参数含双引号时编码器显式报错（不允许悄悄改值）' 'throw' $cmdRefuseMsg

# ---------------------------------------------------------------- 4. 空参数单独确认（命令里必须保留两个引号）
$p4 = Join-Path $work 'probe-empty.json'
$r4 = Invoke-Probe -Kind 'exe' -Label 'exe-empty' -Cases @('a', '', 'b') -File $recJs -ProbeOut $p4
$got4 = @($r4.Probe.args)
Assert-Check 'exe.empty-arg' ($got4.Count -eq 3 -and $got4[1] -eq '' -and $got4[0] -eq 'a' -and $got4[2] -eq 'b') '空参数在 exe 调用中保持为独立空串（不能被吞掉或与相邻参数合并）' @('a', '', 'b') $got4 $p4
Assert-Check 'exe.empty-arg-shown' ($r4.Result.commandLine -match '""') '记录里的脱敏命令行保留空参数的两个引号，可据此复现' '""' $r4.Result.commandLine

# ---------------------------------------------------------------- 5. 退出码透传
$p5 = Join-Path $work 'probe-exit.json'
$r5 = Invoke-Probe -Kind 'powershell' -Label 'ps-exit7' -Cases @('x') -File $recPs -ProbeOut $p5 -Env @{ MW_PROBE_EXIT = '7' }
Assert-Check 'exit.propagated' ($r5.Result.exitCode -eq 7 -and $r5.Result.status -eq 'completed') '子进程退出码 7 被原样记录，状态 completed' 7 $r5.Result.exitCode

# ---------------------------------------------------------------- 6. 超时 + 整棵进程树
$p6 = Join-Path $work 'probe-timeout.json'
$childFile = Join-Path $work 'child.pid'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r6 = Invoke-Probe -Kind 'powershell' -Label 'ps-timeout' -Cases @('x') -File $recPs -ProbeOut $p6 `
    -Env @{ MW_PROBE_SLEEP = '120'; MW_PROBE_CHILD = $childFile } -Timeout 3
$sw.Stop()
$childPid = 0
if (Test-Path -LiteralPath $childFile) { $childPid = [int](Get-Content -LiteralPath $childFile -Raw) }
Start-Sleep -Seconds 2
$childAlive = $false
if ($childPid -gt 0) { $childAlive = [bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue) }
Assert-Check 'timeout.timedOut' ($r6.Result.timedOut -and $r6.Result.status -eq 'timeout') '超过超时时间被判定为 timeout' 'timeout' $r6.Result.status
Assert-Check 'timeout.duration' ($r6.Result.durationMs -ge 1000) ('超时耗时记录 ' + $r6.Result.durationMs + 'ms（真实等待，不是立即返回）') '>=1000' $r6.Result.durationMs
Assert-Check 'timeout.tree-killed' ($childPid -gt 0 -and -not $childAlive) ('派生进程 ' + $childPid + ' 在超时后被结束（整棵进程树）') 'not-running' $(if ($childAlive) { 'still-running' } else { 'gone' })

# ---------------------------------------------------------------- 7. stdout/stderr 落盘 + SHA256
$logScript = Join-Path $work 'emit.ps1'
[IO.File]::WriteAllText($logScript, "[Console]::Out.WriteLine('标准输出：中文 ✓'); [Console]::Error.WriteLine('标准错误：中文 ✗'); exit 3`n", (New-Object Text.UTF8Encoding($true)))
$r7 = Invoke-Capture -Label 'ps-streams' -FilePath $logScript -Arguments @() -Kind 'powershell' `
    -EvidenceDir $evidenceDir -RunId $runId -TimeoutSeconds 120
$rec7 = $r7.Record
$fileOutOk = $false; $fileErrOk = $false; $shaOutOk = $false
if ($rec7.stdoutPath -and (Test-Path -LiteralPath $rec7.stdoutPath)) {
    $b = [IO.File]::ReadAllBytes($rec7.stdoutPath)
    $fileOutOk = ($b.Length -eq $rec7.stdoutBytes)
    $sha = Get-MwBytesSha256 -Bytes $b
    $shaOutOk = ($sha -eq $rec7.stdoutSha256)
}
if ($rec7.stderrPath -and (Test-Path -LiteralPath $rec7.stderrPath)) {
    $be = [IO.File]::ReadAllBytes($rec7.stderrPath)
    $fileErrOk = ($be.Length -eq $rec7.stderrBytes)
}
Assert-Check 'stream.stdout-file' ($fileOutOk -and $rec7.stdoutBytes -gt 0) 'stdout 落盘且字节数与记录一致' 'bytes>0' $rec7.stdoutBytes $rec7.stdoutPath
Assert-Check 'stream.stderr-file' ($fileErrOk -and $rec7.stderrBytes -gt 0) 'stderr 落盘且字节数与记录一致' 'bytes>0' $rec7.stderrBytes $rec7.stderrPath
$shaWord = if ($shaOutOk) { 'match' } else { 'mismatch' }
Assert-Check 'stream.sha256' $shaOutOk '本机回收文件的 SHA256 与记录值一致' $rec7.stdoutSha256 $shaWord $rec7.stdoutPath
Assert-Check 'stream.utf8-text' ($rec7.stdoutText -match '标准输出：中文') '重新解码后中文未乱码（严格 UTF-8 优先，回退 936）' '中文 ✓' $rec7.stdoutText
Assert-Check 'stream.timestamps' ($rec7.startedUtc -and $rec7.endedUtc -and $rec7.durationMs -ge 0) '开始/结束时间与耗时均已记录' 'present' ($rec7.startedUtc + ' → ' + $rec7.endedUtc)

# ---------------------------------------------------------------- 8. 命令行脱敏
$r8 = Invoke-Capture -Label 'ps-secret' -FilePath $logScript -Arguments @('-Password', 'S3cretValue', '/PASSWORD=TopSecret') `
    -Kind 'powershell' -EvidenceDir $evidenceDir -RunId $runId -TimeoutSeconds 60
$shown = $r8.Record.commandLine
$raw = $r8.Record._commandLineRaw
Assert-Check 'redact.persisted' ($shown -notmatch 'S3cretValue' -and $shown -notmatch 'TopSecret') '落盘命令行为脱敏版，不含明文口令' 'no-secret' $shown
Assert-Check 'redact.raw-in-memory' ($raw -match 'S3cretValue' -and $raw -match 'TopSecret') '内存中的原值仍可用于调试（不落盘）' 'has-secret' 'in-memory-only'

# ---------------------------------------------------------------- 汇总
$failed = @($checks | Where-Object { -not $_.ok })
$report = [ordered]@{
    kind = 'capture-self-test'
    runId = $runId
    at = (Get-Date).ToUniversalTime().ToString('o')
    host = $env:COMPUTERNAME
    powershell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.VersionString
    psExe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    total = $checks.Count
    passed = $checks.Count - $failed.Count
    failed = $failed.Count
    checks = @($checks)
}
[IO.File]::WriteAllText($ReportPath, (($report | ConvertTo-Json -Depth 8) + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("##RESULT capture-selftest total={0} passed={1} failed={2}" -f $checks.Count, ($checks.Count - $failed.Count), $failed.Count)
Write-Host ("report: " + (Resolve-Path -LiteralPath $ReportPath).ProviderPath)
if ($failed.Count -gt 0) { exit 1 }
exit 0
