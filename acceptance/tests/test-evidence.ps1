#requires -Version 5.1
<#
  acceptance\tests\test-evidence.ps1 — 证据机制自测（不依赖虚拟机）

  覆盖用户要求里"结果与证据机制"那几条：
    E1 上传成功：HTTP 200、回执 sha256/bytes 与本机文件一致、落盘字节可复核
    E2 上传篡改：X-MW-Sha256 与服务端实收不一致 → 服务端 409，客户端不得记 ok
    E3 Save-MwPhase 结构：phase.json / results.jsonl / commands.jsonl / manifest.json / manifest.sha256
    E4 manifest 里每个文件的 SHA256 与实际字节一致
    E5 退出码优先级：fail-fixture(11) > fail-product(10) > blocked-precondition(12) > blocked-env(13) > evidence-incomplete(14)
    E6 pass 降级：没有前置条件 / 没有证据路径的 pass 必须变 evidence-incomplete
    E7 脱敏：落盘 JSON 不含 _ 前缀内部字段，命令行里口令被 *** 替换
    E8 run-id 隔离：两个 run 的证据目录互不覆盖，回执分别记录

  用法：powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\tests\test-evidence.ps1
  退出码：0 全通过；1 有失败。
#>
param([int]$Port = 0)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$accept = Split-Path -Parent $here
. (Join-Path $accept 'lib\Evidence.ps1')
. (Join-Path $accept 'lib\Check.ps1')
. (Join-Path $accept 'lib\Capture.ps1')

$checks = New-Object System.Collections.ArrayList
function Assert-Check([string]$Id, [bool]$Ok, [string]$Detail, $Expected = $null, $Actual = $null, $Evidence = $null) {
    [void]$checks.Add([ordered]@{ id = $Id; ok = $Ok; detail = $Detail; expected = $Expected; actual = $Actual; evidence = $Evidence })
    Write-Host ("[{0}] {1} - {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Id, $Detail)
}

if ($Port -le 0) {
    # 端口可能被系统保留/占用（实测 8123 被占用且 0.0.0.0 绑定报 10013），这里让系统分配
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
    $l.Start()
    $Port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
}
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$work = Join-Path $env:TEMP ('mw-evidence-test-' + $stamp)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$baseUrl = 'http://127.0.0.1:' + $Port

# ---------------------------------------------------------------- 起服务
$py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
if (-not $py) { Write-Host '找不到 python，无法自测证据服务'; exit 2 }
$serverScript = Join-Path $accept 'v2\host\EvidenceServer.py'
$so = Join-Path $work 'server.out.log'; $se = Join-Path $work 'server.err.log'
$proc = Start-Process -FilePath $py -ArgumentList @($serverScript, "$Port") -PassThru -WindowStyle Hidden -RedirectStandardOutput $so -RedirectStandardError $se
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 300
    try { $h = Invoke-WebRequest -Uri ($baseUrl + '/health') -TimeoutSec 3 -UseBasicParsing; if ($h.StatusCode -eq 200) { $ready = $true; break } } catch { }
}
Assert-Check 'E0.server' $ready '证据服务可用（/health 200）' '200' $(if ($ready) { '200' } else { 'unreachable' }) $se
if (-not $ready) { try { $proc.Kill() } catch { }; Write-Host '##RESULT evidence-selftest total=1 passed=0 failed=1'; exit 1 }

