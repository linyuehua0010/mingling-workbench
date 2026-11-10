#requires -Version 5.1
<#
  安装器覆盖前备份。只读源程序目录，不进入 bots/private/secrets/out/logs，
  也不备份 旧版/ 自身。退出码：0 成功或无需备份，3 参数错误，4 备份失败。
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$Reason = 'install'
)
$ErrorActionPreference = 'Stop'
$AppDir = [IO.Path]::GetFullPath($AppDir).TrimEnd('\')
$Workspace = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if (-not (Test-Path -LiteralPath $AppDir -PathType Container)) { exit 0 }

$existing = @('MinglingWorkbench.exe', 'unins000.exe', 'unins000.dat', 'MinglingWorkbench.new.exe') |
    ForEach-Object { Join-Path $AppDir $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($existing.Count -eq 0) { exit 0 }

$older = Join-Path $Workspace '旧版'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $older ('install-backup-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$protected = @('bots', 'private', 'secrets', 'out', 'logs', '旧版')
$files = New-Object System.Collections.ArrayList
try {
    foreach ($item in @(Get-ChildItem -LiteralPath $AppDir -File -Force -Recurse -ErrorAction Stop)) {
        $relative = $item.FullName.Substring($AppDir.Length).TrimStart('\')
        $top = ($relative -split '\\')[0]
        if ($protected -contains $top) { continue }
        if ($item.Name -eq 'MinglingWorkbench.new.exe') { continue }
        $target = Join-Path $dest $relative
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        [void]$files.Add([pscustomobject]@{
            path = $relative.Replace('\', '/')
            size = [long]$item.Length
            lastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    if ($files.Count -eq 0) { exit 0 }
    $manifest = [ordered]@{
        schema = 1
        reason = $Reason
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        appDir = $AppDir
        workspace = $Workspace
        excludedRoots = $protected
        fileCount = $files.Count
        files = $files
    }
    [IO.File]::WriteAllText((Join-Path $dest 'backup-manifest.json'), (($manifest | ConvertTo-Json -Depth 6) + "`n"), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $older 'last-install-backup.txt'), $dest + "`r`n", (New-Object Text.UTF8Encoding($false)))
    exit 0
} catch {
    try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'mingling-backup-error.txt'), ($_.Exception.ToString() + "`r`n"), (New-Object Text.UTF8Encoding($false))) } catch {}
    exit 4
}
