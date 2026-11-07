# 版本自检：确认 win32\src\version.h 里「数字」和「字符串」没走散。
#
#   数字：APP_VERSION_MAJOR / MINOR / PATCH / BUILD   → 资源 FILEVERSION、安装包
#   渠道：APP_VERSION_SUFFIX（正式版 ""，快照版 "-snapshot"）
#   开关：APP_SNAPSHOT（1 = 快照通道：独立状态目录/窗口类/卸载项，必须与后缀一致）
#   快照序号：APP_SNAPSHOT_N（V3-snapshot-2 里的 2，必须等于 APP_VERSION_BUILD）
#   字符串：APP_VERSION_PLAIN / APP_VERSION_TAG / APP_VERSION_STR / APP_VERSION / APP_VERSION_SHORT
#
# 命名规则：
#   正式版  V<major>.<minor>.<patch>                 例：V3.1.0
#   快照版  V<major>-snapshot-<n>                    例：V3-snapshot-2
#           第一个数字 = 现正式版最新大版本 + 1；n = 该快照通道里的第几版
#   安装包  MinglingWorkbench-<APP_VERSION_SHORT>-setup.exe
#           正式版 3.1.0 / 快照版 3-snapshot-2
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-version.ps1
# 通过：退出码 0，打印一行「[版本] OK V3-snapshot-2 (3.0.0.2)」。
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

# 渠道后缀：正式版是空串，快照版是 "-snapshot"。
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
$snapN = Get-Num 'APP_SNAPSHOT_N'
if ($null -eq $snapN) { $snapN = '0' }
if (($suffix -ne "" -and $snap -ne "1") -or ($suffix -eq "" -and $snap -ne "0")) {
    Write-Host "[版本] APP_SNAPSHOT=$snap 与 APP_VERSION_SUFFIX=`"$suffix`" 不一致："
    Write-Host "        快照版要 APP_SNAPSHOT 1 + 后缀 -snapshot；正式版要 0 + 空串。"
    exit 1
}

if ($snap -eq "1") {
    # 快照版：V<major>-snapshot-<n>；文件版本第四段 = n；短串 = <major>-snapshot-<n>
    if ($suffix -ne "-snapshot") {
        Write-Host "[版本] 快照版的 APP_VERSION_SUFFIX 必须是 `"-snapshot`"，现在是 `"$suffix`"。"
        exit 1
    }
    if ([int]$snapN -lt 1) {
        Write-Host "[版本] 快照版要写 APP_SNAPSHOT_N（V3-snapshot-2 里的 2），现在是 $snapN。"
        exit 1
    }
    if ($build -ne $snapN) {
        Write-Host "[版本] APP_VERSION_BUILD=$build 与 APP_SNAPSHOT_N=$snapN 必须一样"
        Write-Host "        （文件版本第四段就是快照序号，3,0,0,2 ←→ V3-snapshot-2）。"
        exit 1
    }
    $tag   = "V$major-snapshot-$snapN"
    $short = "$major-snapshot-$snapN"
    $fullS = "$major.$minor.$patch.$snapN"
} else {
    # 正式版：V<major>.<minor>.<patch>；第四段仍是 BUILD（历史习惯，通常 0）
    if ($snapN -ne "0") {
        Write-Host "[版本] 正式版不该写 APP_SNAPSHOT_N（现在是 $snapN，正式版为 0）。"
        exit 1
    }
    $tag   = "V$plain"
    $short = $plain
    $fullS = "$plain.$build"
}

$bad = @()

function Want([string]$macro, [string]$expect) {
    $got = Get-Str $macro
    if ($null -eq $got) { $script:bad += "$macro 缺失，应为 `"$expect`""; return }
    if ($got -ne $expect) { $script:bad += "$macro = `"$got`"，应为 `"$expect`"" }
}

Want 'APP_VERSION_PLAIN'   $plain
Want 'APP_VERSION_TAG'     $tag
Want 'APP_VERSION_STR'     $fullS
Want 'APP_VERSION_SHORT'   $short
Want 'APP_VERSION'         $tag
Want 'APP_VERSION_PLAIN_W' $plain
Want 'APP_VERSION_FULL_W'  $fullS
Want 'APP_VERSION_SHORT_W' $short

if ($bad.Count -gt 0) {
    Write-Host "[版本] 数字是 $tag（$fullS），但下面的字符串对不上："
    foreach ($b in $bad) { Write-Host "        · $b" }
    Write-Host "       改 $Header，或者直接照上面「应为」抄。"
    exit 1
}

Write-Host "[版本] OK $tag ($fullS)"
exit 0
