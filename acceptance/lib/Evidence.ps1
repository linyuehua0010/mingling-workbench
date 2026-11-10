#requires -Version 5.1
<#
  acceptance\lib\Evidence.ps1 — 运行编号、阶段落盘、证据清单、上传回收（主机与来宾共用）。

  设计约束（对应本轮问题）：
  * 每次运行一个独立 run-id，绝不覆盖旧证据：evidence\<run-id>\...，同一 run 内按阶段分目录。
  * 落盘前递归去掉下划线开头的字段（Capture 的 _commandLineRaw 等只在内存里存在）。
  * 每个阶段独立落盘并上传；失败也要落盘（调用方在 finally 里调 Save-MwPhase）。
  * 上传必须校验：HTTP 状态码 + 本机文件 SHA256 + 回执里的 sha256/bytes。
  * 清单 manifest.json 覆盖 run 目录下所有文件，另写 manifest.sha256。
#>

function New-MwRunId {
    param([string]$Prefix = 'v310')

    $suffix = -join ((48..57) + (97..102) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    return ('{0}-{1}-{2}' -f $Prefix, (Get-Date).ToString('yyyyMMdd-HHmmss'), $suffix)
}

function ConvertTo-MwSafeObject {
    <# 递归投影：丢掉下划线开头的键，把 OrderedDictionary / PSCustomObject 统一成可 JSON 化的结构。 #>
    param($InputObject, [int]$Depth = 0)

    if ($Depth -gt 24) { return '<max-depth>' }
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal]) { return $InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $InputObject.Keys) {
            if ([string]$k -like '_*') { continue }
            $o[[string]$k] = ConvertTo-MwSafeObject -InputObject $InputObject[$k] -Depth ($Depth + 1)
        }
        return $o
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $arr = @()
        foreach ($i in $InputObject) { $arr += ConvertTo-MwSafeObject -InputObject $i -Depth ($Depth + 1) }
        # 逗号不能省：PowerShell 的函数返回会展开数组，单元素数组会被压成标量、
        # 空数组会变成 $null，进而让 JSON 里 {"problems":[]} 变成 {}、
        # 单条检查的 evidence 数组变成一个字符串（b18 的 11 条 evidence-incomplete 另一层根因）。
        return ,$arr
    }
    if ($InputObject -is [psobject]) {
        $o = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $o[$p.Name] = ConvertTo-MwSafeObject -InputObject $p.Value -Depth ($Depth + 1)
        }
        return $o
    }
    return [string]$InputObject
}

function Save-MwJson {
    param([Parameter(Mandatory)][string]$Path, $Object, [int]$Depth = 24, [switch]$NoSafe)

    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $safe = if ($NoSafe) { $Object } else { ConvertTo-MwSafeObject -InputObject $Object }
    [IO.File]::WriteAllText($Path, (($safe | ConvertTo-Json -Depth $Depth) + "`n"), (New-Object Text.UTF8Encoding($false)))
    # 注意：故意不输出 $Path。调用方若需要路径请自行拼；输出路径会让 `$p = Save-EvidenceJson ...`
    # 之类调用得到 @(路径,路径) 的双元素数组，进而把 -Evidence 数组压成 'p p' 一个字符串（b18 的 11 条 evidence-incomplete 根因）。
    return
}

