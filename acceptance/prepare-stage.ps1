#requires -Version 5.1
# 从仓库 dist 重新填充 HTTP 验收输入；stage 中不提交大安装包。
$repo = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $PSScriptRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $repo 'dist\MinglingWorkbench-3.1.0-setup.exe') $stage -Force
Copy-Item (Join-Path $repo 'dist\MinglingWorkbench-3.0.0-setup.exe') $stage -Force
foreach ($f in 'components.json', 'astrbot-requirements.txt', 'edge-tts-requirements.txt') {
    Copy-Item (Join-Path $repo ('tools\' + $f)) $stage -Force
}
$files = 'MinglingWorkbench-3.1.0-setup.exe', 'MinglingWorkbench-3.0.0-setup.exe', 'components.json', 'astrbot-requirements.txt', 'edge-tts-requirements.txt'
$lines = foreach ($f in $files) { (Get-FileHash (Join-Path $stage $f) -Algorithm SHA256).Hash.ToLowerInvariant() + ' ' + $f }
[IO.File]::WriteAllLines((Join-Path $stage 'checksums.txt'), $lines, (New-Object Text.UTF8Encoding($false)))
Write-Output $stage
