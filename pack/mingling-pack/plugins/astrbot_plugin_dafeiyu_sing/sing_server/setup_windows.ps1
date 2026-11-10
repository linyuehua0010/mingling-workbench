# 冥零本地唱歌部署入口；实现统一在工作台 tools/setup-singing.ps1。
param([string]$Root = '')
$base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..'))
$script = Join-Path $base 'tools\setup-singing.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw '请使用包含 tools/setup-singing.ps1 的完整冥零工作台' }
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Base',$base,'-Action','install')
if ($Root) { $arguments += @('-Root',$Root) }
& powershell.exe @arguments
exit $LASTEXITCODE
