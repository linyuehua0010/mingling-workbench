# 版本自检：确认 win32\src\version.h 里「数字」和「字符串」没走散。
#
#   数字：APP_VERSION_MAJOR / MINOR / PATCH / BUILD   → 资源 FILEVERSION、安装包
#   渠道：APP_VERSION_SUFFIX（正式版 ""，快照版 "-snapshot"）
#   开关：APP_SNAPSHOT（1 = 快照通道：独立状态目录/窗口类/卸载项，必须与后缀一致）
#   字符串：APP_VERSION_PLAIN / APP_VERSION_TAG / APP_VERSION_STR / APP_VERSION
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1
# 通过：退出码 0，打印一行「版本 OK V3.0.0-snapshot (3.0.0.0-snapshot)」。
# 走散：退出码 1，并列出哪一条对不上、应该改成什么。

param(
    [string]$Header = ""
)

$ErrorActionPreference = 'Stop'
if (-not $Header) { $Header = Join-Path $PSScriptRoot '..\win32\src\version.h' }
if (-not (Test-Path -LiteralPath $Header)) {
    Write-Host "[版本] 找不到 version.h：$Header"
    exit 1
}

$text = Get-Content -LiteralPath $Header -Raw -Encoding UTF8

function Get-Num([string]$name) {
    $m = [regex]::Match($text, '(?m)^\s*#define\s+' + $name + '\s+(\d+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-Str([string]$name) {
    $m = [regex]::Match($text, '(?m)^\s*#define\s+' + $name + '\s+L?"([^"]*)"')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

$major = Get-Num 'APP_VERSION_MAJOR'
$minor = Get-Num 'APP_VERSION_MINOR'
$patch = Get-Num 'APP_VERSION_PATCH'
$build = Get-Num 'APP_VERSION_BUILD'
if ($null -eq $major -or $null -eq $minor -or $null -eq $patch -or $null -eq $build) {
    Write-Host "[版本] version.h 缺数字段（MAJOR/MINOR/PATCH/BUILD 四个都要有）"
    exit 1
}

$plain = "$major.$minor.$patch"
$full  = "$plain.$build"

# 渠道后缀：正式版是空串，快照版是 "-snapshot"。显示用的串都带它，数字部不带。
$suffix = Get-Str 'APP_VERSION_SUFFIX'
if ($null -eq $suffix) {
    Write-Host "[版本] version.h 缺 APP_VERSION_SUFFIX（正式版写 `"`"，快照版写 `"-snapshot`"）"
    exit 1
}
$snap = Get-Num 'APP_SNAPSHOT'
if ($null -eq $snap) {
    Write-Host "[版本] version.h 缺 APP_SNAPSHOT（正式版 0，快照版 1）"
    exit 1
}
if (($suffix -ne "" -and $snap -ne "1") -or ($suffix -eq "" -and $snap -ne "0")) {
    Write-Host "[版本] APP_SNAPSHOT=$snap 与 APP_VERSION_SUFFIX=`"$suffix`" 不一致："
    Write-Host "        快照版要 APP_SNAPSHOT 1 + 后缀 -snapshot；正式版要 0 + 空串。"
    exit 1
}

$tag   = "V$plain$suffix"
$fullS = "$full$suffix"

$bad = @()

function Want([string]$macro, [string]$expect) {
    $got = Get-Str $macro
    if ($null -eq $got) { $script:bad += "$macro 缺失，应为 `"$expect`""; return }
    if ($got -ne $expect) { $script:bad += "$macro = `"$got`"，应为 `"$expect`"" }
}

Want 'APP_VERSION_PLAIN'   $plain
Want 'APP_VERSION_TAG'     $tag
Want 'APP_VERSION_STR'     $fullS
Want 'APP_VERSION'         $tag
Want 'APP_VERSION_PLAIN_W' $plain
Want 'APP_VERSION_FULL_W'  $fullS

if ($bad.Count -gt 0) {
    Write-Host "[版本] 数字是 $tag（$fullS），但下面的字符串对不上："
    foreach ($b in $bad) { Write-Host "        · $b" }
    Write-Host "       改 $Header，或者直接照上面「应为」抄。"
    exit 1
}

Write-Host "[版本] OK $tag ($fullS)"
exit 0
