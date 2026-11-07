param([string]$Dir = '')

# 收尾：把「这份 Skill 装在哪、是哪一版」记进工作区，工作台更新页/维护页据此显示版本。
# 写两个文件（都覆盖写，UTF-8 无 BOM）：
#   <工作区>\tools\skill-home.txt      这份 Skill 的绝对路径
#   <工作区>\tools\skill-version.json  这份 Skill 的 version.json 拷贝
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File finish.ps1 -Dir "<工作区>"

$ErrorActionPreference = 'Stop'
$skill = Split-Path $PSScriptRoot -Parent          # 这份 Skill 的根（scripts 的上一级）
$verFile = Join-Path $skill 'version.json'
if (-not (Test-Path $verFile)) { Write-Host "##FAIL 收尾|这份 Skill 里没有 version.json：$skill"; exit 1 }

# 没给 -Dir 就照工作台自己的 settings.json 找
if (-not $Dir) {
    foreach ($d in @((Join-Path $env:APPDATA 'MinglingWorkbench\snapshot'),
                     (Join-Path $env:APPDATA 'MinglingWorkbench'))) {
        $p = Join-Path $d 'settings.json'
        if (-not (Test-Path $p)) { continue }
        $j = $null
        try { $j = (Get-Content $p -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
        if ($j -and $j.workspace) { $Dir = [string]$j.workspace; break }
    }
}
if (-not $Dir) { Write-Host '##FAIL 收尾|没给 -Dir，settings.json 里也没写工作区'; exit 1 }

$Dir = $Dir.TrimEnd('\', '/')
$tools = Join-Path $Dir 'tools'
if (-not (Test-Path $tools)) {
    Write-Host "##FAIL 收尾|$Dir 下面没有 tools\，这不像冥零工作台的工作区"
    exit 1
}
if (-not ((Test-Path (Join-Path $Dir 'bots')) -or (Test-Path (Join-Path $Dir 'answers.json')))) {
    Write-Host "##FAIL 收尾|$Dir 下面既没有 bots\ 也没有 answers.json，先确认机器人根"
    exit 1
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $tools 'skill-version.json'), (Get-Content $verFile -Raw -Encoding UTF8), $utf8)
[System.IO.File]::WriteAllText((Join-Path $tools 'skill-home.txt'), $skill, $utf8)

$ver = ''
try { $ver = [string](((Get-Content $verFile -Raw -Encoding UTF8) | ConvertFrom-Json).version) } catch {}
Write-Host "##OK 收尾|工作台认得这份 Skill 了：$skill（$ver）"
Write-Host "##RESULT ok=1 done=1 fail=0"