function Add-MwJsonLine {
    <# 追加一行 JSON（results.jsonl / commands.jsonl），便于边跑边落盘、崩溃后仍可读。 #>
    param([Parameter(Mandatory)][string]$Path, $Object, [int]$Depth = 24)

    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $safe = ConvertTo-MwSafeObject -InputObject $Object
    $line = ($safe | ConvertTo-Json -Compress -Depth $Depth)
    [IO.File]::AppendAllText($Path, $line + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-MwSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-MwManifest {
    <# 给一个 run 目录生成证据清单：相对路径/字节/SHA256 + 清单自身 SHA256。 #>
    param([Parameter(Mandatory)][string]$Root, [string]$ManifestName = 'manifest.json')

    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $files = New-Object System.Collections.ArrayList
    foreach ($f in Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\')
        if ($rel -eq $ManifestName -or $rel -eq ($ManifestName + '.sha256')) { continue }
        [void]$files.Add([ordered]@{
            path = $rel
            bytes = $f.Length
            sha256 = $(try { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } catch { 'UNAVAILABLE: ' + $_.Exception.Message })
        })
    }
    $manifest = [ordered]@{
        root = $rootFull
        at = (Get-Date).ToUniversalTime().ToString('o')
        count = $files.Count
        files = @($files)
    }
    $mp = Join-Path $rootFull $ManifestName
    Save-MwJson -Path $mp -Object $manifest
    $sha = Get-MwSha256 -Path $mp
    [IO.File]::WriteAllText($mp + '.sha256', ($sha + '  ' + $ManifestName + "`n"), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ manifestPath = $mp; manifestSha256 = $sha; count = $files.Count }
}

function Send-MwEvidence {
    <#
      上传单个文件到证据服务，并校验三件事：HTTP 状态码 2xx、本机文件 SHA256、回执里的 sha256/bytes。
      旧夹具忽略 HTTP 状态且服务端永远 200，导致“上传成功”无法证明；这里把失败原因记进返回值。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 300
    )

    $res = [ordered]@{
        path = $Path; url = $Url; httpStatus = 0; ok = $false
        localSha256 = ''; localBytes = 0; ack = $null; ackSha256 = ''; ackBytes = -1
        error = ''; at = (Get-Date).ToUniversalTime().ToString('o')
    }
    if (-not (Test-Path -LiteralPath $Path)) { $res.error = '文件不存在'; return $res }
    $res.localSha256 = Get-MwSha256 -Path $Path
    $res.localBytes = (Get-Item -LiteralPath $Path).Length

    $bodyFile = Join-Path $env:TEMP ('mw-upload-' + [guid]::NewGuid().ToString('n') + '.body')
    try {
        $hdr = 'X-MW-Sha256: ' + $res.localSha256
        $code = & curl.exe -sS --max-time $TimeoutSeconds -o $bodyFile -w '%{http_code}' `
            -X POST --data-binary "@$Path" -H $hdr $Url 2>&1
        $codeText = ("$code").Trim()
        $digits = [regex]::Match($codeText, '\b([1-5][0-9][0-9])\b')
        if ($digits.Success) { $res.httpStatus = [int]$digits.Groups[1].Value } else { $res.error = ('HTTP 状态无法解析：' + $codeText) }
    } catch {
        $res.error = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $bodyFile) {
        $res.ack = (Get-Content -LiteralPath $bodyFile -Raw -Encoding UTF8)
        try {
            $obj = $res.ack | ConvertFrom-Json
            if ($obj.sha256) { $res.ackSha256 = [string]$obj.sha256 }
            if ($null -ne $obj.bytes) { $res.ackBytes = [int]$obj.bytes }
        } catch { }
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
    $shaOk = ($res.ackSha256 -eq '' -or $res.ackSha256 -eq $res.localSha256)
    $bytesOk = ($res.ackBytes -lt 0 -or $res.ackBytes -eq $res.localBytes)
    $res.ok = ($res.httpStatus -ge 200 -and $res.httpStatus -lt 300 -and $shaOk -and $bytesOk)
    if (-not $res.ok -and -not $res.error) {
        $res.error = "上传校验未通过 http=$($res.httpStatus) sha=$shaOk bytes=$bytesOk"
    }
    return $res
}

function Save-MwPhase {
    <#
      阶段落盘（成功与失败都要调用）。写 phase.json / results.jsonl / commands.jsonl / manifest.json，
      返回阶段目录，供调用方继续上传。
    #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)]$Summary,
        $Results = @(),
        $Commands = @()
    )

    $dir = Join-Path $RunDir ('phases\' + $Phase)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $resPath = Join-Path $dir 'results.jsonl'
    if (Test-Path -LiteralPath $resPath) { Remove-Item -LiteralPath $resPath -Force }
    foreach ($r in @($Results)) { Add-MwJsonLine -Path $resPath -Object $r }
    $cmdPath = Join-Path $dir 'commands.jsonl'
    if (Test-Path -LiteralPath $cmdPath) { Remove-Item -LiteralPath $cmdPath -Force }
    foreach ($c in @($Commands)) { Add-MwJsonLine -Path $cmdPath -Object $c }
    Save-MwJson -Path (Join-Path $dir 'phase.json') -Object $Summary
    $m = Write-MwManifest -Root $dir -ManifestName 'manifest.json'
    return [pscustomobject]@{ dir = $dir; manifest = $m; resultsPath = $resPath; commandsPath = $cmdPath }
}
