# 冥零工作台 · 旧装组件入口（转发壳）
#
# V3.1.0 起，装组件的逻辑只有一份：tools\bootstrap.ps1（清单 tools\components.json）。
# 老教程、老快捷方式里的 auto-setup.ps1 调用原样留着，本脚本只把参数翻译成
# bootstrap.ps1 的 -Component / -Exclude，然后原样转发输出与退出码。
# 想加组件、改下载源、改校验，都去改清单和 bootstrap.ps1，不要往这里加第二套逻辑。
#
# 兼容参数（与 V3.0.0 一致）：
#   -Workspace <dir> -Bots <dir> [-Base <dir>] [-Force]
#   [-SkipOllama] [-SkipSnowLuma] [-SkipBreeze] [-SkipAstrBot] [-SkipWhale]
#   [-Offline] [-Proxy <url>]
#
# 例：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\auto-setup.ps1 `
#       -Workspace "<工作区>" -Bots "<工作区>\bots" -Base "<工作区>"
#
# 退出码与 bootstrap.ps1 相同：0=全部到位，2=有缺项，1=脚本自身出错。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$Bots,
    [string]$Base = '',
    [switch]$Force,
    [switch]$SkipOllama,
    [switch]$SkipSnowLuma,
    [switch]$SkipBreeze,
    [switch]$SkipAstrBot,
    [switch]$SkipWhale,
    [switch]$Offline,
    [string]$Proxy = ''
)

$ErrorActionPreference = 'Stop'

$bootstrap = Join-Path $PSScriptRoot 'bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrap)) {
    Write-Host ('没找到 ' + $bootstrap + '（这一版没带 bootstrap.ps1）')
    exit 1
}

# 老入口装的五个组件 + 启动脚本；依赖（node/uv/python）由 bootstrap 按清单自动展开。
$want = New-Object System.Collections.ArrayList
foreach ($id in @('uv', 'astrbot', 'snowluma', 'breeze', 'ollama', 'bili-whale', 'bots-launchers')) {
    [void]$want.Add($id)
}
$skip = New-Object System.Collections.ArrayList
if ($SkipOllama) { [void]$skip.Add('ollama'); [void]$skip.Add('embedding-model') }
if ($SkipSnowLuma) { [void]$skip.Add('snowluma') }
if ($SkipBreeze) { [void]$skip.Add('breeze') }
if ($SkipAstrBot) { [void]$skip.Add('astrbot') }
if ($SkipWhale) { [void]$skip.Add('bili-whale') }

if (-not $Base) { $Base = $Workspace }

$argv = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $bootstrap,
    '-Base', $Base,
    '-Workspace', $Workspace,
    '-Bots', $Bots,
    '-Component', ($want -join ',')
)
if ($skip.Count -gt 0) { $argv += @('-Exclude', ($skip -join ',')) }
if ($Force) { $argv += '-Force' }
if ($Offline) { $argv += '-Offline' }
if ($Proxy) { $argv += @('-Proxy', $Proxy) }

Write-Host 'auto-setup.ps1 已并入 bootstrap.ps1，本次转发（装组件逻辑只有一份）。'
& powershell.exe @argv
exit $LASTEXITCODE
