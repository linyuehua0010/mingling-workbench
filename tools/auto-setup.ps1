# 冥零工作台 · 一键把五个组件装进 <工作区>\bots
#
# 谁调：her::BotsSetup()（win32/src/her/her_setup.cpp）用 CreateProcess 拉起，
#       也可以手跑：
#         powershell -NoProfile -ExecutionPolicy Bypass -File tools\auto-setup.ps1 `
#                    -Workspace "<工作区>" -Bots "<工作区>\bots" -Base "<Base>"
#
# 输出协议（C++ 逐行读，一行一条，前缀别改）：
#   ##STEP <0-100>|<在做什么>
#   ##OK   <组件>|<装到哪 / 版本>
#   ##FAIL <组件>|<为什么 + 怎么办>
#   ##RESULT ok=<0|1> fixed=<n>
#
# 几条规矩：
#   * 只往 -Bots 里写；老布局（<Base>\SnowLuma 之类）一个字节都不动，
#     工作台的状态检测是「先新后旧」，所以老机器升级不会变红。
#   * 单个组件失败不终止，继续装后面的；最后 ##RESULT ok=0 但已装好的保留。
#   * 装过且文件还在就跳过（-Force 才重装），重复点按钮不会重复下载。
#   * 只改自己的用户级环境变量，不动系统 PATH。
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$Bots,
    [string]$Base = "",
    [switch]$Force,
    [switch]$SkipOllama,
    [switch]$SkipSnowLuma,
    [switch]$SkipBreeze,
    [switch]$SkipAstrBot,
    [switch]$SkipWhale
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
# 输出给 C++ 的是管道，RunCaptureStream 按 UTF-8 解码；不改这一句中文会变乱码
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not $Base) { $Base = Split-Path -Parent $Workspace }
$Repo = Split-Path -Parent $PSScriptRoot                     # tools 的上一级 = 仓库根（开发树）
if (-not (Test-Path (Join-Path $Repo "sidecar"))) { $Repo = "" }

$tmp = Join-Path $env:TEMP ("mingling-bots-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:fixed = 0
$script:failed = 0
$script:items = [ordered]@{}

# ------------------------------------------------------------------ 协议输出
function Step([int]$pct, [string]$msg) {
    "##STEP $pct|$msg" | Write-Output
    Write-Host ("  [{0,3}%] {1}" -f $pct, $msg)
}
function Ok([string]$name, [string]$detail) {
    $script:fixed++
    $script:items[$name] = $detail
    "##OK $name|$detail" | Write-Output
    Write-Host ("       OK  {0} · {1}" -f $name, $detail)
}
function Bad([string]$name, [string]$why) {
    $script:failed++
    "##FAIL $name|$why" | Write-Output
    Write-Host ("       !!  {0} · {1}" -f $name, $why) -ForegroundColor Yellow
}

# ------------------------------------------------------------------ 下载 / 解压
function Get-Download([string]$Url, [string]$OutFile) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 1800
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1024) { return $true }
        } catch {
            Write-Host ("       下载重试 {0}/3：{1}" -f $i, $_.Exception.Message)
            Start-Sleep -Seconds (2 * $i)
        }
    }
    return $false
}

function Get-ReleaseAsset([string]$RepoSlug, [string]$Pattern, [string]$Exclude = "") {
    $uri = "https://api.github.com/repos/$RepoSlug/releases/latest"
    $hdr = @{ "User-Agent" = "MinglingWorkbench/2.0"; "Accept" = "application/vnd.github+json" }
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 60
            $hit = $r.assets |
                Where-Object { $_.name -match $Pattern -and ($Exclude -eq "" -or $_.name -notmatch $Exclude) } |
                Select-Object -First 1
            if ($hit) {
                return @{
                    url     = $hit.browser_download_url
                    name    = $hit.name
                    version = ($r.tag_name -replace "^v", "")
                }
            }
        } catch {
            Start-Sleep -Seconds (2 * $i)
        }
    }
    return $null
}

