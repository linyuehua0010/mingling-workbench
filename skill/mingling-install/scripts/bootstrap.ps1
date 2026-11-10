#requires -Version 5.1
# 技能侧统一入口：解析安装程序目录，再把参数原样交给同一个 tools\bootstrap.ps1。
# 不要求用户把 bootstrap 复制到工作区，也不维护第二份安装逻辑。
$ErrorActionPreference = 'Stop'
$resolver = Join-Path $PSScriptRoot 'resolve-program-root.ps1'
$program = (& $resolver).Trim()
if (-not $program) { exit 2 }
$bootstrap = Join-Path $program 'tools\bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
    [Console]::Error.WriteLine("程序目录里没有 bootstrap.ps1：$bootstrap")
    exit 2
}
Write-Output ("##BOOTSTRAP " + $bootstrap)
& $bootstrap @args
exit $LASTEXITCODE
