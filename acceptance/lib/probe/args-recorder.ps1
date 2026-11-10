#requires -Version 5.1
# 参数接收探针（PowerShell）：把实际收到的参数写成 JSON，供 Invoke-Capture 自测比对。
# 故意不写 param() 块：-File 调用时未绑定的位置参数全部进 $args，看到的就是“实际收到的值”。
$items = @()
foreach ($a in $args) { $items += [string]$a }
$obj = [ordered]@{
    kind    = 'powershell'
    count   = $items.Count
    args    = $items
    scriptPath = $PSCommandPath
}
$out = $env:MW_PROBE_OUT
if (-not $out) { $out = Join-Path $env:TEMP 'mw-probe-ps.json' }
[IO.File]::WriteAllText($out, ($obj | ConvertTo-Json -Compress -Depth 5), (New-Object Text.UTF8Encoding($false)))
if ($env:MW_PROBE_CHILD) {
    # 记录派生进程 PID，供“超时后整棵进程树被杀”的断言使用
    $child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') -ArgumentList @('-n', '120', '127.0.0.1') -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText($env:MW_PROBE_CHILD, [string]$child.Id, (New-Object Text.UTF8Encoding($false)))
}
if ($env:MW_PROBE_SLEEP) { Start-Sleep -Seconds ([int]$env:MW_PROBE_SLEEP) }
$exit = 0
if ($env:MW_PROBE_EXIT) { $exit = [int]$env:MW_PROBE_EXIT }
exit $exit
