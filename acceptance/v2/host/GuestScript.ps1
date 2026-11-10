#requires -Version 5.1
<#
  acceptance\v2\host\GuestScript.ps1 — 来宾脚本模板与取回

  设计要点（都是从上一轮失败里学到的）：
  - 来宾程序通过 vmrun runProgramInGuest 运行时，**stdout/stderr 不会被回传到宿主机**，
    因此所有结果都必须自己落盘，再由宿主机 copyFileFromGuestToHost 取回。
  - 因此模板必须“无论主体怎么失败都落盘”：外层 try/catch 把异常写进 JSON，
    末尾显式 exit 0，让宿主机按 JSON 内容判断，而不是按退出码猜。
  - 生成出来的完整代码要作为证据落盘（<evidence>\<name>.guest.ps1），
    这样“宿主机以为自己发了什么”和“来宾实际收到什么”可以对照。
  - 取回失败时用 POST 回执兜底（服务器把上传物落在 evidence\<runId>\<phase>\ 下）。
#>

function New-MwGuestScriptCode {
    <# 组装来宾脚本全文。主体用 $R 收集字段；模板负责落盘、POST 回执、异常兜底、exit 0。 #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$GuestDir,
        [Parameter(Mandatory)][string]$Body,
        [string]$EvidenceUrl = '',
        [string]$RunId = '',
        [string]$Phase = 'channel'
    )
    $postBlock = ''
    if ($EvidenceUrl -and $RunId) {
        $postBlock = @"
try {
  `$bodyBytes = [IO.File]::ReadAllBytes(`$out)
  `$resp = Invoke-WebRequest -Uri '$EvidenceUrl/upload/$RunId/$Phase/$Name.json' -Method Post -Body `$bodyBytes -ContentType 'application/json' -TimeoutSec 60 -UseBasicParsing
  `$status = `$resp.StatusCode
} catch {
  `$status = 'ERROR:' + `$_.Exception.Message
}
"@
    } else {
        $postBlock = "`$status = 'skipped'"
    }
    $code = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$name = '$Name'
`$dir = '$GuestDir'
`$R = [ordered]@{ name = `$name; ok = `$false; data = [ordered]@{}; error = ''; stack = ''; startedUtc = (Get-Date).ToUniversalTime().ToString('o') }
try {
  New-Item -ItemType Directory -Force -Path `$dir | Out-Null
} catch {
  # 连目录都建不了：仍然尽量把错误落到 TEMP，宿主机取不回时至少 POST 能兜底
  `$dir = `$env:TEMP
}
try {
$Body
} catch {
  `$R.error = `$_.Exception.Message
  `$R.stack = `$_.ScriptStackTrace
}
`$R['endedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
`$out = Join-Path `$dir (`$name + '.json')
try {
  (`$R | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath `$out -Encoding UTF8
  `$R['sha256'] = (Get-FileHash -LiteralPath `$out -Algorithm SHA256).Hash.ToLower()
  `$R['path'] = `$out
  (`$R | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath `$out -Encoding UTF8
} catch {
  `$out = Join-Path `$env:TEMP (`$name + '.json')
  (`$R | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath `$out -Encoding UTF8
}
$postBlock
try { (`$R | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (`$out + '.result.json') -Encoding UTF8 } catch { }
'##GUEST-DONE ' + `$name + ' ok=' + `$R.ok + ' err=' + `$R.error
exit 0
"@
    # 生成后立刻用同一个 PowerShell 解析器做语法检查：模板/转义错误要在宿主机就暴露，
    # 不能等来宾里 exit 1 才去猜（上一轮 T1 就是因为 `$id` 未转义生成成空括号而整段不执行）。
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $msg = ($parseErrors | ForEach-Object { 'L' + $_.Extent.StartLineNumber + ': ' + $_.Message }) -join '; '
        throw ('来宾脚本生成后语法错误（夹具缺陷）：' + $msg)
    }
    return $code
}

function Invoke-MwGuestScript {
    <# 生成→落盘代码→执行→取回 JSON（失败时用 HTTP 回执兜底）。 #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$GuestDir,
        [Parameter(Mandatory)][string]$EvidenceDir,
        [string]$EvidenceUrl = '',
        [string]$RunId = '',
        [string]$Phase = 'channel',
        [int]$TimeoutSeconds = 300
    )
    $code = New-MwGuestScriptCode -Name $Name -GuestDir $GuestDir -Body $Body -EvidenceUrl $EvidenceUrl -RunId $RunId -Phase $Phase
    $codePath = Join-Path $EvidenceDir ($Name + '.guest.ps1')
    [IO.File]::WriteAllText($codePath, $code, (New-Object Text.UTF8Encoding($true)))
    $rec = Invoke-MwGuestPowerShellText -Code $code -TimeoutSeconds $TimeoutSeconds -Label ('guest-' + $Name)
    $guestFile = Join-Path $GuestDir ($Name + '.json')
    $hostFile = Join-Path $EvidenceDir ($Name + '.json')
    $fetched = $false
    try {
        Copy-MwFileFromGuest -GuestPath $guestFile -HostPath $hostFile | Out-Null
        $fetched = Test-Path -LiteralPath $hostFile
    } catch { $fetched = $false }
    $obj = $null
    if ($fetched) { try { $obj = Get-Content -LiteralPath $hostFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null } }
    return [pscustomobject]@{
        name = $Name; record = $rec; fetched = $fetched; file = $hostFile; obj = $obj
        codePath = $codePath; exitCode = $rec.exitCode; stdoutText = $rec.stdoutText; stderrText = $rec.stderrText
    }
}
