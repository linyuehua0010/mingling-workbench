# 抓取安装包需要的两个大件：node.exe 和 ffmpeg.exe
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\fetch-runtime.ps1
#   powershell ... -File tools\fetch-runtime.ps1 -NodeExe D:\node\node.exe -FfmpegExe D:\ff\ffmpeg.exe
param(
    [string]$NodeExe = "",
    [string]$FfmpegExe = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$nodeDst = Join-Path $repo "sidecar\node\node.exe"
$ffDst = Join-Path $repo "sidecar\bili-whale\bin\ffmpeg.exe"
$tmp = Join-Path $env:TEMP ("mingling-runtime-" + [guid]::NewGuid().ToString("N"))

function Say($msg) { Write-Host "[runtime] $msg" }

if (-not (Test-Path (Join-Path $repo "sidecar\bili-whale\tools\bili.mjs"))) {
    throw "sidecar\bili-whale 不在。请先把 MIT 许可的 dsh-bili-whale 包放到 sidecar\bili-whale（见 docs\THIRD-PARTY.md）。"
}

New-Item -ItemType Directory -Force -Path (Split-Path $nodeDst), (Split-Path $ffDst), $tmp | Out-Null

if ((Test-Path $nodeDst) -and -not $Force) {
    Say "node.exe 已存在，跳过（-Force 可重下）"
} elseif ($NodeExe) {
    Copy-Item $NodeExe $nodeDst -Force
    Say "已复制本地 node：$NodeExe"
} else {
    Say "从 nodejs.org 选最新 LTS ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $index = Invoke-RestMethod "https://nodejs.org/dist/index.json" -UseBasicParsing
    $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
    if (-not $lts) { throw "拿不到 node 版本列表" }
    $url = "https://nodejs.org/dist/$($lts.version)/win-x64/node.exe"
    Say "下载 $url"
    Invoke-WebRequest $url -OutFile $nodeDst -UseBasicParsing
}

if ((Test-Path $ffDst) -and -not $Force) {
    Say "ffmpeg.exe 已存在，跳过（-Force 可重下）"
} elseif ($FfmpegExe) {
    Copy-Item $FfmpegExe $ffDst -Force
    Say "已复制本地 ffmpeg：$FfmpegExe"
} else {
    $zip = Join-Path $tmp "ffmpeg.zip"
    $url = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    Say "下载 $url（约 90MB）"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $exe) { throw "压缩包里没找到 ffmpeg.exe" }
    Copy-Item $exe.FullName $ffDst -Force
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Say ("node.exe   {0:N0} MB" -f ((Get-Item $nodeDst).Length / 1MB))
Say ("ffmpeg.exe {0:N0} MB" -f ((Get-Item $ffDst).Length / 1MB))
Say "完成。现在可以运行 build.bat 和 installer\build-installer.bat。"
