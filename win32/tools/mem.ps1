param([string]$Name = "MinglingWorkbench")
# 量一下工作台吃了多少内存：工作集（任务管理器看到的）、私有提交、句柄数
$p = Get-Process $Name -ErrorAction SilentlyContinue
if (-not $p) { "not running"; exit 1 }
foreach ($x in $p) {
    "{0}  ws={1}MB  priv={2}MB  handles={3}  gdi={4}  user={5}" -f `
        $x.Id, [int]($x.WorkingSet64 / 1MB), [int]($x.PrivateMemorySize64 / 1MB), `
        $x.HandleCount, $x.GdiObjects, $x.UserObjects
}
