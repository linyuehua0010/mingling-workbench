#requires -Version 5.1
# 开发机可执行的非安装验证：清单/图/哈希/锁/安装包/升级辅助脚本单元测试。
# 这些不能替代虚拟机端到端安装，同一结果文件里会明确写 scope。
param([string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'evidence' }
$outFile = Join-Path $OutDir ('local-verify-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$rows = New-Object System.Collections.ArrayList
function Add-Result([string]$Id, [string]$Status, [string]$Detail, $Data = $null) {
    [void]$rows.Add([ordered]@{ id = $Id; status = $Status; detail = $Detail; data = $Data })
}

$manifestPath = Join-Path $repo 'tools\components.json'
$m = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$cs = @($m.components)
$ids = @{}
$errors = New-Object System.Collections.ArrayList
foreach ($c in $cs) {
    if ($ids.ContainsKey([string]$c.id)) { [void]$errors.Add("重复 id: $($c.id)") } else { $ids[[string]$c.id] = $c }
    foreach ($f in @('id', 'detect', 'install', 'verify', 'source')) {
        if (-not $c.PSObject.Properties[$f] -or $null -eq $c.$f) { [void]$errors.Add("$($c.id) 缺 $f") }
    }
    if ([string]$c.source.sha256 -notmatch '^[0-9a-fA-F]{64}$') { [void]$errors.Add("$($c.id) source.sha256 无效") }
    foreach ($r in @($c.requires)) {
        if ($r -and -not $ids.ContainsKey([string]$r)) { [void]$errors.Add("$($c.id) 悬空 requires $r") }
    }
    $steps = @($c.install.steps) + @($c.install.fallbacks)
    $required = @{
        download = @('urls', 'sha256', 'dest'); copy_tree = @('from', 'to'); copy_file = @('from', 'to')
        write_file = @('path', 'content'); mkdir = @('paths'); winget = @('id'); uv_tool = @('package', 'tool_dir', 'bin_dir')
        uv_python = @('version', 'install_dir'); npm_install = @('dir'); command = @('exe'); env_user = @('name', 'value')
        manual = @(); none = @()
    }
    foreach ($s in $steps) {
        if ($null -eq $s) { continue }
        if (-not $required.ContainsKey([string]$s.kind)) { [void]$errors.Add("$($c.id) 未知步骤 $($s.kind)"); continue }
        foreach ($f in $required[[string]$s.kind]) {
            if (-not $s.PSObject.Properties[$f] -or $null -eq $s.$f -or [string]$s.$f -eq '') { [void]$errors.Add("$($c.id).$($s.kind) 缺 $f") }
        }
    }
}
$color = @{}
$cycles = New-Object System.Collections.ArrayList
function Visit([string]$id, [string[]]$trail) {
    if ($color[$id] -eq 1) { [void]$cycles.Add(((@($trail) + $id) -join ' -> ')); return }
    if ($color[$id] -eq 2) { return }
    $color[$id] = 1
    foreach ($r in @($ids[$id].requires)) { if ($ids.ContainsKey([string]$r)) { Visit ([string]$r) (@($trail) + $id) } }
    $color[$id] = 2
}
foreach ($id in $ids.Keys) { Visit ([string]$id) @() }
foreach ($x in $cycles) { [void]$errors.Add("依赖环 $x") }
Add-Result 'criteria-1' $(if ($errors.Count -eq 0) { '通过（仅清单结构）' } else { '失败' }) "组件 $($cs.Count) 个；字段/图错误 $($errors.Count) 个" @($errors)

$sourceBad = @($cs | Where-Object { [string]$_.source.sha256 -notmatch '^[0-9a-fA-F]{64}$' } | ForEach-Object id)
Add-Result 'criteria-2-static' $(if ($sourceBad.Count -eq 0) { '通过（仅静态完整性）' } else { '失败' }) '所有 source 均为 64 位 SHA256；篡改拒装需 VM 实测' @{ invalid = $sourceBad }

$manifests = New-Object System.Collections.ArrayList
foreach ($c in $cs) {
    foreach ($s in @($c.install.steps)) {
        if ($s.kind -ne 'copy_tree' -or -not $s.manifest) { continue }
        $mp = Join-Path $repo ([string]$s.manifest)
        $rootRel = ([string]$s.from).Replace('{repo}\', '')
        $actual = & (Join-Path $repo 'tools\source-manifest.ps1') -Root (Join-Path $repo $rootRel) -Verify -Manifest $mp
        $ok = (([string]$actual).Trim() -eq [string]$s.sha256)
        [void]$manifests.Add([ordered]@{ component = $c.id; manifest = $s.manifest; expected = $s.sha256; actual = ([string]$actual).Trim(); ok = $ok })
    }
}
Add-Result 'source-tree-manifests' $(if (@($manifests | Where-Object { -not $_.ok }).Count -eq 0) { '通过' } else { '失败' }) "已核验 $(@($manifests).Count) 个随包源码树" @($manifests)

$lockRows = New-Object System.Collections.ArrayList
foreach ($c in $cs) {
    foreach ($s in @($c.install.steps)) {
        if ($s.kind -ne 'uv_tool' -or -not $s.requirements) { continue }
        $lock = Join-Path $repo ([string]$s.requirements -replace '\{(base|repo|app)\}\\', '')
        $h = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$lockRows.Add([ordered]@{ component = $c.id; lock = $s.requirements; expected = [string]$s.requirements_sha256; actual = $h; ok = ($h -eq [string]$s.requirements_sha256 -and $h -eq [string]$c.source.sha256) })
    }
}
Add-Result 'dependency-locks' $(if (@($lockRows | Where-Object { -not $_.ok }).Count -eq 0) { '通过' } else { '失败' }) "uv 依赖锁逐包 SHA256；本项检查锁文件本身" @($lockRows)

$installer = Join-Path $repo 'dist\MinglingWorkbench-3.1.0-setup.exe'
$installerInfo = [ordered]@{ path = $installer; exists = (Test-Path -LiteralPath $installer); bytes = 0; sha256 = '' }
if ($installerInfo.exists) {
    $installerInfo.bytes = (Get-Item -LiteralPath $installer).Length
    $installerInfo.sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
}
Add-Result 'installer-artifact' $(if ($installerInfo.exists) { '存在（未安装验证）' } else { '失败' }) '安装包已生成；安装行为需 VM' $installerInfo

# 升级辅助脚本单元测试（临时目录，不是产品安装）
$t = Join-Path $env:TEMP ('mw-local-' + [guid]::NewGuid().ToString('N'))
try {
    $app = Join-Path $t '程序 测试'
    $ws = Join-Path $t '工作区 测试'
    New-Item -ItemType Directory -Force -Path (Join-Path $app 'tools'), (Join-Path $app 'bots'), (Join-Path $app 'private'), (Join-Path $app '旧版'), $ws | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'MinglingWorkbench.exe'), 'old-exe')
    [IO.File]::WriteAllText((Join-Path $app 'unins000.dat'), 'old-unins')
    [IO.File]::WriteAllText((Join-Path $app 'bots\config.json'), 'protected')
    [IO.File]::WriteAllText((Join-Path $app 'MinglingWorkbench.new.exe'), 'new-exe')
    & (Join-Path $repo 'tools\backup-install.ps1') -AppDir $app -Workspace $ws -Reason unit-test
    $backupExit = $LASTEXITCODE
    $backup = Get-ChildItem -LiteralPath (Join-Path $ws '旧版') -Directory | Select-Object -First 1
    $bm = Get-Content -LiteralPath (Join-Path $backup.FullName 'backup-manifest.json') -Raw | ConvertFrom-Json
    & (Join-Path $repo 'tools\finish-update.ps1') -AppDir $app -WaitSeconds 5 -ManifestLog (Join-Path $ws '旧版\finish.log')
    $finishExit = $LASTEXITCODE
    $newContent = [IO.File]::ReadAllText((Join-Path $app 'MinglingWorkbench.exe'))
    $unit = [ordered]@{
        backupExit = $backupExit; backupFiles = $bm.fileCount; protectedBackedUp = (Test-Path (Join-Path $backup.FullName 'bots\config.json'))
        uninsBackedUp = (Test-Path (Join-Path $backup.FullName 'unins000.dat')); finishExit = $finishExit
        mainReplaced = ($newContent -eq 'new-exe'); newExeRemoved = -not (Test-Path (Join-Path $app 'MinglingWorkbench.new.exe'))
    }
    $unitOk = $backupExit -eq 0 -and $bm.fileCount -eq 2 -and -not $unit.protectedBackedUp -and $unit.uninsBackedUp -and $finishExit -eq 0 -and $unit.mainReplaced -and $unit.newExeRemoved
    Add-Result 'upgrade-helper-unit' $(if ($unitOk) { '通过（单元）' } else { '失败' }) '覆盖前备份排除保护目录且含 unins；主程序 .new 原子替换' $unit
} finally {
    Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
}

$parseErrors = New-Object System.Collections.ArrayList
$ps1 = @(Get-ChildItem -LiteralPath (Join-Path $repo 'tools') -Filter *.ps1) + @(Get-ChildItem -LiteralPath (Join-Path $repo 'skill\mingling-install\scripts') -Filter *.ps1)
foreach ($p in $ps1) {
    $e = $null
    [void][Management.Automation.Language.Parser]::ParseFile($p.FullName, [ref]$null, [ref]$e)
    if ($e) { foreach ($x in $e) { [void]$parseErrors.Add("$($p.Name): $($x.Message)") } }
}
Add-Result 'powershell-parse' $(if ($parseErrors.Count -eq 0) { '通过' } else { '失败' }) "解析 $($ps1.Count) 个 PowerShell 脚本" @($parseErrors)

$report = [ordered]@{
    schema = 1
    at = (Get-Date).ToUniversalTime().ToString('o')
    scope = '开发机静态/单元；不包含安装、服务启动、VMware 来宾运行'
    results = $rows
}
$json = $report | ConvertTo-Json -Depth 12
$out = $outFile
[IO.File]::WriteAllText($out, $json + "`n", (New-Object Text.UTF8Encoding($false)))
$rows | ForEach-Object { '{0}: {1} - {2}' -f $_.id, $_.status, $_.detail }
Write-Output "evidence=$out"
