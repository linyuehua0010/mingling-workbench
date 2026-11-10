#requires -Version 5.1
<#
  安装器最后的原子替换：等待正在运行的旧 exe 退出/解锁，把已验证的 .new 换成正式文件。
  不启动进程、不写入 bots/private/secrets/out/logs。退出码 0 成功，5 等待超时，6 复制/校验失败。
#>
param(
    [Parameter(Mandatory)][string]$AppDir,
    [int]$WaitSeconds = 180,
    [string]$ManifestLog = ''
)
$ErrorActionPreference = 'Stop'
$AppDir = [IO.Path]::GetFullPath($AppDir).TrimEnd('\')
$target = Join-Path $AppDir 'MinglingWorkbench.exe'
$new = Join-Path $AppDir 'MinglingWorkbench.new.exe'
function Note([string]$m) {
    if ($ManifestLog) {
        try {
            $p = Split-Path -Parent $ManifestLog
            if ($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
            Add-Content -LiteralPath $ManifestLog -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
        } catch {}
    }
}
if (-not (Test-Path -LiteralPath $new -PathType Leaf)) { Note '缺少 .new，无法完成替换'; exit 5 }
$expected = (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$copied = $false
while ((Get-Date) -lt $deadline) {
    try {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $stream = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            $stream.Dispose()
        }
        Copy-Item -LiteralPath $new -Destination $target -Force -ErrorAction Stop
        $copied = $true
        break
    } catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $copied) { Note '等待旧程序退出超时，主程序尚未替换'; exit 5 }
$actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
if ($actual -ne $expected) { Note '替换后主程序 SHA256 不符'; exit 6 }
for ($i = 0; $i -lt 20; $i++) {
    try { Remove-Item -LiteralPath $new -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 250 }
}
Note '主程序替换完成'
exit 0
