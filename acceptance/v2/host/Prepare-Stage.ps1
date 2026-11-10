#requires -Version 5.1
<#
  acceptance\v2\host\Prepare-Stage.ps1 — 生成本轮阶段分发包（主机侧，可重复执行）

  为什么要新目录：旧 acceptance\stage\checksums.txt 里列了 MinglingWorkbench-3.1.0/3.0.0-setup.exe，
  但目录里实际没有这两个 exe（只有清单和辅助脚本），旧夹具会因此静默降级。这里在 v2\stage 下
  按真实文件重新生成清单，并把"期望指纹"单独固化成 expected.json，任何替换都会被启动检查发现。

  输入：
    dist\MinglingWorkbench-3.1.0-setup.exe     当前待验收构建
    dist\MinglingWorkbench-3.0.0-setup.exe     已发布 V3.0（升级基线）
    tools\components.json                      组件清单（来源完整性核对用）
    .workbuddy\acceptance\*requirements*.txt   锁定文件（若存在）
  输出：
    acceptance\v2\stage\<files> + checksums.json + expected.json
#> 
param(
    [string]$StageDir = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$acceptanceRoot = Split-Path -Parent (Split-Path -Parent $here)
$repo = Split-Path -Parent $acceptanceRoot
if (-not $StageDir) { $StageDir = Join-Path $acceptanceRoot 'v2\stage' }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

$sources = [ordered]@{
    'MinglingWorkbench-3.1.0-setup.exe' = (Join-Path $repo 'dist\MinglingWorkbench-3.1.0-setup.exe')
    'MinglingWorkbench-3.0.0-setup.exe' = (Join-Path $repo 'dist\MinglingWorkbench-3.0.0-setup.exe')
    'components.json'                    = (Join-Path $repo 'tools\components.json')
}
foreach ($pair in @(
    # 权威副本在 tools\ 下（与 components.json 的 source.sha256 一致的才是发布用锁文件）；
    # .workbuddy 下的旧副本 hash 不同，不能拿来当基准。
    @{ name = 'astrbot-requirements.txt'; src = 'tools\astrbot-requirements.txt' },
    @{ name = 'edge-tts-requirements.txt'; src = 'tools\edge-tts-requirements.txt' }
)) {
    $p = Join-Path $repo $pair.src
    if (Test-Path -LiteralPath $p) { $sources[$pair.name] = $p }
}

$entries = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList
foreach ($name in $sources.Keys) {
    $src = $sources[$name]
    if (-not (Test-Path -LiteralPath $src)) { [void]$problems.Add("缺少来源：$src"); continue }
    $dst = Join-Path $StageDir $name
    $srcHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    $copyNeeded = $true
    if ((Test-Path -LiteralPath $dst) -and -not $Force) {
        $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        $copyNeeded = ($dstHash -ne $srcHash)
    }
    if ($copyNeeded) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    $final = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($final -ne $srcHash) { [void]$problems.Add("复制后哈希不符：$name") }
    [void]$entries.Add([ordered]@{
        name   = $name
        bytes  = (Get-Item -LiteralPath $dst).Length
        sha256 = $final
        source = $src
        copied = $copyNeeded
    })
    Write-Host ('  {0,-40} {1,12} {2}' -f $name, (Get-Item -LiteralPath $dst).Length, $final.Substring(0, 16))
}

$manifest = [ordered]@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    stageDir     = (Resolve-Path -LiteralPath $StageDir).ProviderPath
    count        = $entries.Count
    files        = @($entries)
    problems     = @($problems)
}
$manifestPath = Join-Path $StageDir 'checksums.json'
($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
# 期望指纹单独一份：验收启动时用它判断"stage 是否被替换过"，而不是自己跟自己比
($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $StageDir 'expected.json') -Encoding UTF8
# 兼容旧格式的文本清单
$lines = foreach ($e in $entries) { $e.sha256 + '  ' + $e.name }
$lines | Set-Content -LiteralPath (Join-Path $StageDir 'checksums.txt') -Encoding ASCII

Write-Host ''
Write-Host ('##RESULT prepare-stage files=' + $entries.Count + ' problems=' + $problems.Count + ' dir=' + $StageDir)
foreach ($p in $problems) { Write-Host ('[problem] ' + $p) }
if ($problems.Count) { exit 1 } else { exit 0 }
