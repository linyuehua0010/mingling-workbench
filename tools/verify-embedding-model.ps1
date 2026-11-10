param(
    [Parameter(Mandatory = $true)][string]$Models
)
# 校验 bge-m3 的模型层是否已按内容寻址落盘。
# 为什么按 blob 校验而不是按 manifest digest：Ollama registry 会重新发布 manifest
# （实测旧 manifest digest 直接 404），但层 blob 的 sha256 是内容寻址、不会变。
$ErrorActionPreference = 'Stop'
$blobs = Join-Path $Models 'blobs'
$want = @(
    @{ digest = 'daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c'; size = [int64]1157671200; what = 'bge-m3 模型层' },
    @{ digest = 'a406579cd136771c705c521db86ca7d60a6f3de7c9b5460e6193a2df27861bde'; size = [int64]1068; what = 'bge-m3 许可层' }
)
$bad = New-Object System.Collections.ArrayList
foreach ($w in $want) {
    $p = Join-Path $blobs ('sha256-' + $w.digest)
    if (-not (Test-Path -LiteralPath $p)) {
        [void]$bad.Add(('缺少{0}：sha256-{1}' -f $w.what, $w.digest))
        continue
    }
    $len = (Get-Item -LiteralPath $p).Length
    if ($len -ne [int64]$w.size) {
        [void]$bad.Add(('{0} 字节数不符：期望 {1}，实际 {2}' -f $w.what, $w.size, $len))
    }
}
if ($bad.Count -gt 0) {
    Write-Output ('模型层校验失败：' + ($bad -join '；'))
    exit 3
}
Write-Output ('模型层校验通过：{0} 层，blobs={1}' -f $want.Count, $blobs)
exit 0
