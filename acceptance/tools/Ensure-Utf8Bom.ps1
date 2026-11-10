#requires -Version 5.1
<#
  acceptance\tools\Ensure-Utf8Bom.ps1 — 给验收用 .ps1 统一补 UTF-8 BOM。

  Windows PowerShell 5.1 读取没有 BOM 的 UTF-8 脚本时按 ANSI(936) 解码，
  脚本里的中文常量（目录名、断言文案）会被拆成乱码且不报错。实测：
  含 “中文 路径” 的 $cases 经无 BOM 脚本传递后变成 “涓枃 璺緞”。
  所以验收脚本、来宾脚本、复制到来宾的脚本在打包前都要过一遍本脚本。
#>
param(
    [string[]]$Path = @(),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
if ($Path.Count -eq 0) { $Path = @((Split-Path -Parent $PSScriptRoot)) }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$fixed = New-Object System.Collections.ArrayList
$ok = New-Object System.Collections.ArrayList
$bad = New-Object System.Collections.ArrayList

$root = Split-Path -Parent $PSScriptRoot
foreach ($p in $Path) {
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $root $p }
    $files = @()
    if (Test-Path -LiteralPath $p -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.ps1' -Force -ErrorAction SilentlyContinue)
    } elseif (Test-Path -LiteralPath $p) {
        $files = @(Get-Item -LiteralPath $p)
    }
    foreach ($f in $files) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) { [void]$ok.Add($f.FullName); continue }
        # 只处理能按 UTF-8 严格解码的文件，避免把 GBK 文件误转
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try { [void]$strict.GetString($bytes) } catch { [void]$bad.Add($f.FullName + ' (非 UTF-8，未改动)'); continue }
        if ($Check) { [void]$bad.Add($f.FullName + ' (缺 BOM)'); continue }
        $text = $strict.GetString($bytes)
        [IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
        [void]$fixed.Add($f.FullName)
    }
}

[ordered]@{
    ok = @($ok); fixed = @($fixed); problems = @($bad)
} | ConvertTo-Json -Depth 4

if ($bad.Count -gt 0) { exit 1 }
exit 0
