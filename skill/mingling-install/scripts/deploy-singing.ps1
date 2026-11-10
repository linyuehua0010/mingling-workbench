param([string]$Base = '', [string]$Root = '', [ValidateSet('install','start','check','test','voice_existing','voice_breeze')][string]$Action = 'check')
$ErrorActionPreference = 'Stop'
if (-not $Base) {
    $settingsPath = Join-Path $env:APPDATA 'MinglingWorkbench\settings.json'
    if (Test-Path -LiteralPath $settingsPath) { $Base = (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).workspace }
}
if (-not $Base) { throw '未找到工作区，请传入 -Base' }
# 程序和 工作区 分离安装时，脚本在程序目录而不是工作区；先按注册表解析程序目录。
$scriptPath = Join-Path $Base 'tools\setup-singing.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    $resolver = Join-Path $PSScriptRoot 'resolve-program-root.ps1'
    $program = ''
    if (Test-Path -LiteralPath $resolver) { try { $program = (& $resolver -Quiet).Trim() } catch { $program = '' } }
    if ($program) { $scriptPath = Join-Path $program 'tools\setup-singing.ps1' }
}
if (-not (Test-Path -LiteralPath $scriptPath)) { throw ('没有找到本地唱歌部署脚本（工作区与程序目录都找过）：已更新到 V3.1 且程序目录含 tools\setup-singing.ps1 才可部署') }
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Base',$Base,'-Action',$Action)
if ($Root) { $arguments += @('-Root',$Root) }
& powershell.exe @arguments
exit $LASTEXITCODE
