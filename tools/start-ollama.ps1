# 登录 Windows 时启动本机记忆；显式加载用户环境，兼容中文目录。
param(
    [string]$Base = (Split-Path -Parent $PSScriptRoot),
    [string]$Exe = ''
)
$ErrorActionPreference = 'Stop'
function Test-OllamaReady {
    try { $null = Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 2; return $true }
    catch { return $false }
}
if (Test-OllamaReady) { Write-Output 'Ollama 已在运行'; exit 0 }
if (-not $Exe) {
    $Exe = @("$Base\bots\Ollama\ollama.exe", "$Base\Ollama\ollama.exe",
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe") |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $Exe -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw '找不到 Ollama 程序' }
$userModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
$modelDir = @($userModels, $env:OLLAMA_MODELS, "$Base\bots\ollama-models",
    "$Base\bots\Ollama\models", "$Base\ollama-models") |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 1
if ($modelDir) { $env:OLLAMA_MODELS = $modelDir }
$keepAlive = [Environment]::GetEnvironmentVariable('OLLAMA_KEEP_ALIVE', 'User')
if ($keepAlive) { $env:OLLAMA_KEEP_ALIVE = $keepAlive }
$logDir = Join-Path $Base 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# 严格幂等：服务探测不能持续改写 logs；后台输出丢弃，需要排障时由用户显式用 -LogDir。
# Start-Process 不允许 stdout/stderr 指向同一个文件（会抛 InvalidOperationException），
# 也必须避免在 -Check/幂等复跑时改写工作区文件，所以两个流分开落到 %TEMP%。
$outLog = Join-Path $env:TEMP 'mingling-ollama-serve.out.log'
$errLog = Join-Path $env:TEMP 'mingling-ollama-serve.err.log'
$server = Start-Process -FilePath $Exe -ArgumentList 'serve' -WorkingDirectory (Split-Path -Parent $Exe) `
    -WindowStyle Hidden -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog -PassThru
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if (Test-OllamaReady) { Write-Output 'Ollama 已启动'; exit 0 }
    if ($server.HasExited) { throw "Ollama 启动失败，请查看 $errLog" }
    Start-Sleep -Milliseconds 500
}
throw "Ollama 未就绪，请查看 $errLog"
