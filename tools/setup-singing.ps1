# 冥零本地唱歌：独立环境，安装/启动/健康检查/本机试听，不发送 QQ 消息。
param(
    [string]$Base = (Split-Path -Parent $PSScriptRoot),
    [string]$Root = '',
    [ValidateSet('install','start','check','test','voice_existing','voice_breeze')][string]$Action = 'check'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$Base = [IO.Path]::GetFullPath($Base)
$repoRoot = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $repoRoot 'pack\mingling-pack\plugins\astrbot_plugin_dafeiyu_sing\sing_server'
$logDir = Join-Path $Base 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$progressFile = Join-Path $logDir 'singing-progress.json'
$settingsPath = Join-Path $Base 'private\feature-settings.json'
$settings = $null
if (Test-Path -LiteralPath $settingsPath) { $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
if (-not $Root -and $settings.sing.root) { $Root = [string]$settings.sing.root }
if (-not $Root) { $Root = Join-Path $Base 'sing' }  # 和 components.json 的 detect 路径、说明书里的 -Root 保持一致
$Root = [IO.Path]::GetFullPath($Root)
$source = Join-Path $Root 'SoulX-Singer'
$python = Join-Path $Root 'venv\Scripts\python.exe'
$model = Join-Path $Root 'models\SoulX-Singer\model.pt'
$service = Join-Path $Root 'sing_server.py'
$url = 'http://127.0.0.1:18620'
if ($settings.sing.server_url) { $url = ([string]$settings.sing.server_url).TrimEnd('/') }
$serviceUri = [Uri]$url
$servicePort = $serviceUri.Port
function Progress-Step([int]$pct, [string]$text) {
    @{pct=$pct; text=$text; action=$Action} | ConvertTo-Json | Set-Content -LiteralPath $progressFile -Encoding UTF8
    Write-Output "##STEP $pct|$text"
}
function Invoke-Native([string]$program, [string[]]$Arguments) {
    # Windows PowerShell 5.1 把 git/curl 的进度 stderr 包装成错误记录；以退出码判断成败。
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $program @Arguments 2>&1 | ForEach-Object { "$($_)" | Add-Content -LiteralPath "$logDir\singing-install.log" -Encoding UTF8 }
        $nativeCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($nativeCode -ne 0) { throw "命令执行失败（$nativeCode），详情见 logs\singing-install.log" }
}
function Health {
    try {
        $h = Invoke-RestMethod "$url/health" -TimeoutSec 3
        if ($h.ok -and 'soulx' -in $h.backends) { return $h }
    } catch {}
    return $null
}
try {
    if ($Action -eq 'voice_existing' -or $Action -eq 'voice_breeze') {
        if (-not (Test-Path -LiteralPath $python)) { throw '请先部署本地唱歌服务' }
        Progress-Step 5 '准备现有冥零音色的对齐工具'
        $uv = @("$Base\bots\uv\bin\uv.exe", "$Base\uv\bin\uv.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $uv) { $uvCommand = Get-Command uv.exe -ErrorAction SilentlyContinue; if ($uvCommand) { $uv = $uvCommand.Source } }
        if (-not $uv) { throw '找不到 uv，请先补齐运行环境' }
        Invoke-Native $uv @('pip','install','--python',$python,'funasr==1.3.0','modelscope','torch==2.7.1+cu128','torchaudio==2.7.1+cu128','--extra-index-url','https://download.pytorch.org/whl/cu128','--index-strategy','unsafe-best-match')
        Progress-Step 30 '制作冥零唱歌参考，不会创建新音色'
        $voiceArguments = @('-X','utf8',"$PSScriptRoot\prepare-singing-voice.py",'--base',$Base,'--root',$Root)
        if ($Action -eq 'voice_breeze') { $voiceArguments += '--from-breeze' }
        Invoke-Native $python $voiceArguments
        Progress-Step 100 '现有冥零音色已用于本地唱歌'
        Write-Output 'RESULT ok=1 why=现有冥零音色已用于本地唱歌'
        exit 0
    }
    if ($Action -eq 'install') {
        Progress-Step 2 '准备独立的本地唱歌环境'
        New-Item -ItemType Directory -Path $Root,"$Root\models\SoulX-Singer" -Force | Out-Null
        $uv = @("$Base\bots\uv\bin\uv.exe", "$Base\bots\AstrBot\bin\uv.exe", "$Base\uv\bin\uv.exe") |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $uv) { $uvCommand = Get-Command uv.exe -ErrorAction SilentlyContinue; if ($uvCommand) { $uv = $uvCommand.Source } }
        if (-not $uv) { throw '找不到 uv，请先运行工作台的一键自动配置补齐运行环境' }
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $git) { throw '请先安装 Git，再部署本地唱歌服务' }
        if (-not (Test-Path -LiteralPath "$source\.git")) {
            Progress-Step 8 '下载 SoulX-Singer 源码'
            Invoke-Native $git.Source @('clone','--depth','1','https://github.com/Soul-AILab/SoulX-Singer.git',$source)
        }
        if (-not (Test-Path -LiteralPath $python)) { Invoke-Native $uv @('venv',"$Root\venv",'--python','3.10') }
        Progress-Step 18 '安装支持 RTX 50 系列的 PyTorch CUDA 12.8 环境'
        Invoke-Native $uv @('pip','install','--python',$python,'torch==2.7.1','torchaudio==2.7.1','--index-url','https://download.pytorch.org/whl/cu128')
        Progress-Step 42 '安装本地唱歌所需依赖'
        Invoke-Native $uv @('pip','install','--python',$python,'-r',"$assets\requirements.txt",'einops','rotary-embedding-torch','beartype','huggingface-hub<1')
        if (-not (Test-Path -LiteralPath $model) -or (Get-Item -LiteralPath $model).Length -lt 2818092278) {
            Progress-Step 55 '下载 SoulX-Singer 模型（约 2.8 GB，可断点续传）'
            $downloaded = $false
            foreach ($modelUrl in @('https://hf-mirror.com/Soul-AILab/SoulX-Singer/resolve/main/model.pt','https://huggingface.co/Soul-AILab/SoulX-Singer/resolve/main/model.pt')) {
                try {
                    Invoke-Native 'curl.exe' @('-fL','--retry','3','--retry-delay','2','-C','-','-o',"$model.part",$modelUrl)
                    if ((Get-Item -LiteralPath "$model.part").Length -lt 2818092278) { throw '模型文件不完整' }
                    Move-Item -LiteralPath "$model.part" -Destination $model -Force
                    $downloaded = $true; break
                } catch { Write-Output '此下载源未完成，尝试下一源' }
            }
            if (-not $downloaded) { throw '模型下载未完成，已保留断点，再次部署会继续下载' }
        }
        Progress-Step 86 '安装服务文件与参考声音'
        foreach ($name in @('sing_server.py','melodies.py')) { Copy-Item -LiteralPath "$assets\$name" -Destination "$Root\$name" -Force }
        $hasVoice = Test-Path -LiteralPath "$Root\voice\prompt.wav"
        $legacyVoice = $hasVoice -and (Test-Path -LiteralPath "$Root\voice\prompt.json") -and
            ((Get-FileHash -LiteralPath "$Root\voice\prompt.wav").Hash -eq '7CBC3550CBD6021CD590D9027BC1A1283051D8CDDA9FFF043F577AB74A586AEE') -and
            ((Get-FileHash -LiteralPath "$Root\voice\prompt.json").Hash -eq '3B3FB352BB19F0B0C02F9C9468A8AE4D8121307D576646E8A652CBDDBD2C2DA6')
        if ($legacyVoice) {
            $voiceBackup = Join-Path $Base ('旧版\singing-legacy-voice-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $voiceBackup -Force | Out-Null
            Copy-Item -LiteralPath "$Root\voice" -Destination "$voiceBackup\voice" -Recurse
        }
        # 只迁移完整匹配的旧内置参考，保留自定义的音频和标注。
        if (-not $hasVoice -or $legacyVoice) {
            New-Item -ItemType Directory -Path "$Root\voice" -Force | Out-Null
            Get-ChildItem -LiteralPath "$assets\voice" -File | Copy-Item -Destination "$Root\voice" -Force
        }
        # 安装目录自带启动入口，路径始终相对该目录，不依赖 D 盘。
        $launcher = '@echo off' + "`r`n" + '"%~dp0venv\Scripts\python.exe" -X utf8 "%~dp0sing_server.py" --soulx "%~dp0SoulX-Singer" --model "%~dp0models\SoulX-Singer\model.pt" --port ' + $servicePort + "`r`npause`r`n"
        [IO.File]::WriteAllText("$Root\start-singing.cmd", $launcher, (New-Object Text.UTF8Encoding($false)))
        Progress-Step 92 '验证显卡计算与模型代码'
        $env:PYTHONPATH = $source
        Invoke-Native $python @('-X','utf8',"$PSScriptRoot\check-singing-env.py",'--source',$source)
        @{root=$Root; python=$python; model=$model; at=(Get-Date -Format s)} | ConvertTo-Json | Set-Content -LiteralPath "$Root\installed.json" -Encoding UTF8
        Progress-Step 100 '本地唱歌服务部署完成，可启动并试听'
        Write-Output 'RESULT ok=1 why=本地唱歌部署完成 next=启动并试听'
        exit 0
    }
    if ($Action -eq 'start') {
        if (Health) { Progress-Step 100 '本地唱歌已经在运行'; Write-Output 'RESULT ok=1 why=本地唱歌已运行'; exit 0 }
        if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $model) -or -not (Test-Path -LiteralPath $service)) { throw '本地唱歌尚未部署完整，请先点部署本地服务' }
        if (-not $serviceUri.IsLoopback -or $serviceUri.Scheme -ne 'http') { throw '此按钮启动本机 HTTP 服务；远程或 HTTPS 地址请在对应机器启动服务' }
        Progress-Step 10 '加载本地唱歌模型'
        $serverArgs = @('-X','utf8',"`"$service`"",'--soulx',"`"$source`"",'--model',"`"$model`"",'--port',"$servicePort")
        $process = Start-Process -FilePath $python -ArgumentList $serverArgs -WorkingDirectory $Root -WindowStyle Hidden `
            -RedirectStandardOutput "$logDir\singing-server.out.log" -RedirectStandardError "$logDir\singing-server.err.log" -PassThru
        for ($attempt=0; $attempt -lt 120; $attempt++) {
            $h = Health
            if ($h) { Progress-Step 100 ("本地唱歌已运行，设备：" + $h.device); Write-Output 'RESULT ok=1 why=本地唱歌已运行'; exit 0 }
            if ($process.HasExited) { throw '本地唱歌启动失败，请查看 logs\singing-server.err.log' }
            Start-Sleep -Seconds 1
        }
        throw '模型仍未就绪，请查看 logs\singing-server.err.log，稍后检测'
    }
    $health = Health
    if (-not $health) { throw '本地唱歌服务未就绪，请先部署并启动' }
    if ($Action -eq 'test') {
        Progress-Step 15 '正在本机生成试听音频，不发送 QQ 消息'
        $testBody = @{backend='soulx';melody='生日快乐';lyrics=''} | ConvertTo-Json -Compress
        $res = Invoke-RestMethod "$url/sing" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($testBody)) -ContentType 'application/json' -TimeoutSec 540
        if (-not $res.ok -or -not (Test-Path -LiteralPath $res.path)) { throw '未生成有效的本地试听文件' }
        Progress-Step 100 ('试听文件：' + $res.path)
        Write-Output ('RESULT ok=1 why=本地试听生成成功 file=' + $res.path)
    } else {
        Progress-Step 100 ('本地唱歌正常，设备：' + $health.device)
        Write-Output 'RESULT ok=1 why=本地唱歌健康检查通过'
    }
} catch {
    Progress-Step 0 $_.Exception.Message
    Write-Output ('RESULT ok=0 why=' + $_.Exception.Message)
    exit 1
}
