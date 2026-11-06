# 把 node.exe / ffmpeg.exe 切成 8MB 小块，绕开 32 位 makensis 的映射上限。
# 输出：build\parts\{node,ffmpeg}\000.. 和 build\parts\parts.nsh
param([int]$ChunkMB = 8)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $repo "build\parts"
$stamp = Join-Path $out ".stamp"

$srcs = [ordered]@{
    node   = Join-Path $repo "sidecar\node\node.exe"
    ffmpeg = Join-Path $repo "sidecar\bili-whale\bin\ffmpeg.exe"
}

if (Test-Path $stamp) { Remove-Item $stamp -Force }
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $out | Out-Null

$chunk = $ChunkMB * 1MB
$fileLines = New-Object System.Collections.Generic.List[string]
$asmLines  = New-Object System.Collections.Generic.List[string]

foreach ($key in $srcs.Keys) {
    $src = $srcs[$key]
    if (-not (Test-Path $src)) { throw "missing $src" }
    $dir = Join-Path $out $key
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $fs = [IO.File]::OpenRead($src)
    try {
        $buf = New-Object byte[] $chunk
        $i = 0
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $name = "{0:D3}" -f $i
            $dst = Join-Path $dir $name
            [IO.File]::WriteAllBytes($dst, $buf[0..($n-1)])
            $fileLines.Add("  SetOutPath `"`$INSTDIR\.parts\$key`"")
            $fileLines.Add("  File `"..\build\parts\$key\$name`"")
            $i++
        }
        $names = 0..($i-1) | ForEach-Object { "`"`$INSTDIR\.parts\$key\{0:D3}`"" -f $_ }
        $asmLines.Add("  nsExec::ExecToLog 'cmd /c copy /b " + ($names -join "+") + " `"`$INSTDIR\sidecar\" + $(if ($key -eq 'node') { 'node\node.exe' } else { 'bili-whale\bin\ffmpeg.exe' }) + "`"'")
    } finally { $fs.Close() }
}
$asmLines.Add("  RMDir /r `"`$INSTDIR\.parts`"")

$nsh = @()
$nsh += "!macro ML_PART_FILES"
$nsh += $fileLines
$nsh += "!macroend"
$nsh += "!macro ML_PART_ASSEMBLE"
$nsh += $asmLines
$nsh += "  SetOutPath `"`$INSTDIR`""
$nsh += "!macroend"
[IO.File]::WriteAllText((Join-Path $out "parts.nsh"), ($nsh -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $true))
Write-Host ("[parts] {0} chunks, {1:N1} MB total" -f ($fileLines.Count/2), ((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum/1MB))