function Expand-Zip([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (Test-Path $tar) {
        & $tar -xf $Zip -C $Dest 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    try { Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force; return $true } catch { return $false }
}

# 压出来的包通常多套一层目录（node-v22.../ 之类），把内容压平到 $Dest
function Flatten-Into([string]$Src, [string]$Dest) {
    $top = @(Get-ChildItem $Src -Force)
    if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $Src = $top[0].FullName }
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Get-ChildItem $Src -Force | Copy-Item -Destination $Dest -Recurse -Force
}

# ------------------------------------------------------------------ 运行时查找
function Find-Uv {
    $cands = @(
        (Join-Path $Base "uv\bin\uv.exe"),
        (Join-Path $Bots "AstrBot\bin\uv.exe")
    )
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    $c = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }

    $a = Get-ReleaseAsset "astral-sh/uv" "uv-x86_64-pc-windows-msvc\.zip$"
    if (-not $a) { return $null }
    $zip = Join-Path $tmp "uv.zip"
    if (-not (Get-Download $a.url $zip)) { return $null }
    $d = Join-Path $tmp "uv"
    if (-not (Expand-Zip $zip $d)) { return $null }
    $hit = Get-ChildItem $d -Recurse -Filter "uv.exe" | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Find-Node {
    $cands = @(
        (Join-Path $Repo "sidecar\node\node.exe"),
        (Join-Path $Bots "SnowLuma\node.exe"),
        (Join-Path $Base "SnowLuma\node.exe")
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
    $c = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Find-Npm([string]$NodeExe) {
    if ($NodeExe) {
        $near = Join-Path (Split-Path $NodeExe) "npm.cmd"
        if (Test-Path $near) { return $near }
    }
    $c = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# ------------------------------------------------------------------ 五个组件
function Install-Ollama {
    $dst = Join-Path $Bots "Ollama"
    $exe = Join-Path $dst "ollama.exe"
    if ((Test-Path $exe) -and -not $Force) { Ok "Ollama" ("已有 " + $dst); return }
    Step 10 "装 Ollama（便携包）"
    $zip = Join-Path $tmp "ollama.zip"
    if (-not (Get-Download "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip" $zip)) {
        Bad "Ollama" "下载失败；检查网络/代理后重试，或手动解压到 bots\Ollama"
        return
    }
    $d = Join-Path $tmp "ollama"
    if (-not (Expand-Zip $zip $d)) { Bad "Ollama" "解压失败（tar.exe 和 Expand-Archive 都没成）"; return }
    Flatten-Into $d $dst
    if (-not (Test-Path $exe)) { Bad "Ollama" "包里没有 ollama.exe，结构可能变了"; return }
    New-Item -ItemType Directory -Force -Path (Join-Path $dst "models") | Out-Null
    Ok "Ollama" $dst
}

function Install-SnowLuma {
    $dst = Join-Path $Bots "SnowLuma"
    if ((Test-Path (Join-Path $dst "index.mjs")) -and -not $Force) { Ok "SnowLuma" ("已有 " + $dst); return }
    Step 25 "装 SnowLuma（QQ 登录端）"
    $a = Get-ReleaseAsset "SnowLuma/SnowLuma" "win-x64\.zip$" "lite"
    if (-not $a) { Bad "SnowLuma" "没找到 win-x64 发布包（GitHub 限流时稍后再点一次）"; return }
    $zip = Join-Path $tmp "snowluma.zip"
    if (-not (Get-Download $a.url $zip)) { Bad "SnowLuma" ("下载失败：" + $a.name); return }
    $d = Join-Path $tmp "snowluma"
    if (-not (Expand-Zip $zip $d)) { Bad "SnowLuma" "解压失败"; return }
    Flatten-Into $d $dst
    if (-not (Test-Path (Join-Path $dst "index.mjs"))) { Bad "SnowLuma" "解压后没有 index.mjs，发布包结构变了"; return }

    # 启动脚本跟老布局的 start-snowluma.cmd 对齐：密码仍然读 private\，不写进 bots
    $pw = Join-Path $Base "private\snowluma-webui.txt"
    $lines = @(
        "@echo off",
        "cd /d `"$dst`"",
        "set SNOWLUMA_HOOK_AUTOLOAD=1",
        "set SNOWLUMA_ACCEPT_EULA=1",
        "set SNOWLUMA_ACCEPT_PRIVACY=1",
        "if exist `"$pw`" set /p SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD=<`"$pw`"",
        ".\node.exe .\index.mjs",
        "pause"
    )
    Set-Content -LiteralPath (Join-Path $dst "start.cmd") -Value $lines -Encoding Default
    Ok "SnowLuma" ($dst + " · " + $a.version)
}

function Install-Breeze {
    $dst = Join-Path $Bots "Breeze"
    $hasSrv = @(Get-ChildItem $dst -Recurse -Filter "breeze-server*.exe" -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasSrv -and -not $Force) { Ok "Breeze" ("已有 " + $dst); return }
    Step 40 "装 Breeze（本地语音）"
    $a = Get-ReleaseAsset "HoppouAI/Breeze-TTS-2.cpp" "windows-x64.*\.zip$"
    if (-not $a) { Bad "Breeze" "没找到 windows-x64 Vulkan 包；可在 settings.json 配 mirror_breeze 手动指定"; return }
    $zip = Join-Path $tmp "breeze.zip"
    if (-not (Get-Download $a.url $zip)) { Bad "Breeze" ("下载失败：" + $a.name); return }
    $d = Join-Path $tmp "breeze"
    if (-not (Expand-Zip $zip $d)) { Bad "Breeze" "解压失败"; return }
    Flatten-Into $d $dst
    $srv = Get-ChildItem $dst -Recurse -Filter "breeze-server*.exe" | Select-Object -First 1
    if (-not $srv) { Bad "Breeze" "包里没有 breeze-server.exe"; return }

    # 模型（*.gguf）体积大，包里不一定带；有就写进 start.cmd，没有就提示放哪
    $model = Get-ChildItem $dst -Recurse -Filter "*.gguf" | Select-Object -First 1
    $lines = @(
        "@echo off",
        "cd /d `"$($srv.DirectoryName)`""
    )
    if ($model) {
        $lines += "`"$($srv.FullName)`" -m `"$($model.FullName)`" --host 127.0.0.1 --port 8137"
    } else {
        $lines += "echo 没有找到模型：把 breeze-tts-2-*.gguf 放进 bots\Breeze\models\ 再改这个文件的 -m 路径"
        $lines += "pause"
    }
    Set-Content -LiteralPath (Join-Path $dst "start.cmd") -Value $lines -Encoding Default
    if ($model) { Ok "Breeze" ($dst + " · " + $a.version) }
    else { Ok "Breeze" ($dst + " · " + $a.version + "（缺模型，见 start.cmd 注释）") }
}

function Install-AstrBot {
    $dst = Join-Path $Bots "AstrBot"
    $exe = Join-Path $dst "bin\astrbot.exe"
    if ((Test-Path $exe) -and -not $Force) { Ok "AstrBot" ("已有 " + $dst); return }
    Step 55 "装 AstrBot（大脑，uv 方式）"
    $uv = Find-Uv
    if (-not $uv) { Bad "AstrBot" "没有 uv.exe 也下不到；先手动放一个 uv.exe 到 bots\AstrBot\bin\ 再点一次"; return }

    $toolDir = Join-Path $dst "tools"
    $binDir = Join-Path $dst "bin"
    $pyDir = Join-Path $dst "python"
    New-Item -ItemType Directory -Force -Path $toolDir, $binDir, $pyDir | Out-Null

    # 只在本进程内生效；同一份写进 env.cmd，手动排错时双击就能用同样的目录
    $env:UV_TOOL_DIR = $toolDir
    $env:UV_TOOL_BIN_DIR = $binDir
    $env:UV_PYTHON_INSTALL_DIR = $pyDir

    Step 62 "AstrBot：拉 Python 运行时（第一次要几分钟）"
    $out = & $uv tool install astrbot --force 2>&1
    if (-not (Test-Path $exe)) {
        $tail = ($out | Select-Object -Last 4) -join " / "
        Bad "AstrBot" ("uv tool install 失败：" + $tail)
        return
    }
    Set-Content -LiteralPath (Join-Path $dst "env.cmd") -Encoding Default -Value @(
        "@echo off",
        "set UV_TOOL_DIR=$toolDir",
        "set UV_TOOL_BIN_DIR=$binDir",
        "set UV_PYTHON_INSTALL_DIR=$pyDir"
    )
    Set-Content -LiteralPath (Join-Path $dst "start.cmd") -Encoding Default -Value @(
        "@echo off",
        "cd /d `"$dst`"",
        "if not exist data mkdir data",
        "`"$exe`" run >> data\run.log 2>&1",
        "pause"
    )
    Ok "AstrBot" $dst
}

function Install-Whale {
    $dst = Join-Path $Bots "bili-whale"
    if ((Test-Path (Join-Path $dst "package.json")) -and -not $Force) { Ok "bili-whale" ("已有 " + $dst); return }
    Step 78 "装 bili-whale（B 站那一半）"

    $src = ""
    if ($Repo -and (Test-Path (Join-Path $Repo "sidecar\bili-whale\package.json"))) {
        $src = Join-Path $Repo "sidecar\bili-whale"
    } elseif (Test-Path (Join-Path $Base "bili\sidecar\bili-whale\package.json")) {
        $src = Join-Path $Base "bili\sidecar\bili-whale"
    }
    if (-not $src) { Bad "bili-whale" "仓库里没有 sidecar\bili-whale（见 docs\THIRD-PARTY.md）"; return }

    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem $src -Force | Where-Object { $_.Name -ne "node_modules" } |
        Copy-Item -Destination $dst -Recurse -Force

    # 依赖只有 qrcode 一个：有 npm 就装，没有就从老布局拷现成的
    $need = -not (Test-Path (Join-Path $dst "node_modules\qrcode"))
    if ($need) {
        $node = Find-Node
        $npm = Find-Npm $node
        if ($npm -and $node) {
            Step 84 "bili-whale：装依赖（qrcode）"
            Push-Location $dst
            & $npm install --omit=dev --no-audit --no-fund 2>&1 | Out-Host
            Pop-Location
        } elseif (Test-Path (Join-Path $Base "bili\sidecar\bili-whale\node_modules")) {
            Copy-Item (Join-Path $Base "bili\sidecar\bili-whale\node_modules") $dst -Recurse -Force
        }
    }
    if (-not (Test-Path (Join-Path $dst "package.json"))) { Bad "bili-whale" "复制失败"; return }

    # 配置：模板 → 真实文件（已存在就不覆盖，免得把用户 cookie 冲掉）
    $cfg = Join-Path $dst "bili-whale.config.json"
    if (-not (Test-Path $cfg)) {
        $tpl = Join-Path $Repo "sidecar\bili-whale.config.template.json"
        if (-not (Test-Path $tpl)) { $tpl = Join-Path $Base "bili\sidecar\bili-whale.config.template.json" }
        if (Test-Path $tpl) { Copy-Item $tpl $cfg -Force }
    }
    if (-not (Test-Path (Join-Path $dst "node_modules\qrcode"))) {
        Ok "bili-whale" ($dst + "（缺 node_modules\qrcode：装个带 npm 的 Node 再点一次）")
    } else {
        Ok "bili-whale" $dst
    }
}

function Write-StartAll {
    $dst = Join-Path $Bots "start-all.cmd"
    $lines = @("@echo off", "title 冥零 · 全部启动")
    foreach ($n in @("Ollama", "SnowLuma", "Breeze", "AstrBot")) {
        $d = Join-Path $Bots $n
        $s = Join-Path $d "start.cmd"
        if (Test-Path $s) {
            $lines += "echo 起 $n"
            $lines += "start `"$n`" /min cmd /c `"`"$s`"`""
            $lines += "timeout /t 6 /nobreak >nul"
        }
    }
    Set-Content -LiteralPath $dst -Value $lines -Encoding Default
}

# ------------------------------------------------------------------ 主流程
Write-Host "冥零 · 一键配置环境"
Write-Host "  bots  : $Bots"
Write-Host "  base  : $Base"
Write-Host "  repo  : $Repo"

Step 3 "准备目录"
New-Item -ItemType Directory -Force -Path $Bots, $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Bots "logs") | Out-Null

if (-not $SkipOllama)   { Install-Ollama }
if (-not $SkipSnowLuma) { Install-SnowLuma }
if (-not $SkipBreeze)   { Install-Breeze }
if (-not $SkipAstrBot)  { Install-AstrBot }
if (-not $SkipWhale)    { Install-Whale }

Step 92 "写环境变量与安装清单"
try {
    [Environment]::SetEnvironmentVariable("MINGLING_BOTS", $Bots, "User")
    [Environment]::SetEnvironmentVariable("OLLAMA_MODELS", (Join-Path $Bots "Ollama\models"), "User")
} catch {
    Write-Host ("       !!  环境变量写失败（不影响本次安装）：" + $_.Exception.Message)
}
Write-StartAll

$man = [ordered]@{
    at    = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    bots  = $Bots
    workspace = $Workspace
    items = $script:items
} | ConvertTo-Json -Depth 5
Set-Content -LiteralPath (Join-Path $Bots ".setup.json") -Value $man -Encoding UTF8

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Step 100 "完成"
$ok = if ($script:failed -eq 0 -and $script:fixed -gt 0) { 1 } else { 0 }
"##RESULT ok=$ok fixed=$($script:fixed)"