try {
    $runA = 'selftest-evidence-a-' + $stamp
    $runB = 'selftest-evidence-b-' + $stamp
    $evA = Join-Path $accept ('evidence\' + $runA)
    $evB = Join-Path $accept ('evidence\' + $runB)

    # ------------------------------------------------------------ E1 正常上传
    $f1 = Join-Path $work 'payload.json'
    [IO.File]::WriteAllText($f1, ('{"msg":"中文证据","n":1}'), (New-Object Text.UTF8Encoding($false)))
    $u1 = $baseUrl + '/upload/' + $runA + '/channel/payload.json'
    $r1 = Send-MwEvidence -Path $f1 -Url $u1
    $landed = Join-Path $evA 'channel\payload.json'
    $landedOk = $false; $landedSha = ''
    if (Test-Path -LiteralPath $landed) {
        $landedSha = Get-MwSha256 -Path $landed
        $landedOk = ($landedSha -eq $r1.localSha256)
    }
    Assert-Check 'E1.upload-ok' ($r1.ok -and $r1.httpStatus -eq 200 -and $landedOk) `
        ('上传 HTTP=' + $r1.httpStatus + '，本机与落盘 SHA256 一致=' + $landedOk + '，回执字节=' + $r1.ackBytes) `
        200 $r1.httpStatus $landed

    # ------------------------------------------------------------ E2 哈希不符必须拒绝
    $u2 = $baseUrl + '/upload/' + $runA + '/channel/bad.json'
    $r2 = Send-MwEvidence -Path $f1 -Url $u2
    # 客户端用正确哈希，服务端只会 200；要制造不符，直接 curl 一个错误头
    $badBody = Join-Path $work 'bad-ack.json'
    $code2 = & curl.exe -sS -o $badBody -w '%{http_code}' -X POST --data-binary "@$f1" -H 'X-MW-Sha256: 0000000000000000000000000000000000000000000000000000000000000000' $u2 2>&1
    $code2n = [int](("$code2").Trim() -replace '[^0-9]', '')
    $ack2 = $null
    try { $ack2 = Get-Content -LiteralPath $badBody -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Assert-Check 'E2.tamper-rejected' ($code2n -eq 409 -and $ack2 -and -not $ack2.ok) `
        ('哈希不符时服务端返回 ' + $code2n + '（期望 409），回执 ok=' + $(if ($ack2) { $ack2.ok } else { 'n/a' })) 409 $code2n $badBody

    # ------------------------------------------------------------ E3/E4 Save-MwPhase + manifest
    $res = @(
        (New-MwCheck -Id 'demo-pass' -Criterion 1 -Requirement '示例' -Preconditions @('前置A') -Steps @('步骤1') `
            -Assertion '断言' -Expected 'x' -Actual 'x' -Evidence @($f1) -Status 'pass' -Detail 'ok')
        (New-MwCheck -Id 'demo-fail' -Criterion 2 -Requirement '示例失败' -Preconditions @('前置B') -Steps @('步骤2') `
            -Assertion '断言' -Expected 'y' -Actual 'z' -Evidence @($f1) -Status 'fail-product' -Detail '产品失败' `
            -Data @{ extra = 'v' })
    )
    $cmds = @([ordered]@{ label = 'demo-cmd'; exitCode = 0; startedUtc = 'x'; endedUtc = 'y' })
    $saved = Save-MwPhase -RunDir $evA -Phase 'selftest' -Summary ([ordered]@{ phase = 'selftest'; ok = $false }) -Results $res -Commands $cmds
    $filesOk = @('phase.json', 'results.jsonl', 'commands.jsonl', 'manifest.json', 'manifest.json.sha256') | ForEach-Object {
        Test-Path -LiteralPath (Join-Path $saved.dir $_)
    }
    Assert-Check 'E3.phase-structure' (@($filesOk | Where-Object { -not $_ }).Count -eq 0) ('phase 目录文件齐全=' + (@($filesOk | Where-Object { $_ }).Count) + '/5') 5 (@($filesOk | Where-Object { $_ }).Count) $saved.dir

    $man = Get-Content -LiteralPath (Join-Path $saved.dir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($man.files)
    $manBad = @()
    foreach ($e in $entries) {
        $p = Join-Path $saved.dir $e.path
        if (-not (Test-Path -LiteralPath $p)) { $manBad += ($e.path + ':missing'); continue }
        $sha = Get-MwSha256 -Path $p
        if ($sha -ne $e.sha256) { $manBad += ($e.path + ':sha') }
        if ((Get-Item -LiteralPath $p).Length -ne [int]$e.bytes) { $manBad += ($e.path + ':bytes') }
    }
    $manShaFile = Get-Content -LiteralPath (Join-Path $saved.dir 'manifest.json.sha256') -Raw -Encoding UTF8
    $manHashOk = ($manShaFile -match [regex]::Escape((Get-MwSha256 -Path (Join-Path $saved.dir 'manifest.json'))))
    Assert-Check 'E4.manifest-hashes' ((@($manBad).Count -eq 0) -and $manHashOk -and $entries.Count -ge 3) `
        ('manifest 条目 ' + $entries.Count + '，逐文件 SHA256 校验异常=' + @($manBad).Count + '，manifest.json.sha256 自校验=' + $manHashOk) 0 @($manBad).Count (Join-Path $saved.dir 'manifest.json')

    # ------------------------------------------------------------ E5 退出码优先级
    $fixture = @((New-MwCheck -Id 'x' -Criterion 1 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'fail-fixture' -Detail 'd'))
    $product = @((New-MwCheck -Id 'x' -Criterion 1 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'fail-product' -Detail 'd'))
    $pre = @((New-MwCheck -Id 'x' -Criterion 1 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'blocked-precondition' -Detail 'd'))
    $envb = @((New-MwCheck -Id 'x' -Criterion 1 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'blocked-env' -Detail 'd'))
    $evi = @((New-MwCheck -Id 'x' -Criterion 1 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'evidence-incomplete' -Detail 'd'))
    $mixed = @($evi[0], $product[0])
    $codes = [ordered]@{
        fixture = Get-MwPhaseExitCode -Results $fixture
        product = Get-MwPhaseExitCode -Results $product
        pre = Get-MwPhaseExitCode -Results $pre
        env = Get-MwPhaseExitCode -Results $envb
        evidence = Get-MwPhaseExitCode -Results $evi
        mixed = Get-MwPhaseExitCode -Results $mixed
        clean = Get-MwPhaseExitCode -Results @($res[0])
    }
    $codesOk = ($codes.fixture -eq 11 -and $codes.product -eq 10 -and $codes.pre -eq 12 -and $codes.env -eq 13 -and $codes.evidence -eq 14 -and $codes.mixed -eq 10 -and $codes.clean -eq 0)
    Assert-Check 'E5.exit-precedence' $codesOk ('退出码 ' + (($codes.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ')) 'fixture=11 product=10 pre=12 env=13 evidence=14 mixed=10 clean=0' ($codes | ConvertTo-Json -Compress) $saved.dir

    # ------------------------------------------------------------ E6 pass 降级
    $bare = New-MwCheck -Id 'bare-pass' -Criterion 3 -Requirement 'r' -Preconditions @() -Steps @('s') -Assertion 'a' -Evidence @() -Status 'pass' -Detail 'd'
    $fakeEv = New-MwCheck -Id 'fake-evidence' -Criterion 3 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @((Join-Path $work 'nope.txt')) -Status 'pass' -Detail 'd'
    $reallyOk = New-MwCheck -Id 'real-pass' -Criterion 3 -Requirement 'r' -Preconditions @('p') -Steps @('s') -Assertion 'a' -Evidence @($f1) -Status 'pass' -Detail 'd'
    Assert-Check 'E6.pass-downgrade' ($bare.status -eq 'evidence-incomplete' -and $fakeEv.status -eq 'evidence-incomplete' -and $reallyOk.status -eq 'pass') `
        ('缺前置→' + $bare.status + '，缺证据→' + $fakeEv.status + '，齐全→' + $reallyOk.status) 'evidence-incomplete/evidence-incomplete/pass' ($bare.status + '/' + $fakeEv.status + '/' + $reallyOk.status) $saved.dir

    # ------------------------------------------------------------ E7 脱敏
    $rec = New-CaptureRecord -Label 'redact-demo' -Kind 'exe' -File 'x.exe' -Arguments @('--token', 'abc123', '/PASSWORD=topsecret') -CommandLine 'x.exe --token abc123 /PASSWORD=topsecret'
    $rec | Add-Member -NotePropertyName _internal -NotePropertyValue 'drop-me' -Force
    $p7 = Join-Path $evA 'channel\rec.json'
    Save-MwJson -Path $p7 -Object $rec
    $txt7 = Get-Content -LiteralPath $p7 -Raw -Encoding UTF8
    $redacted = ($txt7 -notmatch 'abc123') -and ($txt7 -notmatch 'topsecret') -and ($txt7 -notmatch '_internal')
    Assert-Check 'E7.redaction' $redacted '落盘记录不含明文口令，也不含 _ 前缀内部字段' 'no-secret' $(if ($redacted) { 'clean' } else { 'leak' }) $p7

    # ------------------------------------------------------------ E8 run-id 隔离
    $f8 = Join-Path $work 'payload-b.json'
    [IO.File]::WriteAllText($f8, '{"run":"b"}', (New-Object Text.UTF8Encoding($false)))
    $r8 = Send-MwEvidence -Path $f8 -Url ($baseUrl + '/upload/' + $runB + '/channel/payload.json')
    $aHas = Test-Path -LiteralPath (Join-Path $evA 'channel\payload.json')
    $bHas = Test-Path -LiteralPath (Join-Path $evB 'channel\payload.json')
    $recA = (Test-Path -LiteralPath (Join-Path $evA 'receipts.jsonl'))
    $recB = (Test-Path -LiteralPath (Join-Path $evB 'receipts.jsonl'))
    $shaA = if ($aHas) { Get-MwSha256 -Path (Join-Path $evA 'channel\payload.json') } else { '' }
    $shaB = if ($bHas) { Get-MwSha256 -Path (Join-Path $evB 'channel\payload.json') } else { '' }
    $isolated = ($aHas -and $bHas -and $recA -and $recB -and $shaA -ne $shaB)
    Assert-Check 'E8.run-isolation' $isolated ('两个 run 各自落盘且互不覆盖（A=' + $shaA.Substring(0, [Math]::Min(12, $shaA.Length)) + ' B=' + $shaB.Substring(0, [Math]::Min(12, $shaB.Length)) + '）') 'distinct' $(if ($isolated) { 'distinct' } else { 'collision' }) $evB
}
finally {
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}

$total = $checks.Count
$passed = @($checks | Where-Object { $_.ok }).Count
$reportDir = Join-Path $accept 'evidence\self-test'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = [ordered]@{
    suite = 'evidence-selftest'; runId = ('selftest-evidence-' + $stamp); utc = (Get-Date).ToUniversalTime().ToString('o')
    total = $total; passed = $passed; failed = ($total - $passed); checks = @($checks); server = @{ port = $Port; stdout = $so; stderr = $se }
}
$reportPath = Join-Path $reportDir ('selftest-evidence-' + $stamp + '.json')
Save-MwJson -Path $reportPath -Object $report
Write-Host ''
Write-Host ('##RESULT evidence-selftest total=' + $total + ' passed=' + $passed + ' failed=' + ($total - $passed))
Write-Host ('report: ' + $reportPath)
if ($passed -eq $total) { exit 0 } else { exit 1 }
