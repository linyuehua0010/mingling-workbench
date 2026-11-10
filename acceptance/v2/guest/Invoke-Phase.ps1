#requires -Version 5.1
<#
  冥零工作台 V3.1.0 验收 —— 来宾侧单阶段执行器（pre / full / recovery / upgrade / final）

  设计约束（与宿主机调度器约定）：
    * 只写 $GuestRoot、安装目标目录、来宾用户目录；不碰产品源码。
    * 每条外部命令都走 acceptance\lib\Capture.ps1 的 Invoke-Capture（参数编码由库负责）。
    * 每个阶段都落盘 phases\<Phase> 与 <Phase>\done.json，失败也要落盘。
    * 断言只使用 Check.ps1 的状态词表；做不到就 blocked/not-run，不用 pass 掩盖。

  说明：本脚本由宿主机以 powershell.exe -NoProfile -ExecutionPolicy Bypass -File 调用。
#>
param(
  [Parameter(Mandatory)][ValidateSet('pre','full','recovery','upgrade','final')][string]$Phase,
  [Parameter(Mandatory)][string]$RunId,
  [string]$LibDir    = 'C:\Users\Public\MWAcceptance\lib',
  [string]$GuestRoot = 'C:\Users\Public\MWAcceptance',
  [string]$StageUrl  = 'http://192.168.206.1:8000/stage',
  [string]$EvidenceUrl = 'http://192.168.206.1:8000/upload',
  [string]$Installer31 = 'MinglingWorkbench-3.1.0-setup.exe',
  [string]$Installer30 = 'MinglingWorkbench-3.0.0-setup.exe'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- 库
. (Join-Path $LibDir 'Capture.ps1')
. (Join-Path $LibDir 'Check.ps1')
. (Join-Path $LibDir 'Evidence.ps1')
. (Join-Path $LibDir 'Progress.ps1')

# ---------------------------------------------------------------- 自测模式（F-01）
# 只用于本机跑包装层单测：把 GuestRoot 重定向到临时目录，定义完函数后立即执行自测并退出。
# 宿主机调度不会设置这个环境变量，正常验收路径完全不变。
$script:SelfTestMode = ($env:MW_RUNNER_SELFTEST -eq '1')
if ($script:SelfTestMode) {
  $GuestRoot = Join-Path $env:TEMP ('mw-runner-selftest-' + [guid]::NewGuid().ToString('N'))
}

# ---------------------------------------------------------------- 路径
$GuestRoot = ([string]$GuestRoot).TrimEnd('\', '/')
$RunDir    = Join-Path $GuestRoot ('run\' + $RunId)
$script:EvidenceDir = Join-Path $RunDir $Phase
$ProgressDir = Join-Path $RunDir 'progress'
$StageDir  = Join-Path $RunDir 'stage'
$FixtureDir = Join-Path $RunDir 'fixture'
$startedUtc = (Get-Date).ToUniversalTime().ToString('o')

# F-06：阶段总预算必须小于宿主机上限（host：pre 90min / full 180min / recovery 120min / upgrade 120min / final 45min）。
# 这里给内部预算留 5 分钟余量用于落盘与上传；任何单条命令的超时都会被夹到“剩余预算”以内，
# 避免整阶段被宿主机判超时并伪造 fail-fixture。
$script:PhaseBudgetSeconds = @{ pre = 5100; full = 10200; recovery = 6900; upgrade = 6900; final = 2400 }
$script:PhaseBudgetTotal = $(if ($script:PhaseBudgetSeconds.ContainsKey($Phase)) { [int]$script:PhaseBudgetSeconds[$Phase] } else { 5100 })
$script:PhaseStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:BudgetClamped = New-Object System.Collections.ArrayList

foreach ($d in @($RunDir, $script:EvidenceDir, $StageDir, $FixtureDir, (Join-Path $script:EvidenceDir 'checks'))) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# 关键路径常量（全部在 $GuestRoot 下，中文 + 空格是刻意保留的验收条件）
$App       = Join-Path $GuestRoot '冥零 验收\程序 3.1'
$Ws        = Join-Path $GuestRoot '冥零 验收\工作区 3.1'
$AppExe    = Join-Path $App 'MinglingWorkbench.exe'
$Bootstrap = Join-Path $App 'tools\bootstrap.ps1'
$SelfSetup = Join-Path $App 'tools\self-setup.ps1'
$AstrRoot  = Join-Path $Ws 'bots\AstrBot'
$BotsRoot  = Join-Path $Ws 'bots'

$checks   = New-Object System.Collections.ArrayList
$commands = New-Object System.Collections.ArrayList
$script:TestKey = 'sk-mwfix-' + [guid]::NewGuid().ToString('N')
# 夹具缺陷守卫：记录“子进程根本没跑起来”的调用（如 Start-Process/-ArgumentList 把含空格路径按空格切断 → exit -196608）
$script:LaunchAnomaliesAll = New-Object System.Collections.ArrayList
$script:LaunchAnomaliesByCheck = @{}

$summary = [ordered]@{
  phase        = $Phase
  runId        = $RunId
  startedUtc   = $startedUtc
  guestRoot    = $GuestRoot
  runDir       = $RunDir
  evidenceDir  = $script:EvidenceDir
  stageUrl     = $StageUrl
  evidenceUrl  = $EvidenceUrl
  host         = $env:COMPUTERNAME
  user         = $env:USERNAME
  psVersion    = $PSVersionTable.PSVersion.ToString()
  osVersion    = [Environment]::OSVersion.VersionString
  notes        = @()
  assets       = [ordered]@{}
  metrics      = [ordered]@{}
}

Initialize-MwProgress -Dir $ProgressDir -Phase $Phase -RunId $RunId
Set-MwProgress -Step 'init - 初始化运行目录与库' -Command 'Initialize-MwProgress'

# ---------------------------------------------------------------- 小工具
function Save-EvidenceJson {
  param([Parameter(Mandatory)][string]$Name, $Object)
  $p = Join-Path $script:EvidenceDir $Name
  Save-MwJson -Path $p -Object $Object -Depth 14
  return $p
}

function Get-MwRemainingBudget {
  <# F-06：本阶段剩余可用秒数（下限 30s，避免传出非正超时）。 #>
  if (-not $script:PhaseStopwatch) { return 1800 }
  $left = [int]($script:PhaseBudgetTotal - $script:PhaseStopwatch.Elapsed.TotalSeconds)
  if ($left -lt 30) { return 30 }
  return $left
}

function Resolve-MwStepTimeout {
  <# F-06：把单步超时夹到阶段剩余预算内；被夹过的记录写进 phase.json/metrics，便于事后解释。 #>
  param([int]$Requested, [string]$Label = '')
  $left = Get-MwRemainingBudget
  if ($Requested -gt $left) {
    [void]$script:BudgetClamped.Add([ordered]@{ label = $Label; requested = $Requested; used = $left; at = (Get-Date).ToUniversalTime().ToString('o') })
    Add-MwProgressTail -Text ('预算夹紧：' + $Label + ' 请求 ' + $Requested + 's，实际最多 ' + $left + 's（阶段剩余）')
    return $left
  }
  return $Requested
}

function Add-PhaseCheck {
  <#
    F-01：包装层绝不能替调用方“补”前置条件或默认 pass。
      * Preconditions 默认空 → 传 pass 时库会降级 evidence-incomplete（空口通过被拦住）。
      * Status 默认 not-run → 忘写状态不会被当成通过。
      * 每个证据路径逐条 Test-Path -LiteralPath；缺失路径写进 Detail/Data，并把 pass 拉回 evidence-incomplete。
      * checks\<id>.json 写的是库判定后的真实状态（含库的二次降级），不是调用方声称的状态。
  #>
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][int]$Criterion,
    [string]$Requirement = '',
    [string[]]$Preconditions = @(),
    [string[]]$Steps = @(),
    [string]$Assertion = '',
    $Expected = $null,
    $Actual = $null,
    [string[]]$Evidence = @(),
    [ValidateSet('pass','fail-product','fail-fixture','blocked-precondition','blocked-env','evidence-incomplete','manual-pending','not-run')]
    [string]$Status = 'not-run',
    [string]$Detail = '',
    $Data = $null
  )
  $cdir = Join-Path $script:EvidenceDir 'checks'
  if (-not (Test-Path -LiteralPath $cdir)) { New-Item -ItemType Directory -Force -Path $cdir | Out-Null }

  $problems = New-Object System.Collections.ArrayList
  $ev = New-Object System.Collections.ArrayList
  # 防御性展平：任何一个证据元素若本身是数组（例如库函数误把路径返回两次），
  # 直接 [string] 会得到 "p p" 这种一个字符串，Test-Path 必然失败。这里逐元素展开。
  $flatEv = New-Object System.Collections.ArrayList
  foreach ($e0 in @($Evidence)) {
    if ($null -eq $e0) { continue }
    if ($e0 -is [string]) { if ($e0.Trim()) { [void]$flatEv.Add($e0) }; continue }
    if ($e0 -is [System.Collections.IEnumerable]) {
      foreach ($x in $e0) { if ($null -ne $x -and ([string]$x).Trim()) { [void]$flatEv.Add([string]$x) } }
      continue
    }
    [void]$flatEv.Add([string]$e0)
  }
  foreach ($e in @($flatEv)) {
    if (-not $e) { continue }
    $s = [string]$e
    if ($ev -contains $s) { continue }
    if ($s -like 'inline:*') { [void]$ev.Add($s); continue }
    $exists = $false
    try { $exists = Test-Path -LiteralPath $s } catch { $exists = $false }
    if ($exists) { [void]$ev.Add($s) } else { [void]$problems.Add('证据不存在：' + $s) }
  }
  if (@($Preconditions).Count -eq 0) { [void]$problems.Add('缺少前置条件（pass 必须能核对执行前提）') }
  if (@($ev).Count -eq 0) { [void]$problems.Add('缺少证据引用') }

  # 只有“声称通过”会被降级；失败/阻塞状态保留原判定，但缺失路径仍写进 Detail（避免无证据的失败结论）。
  if ($Status -eq 'pass' -and $problems.Count -gt 0) { $Status = 'evidence-incomplete' }
  $detailOut = $Detail
  if ($problems.Count -gt 0) {
    $detailOut = (($detailOut + ' | ' + ($problems -join '; ')).Trim(' ', '|'))
  }
  $dataOut = $Data
  if ($problems.Count -gt 0) {
    $missingList = @($problems | Where-Object { $_ -like '证据不存在：*' } | ForEach-Object { $_.Substring('证据不存在：'.Length) })
    if ($missingList.Count -gt 0 -and $null -ne $dataOut -and $dataOut -is [System.Collections.IDictionary]) {
      $dataOut['evidenceMissing'] = $missingList
    }
  }

  # 夹具缺陷守卫（lead m00360）：关联命令出现 -196608 / “-File 路径不存在”时，结论必须是 fail-fixture。
  $launchAnom = @()
  if ($Id -and $script:LaunchAnomaliesByCheck.ContainsKey($Id)) { $launchAnom = @($script:LaunchAnomaliesByCheck[$Id]) }
  if ($launchAnom.Count -gt 0) {
    $anomText = (@($launchAnom) -join ' ; ')
    [void]$problems.Add('子进程未真正执行：' + $anomText)
    $detailOut = (($detailOut + ' | 子进程参数编码/路径异常，未真正执行：' + $anomText).Trim(' ', '|'))
    if ($Status -in @('pass', 'fail-product', 'evidence-incomplete', 'blocked-precondition', 'blocked-env', 'manual-pending')) { $Status = 'fail-fixture' }
    if ($null -ne $dataOut -and $dataOut -is [System.Collections.IDictionary]) { $dataOut['launchAnomalies'] = @($launchAnom) }
  }

  $splat = @{
    Id = $Id; Criterion = $Criterion; Requirement = $Requirement; Preconditions = $Preconditions
    Steps = $Steps; Assertion = $Assertion; Evidence = @($ev); Status = $Status; Detail = $detailOut
  }
  if ($null -ne $Expected) { $splat.Expected = $Expected }
  if ($null -ne $Actual)   { $splat.Actual = $Actual }
  if ($null -ne $dataOut)  { $splat.Data = $dataOut }
  $c = New-MwCheck @splat
  $cp = Join-Path $cdir ($Id + '.json')
  $c['checkFile'] = $cp
  Save-MwJson -Path $cp -Object $c -Depth 14
  [void]$checks.Add($c)
  return $c
}

function Invoke-WrapperSelfTest {
  <#
    F-01 自测：不跑 VM、不装产品。直接验证包装层的四道门：
      1) 缺证据 + pass        → evidence-incomplete（缺的路径出现在 Detail）
      2) 不写 Status          → not-run（绝不默认 pass）
      3) 前置条件齐全 + 真证据 → pass（对照组，证明不是一律降级）
      4) pass 但无前置条件     → evidence-incomplete
    另外逐条回读 checks\<id>.json，证明落盘状态与内存状态一致。
    结果写到 $env:MW_RUNNER_SELFTEST_OUT（缺省写到证据目录），返回 0/1。
  #>
  $outPath = ''
  if ($env:MW_RUNNER_SELFTEST_OUT) { $outPath = $env:MW_RUNNER_SELFTEST_OUT }
  $real = Join-Path $script:EvidenceDir 'selftest-real-evidence.txt'
  Write-FixtureFile -Path $real -Content 'selftest evidence file' -Bom $false
  $missing = Join-Path $script:EvidenceDir 'selftest-missing-evidence.txt'
  if (Test-Path -LiteralPath $missing) { Remove-Item -LiteralPath $missing -Force }

  $cases = New-Object System.Collections.ArrayList
  function Add-SelfCase {
    param([string]$Name, [string]$ExpectStatus, $Check, [string[]]$DetailMust = @(), [bool]$ExpectFileMatch = $true)
    $fileStatus = ''
    try { $fileStatus = [string]((ConvertFrom-Json -InputObject (Read-TextAuto -Path $Check.checkFile)).status) } catch { $fileStatus = 'read-error' }
    $detailOk = $true
    foreach ($d in $DetailMust) { if (([string]$Check.detail) -notlike ('*' + $d + '*')) { $detailOk = $false } }
    $ok = ($Check.status -eq $ExpectStatus) -and $detailOk -and ((-not $ExpectFileMatch) -or ($fileStatus -eq $Check.status))
    [void]$cases.Add([ordered]@{
      case = $Name; expect = $ExpectStatus; actual = [string]$Check.status
      detailOk = $detailOk; checkFile = $Check.checkFile; checkFileStatus = $fileStatus
      pass = [bool]$ok
    })
  }

  $c1 = Add-PhaseCheck -Id 'selftest-missing-evidence' -Criterion 0 -Requirement 'F-01 自测' `
    -Preconditions @('自测：证据文件一个存在、一个不存在') -Steps @('故意引用不存在的证据路径') `
    -Assertion '缺证据的 pass 必须落成 evidence-incomplete' -Expected 'evidence-incomplete' -Actual 'pass(声称)' `
    -Evidence @($real, $missing) -Status 'pass' -Detail 'selftest'
  Add-SelfCase -Name 'missing-evidence-pass' -ExpectStatus 'evidence-incomplete' -Check $c1 -DetailMust @('selftest-missing-evidence.txt')

  $c2 = Add-PhaseCheck -Id 'selftest-default-status' -Criterion 0 -Requirement 'F-01 自测' `
    -Preconditions @('自测：不传 -Status') -Assertion '未声明状态的检查必须是 not-run' `
    -Evidence @($real) -Detail 'selftest'
  Add-SelfCase -Name 'default-status' -ExpectStatus 'not-run' -Check $c2

  $c3 = Add-PhaseCheck -Id 'selftest-pass-control' -Criterion 0 -Requirement 'F-01 自测' `
    -Preconditions @('自测：前置条件与真实证据都齐全') -Assertion '齐全时仍可 pass（证明不是一律降级）' `
    -Evidence @($real) -Status 'pass' -Detail 'selftest'
  Add-SelfCase -Name 'pass-control' -ExpectStatus 'pass' -Check $c3

  $c4 = Add-PhaseCheck -Id 'selftest-no-precondition' -Criterion 0 -Requirement 'F-01 自测' `
    -Assertion 'pass 但没有前置条件必须降级' -Evidence @($real) -Status 'pass' -Detail 'selftest'
  Add-SelfCase -Name 'no-precondition' -ExpectStatus 'evidence-incomplete' -Check $c4 -DetailMust @('前置条件')

  $failed = @($cases | Where-Object { -not $_.pass })
  $result = [ordered]@{
    ok = ($failed.Count -eq 0); at = (Get-Date).ToUniversalTime().ToString('o')
    evidenceDir = $script:EvidenceDir; cases = @($cases)
  }
  if ($outPath) { Save-MwJson -Path $outPath -Object $result -Depth 10 }
  # 必须走 Write-Host：管道输出会被当成函数返回值吞掉，JSON 就不会出现在 stdout。
  Write-Host ($result | ConvertTo-Json -Depth 10)
  if ($failed.Count -eq 0) { return 0 } else { return 1 }
}

function Read-TextAuto {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $bytes = [IO.File]::ReadAllBytes($Path)
  try {
    $t = [Text.Encoding]::UTF8.GetString($bytes)
    if ($t.IndexOf([char]0xFFFD) -ge 0) { return [Text.Encoding]::Default.GetString($bytes) }
    return $t
  } catch { return [Text.Encoding]::Default.GetString($bytes) }
}

function Get-Lines {
  param([string]$Text)
  if (-not $Text) { return @() }
  return @($Text -split "`r?`n")
}

function Get-FirstLineMatch {
  param([string]$Text, [string]$Pattern)
  foreach ($l in (Get-Lines $Text)) { if ($l -match $Pattern) { return $l } }
  return ''
}

function Get-AllLineMatches {
  param([string]$Text, [string]$Pattern)
  $out = New-Object System.Collections.ArrayList
  foreach ($l in (Get-Lines $Text)) { if ($l -match $Pattern) { [void]$out.Add($l) } }
  return @($out)
}

function Get-BootstrapNumbers {
  param([string]$Text)
  $line = ''
  $ms = [regex]::Matches($Text, '##RESULT\s+([^\r\n]+)')
  if ($ms.Count -gt 0) { $line = $ms[$ms.Count - 1].Groups[1].Value }
  $res = [ordered]@{ line = $line; ok = -1; fixed = -1; satisfied = -1; manual = -1; missing = -1; failed = -1 }
  foreach ($k in @('ok','fixed','satisfied','manual','missing','failed')) {
    $m = [regex]::Match($line, [regex]::Escape($k) + '=(\d+)')
    if ($m.Success) { $res[$k] = [int]$m.Groups[1].Value }
  }
  return $res
}

function Get-OkIds {
  param([string]$Text)
  $ids = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($Text, '##OK\s+([^\|\s]+)')) { [void]$ids.Add($m.Groups[1].Value) }
  return @($ids)
}

function Read-TailText {
  param([string]$Path, [int]$Lines = 30)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
  try { return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue) -join "`n") } catch { return '' }
}

function Test-MwLaunchEncodedFailure {
  <#
    识别“子进程根本没跑起来”，与产品失败区分开：
      * exit -196608 / 0xFFFD0000（0xFFFD0000 = -196608）：powershell.exe 的 -File 目标不存在——常见于
        用 Start-Process -ArgumentList 数组传含空格/中文路径，参数被空格切断；
      * 子进程 stderr 明确报 -File/脚本路径不存在或“无法识别为脚本文件”；
      * exit -1073741510 / 0xC000013A：子进程被 Ctrl+C/终止。
    命中任何一个都必须按夹具错误（fail-fixture）处理，不能当产品失败。
  #>
  param($Record = $null, [string]$Stdout = '', [string]$Stderr = '')
  $hits = New-Object System.Collections.ArrayList
  $ec = $null
  if ($null -ne $Record) {
    if ($Record.PSObject.Properties.Name -contains 'exitCode') { $ec = $Record.exitCode }
    if (-not $Stdout -and ($Record.PSObject.Properties.Name -contains 'stdoutText')) { $Stdout = [string]$Record.stdoutText }
    if (-not $Stderr -and ($Record.PSObject.Properties.Name -contains 'stderrText')) { $Stderr = [string]$Record.stderrText }
  }
  if ($null -ne $ec) {
    $ecNum = $null
    try { $ecNum = [int64]$ec } catch { $ecNum = $null }
    if ($null -ne $ecNum) {
      if ($ecNum -eq -196608 -or $ecNum -eq 0xFFFD0000) {
        [void]$hits.Add('exit=' + $ecNum + ' (0xFFFD0000：-File/目标路径缺失或参数被空格切断)')
      }
      if ($ecNum -eq -1073741510) { [void]$hits.Add('exit=' + $ecNum + ' (0xC000013A：子进程被终止)') }
    }
  }
  $both = ([string]$Stdout) + "`n" + ([string]$Stderr)
  if ($both -match '(?i)-File\s*参数.*(不存在|does not exist)|The argument .* is not recognized as the name of a script file|无法将.*识别为.*脚本文件') {
    [void]$hits.Add('子进程错误：-File/脚本路径未被识别（参数编码问题）')
  }
  if ($both -match '(?i)Cannot find (path|drive)|找不到路径|系统找不到指定的路径') {
    [void]$hits.Add('子进程错误：找不到路径/驱动器（参数编码问题）')
  }
  return [pscustomobject]@{ Bad = ($hits.Count -gt 0); Hits = @($hits) }
}

function Get-MwLaunchPrecondition {
  <#
    “期待失败/期待成功”的检查先证明要执行的程序真的存在：记录 Test-Path + bytes + sha256。
    前置不成立时，任何非零退出都可能只是 -File 没找到，不能当成产品失败证据。
  #>
  param([string[]]$Paths = @(), [string]$Label = '')
  $rows = New-Object System.Collections.ArrayList
  $ok = $true
  foreach ($p in @($Paths)) {
    if (-not $p) { continue }
    $exists = $false; $bytes = 0; $sha = ''; $isDir = $false
    try {
      if (Test-Path -LiteralPath $p) {
        $fi = Get-Item -LiteralPath $p -Force
        $exists = $true; $isDir = [bool]$fi.PSIsContainer
        if (-not $isDir) { $bytes = [int64]$fi.Length; $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
      }
    } catch { }
    if (-not $exists) { $ok = $false }
    [void]$rows.Add([ordered]@{ path = $p; exists = $exists; isDirectory = $isDir; bytes = $bytes; sha256 = $sha })
  }
  return [pscustomobject]@{ label = $Label; ok = $ok; at = (Get-Date).ToUniversalTime().ToString('o'); paths = @($rows) }
}

function Invoke-Cap {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 1800,
    [string]$WorkDir = '',
    [hashtable]$Environment = @{},
    [string]$StepText = '',
    [string]$CheckId = ''
  )
  if ($StepText) { Set-MwProgress -Step $StepText -Command $Label }
  $effTimeout = Resolve-MwStepTimeout -Requested $TimeoutSeconds -Label $Label
  $splat = @{
    Label = $Label; FilePath = $FilePath; Arguments = $Arguments; TimeoutSeconds = $effTimeout
    EvidenceDir = $script:EvidenceDir; RunId = $RunId
  }
  if ($WorkDir) { $splat.WorkDir = $WorkDir }
  if ($Environment -and $Environment.Count -gt 0) { $splat.Environment = $Environment }
  $r = Invoke-Capture @splat
  [void]$commands.Add($r.Record)
  $encCap = Test-MwLaunchEncodedFailure -Record $r.Record
  if ($encCap.Bad) {
    $note = ($Label + ' → ' + (@($encCap.Hits) -join '; '))
    [void]$script:LaunchAnomaliesAll.Add($note)
    if ($CheckId) {
      if (-not $script:LaunchAnomaliesByCheck.ContainsKey($CheckId)) { $script:LaunchAnomaliesByCheck[$CheckId] = New-Object System.Collections.ArrayList }
      [void]$script:LaunchAnomaliesByCheck[$CheckId].Add($note)
    }
    Add-MwProgressTail -Text ('夹具告警：子进程未真正启动（' + $note + '），关联 check 将记 fail-fixture')
  }
  $tail = Read-TailText -Path $r.Record.stdoutPath -Lines 15
  if ($tail) { Add-MwProgressTail -Text $tail }
  if ($r.Record.stderrText) { Add-MwProgressTail -Text (Read-TailText -Path $r.Record.stderrPath -Lines 10) }
  return $r.Record
}

function Invoke-Long {
  <# Start-MwCommand + 心跳 + Complete-MwCommand：长安装期间持续写进度，超时主动杀进程树。 #>
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 3600,
    [string]$WorkDir = '',
    [hashtable]$Environment = @{},
    [string]$StepText = '',
    [string]$CheckId = ''
  )
  if (-not $StepText) { $StepText = $Label }  # 空步骤名会让 Set-MwProgress 的 Mandatory 参数绑定失败（夹具自伤）
  Set-MwProgress -Step $StepText -Command $Label
  $TimeoutSeconds = Resolve-MwStepTimeout -Requested $TimeoutSeconds -Label $Label
  $splat = @{
    Label = $Label; FilePath = $FilePath; Arguments = $Arguments
    EvidenceDir = $script:EvidenceDir; RunId = $RunId
  }
  if ($WorkDir) { $splat.WorkDir = $WorkDir }
  if ($Environment -and $Environment.Count -gt 0) { $splat.Environment = $Environment }
  $state = Start-MwCommand @splat
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $killedByHarness = $false
  if ($state.Started) {
    while (-not $state.Process.HasExited) {
      if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        [void](Stop-MwProcessTree -ProcessId $state.Process.Id)
        $killedByHarness = $true
        break
      }
      Start-Sleep -Seconds 10
      if (-not $state.Process.HasExited) {
        Set-MwProgress -Step ($StepText + '（已运行 ' + [int]$sw.Elapsed.TotalSeconds + ' 秒）') -Command $state.Record.commandLine
        $tail = Get-MwCommandTail -State $state -Bytes 1200
        if ($tail) { Add-MwProgressTail -Text $tail }
      }
    }
  }
  $rec = Complete-MwCommand -State $state -TimeoutSeconds 120 -EvidenceDir $script:EvidenceDir
  if ($killedByHarness) { $rec['harnessTimeout'] = $true }
  [void]$commands.Add($rec)
  $encLong = Test-MwLaunchEncodedFailure -Record $rec
  if ($encLong.Bad) {
    $note2 = ($Label + ' → ' + (@($encLong.Hits) -join '; '))
    [void]$script:LaunchAnomaliesAll.Add($note2)
    if ($CheckId) {
      if (-not $script:LaunchAnomaliesByCheck.ContainsKey($CheckId)) { $script:LaunchAnomaliesByCheck[$CheckId] = New-Object System.Collections.ArrayList }
      [void]$script:LaunchAnomaliesByCheck[$CheckId].Add($note2)
    }
    Add-MwProgressTail -Text ('夹具告警：子进程未真正启动（' + $note2 + '），关联 check 将记 fail-fixture')
  }
  $tail2 = Read-TailText -Path $rec.stdoutPath -Lines 20
  if ($tail2) { Add-MwProgressTail -Text $tail2 }
  return $rec
}

function Get-FileVersion {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
  try { return [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion } catch { return '' }
}

function Wait-FileVersion {
  param([string]$Path, [string]$Pattern, [int]$TimeoutSeconds = 180)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $v = Get-FileVersion -Path $Path
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $v = Get-FileVersion -Path $Path
    if ($v -match $Pattern) { return $v }
    Start-Sleep -Seconds 3
  }
  return (Get-FileVersion -Path $Path)
}

function Get-FileMap {
  <# 递归 sha256 + 大小 + mtime；排除指定顶层目录；读不到的文件单独记录。 #>
  param([string[]]$Roots, [string[]]$ExcludeTopDirs = @())
  $map = [ordered]@{}
  $skipped = New-Object System.Collections.ArrayList
  foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $leaf = Split-Path -Leaf $root
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($root.Length).TrimStart('\')
      $skip = $false
      foreach ($ex in $ExcludeTopDirs) {
        if ($rel -eq $ex -or $rel -like ($ex + '\*')) { $skip = $true; break }
      }
      if ($skip) { continue }
      if ($f.Name -like '*.new.exe') { continue }
      try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch {
        [void]$skipped.Add(($leaf + ':' + $rel)); continue
      }
      $key = $leaf + ':' + $rel
      $map[$key] = [ordered]@{
        sha = $sha; size = [long]$f.Length; mtime = $f.LastWriteTimeUtc.ToString('o')
      }
    }
  }
  return [pscustomobject]@{ Map = $map; Skipped = @($skipped) }
}

function Compare-FileMaps {
  param($Before, $After)
  $changes = New-Object System.Collections.ArrayList
  foreach ($k in $Before.Keys) {
    if (-not $After.Contains($k)) { [void]$changes.Add('removed:' + $k); continue }
    $a = $Before[$k]; $b = $After[$k]
    if ($a.sha -ne $b.sha) { [void]$changes.Add('content:' + $k) }
    elseif ([long]$a.size -ne [long]$b.size) { [void]$changes.Add('size:' + $k) }
    elseif ($a.mtime -ne $b.mtime) { [void]$changes.Add('mtime:' + $k) }
  }
  foreach ($k in $After.Keys) {
    if (-not $Before.Contains($k)) { [void]$changes.Add('added:' + $k) }
  }
  return @($changes)
}

function Get-MwWorkspaceUseSignals {
  <#
    证明“安装器真的把请求的目录当成 Base/工作区”。
    F-03：产品可能把 installer-check.log 迁出工作区，因此不再把该日志存在性当作唯一判据；
    工作区内任一信号（安装器日志 / bootstrap state.json / bots 目录）成立即认为工作区被使用。
  #>
  param([Parameter(Mandatory)][string]$WorkspaceRoot, [string]$AppRoot = '')
  $rows = New-Object System.Collections.ArrayList
  $cands = New-Object System.Collections.ArrayList
  [void]$cands.Add([ordered]@{ kind = 'ws-installer-log'; path = (Join-Path $WorkspaceRoot 'logs\setup\installer-check.log') })
  [void]$cands.Add([ordered]@{ kind = 'ws-bootstrap-state'; path = (Join-Path $WorkspaceRoot 'logs\setup\state.json') })
  [void]$cands.Add([ordered]@{ kind = 'ws-bots-dir'; path = (Join-Path $WorkspaceRoot 'bots') })
  if ($AppRoot) {
    [void]$cands.Add([ordered]@{ kind = 'app-installer-log'; path = (Join-Path $AppRoot 'logs\setup\installer-check.log') })
    [void]$cands.Add([ordered]@{ kind = 'app-bootstrap-state'; path = (Join-Path $AppRoot 'logs\setup\state.json') })
  }
  $inWs = @('ws-installer-log', 'ws-bootstrap-state', 'ws-bots-dir')
  $used = $false
  foreach ($c in $cands) {
    $exists = $false
    try { $exists = Test-Path -LiteralPath $c.path } catch { }
    $isWs = ($inWs -contains $c.kind)
    [void]$rows.Add([ordered]@{ kind = $c.kind; path = $c.path; exists = $exists; inWorkspace = $isWs })
    if ($exists -and $isWs) { $used = $true }
  }
  return [pscustomobject]@{ Used = $used; Signals = @($rows) }
}

function Stop-TestRootProcesses {
  <# 清理上一轮遗留的来宾进程：可执行文件位于被测目录内的进程（AstrBot/Node/Ollama…）会锁住 exe，
     使 Reset-TestDir 删除失败。只杀路径在目标目录内的进程，不按名字盲杀。 #>
  param([Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $killed = New-Object System.Collections.ArrayList
  $procs = @()
  try {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase) -and $_.ProcessId -ne $PID
    })
  } catch { $procs = @() }
  foreach ($pr in $procs) {
    try { & taskkill.exe /PID $pr.ProcessId /T /F 2>$null | Out-Null } catch { }
    [void]$killed.Add([ordered]@{ pid = $pr.ProcessId; name = $pr.Name; path = $pr.ExecutablePath })
  }
  if ($killed.Count -gt 0) {
    try {
      $notePath = Join-Path $script:EvidenceDir ('reset-sweep-' + (Split-Path -Leaf $full) + '.json')
      Write-FixtureFile -Path $notePath -Content (ConvertTo-Json -Depth 5 -InputObject ([ordered]@{ target = $full; killed = @($killed) }))
    } catch { }
  }
  return $killed
}

function Reset-TestDir {
  <# 只允许清 $GuestRoot 下的目标目录。删前先结束该目录内的遗留进程，再带重试删除。 #>
  param([Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $rootFull = [IO.Path]::GetFullPath($GuestRoot).TrimEnd('\')
  if ($full -eq $rootFull -or -not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw ('拒绝清理 $GuestRoot 之外的目录：' + $full)
  }
  $null = Stop-TestRootProcesses -Path $full
  if (Test-Path -LiteralPath $full) {
    $lastErr = $null
    for ($i = 0; $i -lt 40; $i++) {
      try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop; $lastErr = $null; break }
      catch { $lastErr = $_; Start-Sleep -Milliseconds 500 }
    }
    if ($lastErr) { throw ('清理目录失败（仍有进程占用？）：' + $full + ' :: ' + $lastErr.Exception.Message) }
  }
  New-Item -ItemType Directory -Force -Path $full | Out-Null
}

function Write-FixtureFile {
  param([string]$Path, [string]$Content, [bool]$Bom = $false)
  $p = Split-Path -Parent $Path
  if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($Bom)
  [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Resolve-StagePath {
  param([string]$NameOrPath)
  if ([IO.Path]::IsPathRooted($NameOrPath)) { return $NameOrPath }
  return (Join-Path $StageDir $NameOrPath)
}

function Get-StageAsset {
  param([Parameter(Mandatory)][string]$Name)
  $dest = Join-Path $StageDir $Name
  if (Test-Path -LiteralPath $dest) { return $dest }
  $uri = $StageUrl.TrimEnd('/') + '/' + [uri]::EscapeDataString($Name)
  Set-MwProgress -Step ('stage - 下载 ' + $Name) -Command $uri
  Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing -TimeoutSec 900 | Out-Null
  Add-MwProgressTail -Text ('下载完成 ' + $Name + ' ' + (Get-Item -LiteralPath $dest).Length + ' 字节')
  return $dest
}

$summary.notes += '每个 check 的 checks\<id>.json 是本次断言的原始记录；Evidence 同时指到命令 stdout 与安装日志。'
$summary.notes += '未使用真实登录、真实付费 API；模型桩只证明 AstrBot 配置协议。'

# ================================================================ 阶段：pre
function Invoke-PrePhase {
  Set-MwProgress -Step 'pre-1 - 下载并校验来源资产'

  $stageRequired = @($Installer31, $Installer30, 'checksums.txt', 'components.json',
                     'astrbot-requirements.txt', 'edge-tts-requirements.txt')
  $downloaded = [ordered]@{}
  $stageErrors = @()
  foreach ($n in $stageRequired) {
    try {
      $p = Get-StageAsset -Name $n
      $downloaded[$n] = $p
      if (-not (Test-Path -LiteralPath $p)) { $stageErrors += ($n + ' 不存在（GET 未落盘）') }
    } catch {
      $downloaded[$n] = ''
      $stageErrors += ($n + ' 下载失败：' + $_.Exception.Message)
    }
  }
  $summary.assets = $downloaded
  if ($stageErrors.Count -gt 0) {
    $seEv = Save-EvidenceJson -Name 'stage-download-errors.json' -Object ([ordered]@{ stageUrl = $StageUrl; errors = $stageErrors })
    Add-PhaseCheck -Id 'c2-stage-assets' -Criterion 2 `
      -Requirement '宿主 stage 必须提供安装包、清单与 requirements' `
      -Steps @('GET $StageUrl/<name> 逐个下载必需资产') `
      -Assertion '6 个必需资产全部可下载' -Expected '6/6' -Actual ($stageErrors -join '；') `
      -Preconditions @('宿主证据服务 /health 返回 200','StageUrl 指向本轮 prepare-stage 生成的 v2\stage') `
      -Evidence @($seEv) -Status 'blocked-env' `
      -Detail 'stage 缺文件属于宿主/网络环境问题，不是产品失败；pre 停在下载阶段，后续项不假装执行。' `
      -Data ([ordered]@{ errors = $stageErrors; stageUrl = $StageUrl })
    return
  }

  $sums = [ordered]@{}
  $sumProblems = New-Object System.Collections.ArrayList
  $sumDup = New-Object System.Collections.ArrayList
  $sumRows = New-Object System.Collections.ArrayList
  $sumOk = $true
  $sumFile = Join-Path $StageDir 'checksums.txt'
  $sumSelfSha = ''
  if (Test-Path -LiteralPath $sumFile) { $sumSelfSha = (Get-FileHash -LiteralPath $sumFile -Algorithm SHA256).Hash.ToLower() }
  else { [void]$sumProblems.Add('checksums.txt 不存在') }
  foreach ($line in (Get-Lines (Read-TextAuto -Path $sumFile))) {
    if (-not $line.Trim()) { continue }
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
      $h = $Matches[1].ToLower(); $n = $Matches[2].Trim()
      if ($sums.Contains($n)) { [void]$sumDup.Add($n) }
      $sums[$n] = $h
    } else {
      [void]$sumProblems.Add('无法解析的清单行：' + $line)
    }
  }
  # 清单自校：宿主若另发 checksums.txt.sha256 就比对；否则记录清单自身哈希作为锚点。
  $selfAnchor = 'none'
  $selfAnchorFile = $sumFile + '.sha256'
  if (Test-Path -LiteralPath $selfAnchorFile) {
    $selfLine = @(Get-Lines (Read-TextAuto -Path $selfAnchorFile)) | Select-Object -First 1
    $selfExpect = ([string]$selfLine).Trim()
    if ($selfExpect -match '^([0-9a-fA-F]{64})') { $selfExpect = $Matches[1].ToLower() }
    $selfAnchor = $(if ($selfExpect -and $selfExpect -eq $sumSelfSha) { 'match' } else { 'mismatch' })
    if ($selfAnchor -ne 'match') { $sumOk = $false }
  }
  # 逐条校验清单里的全部条目（不再只挑 5 个固定文件）
  foreach ($n in @($sums.Keys)) {
    $p = Join-Path $StageDir $n
    $actual = ''
    $size = 0
    if (Test-Path -LiteralPath $p) {
      $actual = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
      $size = (Get-Item -LiteralPath $p).Length
    }
    $match = ($actual -ne '' -and $actual -eq $sums[$n])
    if (-not $match) { $sumOk = $false }
    [void]$sumRows.Add([ordered]@{ name = $n; expected = $sums[$n]; actual = $actual; match = $match; size = $size })
  }
  # 必需项必须在清单里，否则“全部匹配”可能只是空集通过
  $sumRequiredMissing = New-Object System.Collections.ArrayList
  foreach ($n in @('MinglingWorkbench-3.1.0-setup.exe','MinglingWorkbench-3.0.0-setup.exe','components.json','astrbot-requirements.txt','edge-tts-requirements.txt')) {
    if (-not $sums.Contains($n)) { [void]$sumRequiredMissing.Add($n); $sumOk = $false }
  }
  if ($sumProblems.Count -gt 0 -or $sumDup.Count -gt 0) { $sumOk = $false }
  # stage 目录里未被清单覆盖的文件（只记录，不算失败：宿主可能附带说明文件）
  $sumUnlisted = @()
  try {
    $sumUnlisted = @(Get-ChildItem -LiteralPath $StageDir -File -ErrorAction SilentlyContinue | Where-Object { -not $sums.Contains($_.Name) -and $_.Name -ne 'checksums.txt' } | ForEach-Object { $_.Name })
  } catch { }
  $sumEvidence = Save-EvidenceJson -Name 'stage-checksums.json' -Object ([ordered]@{
    checksumsSelfSha256 = $sumSelfSha; selfAnchor = $selfAnchor; listed = $sums.Count
    requiredMissing = @($sumRequiredMissing); duplicates = @($sumDup); problems = @($sumProblems)
    unlistedStageFiles = @($sumUnlisted); rows = @($sumRows)
  })
  Add-PhaseCheck -Id 'c2-stage-integrity' -Criterion 2 `
    -Requirement '安装包与清单必须和 host 发布的 checksums.txt 一致' `
    -Steps @('GET /stage/<name> 下载 3.1/3.0 安装包、components.json、两份 requirements、checksums.txt', '解析 checksums.txt 全部条目（格式/重复/必需项）', '逐条 SHA256 比对，并校验清单自身锚点') `
    -Assertion '清单里每个条目都存在且 SHA256 匹配；5 个必需项都在清单里；清单可解析且无重复' `
    -Expected ('全部匹配（清单 ' + $sums.Count + ' 条）') -Actual (@($sumRows | Where-Object { $_.match }).Count.ToString() + '/' + $sumRows.Count + ' 匹配') `
    -Evidence @($sumEvidence, $sumFile) `
    -Preconditions @('6 个必需 stage 资产已全部下载成功（stage-download-errors 为空）', 'checksums.txt 与 5 个资产文件存在于本地 stage 目录') `
    -Status $(if ($sumOk) { 'pass' } else { 'fail-product' }) `
    -Detail ('checksums.txt 由 host 侧 prepare-stage 生成；现在校验清单全部条目而不是只挑 5 个，也不再用计算值替代缺失项。下载字节与发布清单不一致时安装包不可信，按 fail-product 阻断（不是 evidence-incomplete）。清单自校锚点=' + $selfAnchor + '。') `
    -Data ([ordered]@{ rows = @($sumRows); problems = @($sumProblems); duplicates = @($sumDup); requiredMissing = @($sumRequiredMissing); selfSha256 = $sumSelfSha; selfAnchor = $selfAnchor; unlisted = @($sumUnlisted) })

  $inst31 = Join-Path $StageDir 'MinglingWorkbench-3.1.0-setup.exe'
  $inst30 = Join-Path $StageDir 'MinglingWorkbench-3.0.0-setup.exe'
  $summary.assets = [ordered]@{ installer31 = $inst31; installer30 = $inst30; sums = $sums }

  if (-not (Test-Path -LiteralPath $inst31)) { throw ('缺少 3.1 安装包：' + $inst31) }

  Set-MwProgress -Step 'pre-2 - 清理目标目录' -Command ('Remove-Item ' + $App + ' ; ' + $Ws)
  Reset-TestDir -Path $App
  Reset-TestDir -Path $Ws

  Set-MwProgress -Step 'pre-3 - 静默安装 3.1（普通用户 / 中文空格路径）'
  $installLog = Join-Path $script:EvidenceDir 'install-3.1.inno.log'
  $iArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER',
             ('/DIR=' + $App), ('/WORKSPACE=' + $Ws), ('/LOG=' + $installLog))
  $iRec = Invoke-Long -Label 'install-31' -FilePath $inst31 -Arguments $iArgs -TimeoutSeconds 900 `
  -CheckId 'c3-normal-user-install' `
    -StepText 'pre-3 - 静默安装 3.1'
  $summary.metrics['install31Exit'] = $iRec.exitCode

  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $summary['administratorToken'] = [bool]$isAdmin
  $summary['identityName'] = $id.Name

  $logText = Read-TextAuto -Path $installLog
  $modeLine = Get-FirstLineMatch -Text $logText -Pattern '(?i)administrative install mode'
  $wsLine = Get-FirstLineMatch -Text $logText -Pattern 'WsPath=\['
  $wsLogged = ''
  if ($wsLine -match 'WsPath=\[(.*)\]') { $wsLogged = $Matches[1] }

  $exeExists = Test-Path -LiteralPath $AppExe
  $fv = Get-FileVersion -Path $AppExe
  $modeNo = ($modeLine -match '(?i):\s*No')

  Add-PhaseCheck -Id 'c3-normal-user-install' -Criterion 3 `
    -Requirement '普通用户（非管理员令牌）静默安装成功' `
    -Steps @('检查当前进程是否在 Administrators 组', '以 /CURRENTUSER 静默安装 3.1', '读取 Inno 日志的安装模式行') `
    -Assertion '安装器退出码 0，且日志显示非管理安装模式' `
    -Expected 'exit=0; Administrative install mode: No' `
    -Actual ('exit=' + $iRec.exitCode + '; admin=' + $isAdmin + '; log=' + $modeLine) `
    -Evidence @($installLog, $iRec.stdoutPath, $iRec.stderrPath) `
    -Preconditions @('当前进程令牌为非管理员（WindowsPrincipal.IsInRole(Administrator)=False）', '安装包 SHA256 与 stage 清单一致（c2-stage-integrity 已核对）') `
    -Status $(if ($iRec.exitCode -ne 0) { 'fail-product' } elseif ($isAdmin) { 'blocked-env' } elseif ($modeNo) { 'pass' } else { 'evidence-incomplete' }) `
    -Detail $(if ($isAdmin) { '来宾会话带管理员令牌，无法证明普通用户路径；安装本身仍按 /CURRENTUSER 执行。' } elseif (-not $modeNo) { '安装成功但 Inno 日志没有可读的 "Administrative install mode: No" 行，无法证明非管理安装模式。' } else { '当前进程非管理员，且日志确认非管理安装模式。' }) `
    -Data ([ordered]@{ exitCode = $iRec.exitCode; isAdmin = [bool]$isAdmin; adminLine = $modeLine; modeNo = $modeNo; logFound = ($logText.Length -gt 0) })

  Add-PhaseCheck -Id 'c3-program-exe-version' -Criterion 3 `
    -Requirement '安装后程序文件存在，且确实是 3.1' `
    -Steps @('检查 {App}\MinglingWorkbench.exe', '读取 FileVersion') `
    -Assertion '退出码 0 只证明安装器跑完；这里额外证明落盘的是 3.1 主程序' `
    -Expected '3.1.x' -Actual $fv `
    -Evidence @($installLog, $AppExe) `
    -Preconditions @('安装器已执行并返回退出码（iRec 非空、Inno 日志已落盘）') `
    -Status $(if ($exeExists -and $fv -match '^3\.1\.') { 'pass' } else { 'fail-product' }) `
    -Detail '安装器的 [Run] 会忽略 finish-update 退出码，所以版本必须单独核对。' `
    -Data ([ordered]@{ exists = $exeExists; fileVersion = $fv; path = $AppExe })

  $wsNorm = $Ws.TrimEnd('\')
  $loggedNorm = $wsLogged.TrimEnd('\')
  $sepOk = $true
  $sepNotes = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath (Join-Path $Ws 'MinglingWorkbench.exe')) { $sepOk = $false; [void]$sepNotes.Add('工作区出现了主程序 exe') }
  if (Test-Path -LiteralPath (Join-Path $App 'bots')) { $sepOk = $false; [void]$sepNotes.Add('程序目录出现了 bots') }
  if (Test-Path -LiteralPath (Join-Path $App 'secrets')) { $sepOk = $false; [void]$sepNotes.Add('程序目录出现了 secrets') }
  if (-not (Test-Path -LiteralPath $AppExe)) { $sepOk = $false }
  Add-PhaseCheck -Id 'c3-program-workspace-separate' -Criterion 3 `
    -Requirement '程序目录与工作区互不混装' `
    -Steps @('检查 {App}\MinglingWorkbench.exe', '检查 {Ws} 下没有 exe', '检查 {App} 下没有 bots/secrets') `
    -Assertion '程序文件只在程序目录，用户数据只在工作区；日志 WsPath 等于请求的工作区' `
    -Expected ('WsPath=' + $wsNorm) -Actual ('WsPath=' + $loggedNorm) `
    -Evidence @($installLog, $App) `
    -Preconditions @('主程序 exe 与 Inno 日志已落盘（上一步已读取 FileVersion）') `
    -Status $(if ($sepOk -and $loggedNorm -ieq $wsNorm) { 'pass' } else { 'fail-product' }) `
    -Detail (($sepNotes -join '；') + $(if ($loggedNorm -ieq $wsNorm) { '' } else { '；日志 WsPath 与请求不一致' })) `
    -Data ([ordered]@{ requestedWs = $wsNorm; loggedWs = $loggedNorm; notes = @($sepNotes) })

  Add-PhaseCheck -Id 'c4-chinese-space-paths' -Criterion 4 `
    -Requirement '中文 + 空格路径下安装成功，且路径没有在参数编码中被截断' `
    -Steps @('/DIR 与 /WORKSPACE 传入含中文和空格的绝对路径', '核对 exe 落点与 Inno 日志 WsPath') `
    -Assertion 'exe 存在于请求的程序目录；日志里的 WsPath 与请求工作区完全一致' `
    -Expected ('exe=' + $AppExe + '; WsPath=' + $wsNorm) `
    -Actual ('exeExists=' + $exeExists + '; loggedWs=' + $loggedNorm) `
    -Evidence @($installLog, $AppExe, $App) `
    -Preconditions @('程序安装到含中文与空格的 /DIR（安装器退出码 0）', '工作区路径已从 Inno 日志 WsPath 行读出') `
    -Status $(if ($exeExists -and $loggedNorm -ieq $wsNorm) { 'pass' } else { 'fail-product' }) `
    -Detail '旧夹具的 /DIR 因 -match 覆盖 $Matches 被截断；本脚本所有参数都由 Capture.ps1 编码。' `
    -Data ([ordered]@{ app = $App; workspace = $Ws; loggedWs = $wsLogged; exe = $AppExe })

  # ---- 项 1：组件清单结构 / 依赖图 / 状态模型
  Set-MwProgress -Step 'pre-4 - 校验组件清单与依赖图'
  $manifestPath = Join-Path $App 'tools\components.json'
  $manifest = $null
  if (Test-Path -LiteralPath $manifestPath) {
    try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $manifest = $null }
  }
  $comps = @()
  if ($manifest) { $comps = @($manifest.components) }
  $ids = @($comps | ForEach-Object { [string]$_.id })
  $dupIds = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

  $schemaProblems = New-Object System.Collections.ArrayList
  foreach ($c in $comps) {
    foreach ($f in @('id','name','version','source','detect','verify')) {
      if (-not $c.PSObject.Properties[$f] -or -not $c.$f) { [void]$schemaProblems.Add(([string]$c.id + ' 缺 ' + $f)) }
    }
    if (-not $c.source.kind) { [void]$schemaProblems.Add(([string]$c.id + ' source.kind 为空')) }
  }
  $stateRows = New-Object System.Collections.ArrayList
  foreach ($c in $comps) {
    [void]$stateRows.Add([ordered]@{ id = $c.id; manual = [bool]$c.manual; optional = [bool]$c.optional; default_install = [bool]$c.default_install; requires = @($c.requires) })
  }
  $stateEv = Save-EvidenceJson -Name 'component-states.json' -Object $stateRows
  Add-PhaseCheck -Id 'c1-manifest-schema' -Criterion 1 `
    -Requirement 'components.json 是唯一组件图，字段齐全、id 唯一' `
    -Steps @('读取 {App}\tools\components.json', '检查 id/name/version/source/detect/verify 与 id 唯一性') `
    -Assertion '21 个组件；必填字段非空；id 无重复' `
    -Expected '21 组件，0 问题' -Actual ($comps.Count.ToString() + ' 组件，' + $schemaProblems.Count + ' 问题') `
    -Evidence @($manifestPath, $stateEv) `
    -Preconditions @('{App}\tools\components.json 已从安装目录读出且 JSON 可解析') `
    -Status $(if ($comps.Count -eq 21 -and $dupIds.Count -eq 0 -and $schemaProblems.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail '字段缺失或重复 id 都算清单错误。' `
    -Data ([ordered]@{ count = $comps.Count; duplicateIds = @($dupIds); problems = @($schemaProblems); path = $manifestPath })

  $dagProblems = New-Object System.Collections.ArrayList
  foreach ($c in $comps) {
    foreach ($r in @($c.requires)) {
      if ($r -and ($ids -notcontains [string]$r)) { [void]$dagProblems.Add(([string]$c.id + ' 依赖不存在：' + $r)) }
    }
  }
  # Kahn 拓扑排序检查环
  $indeg = @{}
  foreach ($i in $ids) { $indeg[$i] = 0 }
  foreach ($c in $comps) {
    foreach ($r in @($c.requires)) {
      if ($r -and $indeg.ContainsKey([string]$r)) { $indeg[[string]$c.id] = $indeg[[string]$c.id] + 1 }
    }
  }
  $queue = New-Object System.Collections.ArrayList
  foreach ($i in $ids) { if ($indeg[$i] -eq 0) { [void]$queue.Add($i) } }
  $seen = 0
  while ($queue.Count -gt 0) {
    $cur = [string]$queue[0]; $queue.RemoveAt(0); $seen++
    foreach ($c in $comps) {
      if ((@($c.requires) -contains $cur) -and $indeg.ContainsKey([string]$c.id)) {
        $indeg[[string]$c.id] = $indeg[[string]$c.id] - 1
        if ($indeg[[string]$c.id] -eq 0) { [void]$queue.Add([string]$c.id) }
      }
    }
  }
  $cycle = ($seen -ne $ids.Count)
  Add-PhaseCheck -Id 'c1-dependency-dag' -Criterion 1 `
    -Requirement 'requires 不悬空、依赖图无环' `
    -Steps @('逐个组件检查 requires 是否存在于 id 集合', '对整图做 Kahn 拓扑排序') `
    -Assertion '无悬空依赖；拓扑排序能覆盖全部组件（无环）' `
    -Expected '0 悬空，0 环' -Actual ($dagProblems.Count.ToString() + ' 悬空；环=' + $cycle) `
    -Evidence @($manifestPath) `
    -Preconditions @('components.json 已解析，组件数组非空') `
    -Status $(if ($dagProblems.Count -eq 0 -and -not $cycle) { 'pass' } else { 'fail-product' }) `
    -Detail '显式 -Component 会递归 requires，环会让 bootstrap 直接报错。' `
    -Data ([ordered]@{ dangling = @($dagProblems); cycle = $cycle; topoSeen = $seen; total = $ids.Count })

  $hashProblems = New-Object System.Collections.ArrayList
  $emptyHash = @()
  $downloadAssets = New-Object System.Collections.ArrayList
  foreach ($c in $comps) {
    $sh = [string]$c.source.sha256
    if ($sh -notmatch '^[0-9a-fA-F]{64}$') { [void]$hashProblems.Add(([string]$c.id + ' source.sha256 不是 64 hex')) }
    if ($sh -eq ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')) { $emptyHash += [string]$c.id }
    if ([string]$c.source.kind -eq 'download') {
      if (@($c.source.urls).Count -eq 0 -and -not $c.source.url) { [void]$hashProblems.Add(([string]$c.id + ' 没有下载地址')) }
      foreach ($st in @($c.install.steps)) {
        if ([string]$st.kind -eq 'download') {
          if ([string]$st.sha256 -notmatch '^[0-9a-fA-F]{64}$') { [void]$hashProblems.Add(([string]$c.id + ' 下载步骤缺 sha256')) }
          [void]$downloadAssets.Add([ordered]@{ id = $c.id; sha256 = [string]$st.sha256; size = $st.size; dest = [string]$st.dest; urls = @($st.urls) })
        }
      }
    }
  }
  $daEv = Save-EvidenceJson -Name 'download-assets.json' -Object $downloadAssets
  Add-PhaseCheck -Id 'c1-source-hashes' -Criterion 1 `
    -Requirement '每个组件的 source.sha256 是 64 位十六进制；下载资产的步骤也带哈希' `
    -Steps @('检查 source.sha256 格式', '检查 kind=download 的安装步骤 sha256 与地址') `
    -Assertion '格式全部合法；空串哈希单独列出（无法区分真实资产）' `
    -Expected '0 格式错误' -Actual ($hashProblems.Count.ToString() + ' 格式错误；空哈希 ' + $emptyHash.Count + ' 个') `
    -Evidence @($manifestPath, $daEv) `
    -Preconditions @('components.json 已解析，21 个组件条目可读') `
    -Status $(if ($hashProblems.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('空哈希组件（纯人工/无资产）：' + ($emptyHash -join ', ') + '；bootstrap 只对 kind=download 强制校验。') `
    -Data ([ordered]@{ problems = @($hashProblems); emptyHashIds = @($emptyHash); downloadAssets = @($downloadAssets) })

  $statePath = Join-Path $Ws 'logs\setup\state.json'
  $stateOk = $false
  $stateInfo = [ordered]@{ path = $statePath; exists = $false; schema = $null; components = 0 }
  if (Test-Path -LiteralPath $statePath) {
    try {
      $sj = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $stateInfo.schema = $sj.schema
      $stateInfo.components = @($sj.components).Count
      $stateInfo.mode = $sj.mode
      $stateOk = ([int]$sj.schema -eq 1 -and @($sj.components).Count -gt 0)
      $stateInfo['summary'] = $sj.summary
    } catch { $stateInfo['error'] = $_.Exception.Message }
    $stateInfo.exists = $true
  }
  $stateReason = [string]$stateInfo['error']
  if (-not $stateInfo.exists) { $stateReason = 'state.json 不存在（安装器收尾的 bootstrap -Check 没有写出状态模型）' }
  elseif (-not $stateReason) {
    if ([string]$stateInfo.schema -ne '1') { $stateReason = 'schema=' + $stateInfo.schema + '，不是 1' }
    elseif ([int]$stateInfo.components -le 0) { $stateReason = 'components 为空' }
    else { $stateReason = '' }
  }
  $stateInfo['reason'] = $stateReason
  Add-PhaseCheck -Id 'c1-state-model' -Criterion 1 `
    -Requirement '安装器收尾的 bootstrap -Check 写出可读的状态模型' `
    -Steps @('读取 {Ws}\logs\setup\state.json', '核对 schema 与 components 数量') `
    -Assertion 'state.json schema=1，且含按组件记录的状态条目（数量不强制等于清单总数，因为默认选择集可少于 21）' `
    -Expected ('schema=1, components>0（清单共 ' + $comps.Count + '）') -Actual ('schema=' + $stateInfo.schema + ', components=' + $stateInfo.components) `
    -Evidence @($statePath) `
    -Preconditions @('安装器收尾已执行 bootstrap -Check（Inno 日志存在）', 'state.json 路径 = {Ws}\logs\setup\state.json') `
    -Status $(if ($stateOk) { 'pass' } else { 'fail-product' }) `
    -Detail ('安装器用 -LogFile 让 Dirty 为真，因此这一步必然写 state.json。失败原因：' + $(if ($stateReason) { $stateReason } else { '状态未知' })) `
    -Data $stateInfo

  # ---- 项 2：来源真实性链路
  Set-MwProgress -Step 'pre-5 - 核对来源哈希链路（requirements / bili 树 / npm integrity / 模型 digest）'
  $astrComp = $comps | Where-Object { $_.id -eq 'astrbot' } | Select-Object -First 1
  $edgeComp = $comps | Where-Object { $_.id -eq 'edge-tts' } | Select-Object -First 1
  $astrReq = Join-Path $App 'tools\astrbot-requirements.txt'
  $edgeReq = Join-Path $App 'tools\edge-tts-requirements.txt'
  $astrSha = ''
  $edgeSha = ''
  if (Test-Path -LiteralPath $astrReq) { $astrSha = (Get-FileHash -LiteralPath $astrReq -Algorithm SHA256).Hash.ToLower() }
  if (Test-Path -LiteralPath $edgeReq) { $edgeSha = (Get-FileHash -LiteralPath $edgeReq -Algorithm SHA256).Hash.ToLower() }
  $astrHashOk = ($astrComp -and $astrSha -eq ([string]$astrComp.source.sha256).ToLower())
  $edgeHashOk = ($edgeComp -and $edgeSha -eq ([string]$edgeComp.source.sha256).ToLower())
  $hashLines = @(Get-Lines (Read-TextAuto -Path $astrReq) | Where-Object { $_ -match '--hash=sha256:' }).Count
  $unhashed = @(Get-Lines (Read-TextAuto -Path $astrReq) | Where-Object { $_ -match '^[A-Za-z0-9]' -and $_ -notmatch '--hash=sha256:' }).Count

  $biliManifest = Join-Path $App 'tools\source-manifests\bili-whale.json'
  $biliSrc = Join-Path $App 'sidecar\bili-whale'
  $smExe = Join-Path $App 'tools\source-manifest.ps1'
  $smRec = $null
  if ((Test-Path -LiteralPath $smExe) -and (Test-Path -LiteralPath $biliManifest)) {
    $smRec = Invoke-Cap -Label 'bili-tree-manifest-verify' -FilePath $smExe `
      -Arguments @('-Root',$biliSrc,'-Manifest',$biliManifest,'-Verify') -TimeoutSeconds 300 `
      -StepText 'pre-5 - 校验 bili-whale 源码树摘要'
  }

  $lockPath = Join-Path $App 'sidecar\bili-whale\package-lock.json'
  $lockIntegrity = ''
  $expectIntegrity = ''
  $biliComp = $comps | Where-Object { $_.id -eq 'bili-whale' } | Select-Object -First 1
  if ($biliComp) {
    $sec = @($biliComp.source.secondary)
    if ($sec.Count -gt 0) { $expectIntegrity = [string]$sec[0].integrity }
  }
  $lockParser = 'powershell'
  $lockError = ''
  if (Test-Path -LiteralPath $lockPath) {
    try {
      $lock = [IO.File]::ReadAllText($lockPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($lock.packages -and $lock.packages.PSObject.Properties['node_modules/qrcode']) {
        $lockIntegrity = [string]$lock.packages.'node_modules/qrcode'.integrity
      } elseif ($lock.dependencies -and $lock.dependencies.qrcode) {
        $lockIntegrity = [string]$lock.dependencies.qrcode.integrity
      }
    } catch {
      $lockError = $_.Exception.Message
      # PS 5.1 的 ConvertFrom-Json 读不了 lockfileVersion=3 的根包空键 ""（报 name 参数无效）。
      # npm 锁本来就是给 node 用的，这里用同一份文件交给 node 解析，并记录解析器与原始错误。
      $lockParser = 'node'
      $nodeForLock = Join-Path $App 'sidecar\node\node.exe'
      if (-not (Test-Path -LiteralPath $nodeForLock)) { $nodeForLock = 'node' }
      $jsCode = 'const fs=require("fs");const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const p=(l.packages||{})["node_modules/qrcode"]||{};process.stdout.write(JSON.stringify({version:p.version||"",integrity:p.integrity||""}));'
      try {
        $nr = Invoke-Cap -Label 'npm-lock-parse' -FilePath $nodeForLock -Arguments @('-e', $jsCode, $lockPath) -TimeoutSeconds 60 -StepText 'pre-5 - 用 node 解析 npm 锁'
        if ([int]$nr.exitCode -eq 0 -and [string]$nr.stdoutText) {
          $parsedLock = [string]$nr.stdoutText | ConvertFrom-Json
          $lockIntegrity = [string]$parsedLock.integrity
        } else {
          $lockError = 'node 解析失败 exit=' + $nr.exitCode + ' ' + [string]$nr.stderrText
        }
      } catch { $lockError = 'node 解析异常：' + $_.Exception.Message }
    }
  }
  $lockOk = ($expectIntegrity -ne '' -and $lockIntegrity -eq $expectIntegrity)

  $embComp = $comps | Where-Object { $_.id -eq 'embedding-model' } | Select-Object -First 1
  $embDigest = ''
  $embOk = $false
  $embFacts = [ordered]@{ url = ''; digestFormat = $false; urlMatchesManifest = $false; layers = 0; layersValid = $false }
  if ($embComp) {
    $embDigest = ([string]$embComp.source.sha256).ToLower()
    $embUrl = [string]$embComp.source.url
    $embFacts.url = $embUrl
    $embFacts.digestFormat = ($embDigest -match '^[0-9a-f]{64}$')
    # 不能拿“URL 里出现过这个串”当证据：必须是内容寻址的 manifest 路径 …/manifests/sha256:<digest>
    $embFacts.urlMatchesManifest = ($embUrl -match ('/manifests/sha256:' + [regex]::Escape($embDigest) + '$'))
    $embLayers = @($embComp.source.layers)
    $embFacts.layers = $embLayers.Count
    $embFacts.layersValid = ($embLayers.Count -gt 0 -and @($embLayers | Where-Object { ([string]$_.digest -notmatch '^sha256:[0-9a-f]{64}$') -or ([int]$_.size -le 0) }).Count -eq 0)
    $embOk = ($embFacts.digestFormat -and $embFacts.urlMatchesManifest -and $embFacts.layersValid)
  }

  $chainRows = [ordered]@{
    astrbotRequirements = [ordered]@{ file = $astrReq; actual = $astrSha; expected = $(if ($astrComp) { [string]$astrComp.source.sha256 } else { '' }); match = $astrHashOk; hashLines = $hashLines; unhashedLines = $unhashed }
    edgeTtsRequirements = [ordered]@{ file = $edgeReq; actual = $edgeSha; expected = $(if ($edgeComp) { [string]$edgeComp.source.sha256 } else { '' }); match = $edgeHashOk }
    biliManifest = [ordered]@{ file = $biliManifest; verifyExit = $(if ($smRec) { $smRec.exitCode } else { $null }); stdout = $(if ($smRec) { $smRec.stdoutPath } else { '' }) }
    npmIntegrity = [ordered]@{ lock = $lockPath; expected = $expectIntegrity; actual = $lockIntegrity; match = $lockOk; parser = $lockParser; parserError = $lockError }
    modelDigest = [ordered]@{ component = 'embedding-model'; digest = $embDigest; url = $embFacts.url; consistent = $embOk; digestFormat = $embFacts.digestFormat; urlMatchesManifest = $embFacts.urlMatchesManifest; layers = $embFacts.layers; layersValid = $embFacts.layersValid; verifiedByBootstrap = $false; verifiedRemotely = $false; note = '只校验清单与 URL 的内容寻址一致性；远端 layer 字节不在本机复核' }
  }
  $chainEv = Save-EvidenceJson -Name 'source-chain.json' -Object $chainRows
  $biliOk = ($smRec -and $smRec.exitCode -eq 0)
  if (-not $smRec) { $biliOk = $false }
  Add-PhaseCheck -Id 'c2-source-real-chain' -Criterion 2 `
    -Requirement '清单里的来源哈希对应真实链路：requirements 锁、bili 树摘要、npm integrity、模型 digest' `
    -Steps @('计算两份 requirements 的 SHA256 与组件 source.sha256 比对', '运行 source-manifest.ps1 -Verify 校验 bili-whale 树', '从 package-lock.json 读 qrcode integrity 与清单比对', '核对 embedding-model 的 ollama digest') `
    -Assertion 'requirements 文件哈希与清单一致；bili 树校验 exit 0；npm integrity 一致；模型 digest 是 64hex 且 URL 精确指向 /manifests/sha256:<digest> 并带合法 layers' `
    -Expected '四项一致' -Actual ('requirements=' + $astrHashOk + '/' + $edgeHashOk + '; biliExit=' + $(if ($smRec) { $smRec.exitCode } else { 'null' }) + '; lock=' + $lockOk + '; emb=' + $embOk) `
    -Evidence @($chainEv, $astrReq, $edgeReq) `
    -Preconditions @('requirements 锁与 sidecar 源码树已随安装落盘', '{App}\tools\source-manifest.ps1 可执行') `
    -Status $(if ($astrHashOk -and $edgeHashOk -and $biliOk -and $lockOk -and $embOk) { 'pass' } else { 'fail-product' }) `
    -Detail 'astrbot 的 package_sha256 不被 bootstrap 读取；embedding-model 只是把 digest 交给 ollama pull，bootstrap 不独立复核层哈希——因此这里只做“清单内内容寻址一致性”校验（URL 必须以 /manifests/sha256:<digest> 结尾、layers 格式合法），远端 layer 字节明确记为未复核。' `
    -Data $chainRows

  Set-MwProgress -Step 'pre-5b - 代表性篡改拒绝'
  $tamperBase = Join-Path $RunDir 'tamper'
  $tamperCache = Join-Path $tamperBase 'logs\setup\dl'
  if (-not (Test-Path -LiteralPath $tamperCache)) { New-Item -ItemType Directory -Force -Path $tamperCache | Out-Null }
  $fakeZip = Join-Path $tamperCache 'uv-uv-x86_64-pc-windows-msvc.zip'
  Write-FixtureFile -Path $fakeZip -Content 'MW-ACCEPTANCE-TAMPERED-ASSET-NOT-A-ZIP' -Bom $false
  $tRec = Invoke-Cap -Label 'tamper-uv-offline' -FilePath $Bootstrap `
  -CheckId 'c2-tamper-reject' `
    -Arguments @('-Base',$tamperBase,'-Workspace',$tamperBase,'-Bots',(Join-Path $tamperBase 'bots'),'-Component','uv','-Offline') `
    -TimeoutSeconds 300 -StepText 'pre-5b - 用被篡改的缓存跑离线 uv'
  $tamperUv = Join-Path $tamperBase 'uv\bin\uv.exe'
  $tamperText = [string]$tRec.stdoutText + "`n" + [string]$tRec.stderrText
  $tamperRejected = ($tRec.exitCode -eq 2 -and -not (Test-Path -LiteralPath $tamperUv) -and ($tamperText -match '缓存|校验|SHA256'))
  $tamperPre = Get-MwLaunchPrecondition -Label 'tamper-uv-offline' -Paths @($Bootstrap, $fakeZip)
  $tamperPreEv = Save-EvidenceJson -Name 'launch-pre-tamper.json' -Object $tamperPre
  Add-PhaseCheck -Id 'c2-tamper-reject' -Criterion 2 `
    -Requirement '被篡改的资产必须被哈希门拒绝，不能装出 uv.exe' `
    -Steps @('在独立 base 的缓存目录放一个内容错误的 uv zip', '以 -Offline -Component uv 运行 bootstrap') `
    -Assertion 'exit 2；uv.exe 不存在；输出提到缓存/校验' `
    -Expected 'exit=2, 无 uv.exe' -Actual ('exit=' + $tRec.exitCode + ', uvExists=' + (Test-Path -LiteralPath $tamperUv)) `
    -Evidence @($tRec.stdoutPath, $tRec.stderrPath, $fakeZip, $tamperPreEv) `
    -Preconditions @('bootstrap.ps1 与 node 缓存目录存在（可做篡改副本）') `
    -Status $(if (-not $tamperPre.ok) { 'fail-fixture' } elseif ($tamperRejected) { 'pass' } else { 'fail-product' }) `
    -Detail '篡改的是缓存资产而不是清单，验证的是安装时的 SHA256 门。' `
    -Data ([ordered]@{ exitCode = $tRec.exitCode; uvExists = (Test-Path -LiteralPath $tamperUv); output = $tamperText.Substring(0, [Math]::Min(2000, $tamperText.Length)) })

  # ---- 项 5：安装前（组件未装）Check 必须非 0
  Set-MwProgress -Step 'pre-6 - 组件未装时 Check'
  $preCheck = Invoke-Cap -Label 'check-before-components' -FilePath $Bootstrap `
  -CheckId 'c5-check-before-components' `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Check') -TimeoutSeconds 900 `
    -StepText 'pre-6 - 组件未装时 Check（同一安装实例）'
  $preNums = Get-BootstrapNumbers -Text ([string]$preCheck.stdoutText)
  $preCheckOk = ($preCheck.exitCode -eq 2 -and $preNums.missing -gt 0)
  # F-03：installer-check.log 可能被产品迁出工作区；证据只追加真实存在的路径，
  # 同时用 state.json / bots 目录等多信号证明“安装器用的是这个工作区”。
  $c5Pre = Get-MwLaunchPrecondition -Label 'check-before-components' -Paths @($Bootstrap)
  $c5PreEv = Save-EvidenceJson -Name 'launch-pre-check-before.json' -Object $c5Pre
  $c5WsUse = Get-MwWorkspaceUseSignals -WorkspaceRoot $Ws -AppRoot $App
  $c5Ev = New-Object System.Collections.ArrayList
  [void]$c5Ev.Add($preCheck.stdoutPath)
  [void]$c5Ev.Add($preCheck.stderrPath)
  foreach ($sg in $c5WsUse.Signals) { if ($sg.exists) { [void]$c5Ev.Add($sg.path) } }
  $c5LogRow = @($c5WsUse.Signals | Where-Object { $_.kind -eq 'ws-installer-log' })[0]
  Add-PhaseCheck -Id 'c5-check-before-components' -Criterion 5 `
    -Requirement '同一安装实例：组件未装时 Check 必须报缺（exit 2）' `
    -Steps @('3.1 只装程序文件（安装器的 [Run] 只做 -Check，不安装组件）', '在组件安装前运行 bootstrap -Check') `
    -Assertion 'exit 2 且 missing>0；这不是在已装状态上重复跑 Check' `
    -Expected 'exit=2, missing>0' -Actual ('exit=' + $preCheck.exitCode + ', missing=' + $preNums.missing) `
    -Evidence (@($c5Ev) + @($c5PreEv)) `
    -Preconditions @('已安装程序与工作区就绪（主程序存在）', 'bootstrap.ps1 -Check 可执行') `
    -Status $(if (-not $c5Pre.ok) { 'fail-fixture' } elseif ($preCheckOk) { 'pass' } else { 'fail-product' }) `
    -Detail ('安装器 [Run] 的 installer-check.log（若产品已迁出工作区则为程序侧同名文件）是同一状态的另一份证据，但退出码被 Inno 忽略，所以这里自己跑一次拿真实退出码。工作区使用信号=' + ((@($c5WsUse.Signals | Where-Object { $_.exists } | ForEach-Object { $_.kind }) -join ', ')) ) `
    -Data ([ordered]@{ exitCode = $preCheck.exitCode; result = $preNums; workspaceUsed = $c5WsUse.Used; signals = @($c5WsUse.Signals); wsInstallerLog = $c5LogRow.path; wsInstallerLogExists = $c5LogRow.exists })

  # ---- WebView2 缺失分支（不真卸）
  Set-MwProgress -Step 'pre-7 - WebView2 检测分支'
  $wvPresent = $false
  $wvNotes = New-Object System.Collections.ArrayList
  $wvKeys = @(
    @{ root = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'; name = 'pv' },
    @{ root = 'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'; name = 'pv' }
  )
  foreach ($k in $wvKeys) {
    try {
      $v = (Get-ItemProperty -LiteralPath $k.root -Name $k.name -ErrorAction Stop).($k.name)
      if ($v) { $wvPresent = $true; [void]$wvNotes.Add(($k.root + ' pv=' + $v)) }
    } catch { }
  }
  foreach ($pat in @('%ProgramFiles(x86)%\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe', '%ProgramFiles%\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe')) {
    $exp = [Environment]::ExpandEnvironmentVariables($pat)
    if (Test-Path -Path $exp) { $wvPresent = $true; [void]$wvNotes.Add('file:' + $exp) }
  }
  if (-not $wvPresent) {
    $wvRec = Invoke-Cap -Label 'webview2-missing-check' -FilePath $Bootstrap `
      -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Component','webview2','-Check') -TimeoutSeconds 300 `
      -StepText 'pre-7 - WebView2 缺失分支'
    $wvText = [string]$wvRec.stdoutText
    $wvBranch = ($wvRec.exitCode -eq 2 -and $wvText -match '##FAIL\s+webview2')
    Add-PhaseCheck -Id 'c5-webview2-missing-branch' -Criterion 5 `
      -Requirement '检测到 WebView2 缺失时 bootstrap 必须给出可观察的缺项' `
      -Steps @('用与 bootstrap 相同的注册表/文件探针确认缺失', '运行 -Component webview2 -Check') `
      -Assertion 'exit 2 且输出 ##FAIL webview2' `
      -Expected 'exit=2, ##FAIL webview2' -Actual ('exit=' + $wvRec.exitCode) `
      -Evidence @($wvRec.stdoutPath, $wvRec.stderrPath) `
      -Preconditions @('WebView2 检测来自注册表与安装目录探测（结果见 Data.detected）') `
      -Status $(if ($wvBranch) { 'pass' } else { 'fail-product' }) `
      -Detail '本机确实没有 WebView2 探针命中。' `
      -Data ([ordered]@{ probes = @($wvNotes); exitCode = $wvRec.exitCode })
  } else {
    Add-PhaseCheck -Id 'c5-webview2-missing-branch' -Criterion 5 `
      -Requirement '检测到 WebView2 缺失时 bootstrap 必须给出可观察的缺项' `
      -Steps @('用注册表/文件探针确认本机 WebView2 状态') `
      -Assertion '只有缺失时才应走 ##FAIL webview2 分支' `
      -Expected '缺失时 exit 2 + ##FAIL' -Actual '本机已安装 WebView2' `
      -Preconditions @('WebView2 检测来自注册表与安装目录探测（结果见 Data.detected）') `
      -Status 'not-run' `
      -Detail ('本机 WebView2 已安装；按任务约束不真卸 WebView2，因此缺失分支不可观察。已记录探针命中：' + ($wvNotes -join '; ')) `
      -Data ([ordered]@{ present = $true; probes = @($wvNotes) })
  }

  # ---- 项 11：manual 组件独立（pre 的小样本）
  Set-MwProgress -Step 'pre-8 - manual 组件不误报'
  # M-11：不再用 -Base $Ws 制造“detect 路径必然缺失”的恒真 manual。
  # 真实默认执行：不传 -Base，让 bootstrap 自己按 MINGLING_BASE / settings.json / Repo 解析；
  # -Workspace/-Bots 仍指向本实例工作区，保证检测的是同一个安装。
  $manPre = Invoke-Cap -Label 'check-snowluma-manual' -FilePath $Bootstrap `
    -Arguments @('-Workspace',$Ws,'-Bots',$BotsRoot,'-Component','snowluma','-Check') -TimeoutSeconds 600 `
    -StepText 'pre-8 - 默认 Base 下点名 snowluma，qq-login 仍为人工'
  $manPreText = [string]$manPre.stdoutText
  $manPreNums = Get-BootstrapNumbers -Text $manPreText
  $manPreOkIds = Get-OkIds -Text $manPreText
  $manPreBase = ''
  $manPreBaseLine = Get-FirstLineMatch -Text $manPreText -Pattern '^Base='
  if ($manPreBaseLine -match '^Base=(.+)$') { $manPreBase = $Matches[1].Trim() }

  # 直接跑产品自带的 manual 检测脚本，证明“人工态”来自真实登录检查，而不是脚本路径不存在。
  $verifyManual = Join-Path $App 'tools\verify-manual.ps1'
  $manDetect = $null
  if (Test-Path -LiteralPath $verifyManual) {
    $manDetect = Invoke-Cap -Label 'verify-manual-qq-direct' -FilePath $verifyManual `
      -Arguments @('-Kind','qq','-Base',$App,'-Bots',$BotsRoot) -TimeoutSeconds 90 `
      -StepText 'pre-8b - 直接运行 verify-manual.ps1 -Kind qq'
  }
  $manDetectExit = $(if ($manDetect) { $manDetect.exitCode } else { $null })
  $manualOk = ($manPreNums.manual -ge 1 -and ($manPreOkIds -notcontains 'qq-login'))
  $manPreEv = Save-EvidenceJson -Name 'snowluma-manual.json' -Object ([ordered]@{
    resolvedBase = $manPreBase; manual = $manPreNums.manual; okIds = @($manPreOkIds)
    verifyManualPath = $verifyManual; verifyManualExists = (Test-Path -LiteralPath $verifyManual)
    detectExit = $manDetectExit; detectStdout = $(if ($manDetect) { $manDetect.stdoutPath } else { '' })
  })
  Add-PhaseCheck -Id 'c11-pre-snowluma-manual' -Criterion 11 `
    -Requirement '点名父组件（snowluma）会自动带上 manual 依赖 qq-login，但绝不把 qq-login 报成完成' `
    -Steps @('不传 -Base 运行 -Component snowluma -Check（产品默认解析 Base）', '解析输出里的 Base= 与 ##RESULT manual 计数', '直接运行工具目录下的 verify-manual.ps1 -Kind qq 证明人工态来自真实检测') `
    -Assertion 'manual>=1；##OK 不含 qq-login；直接检测的退出码与人工态一致' `
    -Expected 'manual>=1 且没有 ##OK qq-login，且 detect 真实执行' `
    -Actual ('base=' + $manPreBase + '; manual=' + $manPreNums.manual + '; ok=' + ($manPreOkIds -join ',') + '; detectExit=' + $manDetectExit) `
    -Evidence @($manPre.stdoutPath, $manPre.stderrPath, $manPreEv) `
    -Preconditions @('默认执行集不含 snowluma（components.json 中 manual=true）') `
    -Status $(if (-not $manualOk) { 'fail-product' } elseif (-not $manDetect) { 'blocked-precondition' } elseif ($manDetectExit -eq 0) { 'fail-product' } else { 'pass' }) `
    -Detail ('旧写法用 -Base $Ws，让 {base}\tools\verify-manual.ps1 指向不存在的工作区路径，detect 必然失败、manual 恒真。现在不传 -Base（产品默认解析 Base=' + $manPreBase + '），并直接执行程序目录下的 verify-manual.ps1 取得真实退出码 detectExit=' + $manDetectExit + '：退出码非 0 才说明 qq-login 确实未登录、manual 属实；退出码 0 而产品仍报 manual，判 fail-product。') `
    -Data ([ordered]@{ exitCode = $manPre.exitCode; result = $manPreNums; okIds = @($manPreOkIds); resolvedBase = $manPreBase; detectExit = $manDetectExit; verifyManualExists = (Test-Path -LiteralPath $verifyManual) })
}

# ================================================================ 阶段：full
function Start-ModelStub {
  <# 模型桩只服务于“配置协议”验收：/v1/models + /v1/chat/completions。 #>
  param([string]$Python, [string]$Dir)
  $py = Join-Path $Dir 'stub-openai.py'
  $code = @'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path.endswith('/models'):
            self._send(200, {"object": "list", "data": [{"id": "deepseek-chat", "object": "model", "owned_by": "mw-acceptance-stub"}]})
        else:
            self._send(200, {"ok": True, "stub": True})
    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0') or '0')
        if n:
            try:
                self.rfile.read(n)
            except Exception:
                pass
        self._send(200, {"id": "chatcmpl-mwstub", "object": "chat.completion", "model": "deepseek-chat",
                         "choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
    def log_message(self, fmt, *args):
        return

HTTPServer(('127.0.0.1', 18080), H).serve_forever()
'@
  Write-FixtureFile -Path $py -Content $code -Bom $false
  $state = Start-MwCommand -Label 'model-stub-openai' -FilePath $Python -Arguments @($py) `
    -EvidenceDir $script:EvidenceDir -RunId $RunId
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $listening = $false
  while ($sw.Elapsed.TotalSeconds -lt 20) {
    $c = Get-NetTCPConnection -LocalPort 18080 -State Listen -ErrorAction SilentlyContinue
    if ($c) { $listening = $true; break }
    Start-Sleep -Milliseconds 500
  }
  $p = $(if ($state.Started) { $state.Process } else { $null })
  return [pscustomobject]@{ State = $state; Process = $p; Python = $Python; Script = $py; Stdout = ''; Stderr = ''; Listening = $listening }
}

function Stop-ModelStub {
  param($Stub)
  if ($Stub -and $Stub.State -and $Stub.State.Started -and -not $Stub.State.Process.HasExited) {
    [void](Stop-MwProcessTree -ProcessId $Stub.State.Process.Id)
    try { [void]$Stub.State.Process.WaitForExit(10000) } catch { }
  }
  $rec = $null
  if ($Stub -and $Stub.State) {
    $rec = Complete-MwCommand -State $Stub.State -TimeoutSeconds 20 -EvidenceDir $script:EvidenceDir
    [void]$commands.Add($rec)
  }
  return $rec
}

function Get-AstrbotListener {
  $rows = New-Object System.Collections.ArrayList
  try {
    foreach ($c in @(Get-NetTCPConnection -LocalPort 6185 -State Listen -ErrorAction SilentlyContinue)) {
      $proc = $null
      try { $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $c.OwningProcess) } catch { }
      [void]$rows.Add([ordered]@{
        localAddress = $c.LocalAddress; localPort = $c.LocalPort; pid = $c.OwningProcess
        exe = $(if ($proc) { [string]$proc.ExecutablePath } else { '' })
        cmd = $(if ($proc) { [string]$proc.CommandLine } else { '' })
      })
    }
  } catch { }
  return @($rows)
}

function Ensure-AstrbotRunning {
  <# 幂等测量期间必须让 AstrBot 保持运行：停掉它会让 astrbot 的 detect(-RequireRunning) 失败，
     第二次 bootstrap 就会真的重装，从而把“后台停止”误判成“安装器不幂等”。 #>
  param([string]$AstrRoot, [string]$Base, [string]$StartScript, [int]$WaitSeconds = 180)
  $before = @(Get-AstrbotListener)
  if ($before.Count -gt 0) { return [pscustomobject]@{ restarted = $false; pids = @($before | ForEach-Object { $_.pid }) } }
  $rec = $null
  if (Test-Path -LiteralPath $StartScript) {
    $rec = Invoke-Long -Label 'astrbot-ensure-running' -FilePath $StartScript `
      -Arguments @('-Root',$AstrRoot,'-Base',$Base,'-Restart') -TimeoutSeconds $WaitSeconds `
      -StepText 'full-7 - 幂等前确保 AstrBot 在跑'
  }
  $after = @(Get-AstrbotListener)
  return [pscustomobject]@{
    restarted = $true; pids = @($after | ForEach-Object { $_.pid })
    exitCode = $(if ($rec) { $rec.exitCode } else { $null })
    stdout = $(if ($rec) { $rec.stdoutPath } else { '' })
  }
}

function Test-KeyInBytes {
  param([byte[]]$Hay, [byte[]]$Needle)
  if ($null -eq $Hay -or $null -eq $Needle -or $Needle.Length -eq 0 -or $Hay.Length -lt $Needle.Length) { return $false }
  $first = $Needle[0]
  $limit = $Hay.Length - $Needle.Length
  for ($i = 0; $i -le $limit; $i++) {
    if ($Hay[$i] -ne $first) { continue }
    $ok = $true
    for ($j = 1; $j -lt $Needle.Length; $j++) {
      if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
    }
    if ($ok) { return $true }
  }
  return $false
}

function Invoke-KeyScan {
  param([string]$Key, [string[]]$Roots, [int]$MaxBytes = 67108864)
  $encAscii = New-Object System.Text.ASCIIEncoding
  $encU = New-Object System.Text.UnicodeEncoding($false, $false)
  $encB = New-Object System.Text.UnicodeEncoding($true, $false)
  $n1 = $encAscii.GetBytes($Key); $n2 = $encU.GetBytes($Key); $n3 = $encB.GetBytes($Key)
  $scanned = 0
  $hits = New-Object System.Collections.ArrayList
  $skipped = New-Object System.Collections.ArrayList
  $unreadable = New-Object System.Collections.ArrayList
  $seenRoots = @{}
  foreach ($root in $Roots) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
    $rf = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $dup = $false
    foreach ($s in $seenRoots.Keys) {
      if ($rf -eq $s -or $rf.StartsWith($s + '\', [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
    }
    if ($dup) { continue }
    $seenRoots[$rf] = $true
    foreach ($f in @(Get-ChildItem -LiteralPath $rf -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      try {
        $bufs = @()
        $partial = $false
        if ($f.Length -gt $MaxBytes) {
          # M-08：大文件不整读，也不整块跳过：首尾各读 8MB 做部分扫描，证据里标 partial-large。
          $win = 8388608
          $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
          try {
            $len = [long]$f.Length
            $take = [int][Math]::Min([long]$win, $len)
            $bufA = New-Object byte[] $take
            [void]$fs.Read($bufA, 0, $take)
            $bufB = New-Object byte[] $take
            [void]$fs.Seek([Math]::Max(0, $len - $win), [IO.SeekOrigin]::Begin)
            [void]$fs.Read($bufB, 0, $take)
            $bufs = @($bufA, $bufB)
          } finally { $fs.Dispose() }
          $partial = $true
          [void]$skipped.Add([ordered]@{ path = $f.FullName; size = $f.Length; reason = 'partial-large'; windowBytes = $win })
        } else {
          $bufs = @([IO.File]::ReadAllBytes($f.FullName))
        }
        $scanned++
        $found = $false
        foreach ($b in $bufs) {
          if ((Test-KeyInBytes -Hay $b -Needle $n1) -or (Test-KeyInBytes -Hay $b -Needle $n2) -or (Test-KeyInBytes -Hay $b -Needle $n3)) { $found = $true; break }
        }
        if ($found) {
          $p = $f.FullName
          $insideSecrets = $p.StartsWith(($script:WsSecrets + '\'), [StringComparison]::OrdinalIgnoreCase)
          $logLike = ($p -match '\\logs\\' -or $p -match '\.log$' -or $p -match '\.stdout' -or $p -match '\.stderr')
          [void]$hits.Add([ordered]@{ path = $p; insideSecrets = $insideSecrets; logLike = $logLike; bad = ((-not $insideSecrets) -or $logLike) })
        }
      } catch { [void]$unreadable.Add([ordered]@{ path = $f.FullName; error = $_.Exception.Message }) }
    }
  }
  return [pscustomobject]@{ Scanned = $scanned; Hits = @($hits); Skipped = @($skipped); Unreadable = @($unreadable) }
}

function Invoke-FullPhase {
  if (-not (Test-Path -LiteralPath $Bootstrap)) {
    Add-PhaseCheck -Id 'c0-full-precondition' -Criterion 9 -Requirement 'pre 阶段必须先装好 3.1 程序文件' `
      -Assertion '找到 {App}\tools\bootstrap.ps1' -Expected $Bootstrap -Actual '缺失' `
      -Preconditions @('pre 阶段已安装 3.1 主程序（同路径 exe 存在）') `
      -Status 'blocked-precondition' -Detail '没有程序文件就无法跑全量安装；先完成 pre。'
    return
  }

  Set-MwProgress -Step 'full-1 - 全量安装（默认组件）'
  $fullLogDir = Join-Path $Ws 'logs\setup'
  # F-06：宿主机给 full 阶段的上限是 10800s；这里单步最多 9000s（且会被阶段剩余预算再次夹紧），
  # 后续每个子步骤（自设定 apply 1800 / verify 900 / 装齐后 Check 900 / 第二次执行 7200）各自独立超时。
  $fullBudgetSeconds = 9000
  $fullRec = Invoke-Long -Label 'bootstrap-full' -FilePath $Bootstrap `
  -CheckId 'c9-full-install' `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot) -TimeoutSeconds $fullBudgetSeconds `
    -StepText 'full-1 - 全量安装（单步上限 9000s，低于宿主 10800s）'
  $fullText = [string]$fullRec.stdoutText + "`n" + [string]$fullRec.stderrText
  $fullNums = Get-BootstrapNumbers -Text $fullText
  $summary.metrics['fullExit'] = $fullRec.exitCode
  $summary.metrics['fullResult'] = $fullNums.line

  Add-PhaseCheck -Id 'c9-full-install' -Criterion 9 `
    -Requirement '默认参数全量安装成功（不指定 -Component）' `
    -Steps @('运行 bootstrap -Base <Ws> -Workspace <Ws> -Bots <Ws>\bots', '解析 ##RESULT 与退出码') `
    -Assertion 'exit 0；##RESULT ok=1；failed=0' `
    -Expected 'exit=0, ok=1, failed=0' `
    -Actual ('exit=' + $fullRec.exitCode + '; ' + $fullNums.line) `
    -Evidence @($fullRec.stdoutPath, $fullRec.stderrPath) `
    -Preconditions @('{App}\tools\bootstrap.ps1 存在', '来宾可访问外网（组件下载需要）') `
    -Status $(if ($fullRec.exitCode -eq 0 -and $fullNums.ok -eq 1 -and $fullNums.failed -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('全量默认组件包含 1.6GB 的 ollama，耗时由心跳记录。单步预算 ' + $fullBudgetSeconds + 's，阶段总预算 ' + $script:PhaseBudgetTotal + 's（宿主 full 上限 10800s）。timedOut=' + [bool]$fullRec.timedOut + '；被预算夹紧的步骤：' + $script:BudgetClamped.Count) `
    -Data ([ordered]@{ exitCode = $fullRec.exitCode; result = $fullNums; timedOut = [bool]$fullRec.timedOut; harnessTimeout = [bool]($fullRec.PSObject.Properties['harnessTimeout']); stepBudgetSeconds = $fullBudgetSeconds; phaseBudgetSeconds = $script:PhaseBudgetTotal; clamped = @($script:BudgetClamped) })

  # ---- AstrBot 初始化 / 进程 / 监听 / HTTP
  Set-MwProgress -Step 'full-2 - 核对 AstrBot 真实初始化'
  $astrExe = Join-Path $AstrRoot 'bin\astrbot.exe'
  $astrPy = Join-Path $AstrRoot 'python\python.exe'
  $astrInited = Test-Path -LiteralPath (Join-Path $AstrRoot '.astrbot')
  $pyVerRec = $null
  if (Test-Path -LiteralPath $astrPy) {
    $pyVerRec = Invoke-Cap -Label 'astrbot-python-version' -FilePath $astrPy -Arguments @('--version') -TimeoutSeconds 60 `
      -StepText 'full-2 - AstrBot Python 版本'
  }
  $pyVer = ''
  if ($pyVerRec) { $pyVer = ([string]$pyVerRec.stdoutText).Trim() }
  Add-PhaseCheck -Id 'c9-astrbot-init' -Criterion 9 `
    -Requirement 'AstrBot 真实初始化（init --yes）且运行环境就位' `
    -Steps @('检查 {AstrBot}\.astrbot 文件', '检查 bin\astrbot.exe 与 python\python.exe --version') `
    -Assertion '.astrbot 是文件；python 版本为 3.12.16' `
    -Expected 'Python 3.12.16' -Actual $pyVer `
    -Evidence @($AstrRoot, $(if ($pyVerRec) { $pyVerRec.stdoutPath } else { $AstrRoot }), $(if ($pyVerRec) { $pyVerRec.stderrPath } else { $AstrRoot })) `
    -Preconditions @('astrbot 组件已安装（astrbot 可执行文件存在）') `
    -Status $(if ($astrInited -and (Test-Path -LiteralPath $astrExe) -and $pyVer -match '^Python 3\.12\.16') { 'pass' } else { 'fail-product' }) `
    -Detail '.astrbot 是文件（不是目录），这是 start-astrbot 判断已初始化的依据。' `
    -Data ([ordered]@{ astrbotFile = $astrInited; exe = (Test-Path -LiteralPath $astrExe); python = $pyVer })

  # 全量安装的 astrbot 步骤本身会调 start-astrbot.ps1；这里再做一次“确保在跑”，
  # 避免安装尾段进程被系统回收导致监听检查假失败（这不算降低标准，仍要求真实监听）。
  $startScript = Join-Path $App 'tools\start-astrbot.ps1'
  $bootStart = $null
  if (Test-Path -LiteralPath $startScript) {
    $bootStart = Ensure-AstrbotRunning -AstrRoot $AstrRoot -Base $Ws -StartScript $startScript -WaitSeconds 300
  }
  $listeners = @(Get-AstrbotListener)
  $httpLine = ''
  $httpOk = $false
  $httpProbes = New-Object System.Collections.ArrayList
  if ($listeners.Count -gt 0) {
    # M-10：4xx/5xx 不算“有响应”。只接受 2xx，并把三个候选路径的原始状态逐条落证据。
    foreach ($hp in @('/','/api/stat','/login')) {
      $hUri = 'http://127.0.0.1:6185' + $hp
      $hCode = 0
      $hNote = ''
      try {
        $hResp = Invoke-WebRequest -Uri $hUri -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $hCode = [int]$hResp.StatusCode
        try { $hNote = 'contentLength=' + ([string]$hResp.Content).Length } catch { $hNote = 'content-unreadable' }
      } catch {
        try { if ($_.Exception.Response) { $hCode = [int]$_.Exception.Response.StatusCode } } catch { $hCode = 0 }
        $hNote = $_.Exception.Message
      }
      [void]$httpProbes.Add([ordered]@{ uri = $hUri; status = $hCode; note = $hNote })
      if ($hCode -ge 200 -and $hCode -lt 300 -and -not $httpOk) {
        $httpOk = $true
        $httpLine = ('HTTP ' + $hCode + ' ' + $hp)
      }
    }
    if (-not $httpOk) {
      $httpLine = 'no-2xx: ' + (($httpProbes | ForEach-Object { [string]$_.status }) -join ',')
    }
  }
  $httpEv = Save-EvidenceJson -Name 'astrbot-http.json' -Object $httpProbes
  $rootOwned = $false
  foreach ($l in $listeners) {
    if (([string]$l.exe).StartsWith($AstrRoot, [StringComparison]::OrdinalIgnoreCase) -or ([string]$l.cmd) -like ('*' + $AstrRoot + '*')) { $rootOwned = $true }
  }
  $listenEv = Save-EvidenceJson -Name 'astrbot-listener.json' -Object $listeners
  Add-PhaseCheck -Id 'c9-astrbot-process' -Criterion 9 `
    -Requirement 'AstrBot 真后台运行：6185 监听、进程归属正确、HTTP 有响应' `
    -Steps @('Get-NetTCPConnection 6185 Listen', '按 OwningProcess 取 ExecutablePath/CommandLine', 'GET http://127.0.0.1:6185/') `
    -Assertion '有监听；进程路径/命令行落在 AstrBot 根下；至少一个路径返回 HTTP 2xx（4xx/5xx 不算有响应）' `
    -Expected '监听 + 根归属 + HTTP 2xx' `
    -Actual ('listeners=' + $listeners.Count + '; rootOwned=' + $rootOwned + '; ' + $httpLine) `
    -Evidence @($listenEv, $httpEv) `
    -Preconditions @('AstrBot 配置已写入 cmd_config.json', 'AstrBot 进程已启动并记录 pid') `
    -Status $(if ($listeners.Count -gt 0 -and $rootOwned -and $httpOk) { 'pass' } else { 'fail-product' }) `
    -Detail ('只验证进程与端口，不验证真实对话。HTTP 判定口径：/,/api/stat,/login 任一返回 2xx 才算通过；404/500 不通过（详见 astrbot-http.json）。启动保障：restarted=' + $(if ($bootStart) { [bool]$bootStart.restarted } else { 'n/a' }) + '；pids=' + $(if ($bootStart) { (@($bootStart.pids) -join ',') } else { '' })) `
    -Data ([ordered]@{ listeners = $listeners; rootOwned = $rootOwned; http = $httpLine; httpProbes = @($httpProbes); bootRestarted = $(if ($bootStart) { [bool]$bootStart.restarted } else { $null }) })

  # ---- 模型桩 + answers + AstrBot 配置 + 八块自设定
  Set-MwProgress -Step 'full-3 - 准备模型桩与自设定答案'
  $secretsDir = Join-Path $Ws 'secrets'
  $script:WsSecrets = $secretsDir
  if (-not (Test-Path -LiteralPath $secretsDir)) { New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null }
  Write-FixtureFile -Path (Join-Path $secretsDir 'deepseek-key.txt') -Content $script:TestKey -Bom $false
  Write-FixtureFile -Path (Join-Path $Ws 'private\backend.txt') -Content ("url: http://127.0.0.1:6185`nusername: admin`npassword: MwFix-2026-TestOnly`n") -Bom $false

  $stub = $null
  if (Test-Path -LiteralPath $astrPy) { $stub = Start-ModelStub -Python $astrPy -Dir $FixtureDir }
  $stubEv = Save-EvidenceJson -Name 'model-stub.json' -Object ([ordered]@{
    listening = $(if ($stub) { $stub.Listening } else { $false }); script = $(if ($stub) { $stub.Script } else { '' })
    stdout = $(if ($stub) { $stub.Stdout } else { '' }); stderr = $(if ($stub) { $stub.Stderr } else { '' })
    pid = $(if ($stub -and $stub.Process) { $stub.Process.Id } else { $null })
    commandLine = $(if ($stub -and $stub.State) { $stub.State.Record.commandLine } else { '' })
    port = 18080; scope = '只证明 OpenAI 兼容配置协议，不是真实 DeepSeek'
  })

  $answers = [ordered]@{
    base_url = 'http://127.0.0.1:18080/v1'
    backend_url = 'http://127.0.0.1:6185'
    memory = 0; voice = 0; video = 0
    deepseek_key_file = 'secrets/deepseek-key.txt'
  }
  $answersPath = Join-Path $Ws 'answers.json'
  Save-MwJson -Path $answersPath -Object $answers -NoSafe

  if (Test-Path -LiteralPath $astrExe) {
    [void](Invoke-Cap -Label 'astrbot-conf-username' -FilePath $astrExe -Arguments @('conf','set','dashboard.username','admin') -TimeoutSeconds 120 -WorkDir $AstrRoot -StepText 'full-3 - AstrBot 面板用户名')
    [void](Invoke-Cap -Label 'astrbot-conf-password' -FilePath $astrExe -Arguments @('conf','set','dashboard.password','MwFix-2026-TestOnly') -TimeoutSeconds 120 -WorkDir $AstrRoot -StepText 'full-3 - AstrBot 面板密码')
  }

  $startScript = Join-Path $App 'tools\start-astrbot.ps1'
  $startRec = $null
  if (Test-Path -LiteralPath $startScript) {
    $startRec = Invoke-Long -Label 'astrbot-restart' -FilePath $startScript `
    -CheckId 'c9-astrbot-process' `
      -Arguments @('-Root',$AstrRoot,'-Base',$Ws,'-Restart') -TimeoutSeconds 600 `
      -StepText 'full-3 - 启动 AstrBot 后台'
  }
  $listeners2 = @(Get-AstrbotListener)
  $startOk = ($startRec -and $startRec.exitCode -eq 0 -and $listeners2.Count -gt 0)

  $selfText = ''
  $applyRec = $null
  $verifyRec = $null
  $applyOk = $false
  $verifyOk = $false
  if (Test-Path -LiteralPath $SelfSetup) {
    $applyRec = Invoke-Long -Label 'self-setup-apply' -FilePath $SelfSetup `
    -CheckId 'c9-selfsetup-apply' `
      -Arguments @('-Base',$Ws,'-Answers',$answersPath) -TimeoutSeconds 1800 `
      -StepText 'full-4 - 八块自设定 apply'
    $selfText = [string]$applyRec.stdoutText + "`n" + [string]$applyRec.stderrText
    $applyOk = ($applyRec.exitCode -eq 0 -and $selfText -match 'RESULT\s+ok=1\s+done=8\s+fail=0')

    $verifyRec = Invoke-Long -Label 'self-setup-verify' -FilePath $SelfSetup `
    -CheckId 'c9-selfsetup-verify' `
      -Arguments @('-Base',$Ws,'-Answers',$answersPath,'-Verify') -TimeoutSeconds 900 `
      -StepText 'full-4 - 八块自设定 verify'
    $verifyText = [string]$verifyRec.stdoutText + "`n" + [string]$verifyRec.stderrText
    $selfText = $selfText + "`n" + $verifyText
    $verifyOk = ($verifyRec.exitCode -eq 0 -and $verifyText -match 'RESULT\s+ok=1\s+done=8\s+fail=0')
  }

  Add-PhaseCheck -Id 'c9-selfsetup-apply' -Criterion 9 `
    -Requirement '八块自设定真实 apply（provider/platform/chat/plugins/memory/voice/persona/verify）' `
    -Steps @('写 answers.json（base_url 指向本机桩）', '运行 self-setup.ps1 -Base <Ws> -Answers answers.json') `
    -Assertion 'exit 0；RESULT ok=1 done=8 fail=0' `
    -Expected 'ok=1 done=8 fail=0' `
    -Actual $(if ($applyRec) { [string]$applyRec.exitCode } else { 'not-run' }) `
    -Evidence @($answersPath, $(if ($applyRec) { $applyRec.stdoutPath } else { $answersPath }), $(if ($applyRec) { $applyRec.stderrPath } else { $answersPath })) `
    -Preconditions @('answers.json 已写入且 self-setup.ps1 存在') `
    -Status $(if ($applyOk) { 'pass' } elseif (-not $applyRec) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail 'memory=0/voice=0 时对应块按设计直接 Ok，不代表记忆/语音链路可用。' `
    -Data ([ordered]@{ exitCode = $(if ($applyRec) { $applyRec.exitCode } else { $null }); resultLine = $(if ($applyRec) { (Get-FirstLineMatch -Text ([string]$applyRec.stdoutText) 'RESULT\s+') } else { '' }) })

  Add-PhaseCheck -Id 'c9-selfsetup-verify' -Criterion 9 `
    -Requirement '八块自设定 verify 通过' `
    -Steps @('运行 self-setup.ps1 -Verify') `
    -Assertion 'exit 0；RESULT ok=1 done=8 fail=0' `
    -Expected 'ok=1 done=8 fail=0' -Actual $(if ($verifyRec) { [string]$verifyRec.exitCode } else { 'not-run' }) `
    -Evidence @($(if ($verifyRec) { $verifyRec.stdoutPath } else { $answersPath }), $(if ($verifyRec) { $verifyRec.stderrPath } else { $answersPath })) `
    -Preconditions @('apply 已执行并返回（上一步记录输出）') `
    -Status $(if ($verifyOk) { 'pass' } elseif (-not $verifyRec) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail '只验证配置协议，不验证真实模型回答。' `
    -Data ([ordered]@{ exitCode = $(if ($verifyRec) { $verifyRec.exitCode } else { $null }) })

  # 配置里必须真的出现桩地址；出现真实 api.deepseek.com 才说明这一步没被验收桩替换
  $configHits = New-Object System.Collections.ArrayList
  $realDeepSeek = New-Object System.Collections.ArrayList
  $cfgDir = Join-Path $AstrRoot 'data\config'
  if (Test-Path -LiteralPath $cfgDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $cfgDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      if ($f.Length -gt 2097152) { continue }
      $t = Read-TextAuto -Path $f.FullName
      if ($t -match '127\.0\.0\.1:18080') { [void]$configHits.Add($f.FullName) }
      if ($t -match 'api\.deepseek\.com') { [void]$realDeepSeek.Add($f.FullName) }
    }
  }
  $cfgEv = Save-EvidenceJson -Name 'model-config-scan.json' -Object ([ordered]@{ stubFiles = @($configHits); realDeepSeekFiles = @($realDeepSeek); stub = $stubEv })
  # M-09：只看配置文本会把“桩没起来”也算通过。这里对桩端点做一次真实请求，只有 2xx 才算协议证据成立。
  $stubProbe = [ordered]@{ uri = 'http://127.0.0.1:18080/v1/models'; status = 0; ok = $false; note = ''; listeningFlag = ($stub -and [bool]$stub.Listening) }
  try {
    $stubResp = Invoke-WebRequest -Uri $stubProbe.uri -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    $stubProbe.status = [int]$stubResp.StatusCode
    $stubProbe.ok = ($stubProbe.status -ge 200 -and $stubProbe.status -lt 300)
    try { $body = [string]$stubResp.Content; $stubProbe.note = $body.Substring(0, [Math]::Min(200, $body.Length)) } catch { }
  } catch {
    try { if ($_.Exception.Response) { $stubProbe.status = [int]$_.Exception.Response.StatusCode } } catch { }
    $stubProbe.note = $_.Exception.Message
  }
  $stubProbeEv = Save-EvidenceJson -Name 'model-stub-probe.json' -Object $stubProbe
  Add-PhaseCheck -Id 'c9-model-stub-protocol' -Criterion 9 `
    -Requirement '模型桩只证明配置协议（provider 指向 127.0.0.1:18080）' `
    -Steps @('在 AstrBot data\config 中搜索 18080', '搜索 api.deepseek.com 以确认没有走真实服务') `
    -Assertion '桩端点返回 2xx；至少一个配置文件引用本机桩；不宣称真实 DeepSeek 联通' `
    -Expected '桩 /v1/models 返回 2xx，且配置引用 18080' `
    -Actual ('stubHttp=' + $stubProbe.status + ' (ok=' + $stubProbe.ok + '); stubFiles=' + $configHits.Count + '; realDeepSeek=' + $realDeepSeek.Count) `
    -Evidence @($cfgEv, $stubProbeEv) `
    -Preconditions @('本地模型桩已监听端口（stub 记录 pid/port）') `
    -Status $(if ($configHits.Count -eq 0 -or $realDeepSeek.Count -gt 0) { 'fail-product' } elseif ($stubProbe.ok) { 'pass' } else { 'evidence-incomplete' }) `
    -Detail '这是配置协议证据，不是模型可用性证据；桩返回固定 OK。桩未监听时只能算证据不完整，不能算通过。' `
    -Data ([ordered]@{ stubFiles = @($configHits); realDeepSeekFiles = @($realDeepSeek); stubProbe = $stubProbe })

  # ---- 项 5：装齐后 Check 必须 0
  Set-MwProgress -Step 'full-5 - 装齐后 Check'
  $postCheck = Invoke-Cap -Label 'check-after-components' -FilePath $Bootstrap `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Check') -TimeoutSeconds 900 `
    -StepText 'full-5 - 装齐后 Check（同一安装实例）'
  $postNums = Get-BootstrapNumbers -Text ([string]$postCheck.stdoutText)
  $postOk = ($postCheck.exitCode -eq 0 -and $postNums.missing -eq 0 -and $postNums.failed -eq 0)
  # 跨阶段引出 pre 的“装前 Check”结论（同一 RunId 的 pre 阶段证据），避免在本阶段重跑已装状态
  $preC5Text = ''
  $preC5Path = Join-Path $RunDir 'pre\checks\c5-check-before-components.json'
  if (Test-Path -LiteralPath $preC5Path) {
    try { $preC5Text = [string]((ConvertFrom-Json -InputObject (Read-TextAuto -Path $preC5Path)).actual) } catch { }
  }
  if (-not $preC5Text) { $preC5Text = 'pre 阶段证据缺失：' + $preC5Path }
  Add-PhaseCheck -Id 'c5-check-after-components' -Criterion 5 `
    -Requirement '同一安装实例：组件装齐后 Check 必须 exit 0' `
    -Steps @('全量安装完成后运行 bootstrap -Check') `
    -Assertion 'exit 0；missing=0；failed=0' `
    -Expected 'exit=0' -Actual ('exit=' + $postCheck.exitCode + '; ' + $postNums.line) `
    -Evidence @($postCheck.stdoutPath, $postCheck.stderrPath) `
    -Preconditions @('full 默认执行已完成（bootstrap 退出码已记录）') `
    -Status $(if ($postOk) { 'pass' } else { 'fail-product' }) `
    -Detail 'Check 不是只读：缺项时 Dirty 会写 state/日志；这里装齐后应无变化。' `
    -Data ([ordered]@{ exitCode = $postCheck.exitCode; result = $postNums; before = $preC5Text })

  # ---- 项 2：下载缓存与清单哈希的实际对应
  Set-MwProgress -Step 'full-6 - 核对下载缓存哈希'
  $dlDir = Join-Path $Ws 'logs\setup\dl'
  $cacheRows = New-Object System.Collections.ArrayList
  $mismatch = 0
  $matched = 0
  if (Test-Path -LiteralPath $dlDir) {
    foreach ($c in $comps) {
      foreach ($st in @($c.install.steps)) {
        if ([string]$st.kind -ne 'download') { continue }
        $expect = ([string]$st.sha256).ToUpper()
        # 缓存文件名规则（tools/bootstrap.ps1）：<组件id>-<url 文件名>
        $url0 = [string](@($st.urls)[0])
        if (-not $url0) { $url0 = [string]$st.url }
        $fname = ''
        if ($url0) { try { $fname = [IO.Path]::GetFileName(($url0 -split '\?')[0]) } catch { $fname = '' } }
        $cands = @()
        if ($fname) {
          $want = $c.id + '-' + $fname
          $cands = @(Get-ChildItem -LiteralPath $dlDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $want })
        }
        if ($cands.Count -eq 0) {
          $cands = @(Get-ChildItem -LiteralPath $dlDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($c.id + '-*') })
        }
        $actual = ''
        $file = ''
        if ($cands.Count -gt 0) {
          $file = $cands[0].FullName
          try { $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToUpper() } catch { $actual = '' }
        }
        $match = ($expect -ne '' -and $actual -eq $expect)
        if ($match) { $matched++ } elseif ($file -ne '') { $mismatch++ }
        [void]$cacheRows.Add([ordered]@{ id = $c.id; expected = $expect; actual = $actual; file = $file; match = $match })
      }
    }
  }
  $cacheEv = Save-EvidenceJson -Name 'download-cache-hashes.json' -Object $cacheRows
  Add-PhaseCheck -Id 'c2-download-cache-hashes' -Criterion 2 `
    -Requirement '安装时真正落盘的下载资产与清单 sha256 一致' `
    -Steps @('枚举 {Ws}\logs\setup\dl 下各组件的缓存文件', '逐文件 SHA256 与 install.steps[].sha256 比对') `
    -Assertion '已缓存资产哈希一致；不一致数为 0' `
    -Expected 'mismatch=0' -Actual ('matched=' + $matched + ', mismatch=' + $mismatch + ', rows=' + $cacheRows.Count) `
    -Evidence @($cacheEv, $dlDir) `
    -Preconditions @('下载缓存目录存在（full 安装产生）') `
    -Status $(if ($mismatch -eq 0 -and $matched -ge 5) { 'pass' } elseif ($mismatch -gt 0) { 'fail-product' } else { 'evidence-incomplete' }) `
    -Detail 'webview2 已存在时不会下载，因此这类组件没有缓存行是正常的；matched 至少 5 才认为链路被覆盖。' `
    -Data @($cacheRows)

  # ---- 项 6：严格幂等（AstrBot 保持运行；先测 90s 自然写入作为归因基线）
  Set-MwProgress -Step 'full-7 - 严格幂等：确保后台在跑并测自然写入'
  $runState = Ensure-AstrbotRunning -AstrRoot $AstrRoot -Base $Ws -StartScript $startScript -WaitSeconds 300
  $map0 = Get-FileMap -Roots @($Ws, $App)
  Start-Sleep -Seconds 90
  $map1 = Get-FileMap -Roots @($Ws, $App)
  $natural = @(Compare-FileMaps -Before $map0.Map -After $map1.Map)
  $naturalKeys = @{}
  foreach ($c in $natural) {
    $k = [string]$c
    $i = $k.IndexOf(':')
    if ($i -ge 0) { $naturalKeys[$k.Substring($i + 1)] = $true }
  }
  $firstSnap = Save-EvidenceJson -Name 'idempotency-before.json' -Object ([ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o'); files = $map1.Map.Count; skipped = $map1.Skipped
    astrbotRestarted = [bool]$runState.restarted; astrbotPids = @($runState.pids)
    controlWindowSeconds = 90; naturalChanges = $natural.Count; naturalSample = @($natural | Select-Object -First 80)
  })

  Set-MwProgress -Step 'full-8 - 第二次默认执行'
  $secondStartUtc = (Get-Date).ToUniversalTime()
  $secondRec = Invoke-Long -Label 'bootstrap-second-run' -FilePath $Bootstrap `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot) -TimeoutSeconds 7200 `
    -StepText 'full-8 - 第二次默认执行（幂等）'
  $secondText = [string]$secondRec.stdoutText + "`n" + [string]$secondRec.stderrText
  $secondNums = Get-BootstrapNumbers -Text $secondText

  Set-MwProgress -Step 'full-9 - 取第二次快照并按路径归因'
  $map2 = Get-FileMap -Roots @($Ws, $App)
  $changes = @(Compare-FileMaps -Before $map1.Map -After $map2.Map)
  $installerChanges = New-Object System.Collections.ArrayList
  $ambiguousChanges = New-Object System.Collections.ArrayList
  $afterStartChanges = New-Object System.Collections.ArrayList
  foreach ($c in $changes) {
    $k = [string]$c
    $i = $k.IndexOf(':')
    $mapKey = $(if ($i -ge 0) { $k.Substring($i + 1) } else { $k })
    $mtime = ''
    if ($map2.Map.Contains($mapKey)) { $mtime = [string]$map2.Map[$mapKey].mtime }
    $changedDuringSecondRun = $false
    if ($mtime) {
      try { $changedDuringSecondRun = ([datetime]::Parse($mtime).ToUniversalTime() -ge $secondStartUtc) } catch { $changedDuringSecondRun = $false }
    }
    if ($changedDuringSecondRun) {
      # M-20：第二次执行开始之后才写入的文件，不可能由 90s 自然基线解释，直接归因安装器。
      [void]$installerChanges.Add($k)
      [void]$afterStartChanges.Add($k)
    } elseif ($naturalKeys.ContainsKey($mapKey)) {
      [void]$ambiguousChanges.Add($k)
    } else {
      [void]$installerChanges.Add($k)
    }
  }
  $changeSample = @($installerChanges | Select-Object -First 80)
  $secondEv = Save-EvidenceJson -Name 'idempotency-after.json' -Object ([ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o'); files = $map2.Map.Count; skipped = $map2.Skipped
    totalChanges = $changes.Count; installerAttributed = $installerChanges.Count
    secondRunStartUtc = $secondStartUtc.ToString('o'); afterSecondStart = @($afterStartChanges | Select-Object -First 80)
    ambiguous = @($ambiguousChanges | Select-Object -First 80)
    naturalBaseline = @($natural | Select-Object -First 80)
    installerSample = $changeSample; result = $secondNums
  })

  Add-PhaseCheck -Id 'c6-idempotent-exit' -Criterion 6 `
    -Requirement '第二次默认执行不重复安装（fixed=0）且成功' `
    -Steps @('确保 AstrBot 在跑（否则 detect 会把安装判成缺失）', '先测 90s 自然写入基线', '用完全相同的默认参数再跑一次', '解析 ##RESULT') `
    -Assertion 'exit 0；ok=1；fixed=0' `
    -Expected 'exit=0, fixed=0' -Actual ('exit=' + $secondRec.exitCode + '; ' + $secondNums.line) `
    -Evidence @($secondRec.stdoutPath, $secondRec.stderrPath) `
    -Preconditions @('第一次默认执行已完成且退出码 0') `
    -Status $(if ($secondRec.exitCode -eq 0 -and $secondNums.ok -eq 1 -and $secondNums.fixed -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('AstrBot 保持运行（restarted=' + [bool]$runState.restarted + '；pid=' + (@($runState.pids) -join ',') + '），避免把“后台停了”误判成安装器重复安装。') `
    -Data ([ordered]@{ exitCode = $secondRec.exitCode; result = $secondNums; astrbotPids = @($runState.pids); restarted = [bool]$runState.restarted })

  Add-PhaseCheck -Id 'c6-idempotent-files' -Criterion 6 `
    -Requirement '第二次执行不改变文件集合/内容/时间戳（覆盖程序目录根与工作区）' `
    -Steps @('记录 {Ws} 与 {App} 全量 sha256+size+mtime', '第二次执行后再记录', '比较新增/缺失/内容/时间戳', '用 90s 控制窗口把后台自然写入从归因中扣除') `
    -Assertion 'installer 归因变化=0；比较范围不排除 logs/state/新增文件' `
    -Expected 'installerChanges=0' -Actual ('installerChanges=' + $installerChanges.Count + '; total=' + $changes.Count + '; ambiguous=' + $ambiguousChanges.Count + '; before=' + $map1.Map.Count + '; after=' + $map2.Map.Count) `
    -Evidence @($firstSnap, $secondEv) `
    -Preconditions @('第一次默认执行的文件图已落盘（idempotency-before.json）') `
    -Status $(if ($installerChanges.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('测量条件：AstrBot 运行中（pid ' + (@($runState.pids) -join ',') + '）；控制窗口 90s；范围=工作区+程序目录根；阈值=sha256/大小/mtimeUtc 全等。归因规则（M-20）：① 文件 mtime 晚于第二次执行开始时间 → 安装器（后写的不可能是自然基线）；② 否则落在 90s 自然基线路径上的 → ambiguous；③ 其余 → installer。afterSecondStart=' + $afterStartChanges.Count + '，ambiguous=' + $ambiguousChanges.Count + '。') `
    -Data ([ordered]@{ installerChanges = $changeSample; installerTotal = $installerChanges.Count; afterSecondStart = @($afterStartChanges | Select-Object -First 40); ambiguous = @($ambiguousChanges | Select-Object -First 40); naturalBaseline = @($natural | Select-Object -First 40); skipped = @($map1.Skipped + $map2.Skipped); secondRunStartUtc = $secondStartUtc.ToString('o') })

  # ---- 项 10：密钥扫描
  Set-MwProgress -Step 'full-10 - 密钥扫描'
  # 范围：GuestRoot（程序/工作区/日志/缓存/验收产物）+ 用户设置 + %TEMP% 下的产品相关目录。
  # %TEMP% 全量枚举太慢，按名字过滤（mingling/mw/astrbot/uv/npm/setup），未命中的不扫，
  # 这一点会在 Detail 里如实写明，算“跳过项”而不是“已覆盖”。
  $tempRoots = @()
  try {
    $tempRoots = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)mingling|mw|astrbot|uv|npm|bootstrap|setup' } |
      ForEach-Object { $_.FullName })
  } catch { }
  # M-08：补上默认安装目录（%LOCALAPPDATA%\Programs\MinglingWorkbench）与机器级 ProgramData，
  # 否则“密钥没进程序目录”只是没扫到默认安装位置。
  $extraRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\MinglingWorkbench'),
    (Join-Path $env:APPDATA 'MinglingWorkbench'),
    (Join-Path $env:ProgramData 'MinglingWorkbench')
  )
  $scanRoots = @($GuestRoot) + @($extraRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) + $tempRoots
  $scan = Invoke-KeyScan -Key $script:TestKey -Roots $scanRoots
  $bad = @($scan.Hits | Where-Object { $_.bad })
  $scanRows = [ordered]@{
    keyLength = $script:TestKey.Length; keyPrefix = 'sk-mwfix-<redacted>'
    scanned = $scan.Scanned; hits = @($scan.Hits).Count; badHits = $bad.Count
    skipped = @($scan.Skipped); unreadable = @($scan.Unreadable)
    roots = $scanRoots; tempDirs = @($tempRoots); maxBytes = 67108864
  }
  $scanEv = Save-EvidenceJson -Name 'key-scan.json' -Object $scanRows
  Add-PhaseCheck -Id 'c10-key-scan' -Criterion 10 `
    -Requirement '合成密钥只出现在工作区 secrets，不得泄漏到程序/日志/缓存/临时/验收产物' `
    -Steps @('在 {Ws}\secrets\deepseek-key.txt 写入合成 key', '扫描 GuestRoot 与 %APPDATA%\MinglingWorkbench 的所有文件（ASCII/UTF16LE/BE）', '按路径分类，不输出密钥原文') `
    -Assertion 'scanned>0；badHits=0；不可读=0；跳过项单独记录' `
    -Expected 'badHits=0, unreadable=0' -Actual ('scanned=' + $scan.Scanned + ', hits=' + @($scan.Hits).Count + ', bad=' + $bad.Count + ', unreadable=' + @($scan.Unreadable).Count) `
    -Evidence @($scanEv, (Join-Path $Ws 'secrets\deepseek-key.txt')) `
    -Preconditions @('配置流程已结束（cmd_config.json 等可能含密钥的文件已生成）') `
    -Status $(if ($bad.Count -gt 0) { 'fail-product' } elseif ($scan.Scanned -gt 0 -and @($scan.Unreadable).Count -eq 0) { 'pass' } else { 'evidence-incomplete' }) `
    -Detail ('扫描根：' + ($scanRoots -join ' ; ') + '；%TEMP% 只按名字过滤后扫描，未命中的目录属于已知未覆盖范围；大于 64MB 的文件按“首尾各 8MB 部分扫描”处理并标 partial-large（' + @($scan.Skipped).Count + ' 个），不是整块跳过。命中路径只记路径，不记内容。') `
    -Data $scanRows

  # ---- 项 11：默认 manual 独立性
  Set-MwProgress -Step 'full-11 - 默认 manual 组件'
  $manDef = Invoke-Cap -Label 'check-default-manual' -FilePath $Bootstrap `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Check') -TimeoutSeconds 900 `
    -StepText 'full-11 - 默认 Check 的 manual 计数'
  $manDefText = [string]$manDef.stdoutText
  $manDefNums = Get-BootstrapNumbers -Text $manDefText
  $manDefOks = Get-OkIds -Text $manDefText
  $manualIds = @('qq-login','bili-login','deepseek-provider')
  $manualWrongOk = @($manDefOks | Where-Object { $manualIds -contains $_ })
  # 区分“人工项被检测为已满足”与“被安装器当成可安装项修好”：后者才是误报完成。
  $manualFixed = @()
  foreach ($m in [regex]::Matches($manDefText, '##OK\s+([^|\r\n]+)\|([^\r\n]*)')) {
    $mid = $m.Groups[1].Value.Trim()
    $mdet = $m.Groups[2].Value
    if (($manualIds -contains $mid) -and ($mdet -notmatch '已满足')) { $manualFixed += $mid }
  }
  $manualAccounted = [int]$manDefNums.manual + $manualWrongOk.Count
  Add-PhaseCheck -Id 'c11-default-manual' -Criterion 11 `
    -Requirement '默认执行时未完成的 manual 组件不被报成完成、不被安装器代做' `
    -Steps @('运行默认 -Check', '解析 manual 计数与 ##OK 明细（区分“已满足”与“装好了”）') `
    -Assertion 'manual 计数 + 检测为已满足的人工项 >= 3；没有任何人工项被当成可安装项修好' `
    -Expected 'accounted>=3 且 manualFixed=0' `
    -Actual ('manual=' + $manDefNums.manual + '; satisfiedManual=' + ($manualWrongOk -join ',') + '; fixedManual=' + ($manualFixed -join ',')) `
    -Evidence @($manDef.stdoutPath, $manDef.stderrPath) `
    -Preconditions @('默认执行已完成（state.json 可读）') `
    -Status $(if ($manualAccounted -ge 3 -and $manualFixed.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail 'qq-login/bili-login/deepseek-provider 是人工项；detect 命中时输出“已满足”是允许的，但绝不能出现“装好了”。若复用已登录 profile，manual 计数可能少于 3，此时用“已满足”的人工项补足。' `
    -Data ([ordered]@{ exitCode = $manDef.exitCode; result = $manDefNums; okIds = @($manDefOks); satisfiedManual = @($manualWrongOk); fixedManual = @($manualFixed) })

  # 收尾：停模型桩（AstrBot 保持运行，供后续 check/阶段使用）
  $stubStopRec = Stop-ModelStub -Stub $stub
  [void](Save-EvidenceJson -Name 'model-stub-stop.json' -Object ([ordered]@{
    stdoutPath = $(if ($stubStopRec) { $stubStopRec.stdoutPath } else { '' })
    stderrPath = $(if ($stubStopRec) { $stubStopRec.stderrPath } else { '' })
    exitCode = $(if ($stubStopRec) { $stubStopRec.exitCode } else { $null })
  }))
  $summary.metrics['stubListening'] = $(if ($stub) { $stub.Listening } else { $false })
}

# ================================================================ 阶段：recovery
function Copy-TreeIfExists {
  param([string]$From, [string]$To)
  if (-not (Test-Path -LiteralPath $From)) { return $false }
  if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Force -Path $To | Out-Null }
  # 通配符复制必须用 -Path（旧夹具的 -LiteralPath + * 是缺陷）
  Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force -ErrorAction Stop
  return $true
}

function Get-NodeExeFromLayout {
  param([string]$Root)
  $direct = Join-Path $Root 'sidecar\node\node.exe'
  if (Test-Path -LiteralPath $direct) { return $direct }
  $side = Join-Path $Root 'sidecar'
  if (Test-Path -LiteralPath $side) {
    foreach ($d in @(Get-ChildItem -LiteralPath $side -Directory -ErrorAction SilentlyContinue)) {
      $c = Join-Path $d.FullName 'node.exe'
      if (Test-Path -LiteralPath $c) { return $c }
    }
  }
  # 不递归整棵树（工作区可能很大）：只再试几个已知的浅层布局
  foreach ($rel in @('node\node.exe','bots\node\node.exe','tools\node\node.exe','sidecar\nodejs\node.exe')) {
    $c2 = Join-Path $Root $rel
    if (Test-Path -LiteralPath $c2) { return $c2 }
  }
  return ''
}

function Resolve-Qrcode {
  param([string]$NodeExe, [string]$ProjectDir, [string]$Label)
  $rec = $null
  $cwd = ''
  Push-Location -LiteralPath $ProjectDir
  try {
    $cwd = (Get-Location).Path
    $rec = Invoke-Cap -Label $Label -FilePath $NodeExe -Arguments @('-e', "require.resolve('qrcode')") `
      -WorkDir $ProjectDir -TimeoutSeconds 60 -StepText ('recovery - qrcode 解析（cwd=' + $ProjectDir + '）')
  } finally {
    Pop-Location
  }
  return [pscustomobject]@{ Record = $rec; Cwd = $cwd }
}

function Invoke-RecoveryPhase {
  if (-not (Test-Path -LiteralPath $Bootstrap)) {
    Add-PhaseCheck -Id 'c0-recovery-precondition' -Criterion 7 -Requirement 'pre/full 已装好 3.1' `
      -Assertion '存在 {App}\tools\bootstrap.ps1' -Expected $Bootstrap -Actual '缺失' `
      -Preconditions @('pre/full 已安装 3.1 主程序') `
      -Status 'blocked-precondition' -Detail '安装未完成，无法做中断恢复。'
    return
  }

  # ---------- A. 真实中断恢复
  Set-MwProgress -Step 'recovery-1 - 启动可观察安装并中断进程树'
  $intState = Start-MwCommand -Label 'interrupt-bili-whale' -FilePath $Bootstrap `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Component','bili-whale','-Force') `
    -EvidenceDir $script:EvidenceDir -RunId $RunId
  $observed = ''
  $killed = $false
  $fallbackKill = $false
  $installPhaseSeen = $false
  $sw = [Diagnostics.Stopwatch]::StartNew()
  if ($intState.Started) {
    while (-not $intState.Process.HasExited -and $sw.Elapsed.TotalSeconds -lt 180) {
      $tail = Get-MwCommandTail -State $intState -Bytes 6000
      # 记录最后一个 ##STEP；只有真实进入安装动作（npm/node_modules/qrcode）才算“观察到安装阶段”。
      foreach ($mm in [regex]::Matches([string]$tail, '##STEP\s+\d+\|[^\r\n]*')) { $observed = $mm.Value }
      if ($observed -match 'npm|node_modules|qrcode') { $installPhaseSeen = $true; break }
      Start-Sleep -Milliseconds 400
    }
    # F-04：不再有“45s 无条件 fallbackKill”。只有真的看到安装阶段才结束进程树并计入 killed。
    if ($installPhaseSeen -and -not $intState.Process.HasExited) {
      [void](Stop-MwProcessTree -ProcessId $intState.Process.Id)
      $killed = $true
    }
    # 未见安装阶段但进程仍在：只做清理性终止，明确不计入 observed，也不冒充成功。
    if (-not $installPhaseSeen -and -not $intState.Process.HasExited) {
      [void](Stop-MwProcessTree -ProcessId $intState.Process.Id)
      $fallbackKill = $true
    }
  }
  $intRec = Complete-MwCommand -State $intState -TimeoutSeconds 120 -EvidenceDir $script:EvidenceDir
  [void]$commands.Add($intRec)
  $intPid = 0
  if ($intState.Process) { $intPid = $intState.Process.Id }
  $intEnc = Test-MwLaunchEncodedFailure -Record $intRec
  if ($intEnc.Bad) { [void]$script:LaunchAnomaliesAll.Add('interrupt-bili-whale → ' + (@($intEnc.Hits) -join '; ')) }
  $intEv = Save-EvidenceJson -Name 'interrupt.json' -Object ([ordered]@{
    observed = $observed; installPhaseSeen = $installPhaseSeen; killed = $killed; fallbackKill = $fallbackKill
    launchEncodedFailure = $intEnc.Bad; launchHits = @($intEnc.Hits)
    pid = $intPid; exitCode = $intRec.exitCode; elapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    stdout = $intRec.stdoutPath; stderr = $intRec.stderrPath; at = (Get-Date).ToUniversalTime().ToString('o')
  })
  Add-PhaseCheck -Id 'c7-interrupt-observed' -Criterion 7 `
    -Requirement '真实中断：在可观察安装阶段结束测试进程树' `
    -Steps @('以 -Component bili-whale -Force 启动 bootstrap', '轮询 stdout，直到 ##STEP 落在 npm/node_modules/qrcode 安装动作上', 'Stop-MwProcessTree 结束整棵进程树') `
    -Assertion '真实看到安装阶段（##STEP 含 npm/node_modules/qrcode）后才杀进程树；清理性终止不算 observed' `
    -Expected 'installPhaseSeen=true 且 killed=true 且 fallbackKill=false' -Actual ('observed=' + $observed + '; installPhaseSeen=' + $installPhaseSeen + '; killed=' + $killed + '; fallback=' + $fallbackKill + '; exit=' + $intRec.exitCode) `
    -Evidence @($intEv, $intRec.stdoutPath) `
    -Preconditions @('安装目标目录已清理（中断场景准备完成）', 'bootstrap.ps1 可执行') `
    -Status $(if ($intEnc.Bad) { 'fail-fixture' } elseif ($installPhaseSeen -and $killed -and -not $fallbackKill) { 'pass' } else { 'fail-fixture' }) `
    -Detail 'F-04：删除了旧夹具“45 秒后只要看到任意 ##STEP 就杀”的兜底——那会把 fallback 终止冒充成“观察到安装阶段”。若子进程退出码是 -196608（0xFFFD0000）或 stderr 报 -File 路径不存在，先按“参数编码/路径缺失，未真正执行”判 fail-fixture。现在只有轮询到 npm/node_modules/qrcode 阶段才杀并计 killed；若 180s 内没看到安装阶段（组件太快跑完或根本没进安装），只做清理性终止（fallbackKill=true），本项记 fail-fixture，绝不记 pass。' `
    -Data ([ordered]@{ observed = $observed; installPhaseSeen = $installPhaseSeen; killed = $killed; fallbackKill = $fallbackKill; pid = $intPid })

  $biliDir = Join-Path $BotsRoot 'bili-whale'
  $qrcodePkg = Join-Path $biliDir 'node_modules\qrcode\package.json'
  $qrcodeAfterKill = Test-Path -LiteralPath $qrcodePkg
  $nodeExe = Get-NodeExeFromLayout -Root $Ws
  if (-not $nodeExe) { $nodeExe = Get-NodeExeFromLayout -Root $App }
  $nodeDir = $(if ($nodeExe) { Split-Path -Parent $nodeExe } else { Join-Path $Ws 'sidecar\node' })
  $nodeMapBefore = Get-FileMap -Roots @($nodeDir)
  $nodeBeforeRec = $null
  $nodeHashBefore = ''
  if ($nodeExe) { $nodeHashBefore = (Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256).Hash.ToLower() }
  if ($nodeExe) { $nodeBeforeRec = Save-EvidenceJson -Name 'node-before-interrupt.json' -Object ([ordered]@{ exe = $nodeExe; hash = $nodeHashBefore; mtime = (Get-Item -LiteralPath $nodeExe).LastWriteTimeUtc.ToString('o') }) }

  $recPre = Get-MwLaunchPrecondition -Label 'recovery-offline-online' -Paths @($Bootstrap, $biliDir)
  $recPreEv = Save-EvidenceJson -Name 'launch-pre-recovery.json' -Object $recPre
  Set-MwProgress -Step 'recovery-2 - 中断后离线重跑（应失败）'
  $offlineAfterKill = Invoke-Long -Label 'bili-offline-after-interrupt' -FilePath $Bootstrap `
  -CheckId 'c7-offline-fails-after-interrupt' `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Component','bili-whale','-Offline') `
    -TimeoutSeconds 900 -StepText 'recovery-2 - 离线重跑 bili-whale'

  Set-MwProgress -Step 'recovery-3 - 联网重跑（应修好）'
  $onlineAfterKill = Invoke-Long -Label 'bili-online-after-interrupt' -FilePath $Bootstrap `
  -CheckId 'c7-online-recovers' `
    -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Component','bili-whale') `
    -TimeoutSeconds 1800 -StepText 'recovery-3 - 联网重跑 bili-whale'

  $qrcodeAfterOnline = Test-Path -LiteralPath $qrcodePkg
  $resolveAfter = $null
  if ($nodeExe -and (Test-Path -LiteralPath $biliDir)) {
    $resolveAfter = Resolve-Qrcode -NodeExe $nodeExe -ProjectDir $biliDir -Label 'qrcode-resolve-after-recovery'
  }
  $nodeMapAfter = Get-FileMap -Roots @($nodeDir)
  $nodeChanges = @(Compare-FileMaps -Before $nodeMapBefore.Map -After $nodeMapAfter.Map)
  $nodeHashAfter = $(if ($nodeExe) { (Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256).Hash.ToLower() } else { '' })
  $nodeReinstalled = ([bool]$nodeHashBefore -and [bool]$nodeHashAfter -and $nodeHashBefore -ne $nodeHashAfter)
  $nodeAfterRec = Save-EvidenceJson -Name 'node-after-interrupt.json' -Object ([ordered]@{
    exe = $nodeExe; hash = $nodeHashAfter
    hashBefore = $nodeHashBefore; reinstalled = $nodeReinstalled
    mtime = $(if ($nodeExe) { (Get-Item -LiteralPath $nodeExe).LastWriteTimeUtc.ToString('o') } else { '' })
    changes = $nodeChanges
  })

  Add-PhaseCheck -Id 'c7-offline-fails-after-interrupt' -Criterion 7 `
    -Requirement '真实中断后，离线重跑必须失败（不能假装补齐）' `
    -Steps @('中断后立刻 -Component bili-whale -Offline') `
    -Assertion 'exit != 0；qrcode 不存在' `
    -Expected '非 0 退出' -Actual ('exit=' + $offlineAfterKill.exitCode + '; qrcode=' + $qrcodeAfterKill) `
    -Evidence @($offlineAfterKill.stdoutPath, $offlineAfterKill.stderrPath, $intEv, $recPreEv) `
    -Preconditions @('上一步已真实中断安装进程树（killed=true）') `
    -Status $(if (-not $recPre.ok) { 'fail-fixture' } elseif (-not $killed) { 'not-run' } elseif ($offlineAfterKill.exitCode -ne 0 -and -not $qrcodeAfterKill) { 'pass' } elseif ($qrcodeAfterKill) { 'fail-fixture' } else { 'fail-product' }) `
    -Detail $(if (-not $killed) { '未形成真实中断（安装阶段太快/进程已自行结束），本项不执行断言，按 not-run 记录。' } elseif ($qrcodeAfterKill) { '虽然结束了进程树，但 qrcode 已经落盘——中断发生在 npm 完成之后，夹具没有形成“缺 qrcode”的半安装，按 fail-fixture 记录而不是断言产品失败。' } else { '中断发生在 npm 安装阶段；离线无法取包，必须报缺而不是跳过。' }) `
    -Data ([ordered]@{ exitCode = $offlineAfterKill.exitCode; qrcodeExists = $qrcodeAfterKill })

  Add-PhaseCheck -Id 'c7-online-recovers' -Criterion 7 `
    -Requirement '联网重跑必须修好被中断的组件' `
    -Steps @('联网 -Component bili-whale', '检查 node_modules\qrcode\package.json 与 require.resolve') `
    -Assertion 'exit 0；qrcode 包存在；require.resolve 返回 0；node 未被重装（恢复只补缺失的 npm 包）' `
    -Expected 'exit=0, resolve=0, nodeReinstalled=false' `
    -Actual ('exit=' + $onlineAfterKill.exitCode + '; qrcode=' + $qrcodeAfterOnline + '; resolve=' + $(if ($resolveAfter) { $resolveAfter.Record.exitCode } else { 'n/a' }) + '; nodeReinstalled=' + $nodeReinstalled) `
    -Evidence @($onlineAfterKill.stdoutPath, $onlineAfterKill.stderrPath, $recPreEv, $(if ($resolveAfter) { $resolveAfter.Record.stdoutPath } else { $onlineAfterKill.stdoutPath })) `
    -Preconditions @('离线失败已记录（上一步 exit≠0）') `
    -Status $(if (-not $recPre.ok) { 'fail-fixture' } elseif (-not $killed) { 'not-run' } elseif ($onlineAfterKill.exitCode -eq 0 -and $qrcodeAfterOnline -and $resolveAfter -and $resolveAfter.Record.exitCode -eq 0 -and -not $nodeReinstalled) { 'pass' } else { 'fail-product' }) `
    -Detail $(if (-not $killed) { '没有真实中断，恢复路径无从验证，按 not-run 记录。' } else { 'M-07：恢复必须“只补缺失”——断言 qrcode 由缺到有、且 node.exe 哈希未变（未重装整棵 node）。qrcode 解析在 cwd=' + $(if ($resolveAfter) { $resolveAfter.Cwd } else { '未执行' }) + ' 下进行。' }) `
    -Data ([ordered]@{ exitCode = $onlineAfterKill.exitCode; resolveExit = $(if ($resolveAfter) { $resolveAfter.Record.exitCode } else { $null }); resolveCwd = $(if ($resolveAfter) { $resolveAfter.Cwd } else { '' }); nodeHashBefore = $nodeHashBefore; nodeHashAfter = $nodeHashAfter; nodeReinstalled = $nodeReinstalled })

  Add-PhaseCheck -Id 'c7-completed-not-reinstalled' -Criterion 7 `
    -Requirement '已完成的 node 组件在恢复过程中不被重装/覆盖' `
    -Steps @('中断前后对 {Ws}\sidecar\node（不存在则回退 {App}）做 sha256+size+mtime 快照', '比较两次快照') `
    -Assertion 'changes=0（node.exe 哈希与 mtime 不变）' `
    -Expected 'changes=0' -Actual ('changes=' + $nodeChanges.Count) `
    -Evidence @($nodeBeforeRec, $nodeAfterRec) `
    -Preconditions @('node 已由前一次运行装好（哈希已记录）') `
    -Status $(if (-not $killed) { 'not-run' } elseif (-not $nodeExe) { 'blocked-precondition' } elseif ($nodeChanges.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('node 布局从实际安装根推导：exe=' + $nodeExe + '；快照根=' + $nodeDir + '。node 已在 full 阶段装好；恢复 bili-whale 只应补 npm 包。') `
    -Data ([ordered]@{ nodeExe = $nodeExe; changes = $nodeChanges })

  # ---------- B. 构造半安装（合成，单独一条 check）
  Set-MwProgress -Step 'recovery-4 - 构造半安装'
  $half = Join-Path $GuestRoot ('冥零 验收\半装 ' + $RunId)
  Reset-TestDir -Path $half
  $halfBots = Join-Path $half 'bots'
  $halfBili = Join-Path $halfBots 'bili-whale'
  New-Item -ItemType Directory -Force -Path (Join-Path $half 'logs\setup\dl'), (Join-Path $half 'logs\setup\npm-cache'), $halfBili | Out-Null

  $nodeCache = @()
  $wsDl = Join-Path $Ws 'logs\setup\dl'
  if (Test-Path -LiteralPath $wsDl) {
    $nodeCache = @(Get-ChildItem -LiteralPath $wsDl -File -Filter 'node-*' -ErrorAction SilentlyContinue)
    foreach ($f in $nodeCache) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $half 'logs\setup\dl') -Force }
  }
  $nodeInstall = Invoke-Long -Label 'half-node-offline' -FilePath $Bootstrap `
    -Arguments @('-Base',$half,'-Workspace',$half,'-Bots',$halfBots,'-Component','node','-Offline') `
    -TimeoutSeconds 600 -StepText 'recovery-4 - 半装：node -Offline'
  $halfNodeExe = Get-NodeExeFromLayout -Root $half
  $biliCopied = $false
  $biliSrc = Join-Path $App 'sidecar\bili-whale'
  if (Test-Path -LiteralPath $biliSrc) {
    $biliCopied = Copy-TreeIfExists -From $biliSrc -To $halfBili
  }
  $halfRemovedQrcode = $false
  if ($biliCopied -and (Test-Path -LiteralPath (Join-Path $halfBili 'node_modules\qrcode'))) {
    # 合成前提：若复制过来的树自带 qrcode，必须先在“跑离线”之前移除，否则离线会假成功
    Remove-Item -LiteralPath (Join-Path $halfBili 'node_modules\qrcode') -Recurse -Force
    $halfRemovedQrcode = $true
  }
  $halfBiliOffline = Invoke-Long -Label 'half-bili-offline' -FilePath $Bootstrap `
  -CheckId 'c7-half-install-synthetic' `
    -Arguments @('-Base',$half,'-Workspace',$half,'-Bots',$halfBots,'-Component','bili-whale','-Offline') `
    -TimeoutSeconds 300 -StepText 'recovery-4 - 半装：bili-whale -Offline（必须失败）'
  $halfQrcode = Join-Path $halfBili 'node_modules\qrcode\package.json'
  $halfResolve = $null
  if ($halfNodeExe -and (Test-Path -LiteralPath $halfBili)) {
    $halfResolve = Resolve-Qrcode -NodeExe $halfNodeExe -ProjectDir $halfBili -Label 'half-qrcode-resolve'
  }
  $halfEv = Save-EvidenceJson -Name 'half-install.json' -Object ([ordered]@{
    half = $half; nodeExe = $halfNodeExe; nodeCache = @($nodeCache.Name); biliCopied = $biliCopied
    nodeExit = $nodeInstall.exitCode; biliOfflineExit = $halfBiliOffline.exitCode
    qrcodeExists = (Test-Path -LiteralPath $halfQrcode)
    removedShippedQrcode = $halfRemovedQrcode
    resolveExit = $(if ($halfResolve) { $halfResolve.Record.exitCode } else { $null })
    resolveCwd = $(if ($halfResolve) { $halfResolve.Cwd } else { '' })
    resolveOut = $(if ($halfResolve) { ([string]$halfResolve.Record.stdoutText).Trim() } else { '' })
  })

  $halfOk = ($nodeInstall.exitCode -eq 0 -and $biliCopied -and $halfBiliOffline.exitCode -eq 2 -and
             -not (Test-Path -LiteralPath $halfQrcode) -and $halfResolve -and $halfResolve.Record.exitCode -ne 0)
  Add-PhaseCheck -Id 'c7-half-install-synthetic' -Criterion 7 `
    -Requirement '构造半安装（node 在、qrcode 缺）：离线必须报缺，qrcode 解析必须失败' `
    -Steps @('node -Offline 装到合成目录', '用 -Path 通配符复制 sidecar\bili-whale（不用 -LiteralPath）', 'bili-whale -Offline', 'cd 到半装 bili-whale 后 node -e require.resolve(''qrcode'')') `
    -Assertion 'node exit 0；bili 离线 exit 2；qrcode\package.json 不存在；resolve 非 0' `
    -Expected 'node=0, bili=2, resolve!=0' `
    -Actual ('node=' + $nodeInstall.exitCode + '; bili=' + $halfBiliOffline.exitCode + '; resolve=' + $(if ($halfResolve) { $halfResolve.Record.exitCode } else { 'n/a' })) `
    -Evidence @($halfEv, $halfBiliOffline.stdoutPath, $(if ($halfResolve) { $halfResolve.Record.stdoutPath } else { $halfEv })) `
    -Preconditions @('已构造半安装目录（复制自真实安装）') `
    -Status $(if ($halfOk) { 'pass' } elseif (-not $biliCopied) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail ('node.exe 从真实布局推导得到：' + $halfNodeExe + '；qrcode 解析 cwd=' + $(if ($halfResolve) { $halfResolve.Cwd } else { '未执行' }) + '；解析输出只记路径不伪造。') `
    -Data ([ordered]@{ nodeExe = $halfNodeExe; biliExit = $halfBiliOffline.exitCode; qrcode = (Test-Path -LiteralPath $halfQrcode) })

  # 半装联网补齐（只补包，不重装 node）
  $nodeHalfBefore = Get-FileMap -Roots @((Join-Path $half 'sidecar'))
  $halfOnline = Invoke-Long -Label 'half-bili-online' -FilePath $Bootstrap `
  -CheckId 'c7-half-install-online-fix' `
    -Arguments @('-Base',$half,'-Workspace',$half,'-Bots',$halfBots,'-Component','bili-whale') `
    -TimeoutSeconds 1800 -StepText 'recovery-4b - 半装联网补齐 bili-whale'
  $halfOnlineResolve = $null
  if ($halfNodeExe -and (Test-Path -LiteralPath $halfBili)) {
    $halfOnlineResolve = Resolve-Qrcode -NodeExe $halfNodeExe -ProjectDir $halfBili -Label 'half-qrcode-resolve-online'
  }
  $nodeHalfAfter = Get-FileMap -Roots @((Join-Path $half 'sidecar'))
  $nodeHalfChanges = @(Compare-FileMaps -Before $nodeHalfBefore.Map -After $nodeHalfAfter.Map)
  $halfOnlineEv = Save-EvidenceJson -Name 'half-install-online.json' -Object ([ordered]@{
    exitCode = $halfOnline.exitCode; qrcode = (Test-Path -LiteralPath $halfQrcode)
    resolveExit = $(if ($halfOnlineResolve) { $halfOnlineResolve.Record.exitCode } else { $null })
    nodeChanges = $nodeHalfChanges; resolveCwd = $(if ($halfOnlineResolve) { $halfOnlineResolve.Cwd } else { '' })
  })
  Add-PhaseCheck -Id 'c7-half-install-online-fix' -Criterion 7 `
    -Requirement '半安装联网只补缺失的包，不覆盖已装 node' `
    -Steps @('对半装目录联网运行 bili-whale', '检查 qrcode 与 resolve', '比较 half\sidecar 前后哈希') `
    -Assertion 'exit 0；qrcode 存在；resolve=0；node 文件零变化' `
    -Expected 'exit=0, resolve=0, nodeChanges=0' `
    -Actual ('exit=' + $halfOnline.exitCode + '; qrcode=' + (Test-Path -LiteralPath $halfQrcode) + '; resolve=' + $(if ($halfOnlineResolve) { $halfOnlineResolve.Record.exitCode } else { 'n/a' }) + '; nodeChanges=' + $nodeHalfChanges.Count) `
    -Evidence @($halfOnlineEv, $halfOnline.stdoutPath) `
    -Preconditions @('半安装程序目录存在且 qrcode 缺失（上一步构造）') `
    -Status $(if ($halfOnline.exitCode -eq 0 -and (Test-Path -LiteralPath $halfQrcode) -and $halfOnlineResolve -and $halfOnlineResolve.Record.exitCode -eq 0 -and $nodeHalfChanges.Count -eq 0) { 'pass' } else { 'fail-product' }) `
    -Detail 'npm 缓存固定在 {base}\logs\setup\npm-cache；这是产品实现，未额外清空。' `
    -Data ([ordered]@{ nodeChanges = $nodeHalfChanges })

  # ---------- C. 项 8：离线三态（uv）
  Set-MwProgress -Step 'recovery-5 - 离线三态（线上/有效缓存/空缓存/坏缓存）'
  $offlineBase = Join-Path $GuestRoot ('冥零 验收\离线 ' + $RunId)
  Reset-TestDir -Path $offlineBase
  $uvOnlineBase = Join-Path $offlineBase 'online'
  $uvValidBase = Join-Path $offlineBase 'valid'
  $uvEmptyBase = Join-Path $offlineBase 'empty'
  $uvBadBase = Join-Path $offlineBase 'bad'

  $uvOnline = Invoke-Long -Label 'uv-online' -FilePath $Bootstrap `
  -CheckId 'c8-offline-valid-cache' `
    -Arguments @('-Base',$uvOnlineBase,'-Workspace',$uvOnlineBase,'-Bots',(Join-Path $uvOnlineBase 'bots'),'-Component','uv') `
    -TimeoutSeconds 900 -StepText 'recovery-5 - uv 联网安装'
  $uvCacheDir = Join-Path $uvOnlineBase 'logs\setup\dl'
  $uvCache = @()
  if (Test-Path -LiteralPath $uvCacheDir) { $uvCache = @(Get-ChildItem -LiteralPath $uvCacheDir -File -Filter 'uv-*' -ErrorAction SilentlyContinue) }

  foreach ($b in @($uvValidBase, $uvEmptyBase, $uvBadBase)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $b 'logs\setup\dl') | Out-Null
  }
  foreach ($f in $uvCache) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $uvValidBase 'logs\setup\dl') -Force
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $uvBadBase 'logs\setup\dl') -Force
  }
  $badFile = ''
  $badDir = Join-Path $uvBadBase 'logs\setup\dl'
  $badCands = @(Get-ChildItem -LiteralPath $badDir -File -ErrorAction SilentlyContinue)
  if ($badCands.Count -gt 0) {
    $badFile = $badCands[0].FullName
    $fs = [IO.File]::Open($badFile, 'Open', 'ReadWrite')
    try { $b0 = $fs.ReadByte(); $fs.Position = 0; $fs.WriteByte(($b0 -bxor 255)) } finally { $fs.Dispose() }
  }
  $uvPre = Get-MwLaunchPrecondition -Label 'offline-uv' -Paths @($Bootstrap, $uvValidBase, $uvEmptyBase, $uvBadBase)
  $uvPreEv = Save-EvidenceJson -Name 'launch-pre-offline-uv.json' -Object $uvPre
  $uvValid = Invoke-Long -Label 'uv-offline-valid' -FilePath $Bootstrap `
  -CheckId 'c8-offline-valid-cache' `
    -Arguments @('-Base',$uvValidBase,'-Workspace',$uvValidBase,'-Bots',(Join-Path $uvValidBase 'bots'),'-Component','uv','-Offline') `
    -TimeoutSeconds 300 -StepText 'recovery-5 - uv 离线（有效缓存）'
  $uvEmpty = Invoke-Long -Label 'uv-offline-empty' -FilePath $Bootstrap `
  -CheckId 'c8-offline-empty-cache' `
    -Arguments @('-Base',$uvEmptyBase,'-Workspace',$uvEmptyBase,'-Bots',(Join-Path $uvEmptyBase 'bots'),'-Component','uv','-Offline') `
    -TimeoutSeconds 300 -StepText 'recovery-5 - uv 离线（空缓存）'
  $uvBad = Invoke-Long -Label 'uv-offline-bad' -FilePath $Bootstrap `
  -CheckId 'c8-offline-bad-cache' `
    -Arguments @('-Base',$uvBadBase,'-Workspace',$uvBadBase,'-Bots',(Join-Path $uvBadBase 'bots'),'-Component','uv','-Offline') `
    -TimeoutSeconds 300 -StepText 'recovery-5 - uv 离线（坏缓存）'
  $uvExeOnline = Join-Path $uvOnlineBase 'uv\bin\uv.exe'
  $uvExeValid = Join-Path $uvValidBase 'uv\bin\uv.exe'
  $uvExeBad = Join-Path $uvBadBase 'uv\bin\uv.exe'
  $uvEv = Save-EvidenceJson -Name 'offline-uv.json' -Object ([ordered]@{
    cache = @($uvCache.Name); badFile = $badFile
    online = $uvOnline.exitCode; valid = $uvValid.exitCode; empty = $uvEmpty.exitCode; bad = $uvBad.exitCode
    exeOnline = (Test-Path -LiteralPath $uvExeOnline); exeValid = (Test-Path -LiteralPath $uvExeValid); exeBad = (Test-Path -LiteralPath $uvExeBad)
  })

  Add-PhaseCheck -Id 'c8-offline-valid-cache' -Criterion 8 `
    -Requirement '有效缓存 + -Offline 可以成功安装' `
    -Steps @('联网安装 uv 产生缓存', '复制缓存到独立 Base', '-Offline 重装') `
    -Assertion 'online=0；valid=0；uv.exe 存在' `
    -Expected '0/0' -Actual ('online=' + $uvOnline.exitCode + '; valid=' + $uvValid.exitCode) `
    -Evidence @($uvEv, $uvValid.stdoutPath, $uvPreEv) `
    -Preconditions @('离线缓存目录已准备好（含校验通过的 node 缓存）') `
    -Status $(if (-not $uvPre.ok) { 'fail-fixture' } elseif ($uvOnline.exitCode -eq 0 -and $uvValid.exitCode -eq 0 -and (Test-Path -LiteralPath $uvExeValid)) { 'pass' } else { 'fail-product' }) `
    -Detail '缓存位置 {Base}\logs\setup\dl。' `
    -Data ([ordered]@{ online = $uvOnline.exitCode; valid = $uvValid.exitCode })

  Add-PhaseCheck -Id 'c8-offline-empty-cache' -Criterion 8 `
    -Requirement '空缓存 + -Offline 必须失败' `
    -Steps @('新建空 Base', '-Offline 安装 uv') `
    -Assertion 'exit 2；uv.exe 不存在' `
    -Expected '2' -Actual ([string]$uvEmpty.exitCode) `
    -Evidence @($uvEv, $uvEmpty.stdoutPath, $uvPreEv) `
    -Preconditions @('离线缓存目录已清空') `
    -Status $(if (-not $uvPre.ok) { 'fail-fixture' } elseif ($uvEmpty.exitCode -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $uvEmptyBase 'uv\bin\uv.exe'))) { 'pass' } else { 'fail-product' }) `
    -Detail '没有网也没有缓存时必须报缺，不能假成功。' `
    -Data ([ordered]@{ exitCode = $uvEmpty.exitCode })

  Add-PhaseCheck -Id 'c8-offline-bad-cache' -Criterion 8 `
    -Requirement '坏缓存 + -Offline 必须拒绝安装（哈希不符）' `
    -Steps @('复制有效缓存', '翻转缓存文件首字节', '-Offline 安装 uv') `
    -Assertion 'exit 2；uv.exe 不存在' `
    -Expected '2' -Actual ([string]$uvBad.exitCode) `
    -Evidence @($uvEv, $uvBad.stdoutPath, $badFile, $uvPreEv) `
    -Preconditions @('离线缓存目录已放入被篡改的缓存包') `
    -Status $(if (-not $uvPre.ok) { 'fail-fixture' } elseif ($badFile -and $uvBad.exitCode -eq 2 -and -not (Test-Path -LiteralPath $uvExeBad)) { 'pass' } elseif (-not $badFile) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail '篡改首个字节，bootstrap 必须按清单 sha256 拒绝。' `
    -Data ([ordered]@{ exitCode = $uvBad.exitCode; file = $badFile })

  # ---------- D. 真实断网
  # 断网由宿主执行（宿主停 VMware NAT 服务，vmrun/VMCI 控制与 copyFile 取证不受影响）。
  # 宿主在切网前写 $GuestRoot\network-cut-by-host.flag；来宾普通用户不再自己 Disable-NetAdapter。
  Set-MwProgress -Step 'recovery-6 - 真实断网'
  $netPre = Get-MwLaunchPrecondition -Label 'real-network-cut' -Paths @($Bootstrap)
  $netPreEv = Save-EvidenceJson -Name 'launch-pre-network-cut.json' -Object $netPre
  $netFlagPath = Join-Path $GuestRoot 'network-cut-by-host.flag'
  $netHostCut = Test-Path -LiteralPath $netFlagPath
  $netIsAdmin = $false
  try {
    $netIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { $netIsAdmin = $false }
  $netSw = [Diagnostics.Stopwatch]::StartNew()
  $netResult = [ordered]@{
    mode = 'none'; hostCutFlag = $netHostCut; flagPath = $netFlagPath; isAdmin = $netIsAdmin
    attempted = $false; adapter = ''; ifIndex = 0; disabled = $false; restored = $false; restoreNeeded = $false
    externalFailed = $false; dnsFailed = $false; dnsError = ''; apiOk = $false; dnsApiError = ''
    externalTargets = @(); tcpTargets = @(); dnsAttempts = @()
    hostChannelOk = $false; hostError = ''; emptyOfflineExit = $null; reason = ''; externalError = ''
    netOffStdout = ''; netOffStderr = ''
    normalExit = $null; normalOkOne = $false; normalSatisfied = -1; normalStdout = ''; normalStderr = ''
    elapsedSeconds = 0
  }

  function Test-MwTcpTarget {
    param([string]$TargetIp, [int]$Port, [int]$TimeoutMs = 6000)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $err = ''; $cli = $null
    try {
      $cli = New-Object System.Net.Sockets.TcpClient
      $ar = $cli.BeginConnect($TargetIp, $Port, $null, $null)
      if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $cli.EndConnect($ar); $ok = $true }
      else { $err = 'connect timeout ' + $TimeoutMs + 'ms' }
    } catch { $err = $_.Exception.Message } finally { if ($cli) { try { $cli.Close() } catch { } } }
    $sw.Stop()
    return [ordered]@{ target = ($TargetIp + ':' + $Port); kind = 'tcp'; ok = $ok; elapsedMs = [int]$sw.ElapsedMilliseconds; error = $err }
  }

  # 外网可达性探针：两个独立 IP:port（不经 DNS）+ 域名解析。全部失败才算外网不可达。
  $netProbeBlock = {
    $tcp = New-Object System.Collections.ArrayList
    [void]$tcp.Add((Test-MwTcpTarget -TargetIp '1.1.1.1' -Port 443 -TimeoutMs 6000))
    [void]$tcp.Add((Test-MwTcpTarget -TargetIp '223.5.5.5' -Port 53 -TimeoutMs 6000))
    $netResult.tcpTargets = @($tcp)
    $netResult.externalFailed = (@($tcp | Where-Object { $_.ok }).Count -eq 0)
    $netResult.externalError = (@($tcp | ForEach-Object { $_.error } | Where-Object { $_ }) -join ' | ')

    # 证明 DNS 失败不是「命令不存在 / API 坏」：先证明 .NET DNS API 本身可用（localhost 应解析），再看外网域名。
    $apiOk = $false; $apiErr = ''; $dnsOk = $false; $dnsErr = ''
    $attempts = New-Object System.Collections.ArrayList
    try {
      $lo = [System.Net.Dns]::GetHostAddresses('localhost')
      $apiOk = (@($lo).Count -gt 0)
      [void]$attempts.Add([ordered]@{ name = 'localhost'; api = '.NET Dns'; ok = $apiOk; addresses = @(@($lo) | ForEach-Object { [string]$_ }); error = '' })
    } catch { $apiErr = $_.Exception.Message; [void]$attempts.Add([ordered]@{ name = 'localhost'; api = '.NET Dns'; ok = $false; addresses = @(); error = $apiErr }) }
    try {
      $dn = [System.Net.Dns]::GetHostAddresses('example.com')
      $dnsOk = (@($dn).Count -gt 0)
      [void]$attempts.Add([ordered]@{ name = 'example.com'; api = '.NET Dns'; ok = $dnsOk; addresses = @(@($dn) | ForEach-Object { [string]$_ }); error = '' })
    } catch { $dnsErr = $_.Exception.Message; [void]$attempts.Add([ordered]@{ name = 'example.com'; api = '.NET Dns'; ok = $false; addresses = @(); error = $dnsErr }) }
    $rdErr = ''
    try {
      $rd = @(Resolve-DnsName -Name 'example.com' -ErrorAction Stop)
      [void]$attempts.Add([ordered]@{ name = 'example.com'; api = 'Resolve-DnsName'; ok = (@($rd).Count -gt 0); addresses = @(); error = '' })
    } catch { $rdErr = $_.Exception.Message; [void]$attempts.Add([ordered]@{ name = 'example.com'; api = 'Resolve-DnsName'; ok = $false; addresses = @(); error = $rdErr }) }
    $netResult.dnsAttempts = @($attempts)
    $netResult.apiOk = $apiOk
    $netResult.dnsApiError = $apiErr
    $netResult.dnsFailed = ($apiOk -and -not $dnsOk)
    $netResult.dnsError = $dnsErr + $(if ($rdErr) { ' | Resolve-DnsName: ' + $rdErr } else { '' })
    if (-not $apiOk) { $netResult.externalFailed = $false }

    # 宿主证据/控制通道：若宿主只切了 NAT，192.168.206.0/24 上的 stage HTTP 可能仍可达；只记录，不作为唯一判据。
    try {
      $hr = Invoke-WebRequest -Uri ($StageUrl.TrimEnd('/') + '/ping.txt') -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
      $netResult.hostChannelOk = ($hr.StatusCode -eq 200)
    } catch { $netResult.hostChannelOk = $false; $netResult.hostError = $_.Exception.Message }
  }

  # -Offline + 空缓存：清单里没有缓存，必须 exit 2（缺资产），不能假装成功。
  $netOffBlock = {
    $netEmptyBase = Join-Path $offlineBase 'netcut'
    Reset-TestDir -Path $netEmptyBase
    New-Item -ItemType Directory -Force -Path (Join-Path $netEmptyBase 'logs\setup\dl') | Out-Null
    $netOff = Invoke-Long -Label 'uv-offline-netcut' -FilePath $Bootstrap `
    -CheckId 'c8-real-network-cut' `
      -Arguments @('-Base',$netEmptyBase,'-Workspace',$netEmptyBase,'-Bots',(Join-Path $netEmptyBase 'bots'),'-Component','uv','-Offline') `
      -TimeoutSeconds 300 -StepText 'recovery-6 - 断网 + 空缓存 + Offline'
    $netResult.emptyOfflineExit = $netOff.exitCode
    $netResult.netOffStdout = $netOff.stdoutPath
    $netResult.netOffStderr = $netOff.stderrPath
  }

  # 正常模式（不带 -Offline）+ 空缓存：断网下必须失败，不能返回 ok=1，也不能把组件判成已满足。
  $netNormalBlock = {
    $netNormalBase = Join-Path $offlineBase 'netcut-normal'
    Reset-TestDir -Path $netNormalBase
    New-Item -ItemType Directory -Force -Path (Join-Path $netNormalBase 'logs\setup\dl') | Out-Null
    $netNormal = Invoke-Long -Label 'uv-normal-netcut' -FilePath $Bootstrap `
    -CheckId 'c8-real-network-cut' `
      -Arguments @('-Base',$netNormalBase,'-Workspace',$netNormalBase,'-Bots',(Join-Path $netNormalBase 'bots'),'-Component','uv') `
      -TimeoutSeconds 420 -StepText 'recovery-6b - 断网 + 空缓存 + 正常联网模式（必须失败）'
    $netResult.normalExit = $netNormal.exitCode
    $netResult.normalStdout = $netNormal.stdoutPath
    $netResult.normalStderr = $netNormal.stderrPath
    $netNormalNums = Get-BootstrapNumbers -Text ([string]$netNormal.stdoutText)
    $netResult.normalOkOne = ($netNormalNums.ok -eq 1)
    $netResult.normalSatisfied = [int]$netNormalNums.satisfied
  }

  if ($netHostCut) {
    # ---------- D1. 宿主已切网：不碰网卡，只做「确实不可达 + 正常模式确实失败」的取证
    $netResult.mode = 'host-cut'
    $netResult.attempted = $true
    & $netProbeBlock
    & $netOffBlock
    & $netNormalBlock
    $netResult.reason = '断网由宿主执行（flag 文件存在：' + $netFlagPath + '）；来宾未禁用/启用任何网卡。'
  } else {
    # ---------- D2. 无 flag：只有管理员才允许自行禁用网卡；普通用户显式 blocked-precondition
    $defaultRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq 'Alive' -or $_.State -eq 'Preferred' })
    $hostIface = $null
    try {
      $hostRoutes = @(Find-NetRoute -RemoteIPAddress '192.168.206.1' -ErrorAction Stop)
      foreach ($hr in $hostRoutes) {
        if ($hr.PSObject.Properties.Name -contains 'InterfaceIndex' -and [int]$hr.InterfaceIndex -gt 0) {
          $hostIface = [int]$hr.InterfaceIndex; break
        }
      }
    } catch { }
    $pick = $null
    foreach ($r in $defaultRoutes) {
      if ($hostIface -and $r.InterfaceIndex -eq $hostIface) { continue }
      $pick = $r; break
    }
    if (-not $netIsAdmin) {
      $netResult.reason = '无宿主断网标记（' + $netFlagPath + '）且当前会话不是管理员：普通用户无法 Disable-NetAdapter，'
      $netResult.reason += '按 blocked-precondition 记录，不伪造断网。'
      $netResult.attempted = $false
    } elseif (-not $pick) {
      $netResult.reason = '找不到与宿主证据通道分离的默认路由网卡（无 flag，管理员自断网路径不可用）。'
      $netResult.attempted = $false
    } else {
      $netResult.mode = 'self-cut'
      $netResult.attempted = $true
      $netResult.ifIndex = [int]$pick.InterfaceIndex
      $adp = Get-NetAdapter -InterfaceIndex $pick.InterfaceIndex -ErrorAction SilentlyContinue
      if ($adp) { $netResult.adapter = [string]$adp.Name }
      $netResult.restoreNeeded = $true
      try {
        Disable-NetAdapter -InterfaceIndex $pick.InterfaceIndex -Confirm:$false -ErrorAction Stop
        $netResult.disabled = $true
      } catch {
        $netResult.reason = '禁用网卡失败（管理员）：' + $_.Exception.Message
      }
      if ($netResult.disabled) {
        try {
          Start-Sleep -Seconds 3
          & $netProbeBlock
          & $netOffBlock
          & $netNormalBlock
        } finally {
          try { Enable-NetAdapter -InterfaceIndex $netResult.ifIndex -Confirm:$false -ErrorAction Stop; $netResult.restored = $true }
          catch { $netResult.reason = $netResult.reason + ' 恢复网卡失败（finally）：' + $_.Exception.Message }
        }
      }
    }
  }
  if ($netResult.restoreNeeded -and -not $netResult.restored) {
    try { Enable-NetAdapter -InterfaceIndex $netResult.ifIndex -Confirm:$false -ErrorAction Stop; $netResult.restored = $true }
    catch { $netResult.reason = $netResult.reason + ' 恢复网卡失败：' + $_.Exception.Message }
  }
  if (-not $netResult.restoreNeeded) { $netResult.restored = $true }
  $netSw.Stop()
  $netResult.elapsedSeconds = [int]$netSw.Elapsed.TotalSeconds
  $netEv = Save-EvidenceJson -Name 'network-cut.json' -Object $netResult
  $netEvList = @($netEv)
  if ($netHostCut) { $netEvList += $netFlagPath }
  $netPass = ($netResult.externalFailed -and $netResult.dnsFailed -and $netResult.apiOk -and
    $null -ne $netResult.emptyOfflineExit -and [int]$netResult.emptyOfflineExit -eq 2 -and
    $null -ne $netResult.normalExit -and [int]$netResult.normalExit -ne 0 -and
    (-not $netResult.normalOkOne) -and [int]$netResult.normalSatisfied -lt 1 -and $netResult.restored)
  $netExternalSummary = (@($netResult.tcpTargets | ForEach-Object { $_.target + '=' + $_.ok + '(' + $_.elapsedMs + 'ms)' }) -join ', ')
  Add-PhaseCheck -Id 'c8-real-network-cut' -Criterion 8 `
    -Requirement '真实断网：外网确实不可达（双目标+DNS）、正常模式必须失败、-Offline 按缓存状态；断网动作在来宾侧显式标注来源（宿主 flag 或管理员自行断网）' `
    -Steps @('读 $GuestRoot\network-cut-by-host.flag 判定断网来源', '两个独立 IP:port（1.1.1.1:443、223.5.5.5:53）必须都失败，逐条记录耗时与错误', '先证 .NET DNS API 可用（localhost），再证 example.com 解析失败', '请求宿主 /stage/ping.txt（记录控制/证据通道状态）', '空缓存 -Offline 装 uv（必须 exit 2）', '空缓存正常模式装 uv（不带 -Offline，必须失败、不能 ok=1、不能判成已满足）', '仅 self-cut 模式才恢复网卡') `
    -Assertion '两个 IP 目标全失败且 DNS API 可用但解析失败；离线空缓存 exit 2；正常模式 exit != 0、无 ok=1、satisfied<1；self-cut 需已恢复网卡；host-cut 不碰网卡' `
    -Expected 'externalFailed=true, dnsFailed=true, offline=2, normal!=0, normalSatisfied<1, restored=true' `
    -Actual ('mode=' + $netResult.mode + '; tcp=' + $netExternalSummary + '; dnsFailed=' + $netResult.dnsFailed + '; apiOk=' + $netResult.apiOk + '; offline=' + $netResult.emptyOfflineExit + '; normal=' + $netResult.normalExit + '; normalOk1=' + $netResult.normalOkOne + '; normalSatisfied=' + $netResult.normalSatisfied + '; restored=' + $netResult.restored) `
    -Evidence ($netEvList + @($netPreEv)) `
    -Preconditions @('宿主已切外网（flag 已写入来宾）', '来宾到宿主证据通道仍可达') `
    -Status $(if (-not $netPre.ok) { 'fail-fixture' } elseif ($netPass) { 'pass' } elseif ($netResult.mode -eq 'none') { 'blocked-precondition' } elseif ($netResult.mode -eq 'self-cut' -and -not $netResult.disabled) { 'blocked-precondition' } elseif ($netResult.mode -eq 'host-cut' -and -not $netResult.externalFailed) { 'fail-fixture' } else { 'fail-product' }) `
    -Detail ($netResult.reason + ' 模式=' + $netResult.mode + '；网卡=' + $netResult.adapter + '（ifIndex=' + $netResult.ifIndex + '）；外网错误=' + $netResult.externalError + '；DNS 错误=' + $netResult.dnsError + '；宿主通道=' + $netResult.hostChannelOk + ' ' + $netResult.hostError + '。F-05：正常模式在断网下若返回 ok=1 或把 uv 判成已满足，按 fail-product；host-cut 模式下外网仍可达则说明宿主没切干净，按 fail-fixture（夹具错误），不算产品失败。管理员操作在普通用户下显式 blocked-precondition。') `
    -Data $netResult
}

# ================================================================ 阶段：upgrade
function Get-TreeSnapshot {
  param([Parameter(Mandatory)][string]$Root, [string[]]$ExcludeTopDirs = @())
  $map = @{}
  if (-not (Test-Path -LiteralPath $Root)) { return $map }
  foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
    $skip = $false
    foreach ($ex in $ExcludeTopDirs) {
      if ($rel -eq $ex -or $rel -like ($ex + '\*')) { $skip = $true; break }
    }
    if ($skip) { continue }
    try { $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
  }
  return $map
}

function Get-ProtectedSnapshot {
  param([Parameter(Mandatory)][string]$Root)
  $map = @{}
  foreach ($d in @('bots','private','secrets','out','logs')) {
    $p = Join-Path $Root $d
    if (-not (Test-Path -LiteralPath $p)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
      try { $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
    }
  }
  return $map
}

function Compare-Snapshot {
  param([hashtable]$Before, [hashtable]$After)
  $changes = New-Object System.Collections.ArrayList
  foreach ($k in $Before.Keys) {
    if (-not $After.ContainsKey($k)) { [void]$changes.Add('removed:' + $k) }
    elseif ($After[$k] -ne $Before[$k]) { [void]$changes.Add('content:' + $k) }
  }
  foreach ($k in $After.Keys) {
    if (-not $Before.ContainsKey($k)) { [void]$changes.Add('added:' + $k) }
  }
  return @($changes)
}

function Split-ProtectedChanges {
  <# F-03：把“安装器已知写入”从“覆盖用户内容”里分离出来。
     已知写入只有 <工作区>\logs\setup\installer-check.log（产品当前行为；日志迁出工作区后这里自然为空）。
     其余任何 added/removed/content 都算真实的受保护目录变化。 #>
  param([string[]]$Changes)
  $known = New-Object System.Collections.ArrayList
  $real = New-Object System.Collections.ArrayList
  foreach ($c in @($Changes)) {
    $body = [string]$c
    $idx = $body.IndexOf(':')
    if ($idx -ge 0) { $body = $body.Substring($idx + 1) }
    $b = $body.Replace('\', '/')
    if ([string]$c -like 'added:*' -and $b -match '^logs/setup/installer-check\.log$') { [void]$known.Add($c) }
    else { [void]$real.Add($c) }
  }
  return [pscustomobject]@{ Known = @($known); Real = @($real); All = @($Changes) }
}

function Seed-ProtectedFixture {
  param([Parameter(Mandatory)][string]$Root)
  $rows = [ordered]@{
    'bots\AstrBot\data\config\acceptance.json' = '{"fixture":"upgrade-12"}'
    'private\backend.txt' = "url: http://127.0.0.1:6185`nusername: admin`npassword: MwFix-2026-TestOnly`n"
    'secrets\deepseek-key.txt' = $script:TestKey
    'out\验收 产物.txt' = 'upgrade fixture out'
    'logs\existing.log' = 'upgrade fixture log'
    'bots\AstrBot\data\memory\queue.jsonl' = '{"q":1}'
  }
  foreach ($k in $rows.Keys) { Write-FixtureFile -Path (Join-Path $Root $k) -Content $rows[$k] -Bom $false }
  return $rows
}

function Set-MwTestSettings {
  param([string]$BasePath, [string]$WsPath)
  $dir = Join-Path $env:APPDATA 'MinglingWorkbench'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Save-MwJson -Path (Join-Path $dir 'settings.json') -Object ([ordered]@{ base = $BasePath; workspace = $WsPath }) -NoSafe
}

function Install-MwVersion {
  param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$WsDir,
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][string]$Label,
    [string]$Dir = '',
    [switch]$NoDir,
    [string]$StepText = '',
    [string]$CheckId = ''
  )
  if (-not (Test-Path -LiteralPath $InstallerPath)) { return $null }
  $a = New-Object System.Collections.ArrayList
  foreach ($x in @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER')) { [void]$a.Add($x) }
  # M-17：默认目录必须由产品自己推断。只有显式给出 -Dir（且没有 -NoDir）时才传 /DIR。
  if (-not $NoDir -and $Dir) { [void]$a.Add('/DIR=' + $Dir) }
  [void]$a.Add('/WORKSPACE=' + $WsDir)
  [void]$a.Add('/LOG=' + $LogPath)
  return Invoke-Long -Label $Label -FilePath $InstallerPath -Arguments @($a) -TimeoutSeconds 1200 -StepText $StepText -CheckId $CheckId
}

function Find-BackupManifest {
  <# 在 <工作区>\旧版 与 <程序目录>\旧版 下找 backup-install 写出的 manifest。 #>
  param([string]$WsRoot, [string]$AppDir)
  $cands = New-Object System.Collections.ArrayList
  foreach ($base in @($WsRoot, $AppDir)) {
    if (-not $base) { continue }
    $old = Join-Path $base '旧版'
    if (-not (Test-Path -LiteralPath $old)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $old -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'install-backup-*' } | Sort-Object LastWriteTime -Descending)) {
      [void]$cands.Add($d)
    }
  }
  foreach ($d in $cands) {
    $m = Join-Path $d.FullName 'backup-manifest.json'
    if (Test-Path -LiteralPath $m) { return [pscustomobject]@{ Dir = $d.FullName; Manifest = $m } }
  }
  return [pscustomobject]@{ Dir = ''; Manifest = '' }
}

function Add-RelaunchCheck {
  <# 升级后工作台应被重新拉起：以“同路径 exe 的进程创建时间晚于升级开始”为可观察证据。 #>
  param(
    [string]$Id, [int]$Criterion, [string]$ExePath, [datetime]$Since,
    [string]$WsRoot, [string]$Label, [string]$WsUsed
  )
  $proc = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    try {
      $proc = @(Get-CimInstance Win32_Process -Filter "Name='MinglingWorkbench.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $ExePath) -and $_.CreationDate -and ($_.CreationDate -ge $Since) }) |
        Select-Object -First 1
    } catch { $proc = $null }
    if ($proc) { break }
    Start-Sleep -Seconds 2
  }
  $relaunchPid = 0
  $relaunchCmd = ''
  if ($proc) { $relaunchPid = [int]$proc.ProcessId; $relaunchCmd = [string]$proc.CommandLine }
  $relaunchEv = Save-EvidenceJson -Name ($Id + '.json') -Object ([ordered]@{
    id = $Id; exe = $ExePath; since = $Since.ToUniversalTime().ToString('o')
    pid = $relaunchPid; commandLine = $relaunchCmd; path = $Label
  })
  Add-PhaseCheck -Id $Id -Criterion $Criterion `
    -Preconditions @('同路径 exe 存在：' + [string]$ExePath, '升级开始时间已记录：' + $Since.ToUniversalTime().ToString('o')) `
    -Requirement '升级完成后工作台首次启动（被更新器重新拉起）' `
    -Steps @('记录升级开始时间', '升级后 60s 内按 exe 路径查 Win32_Process，要求 CreationDate >= 开始时间') `
    -Assertion '找得到同路径、升级开始后创建的工作台进程' `
    -Expected 'relaunch pid > 0' `
    -Actual ('pid=' + $relaunchPid + '; exe=' + $ExePath) `
    -Evidence @($relaunchEv) `
    -Status $(if (-not (Test-Path -LiteralPath $ExePath)) { 'blocked-precondition' } elseif ($relaunchPid -gt 0) { 'pass' } else { 'fail-product' }) `
    -Detail ('首次启动后的具体新增文件没有稳定契约（安装器自己会写 logs\setup\installer-check.log），因此这里只用“进程被重新拉起”作为可观察证据，不猜日志文件名。' + $(if ($WsUsed) { '' } else { ' 工作区参数是否生效未证明。' })) `
    -Data ([ordered]@{ pid = $relaunchPid; commandLine = $relaunchCmd; exe = $ExePath; since = $Since.ToUniversalTime().ToString('o') })
}

function Invoke-UpgradePhase {
  $inst31 = Resolve-StagePath -NameOrPath $Installer31
  $inst30 = Resolve-StagePath -NameOrPath $Installer30
  $missing = @()
  foreach ($p in @($inst31, $inst30)) { if (-not (Test-Path -LiteralPath $p)) { $missing += $p } }
  if ($missing.Count -gt 0) {
    Add-PhaseCheck -Id 'c0-upgrade-precondition' -Criterion 12 -Requirement '需要 3.0 与 3.1 安装包' `
      -Assertion '两个安装包都存在' -Expected 'both exist' -Actual ($missing -join '; ') `
      -Preconditions @('stage 已提供 3.0 与 3.1 安装包路径（本轮 Prepare-Stage 生成）') `
      -Status 'blocked-precondition' -Detail '缺安装包，升级验收无法执行。'
    return
  }

  # 3.0 的 iss 不在仓库里，/WORKSPACE 是否被接受无法静态确认；保留传参，结论按实测记录。
  $wsNote30 = '未验证命令：V3.0 安装器是否接受 /WORKSPACE（仓库只确认 3.1 读 {param:WORKSPACE}）；若被忽略，工作区会落到默认位置，受保护目录断言会 fail-product 而不是伪造通过。'

  $settingsDir = Join-Path $env:APPDATA 'MinglingWorkbench'
  $settingsPath = Join-Path $settingsDir 'settings.json'
  $settingsBackup = Join-Path $FixtureDir 'settings.json.orig'
  $hadSettings = Test-Path -LiteralPath $settingsPath
  if ($hadSettings) { Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup -Force }
  $regPath = 'HKCU:\Software\MinglingWorkbench'
  $regBackup = $null
  try {
    if (Test-Path $regPath) { $regBackup = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue }
  } catch { }
  $restoreSettings = {
    try {
      if ($hadSettings) { Copy-Item -LiteralPath $settingsBackup -Destination $settingsPath -Force }
      elseif (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force }
    } catch { }
    try {
      if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
      if ($regBackup -and $regBackup.ProgramRoot) { Set-ItemProperty -Path $regPath -Name 'ProgramRoot' -Value $regBackup.ProgramRoot }
      else { Set-ItemProperty -Path $regPath -Name 'ProgramRoot' -Value $App }
    } catch { }
  }
  $helper = Join-Path $env:TEMP ('mingling-updater-acceptance-' + $RunId + '.exe')

  try {
    # ---------- 路径 1：V3.0 自定义目录
    Set-MwProgress -Step 'upgrade-1 - V3.0 自定义目录基线'
    $custom = Join-Path $GuestRoot '冥零 验收\升级 自定义'
    $customWs = Join-Path $GuestRoot '冥零 验收\升级 自定义 工作区'
    Reset-TestDir -Path $custom
    Reset-TestDir -Path $customWs
    Set-MwTestSettings -BasePath $custom -WsPath $customWs
    $log30c = Join-Path $script:EvidenceDir 'install-3.0-custom.log'
    $i30c = Install-MwVersion -InstallerPath $inst30 -Dir $custom -WsDir $customWs -LogPath $log30c `
      -Label 'install-3.0-custom' -StepText 'upgrade-1 - 安装 V3.0 到自定义目录' -CheckId 'c12-custom-upgrade'
    $customExe = Join-Path $custom 'MinglingWorkbench.exe'
    if ($i30c) { [void](Wait-FileVersion -Path $customExe -Pattern '^3\.0\.' -TimeoutSeconds 120) }
    $v30c = Get-FileVersion -Path $customExe
    # F-03：/WORKSPACE 是否被接受不再只看 installer-check.log（产品可能把日志迁出工作区）；
    # 工作区内 installer-check.log / state.json / bots 目录任一存在，都证明安装器用了这个工作区。
    $wsUse1 = Get-MwWorkspaceUseSignals -WorkspaceRoot $customWs -AppRoot $custom
    $wsUsed1 = $wsUse1.Used
    $wsUse1Ev = Save-EvidenceJson -Name 'workspace-use-custom.json' -Object ([ordered]@{
      label = 'custom'; workspace = $customWs; app = $custom; used = $wsUse1.Used; signals = @($wsUse1.Signals)
    })

    Seed-ProtectedFixture -Root $customWs | Out-Null
    $protectedBefore1 = Get-ProtectedSnapshot -Root $customWs
    $programBefore1 = Get-TreeSnapshot -Root $custom -ExcludeTopDirs @('bots','private','secrets','out','logs','旧版')
    $snap1Before = Save-EvidenceJson -Name 'upgrade-custom-before.json' -Object ([ordered]@{
      protected = $protectedBefore1; programFiles = $programBefore1.Count; version = $v30c
    })

    Set-MwProgress -Step 'upgrade-2 - V3.0 → 3.1（自定义目录，CLI --wb-update）'
    $upd1 = $null
    $t1 = Get-Date
    if (Test-Path -LiteralPath $customExe) {
      $upd1 = Invoke-Long -Label 'update-custom' -FilePath $customExe `
      -CheckId 'c12-custom-upgrade' `
        -Arguments @('--wb-update', $inst31, '3.1.0-acceptance') -TimeoutSeconds 1200 `
        -StepText 'upgrade-2 - 自定义目录 --wb-update'
    }
    $v31c = Wait-FileVersion -Path $customExe -Pattern '^3\.1\.' -TimeoutSeconds 240
    Start-Sleep -Seconds 3
    Add-RelaunchCheck -Id 'c12-custom-relaunch' -Criterion 12 -ExePath $customExe -Since $t1 `
      -WsRoot $customWs -Label 'custom' -WsUsed $wsUsed1
    $protectedAfter1 = Get-ProtectedSnapshot -Root $customWs
    $changes1 = @(Compare-Snapshot -Before $protectedBefore1 -After $protectedAfter1)

    # backup-install.ps1 把备份写到 <工作区>\旧版；updater 自己的 workbench-<tag>
    # 目录落在 WorkspaceDir\旧版（此路径1里两者都可能出现），所以两处都找。
    $backupDirs = @()
    foreach ($bdir in @((Join-Path $customWs '旧版'), (Join-Path $custom '旧版'))) {
      if (Test-Path -LiteralPath $bdir) {
        $backupDirs += @(Get-ChildItem -LiteralPath $bdir -Directory -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending)
      }
    }
    $manifestPath = ''
    foreach ($d in $backupDirs) {
      $mp = Join-Path $d.FullName 'backup-manifest.json'
      if (Test-Path -LiteralPath $mp) { $manifestPath = $mp; break }
    }
    $manifestRows = @()
    $backupMatched = 0
    $backupMismatched = 0
    $backupUnins = $false
    if ($manifestPath) {
      try {
        $mj = ConvertFrom-Json -InputObject (Read-TextAuto -Path $manifestPath)
        foreach ($it in @($mj.files)) {
          $rel = ([string]$it.path).TrimStart('\')
          $sha = ([string]$it.sha256).ToUpper()
          $have = $programBefore1[$rel]
          $ok = ($have -and ([string]$have).ToUpper() -eq $sha)
          if ($ok) { $backupMatched++ } else { $backupMismatched++ }
          $manifestRows += [ordered]@{ path = $rel; manifestSha = $sha; beforeSha = $have; match = [bool]$ok }
        }
      } catch { }
      $backupUnins = ((Test-Path -LiteralPath (Join-Path (Split-Path -Parent $manifestPath) 'unins000.exe')) -and
                      (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $manifestPath) 'unins000.dat')))
    }
    $snap1After = Save-EvidenceJson -Name 'upgrade-custom-after.json' -Object ([ordered]@{
      version = $v31c; protectedChanges = $changes1; manifest = $manifestPath
      backupMatched = $backupMatched; backupMismatched = $backupMismatched; backupUnins = $backupUnins
      manifestRows = $manifestRows
    })

    Add-PhaseCheck -Id 'c12-custom-upgrade' -Criterion 12 `
      -Requirement 'V3.0 自定义目录经 --wb-update 升级到 3.1' `
      -Steps @('静默安装 V3.0 到中文+空格自定义目录', '运行 MinglingWorkbench.exe --wb-update <3.1 安装包>', '等待 FileVersion 变 3.1') `
      -Assertion 'update exit 0；FileVersion ^3.1；原目录不变' `
      -Expected 'exit=0, version=3.1.x' `
      -Actual ('v30=' + $v30c + '; updateExit=' + $(if ($upd1) { $upd1.exitCode } else { 'n/a' }) + '; v31=' + $v31c + '; wsUsed=' + $wsUsed1) `
      -Evidence @($snap1Before, $snap1After, $log30c, $wsUse1Ev, $(if ($upd1) { $upd1.stdoutPath } else { $log30c })) `
      -Preconditions @('V3.0 已安装到自定义目录（FileVersion ^3\.0\.）', '3.1 安装包与升级入口路径存在') `
      -Status $(if ($upd1 -and $upd1.exitCode -eq 0 -and $v30c -match '^3\.0\.' -and $v31c -match '^3\.1\.' -and $wsUsed1) { 'pass' } elseif (-not (Test-Path -LiteralPath $customExe)) { 'blocked-precondition' } elseif (-not $wsUsed1) { 'blocked-precondition' } else { 'fail-product' }) `
      -Detail ('同一条升级路径里同时验证版本与路径；安装目录仍是原自定义目录。wsUsed=' + $wsUsed1 + '（工作区信号见 workspace-use-custom.json，证明 V3.0 接受了 /WORKSPACE）。' + $wsNote30) `
      -Data ([ordered]@{ v30 = $v30c; v31 = $v31c; exit = $(if ($upd1) { $upd1.exitCode } else { $null }); wsUsed = $wsUsed1 })

    $split1 = Split-ProtectedChanges -Changes $changes1
    Add-PhaseCheck -Id 'c12-custom-protected' -Criterion 12 `
      -Requirement '受保护目录（bots/private/secrets/out/logs）里的用户内容不被升级覆盖；旧版程序备份完整性由 c12-custom-backup 覆盖' `
      -Steps @('升级前写 6 个受保护种子文件并全量快照', '升级后重新快照', '按“覆盖用户内容”与“安装器已知日志写入”分类比较') `
      -Assertion '种子文件无 removed/content 变化；除 logs/setup/installer-check.log 外不新增文件' `
      -Expected 'realChanges=0' -Actual ('real=' + $split1.Real.Count + '; knownInstallerLogAdds=' + $split1.Known.Count + '; all=' + $changes1.Count) `
      -Evidence @($snap1Before, $snap1After, $wsUse1Ev) `
      -Preconditions @('自定义目录升级已完成（c12-custom-upgrade 已判定）', '保护目录快照在升级前已记录') `
      -Status $(if (-not $wsUsed1) { 'blocked-precondition' } elseif ($split1.Real.Count -eq 0) { 'pass' } else { 'fail-product' }) `
      -Detail $(if (-not $wsUsed1) { 'V3.0 安装器没有在工作区留下任何可观察信号（installer-check.log / state.json / bots）：无法证明 /WORKSPACE 生效；对空目录做“零变化”断言没有意义，按 blocked-precondition 记录。' } else { 'F-03：{Workspace}\logs\setup\installer-check.log 是安装器 [Run] 每次都会写的已知日志，单独列出、不计为“覆盖用户内容”；其余任何变化都不豁免。该已知写入依赖产品把日志路径迁出工作区后才会消失。' }) `
      -Data ([ordered]@{ realChanges = @($split1.Real | Select-Object -First 60); knownInstallerLogAdds = @($split1.Known); total = $changes1.Count })

    Add-PhaseCheck -Id 'c12-custom-backup' -Criterion 12 `
      -Requirement '升级前完整备份旧程序（含 unins），且有 backup-manifest.json' `
      -Steps @('在 {App}\旧版 下找 backup-manifest.json', '逐文件与升级前程序快照比对 sha256', '检查 unins000.exe/.dat') `
      -Assertion 'manifest 存在；unins 存在；每个 manifest 文件的 sha 与升级前一致' `
      -Expected 'manifest=ok, unins=ok, mismatched=0' `
      -Actual ('manifest=' + [bool]$manifestPath + '; files=' + $manifestRows.Count + '; matched=' + $backupMatched + '; mismatched=' + $backupMismatched + '; unins=' + $backupUnins) `
      -Evidence @($snap1After, $(if ($manifestPath) { $manifestPath } else { $snap1After })) `
      -Preconditions @('升级已完成且旧程序备份目录已生成') `
      -Status $(if (-not $wsUsed1) { 'blocked-precondition' } elseif ($manifestPath -and $backupUnins -and $backupMismatched -eq 0 -and $backupMatched -gt 0) { 'pass' } else { 'fail-product' }) `
      -Detail 'updater 自己的 workbench-<tag> 备份目录没有 manifest；这里只认 backup-install.ps1 写出的 manifest。' `
      -Data ([ordered]@{ manifest = $manifestPath; rows = @($manifestRows | Select-Object -First 40) })

    # ---------- 路径 2：V3.0 默认目录
    Set-MwProgress -Step 'upgrade-3 - V3.0 默认目录基线'
    $def = Join-Path $env:LOCALAPPDATA 'Programs\MinglingWorkbench'
    $defWs = Join-Path $GuestRoot '冥零 验收\升级 默认 工作区'
    Reset-TestDir -Path $defWs
    # 默认目录可能已有上一轮装的 3.1；先尽力清空，确保“从 3.0 基线升级”而不是在 3.1 上原地打转。
    $defReset = $false
    if (Test-Path -LiteralPath $def) {
      try { Remove-Item -LiteralPath $def -Recurse -Force -ErrorAction Stop; $defReset = $true } catch { $defReset = $false }
    } else { $defReset = $true }
    # M-17：故意不预建 $def——目录与 exe 必须是安装器按 DefaultInstallDir 自己创建的。
    Set-MwTestSettings -BasePath $def -WsPath $defWs
    $log30d = Join-Path $script:EvidenceDir 'install-3.0-default.log'
    $i30d = Install-MwVersion -InstallerPath $inst30 -NoDir -WsDir $defWs -LogPath $log30d `
      -Label 'install-3.0-default' -StepText 'upgrade-3 - 安装 V3.0 到默认目录（不传 /DIR，验证 DefaultInstallDir 推断）' -CheckId 'c12-default-upgrade'
    $defExe = Join-Path $def 'MinglingWorkbench.exe'
    if ($i30d) { [void](Wait-FileVersion -Path $defExe -Pattern '^3\.0\.' -TimeoutSeconds 120) }
    $v30d = Get-FileVersion -Path $defExe
    # M-17：不传 /DIR 时，用 Inno 日志里的 Dest filename 证明安装器自己推断到了 DefaultInstallDir。
    $defLogHits = New-Object System.Collections.ArrayList
    $defLogMatch = $false
    try {
      foreach ($ln in @(Get-Lines (Read-TextAuto -Path $log30d))) {
        if ($ln -match 'Dest filename:\s*(.+\\MinglingWorkbench\.exe)\s*$') {
          $dp = $Matches[1].Trim()
          [void]$defLogHits.Add($dp)
          if ([IO.Path]::GetDirectoryName($dp).TrimEnd('\') -ieq $def.TrimEnd('\')) { $defLogMatch = $true }
        }
      }
    } catch { }
    $defInferenceEv = Save-EvidenceJson -Name 'default-dir-inference.json' -Object ([ordered]@{
      noDirSwitch = $true; expectedDefault = $def
      exeExists = (Test-Path -LiteralPath $defExe); version = $v30d
      logDestHits = @($defLogHits | Select-Object -Unique); logMatchesDefault = $defLogMatch
      installLog = $log30d
    })
    $wsUse2 = Get-MwWorkspaceUseSignals -WorkspaceRoot $defWs -AppRoot $def
    $wsUsed2 = $wsUse2.Used
    $wsUse2Ev = Save-EvidenceJson -Name 'workspace-use-default.json' -Object ([ordered]@{
      label = 'default'; workspace = $defWs; app = $def; used = $wsUse2.Used; signals = @($wsUse2.Signals)
    })
    Seed-ProtectedFixture -Root $defWs | Out-Null
    $protBefore2 = Get-ProtectedSnapshot -Root $defWs
    $snap2Before = Save-EvidenceJson -Name 'upgrade-default-before.json' -Object ([ordered]@{ version = $v30d; protected = $protBefore2 })

    Set-MwProgress -Step 'upgrade-4 - V3.0 → 3.1（默认目录）'
    $upd2 = $null
    $t2 = Get-Date
    if (Test-Path -LiteralPath $defExe) {
      $upd2 = Invoke-Long -Label 'update-default' -FilePath $defExe `
      -CheckId 'c12-default-upgrade' `
        -Arguments @('--wb-update', $inst31, '3.1.0-default-sync') -TimeoutSeconds 1200 `
        -StepText 'upgrade-4 - 默认目录 --wb-update'
    }
    $v31d = Wait-FileVersion -Path $defExe -Pattern '^3\.1\.' -TimeoutSeconds 900
    Start-Sleep -Seconds 3
    Add-RelaunchCheck -Id 'c12-default-relaunch' -Criterion 12 -ExePath $defExe -Since $t2 `
      -WsRoot $defWs -Label 'default' -WsUsed $wsUsed2
    $protAfter2 = Get-ProtectedSnapshot -Root $defWs
    $changes2 = @(Compare-Snapshot -Before $protBefore2 -After $protAfter2)
    $snap2After = Save-EvidenceJson -Name 'upgrade-default-after.json' -Object ([ordered]@{ version = $v31d; protectedChanges = $changes2 })

    Add-PhaseCheck -Id 'c12-default-upgrade' -Criterion 12 `
      -Requirement 'V3.0 默认目录经 --wb-update 升级到 3.1' `
      -Steps @('静默安装 V3.0 且不传 /DIR，让安装器用 DefaultInstallDir', '核对 Inno 日志 Dest filename 落在默认目录', '--wb-update', '等待版本') `
      -Assertion '未传 /DIR 时安装器仍落在 %LOCALAPPDATA%\Programs\MinglingWorkbench；exit 0；版本 ^3.1' `
      -Expected 'exe 在默认目录、logMatchesDefault=true、exit=0、3.1.x' `
      -Actual ('v30=' + $v30d + '; logMatches=' + $defLogMatch + '; exit=' + $(if ($upd2) { $upd2.exitCode } else { 'n/a' }) + '; v31=' + $v31d + '; wsUsed=' + $wsUsed2) `
      -Evidence @($snap2Before, $snap2After, $log30d, $defInferenceEv, $wsUse2Ev, $(if ($upd2) { $upd2.stdoutPath } else { $log30d })) `
      -Preconditions @('V3.0 已安装到默认目录（FileVersion ^3\.0\.）', '未传 /DIR，目录由产品自行推断') `
      -Status $(if ($upd2 -and $upd2.exitCode -eq 0 -and $v30d -match '^3\.0\.' -and $v31d -match '^3\.1\.' -and $wsUsed2 -and $defLogMatch) { 'pass' } elseif (-not (Test-Path -LiteralPath $defExe)) { 'blocked-precondition' } elseif (-not $wsUsed2) { 'blocked-precondition' } else { 'fail-product' }) `
      -Detail ('M-17：本路径不再显式传 /DIR，安装器必须用 DefaultInstallDir 落到 ' + $def + '；logMatchesDefault=' + $defLogMatch + ' 是“推断真的生效”的独立证据。wsUsed=' + $wsUsed2 + '（工作区信号见 workspace-use-default.json，证明 V3.0 接受了 /WORKSPACE）。' + $wsNote30) `
      -Data ([ordered]@{ v30 = $v30d; v31 = $v31d; exit = $(if ($upd2) { $upd2.exitCode } else { $null }); wsUsed = $wsUsed2; defReset = $defReset; logMatchesDefault = $defLogMatch; logDestHits = @($defLogHits) })

    $split2 = Split-ProtectedChanges -Changes $changes2
    Add-PhaseCheck -Id 'c12-default-protected' -Criterion 12 `
      -Requirement '默认目录升级不覆盖受保护目录里的用户内容；旧版程序备份完整性由 c12-default-backup 覆盖' `
      -Steps @('升级前后快照 bots/private/secrets/out/logs', '按“覆盖用户内容”与“安装器已知日志写入”分类比较') `
      -Assertion '种子文件无 removed/content 变化；除 logs/setup/installer-check.log 外不新增文件' `
      -Expected 'realChanges=0' -Actual ('real=' + $split2.Real.Count + '; knownInstallerLogAdds=' + $split2.Known.Count + '; all=' + $changes2.Count) `
      -Evidence @($snap2Before, $snap2After, $wsUse2Ev) `
      -Preconditions @('默认目录升级已完成（c12-default-upgrade 已判定）', '保护目录快照在升级前已记录') `
      -Status $(if (-not $wsUsed2) { 'blocked-precondition' } elseif ($split2.Real.Count -eq 0) { 'pass' } else { 'fail-product' }) `
      -Detail $(if (-not $wsUsed2) { 'V3.0 安装器没有在默认工作区留下任何可观察信号（installer-check.log / state.json / bots），/WORKSPACE 是否生效无法证明；按 blocked-precondition 记录。' } else { 'F-03：installer-check.log 的已知写入单独列出，不豁免其它任何受保护内容变化；依赖产品把日志路径迁出工作区后该已知写入才会消失。' }) `
      -Data ([ordered]@{ realChanges = @($split2.Real | Select-Object -First 60); knownInstallerLogAdds = @($split2.Known); total = $changes2.Count })

    $bk2 = Find-BackupManifest -WsRoot $defWs -AppDir $def
    $bk2Files = 0
    if ($bk2.Manifest) {
      try { $bk2Files = @((ConvertFrom-Json -InputObject (Read-TextAuto -Path $bk2.Manifest)).files).Count } catch { $bk2Files = -1 }
    }
    $bk2Unins = $false
    if ($bk2.Manifest) {
      $bd2 = Split-Path -Parent $bk2.Manifest
      $bk2Unins = ((Test-Path -LiteralPath (Join-Path $bd2 'unins000.exe')) -and (Test-Path -LiteralPath (Join-Path $bd2 'unins000.dat')))
    }
    Add-PhaseCheck -Id 'c12-default-backup' -Criterion 12 `
      -Requirement '默认目录升级前旧程序被完整备份（含 unins000）' `
      -Steps @('在 <工作区>\旧版 与 <程序目录>\旧版 下按时间找 install-backup-*', '读 backup-manifest.json 的 files 数', '核对同目录 unins000.exe / unins000.dat') `
      -Assertion 'manifest 存在、files>0、unins 两件在备份目录' `
      -Expected 'manifest 有、files>0、unins 齐全' `
      -Actual ('manifest=' + $bk2.Manifest + '; files=' + $bk2Files + '; unins=' + $bk2Unins) `
      -Evidence @($(if ($bk2.Manifest) { $bk2.Manifest } else { $snap2After }), $snap2After) `
      -Preconditions @('升级已完成且旧程序备份目录已生成') `
      -Status $(if (-not $wsUsed2) { 'blocked-precondition' } elseif ($bk2.Manifest -and $bk2Unins -and $bk2Files -gt 0) { 'pass' } else { 'fail-product' }) `
      -Detail $(if (-not $wsUsed2) { '默认工作区未被证明生效，无法判断备份是否落在这里；按 blocked-precondition。' } else { '默认路径旧版助手（--wb-update-run）走的是 3.0 helper；若备份缺失属产品行为，不补做。' }) `
      -Data ([ordered]@{ manifest = $bk2.Manifest; dir = $bk2.Dir; files = $bk2Files; unins = $bk2Unins })

    # ---------- 路径 3：V3.0 旧版独立助手
    Set-MwProgress -Step 'upgrade-5 - 回退 3.0 准备旧版助手基线'
    $log30e = Join-Path $script:EvidenceDir 'install-3.0-helper-base.log'
    $i30e = Install-MwVersion -InstallerPath $inst30 -Dir $def -WsDir $defWs -LogPath $log30e `
      -Label 'install-3.0-helper-base' -StepText 'upgrade-5 - 回退安装 V3.0' -CheckId 'c12-old-helper-upgrade'
    if ($i30e) { [void](Wait-FileVersion -Path $defExe -Pattern '^3\.0\.' -TimeoutSeconds 180) }
    $v30e = Get-FileVersion -Path $defExe
    Seed-ProtectedFixture -Root $defWs | Out-Null
    $protBefore3 = Get-ProtectedSnapshot -Root $defWs
    $snap3Before = Save-EvidenceJson -Name 'upgrade-old-helper-before.json' -Object ([ordered]@{ version = $v30e; protected = $protBefore3 })

    $helperOk = $false
    if (Test-Path -LiteralPath $defExe) { Copy-Item -LiteralPath $defExe -Destination $helper -Force; $helperOk = $true }
    $hb = Join-Path $GuestRoot '冥零 验收\old-helper-backup'
    if (-not (Test-Path -LiteralPath $hb)) { New-Item -ItemType Directory -Force -Path $hb | Out-Null }
    $logHelper = Join-Path $script:EvidenceDir 'old-helper.inno.log'
    $upd3 = $null
    $t3 = Get-Date
    if ($helperOk) {
      $upd3 = Invoke-Long -Label 'update-old-helper' -FilePath $helper `
      -CheckId 'c12-old-helper-upgrade' `
        -Arguments @('--wb-update-run', $hb, $inst31, $logHelper, '0', $defExe) -TimeoutSeconds 1200 `
        -StepText 'upgrade-5 - 旧版独立助手 --wb-update-run'
    }
    $v31e = Wait-FileVersion -Path $defExe -Pattern '^3\.1\.' -TimeoutSeconds 900
    Start-Sleep -Seconds 4
    $wsUse3 = Get-MwWorkspaceUseSignals -WorkspaceRoot $defWs -AppRoot $def
    $wsUsed3 = $wsUse3.Used
    $wsUse3Ev = Save-EvidenceJson -Name 'workspace-use-old-helper.json' -Object ([ordered]@{
      label = 'old-helper'; workspace = $defWs; app = $def; used = $wsUse3.Used; signals = @($wsUse3.Signals)
    })
    Add-RelaunchCheck -Id 'c12-old-helper-relaunch' -Criterion 12 -ExePath $defExe -Since $t3 `
      -WsRoot $defWs -Label 'old-helper' -WsUsed $wsUsed3
    $protAfter3 = Get-ProtectedSnapshot -Root $defWs
    $changes3 = @(Compare-Snapshot -Before $protBefore3 -After $protAfter3)
    $snap3After = Save-EvidenceJson -Name 'upgrade-old-helper-after.json' -Object ([ordered]@{
      version = $v31e; helper = $helper; helperExists = $helperOk; protectedChanges = $changes3
    })

    Add-PhaseCheck -Id 'c12-old-helper-upgrade' -Criterion 12 `
      -Requirement 'V3.0 旧版独立助手（--wb-update-run）也能升级到 3.1' `
      -Steps @('回退安装 V3.0', '复制 V3.0 exe 到 %TEMP% 作为旧助手', '运行 helper --wb-update-run <backup> <3.1包> <log> 0 <目标exe>', '等待目标 exe 版本变化') `
      -Assertion 'exit 0；目标 exe 版本 ^3.1' -Expected 'exit=0, 3.1.x' `
      -Actual ('v30=' + $v30e + '; exit=' + $(if ($upd3) { $upd3.exitCode } else { 'n/a' }) + '; v31=' + $v31e) `
      -Evidence @($snap3After, $logHelper, $(if ($upd3) { $upd3.stdoutPath } else { $logHelper })) `
      -Preconditions @('旧版独立助手基线已安装（FileVersion ^3\.0\.）', '升级入口 --wb-update-run 参数已就绪') `
      -Status $(if ($upd3 -and $upd3.exitCode -eq 0 -and $v30e -match '^3\.0\.' -and $v31e -match '^3\.1\.') { 'pass' } elseif (-not $helperOk) { 'blocked-precondition' } else { 'fail-product' }) `
      -Detail ('3.0 助手不带 /DIR，依赖 3.1 安装器从父进程命令行提取旧 exe 路径；这是 DetectLegacyLayout 的真实分支。' + $wsNote30) `
      -Data ([ordered]@{ v30 = $v30e; v31 = $v31e; helper = $helper; exit = $(if ($upd3) { $upd3.exitCode } else { $null }) })

    $split3 = Split-ProtectedChanges -Changes $changes3
    Add-PhaseCheck -Id 'c12-old-helper-protected' -Criterion 12 `
      -Requirement '旧助手上推不覆盖受保护目录里的用户内容；旧版程序备份完整性由 c12-old-helper-backup 覆盖' `
      -Steps @('升级前后各写一份受保护快照证据', '按“覆盖用户内容”与“安装器已知日志写入”分类比较') `
      -Assertion '种子文件无 removed/content 变化；除 logs/setup/installer-check.log 外不新增文件' `
      -Expected 'realChanges=0' -Actual ('real=' + $split3.Real.Count + '; knownInstallerLogAdds=' + $split3.Known.Count + '; all=' + $changes3.Count) `
      -Evidence @($snap3Before, $snap3After, $wsUse3Ev) `
      -Preconditions @('旧版助手升级已完成（c12-old-helper-upgrade 已判定）', '保护目录快照在升级前已记录') `
      -Status $(if (-not $wsUsed3) { 'blocked-precondition' } elseif ($split3.Real.Count -eq 0) { 'pass' } else { 'fail-product' }) `
      -Detail $(if (-not $wsUsed3) { '旧助手路径下没有看到工作区信号（installer-check.log / state.json / bots），无法证明安装器写的是请求的工作区；按 blocked-precondition 记录。' } else { 'F-03：旧助手路径下 installer 仍会写 installer-check.log，该已知写入单独列出；before/after 两份快照都在证据里，不再只有 after。' }) `
      -Data ([ordered]@{ realChanges = @($split3.Real | Select-Object -First 60); knownInstallerLogAdds = @($split3.Known); beforeCount = $protBefore3.Count; afterCount = $protAfter3.Count; total = $changes3.Count })

    $bk3 = Find-BackupManifest -WsRoot $defWs -AppDir $def
    $bk3Files = 0
    if ($bk3.Manifest) {
      try { $bk3Files = @((ConvertFrom-Json -InputObject (Read-TextAuto -Path $bk3.Manifest)).files).Count } catch { $bk3Files = -1 }
    }
    $bk3Unins = $false
    if ($bk3.Manifest) {
      $bd3 = Split-Path -Parent $bk3.Manifest
      $bk3Unins = ((Test-Path -LiteralPath (Join-Path $bd3 'unins000.exe')) -and (Test-Path -LiteralPath (Join-Path $bd3 'unins000.dat')))
    }
    Add-PhaseCheck -Id 'c12-old-helper-backup' -Criterion 12 `
      -Requirement '旧助手升级前旧程序被完整备份（含 unins000）' `
      -Steps @('旧助手带 <backupDir> 参数', '在备份目录读 backup-manifest.json', '核对 unins000.exe/.dat') `
      -Assertion 'manifest 存在、files>0、unins 两件在备份目录' `
      -Expected 'manifest 有、files>0、unins 齐全' `
      -Actual ('manifest=' + $bk3.Manifest + '; files=' + $bk3Files + '; unins=' + $bk3Unins) `
      -Evidence @($(if ($bk3.Manifest) { $bk3.Manifest } else { $snap3After }), $snap3After) `
      -Preconditions @('升级已完成且旧程序备份目录已生成') `
      -Status $(if (-not $wsUsed3) { 'blocked-precondition' } elseif ($bk3.Manifest -and $bk3Unins -and $bk3Files -gt 0) { 'pass' } else { 'fail-product' }) `
      -Detail $(if (-not $wsUsed3) { '工作区未被证明生效，无法判断备份落点；按 blocked-precondition。' } else { '3.0 helper 的 --wb-update-run 由 helper 自己备份到 <backupDir>；updater 代码看起来只复制程序文件、不写 manifest，因此本项可能暴露产品缺口，按真实结果记。' }) `
      -Data ([ordered]@{ manifest = $bk3.Manifest; dir = $bk3.Dir; files = $bk3Files; unins = $bk3Unins })
  } finally {
    & $restoreSettings
    try { if (Test-Path -LiteralPath $helper) { Remove-Item -LiteralPath $helper -Force } } catch { }
  }
}

# ================================================================ 阶段：final
function Get-BootstrapChildTrace {
  param([int]$EntryPid, [datetime]$Since, [int]$TimeoutSeconds = 90)
  $found = New-Object System.Collections.ArrayList
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    try {
      $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
      foreach ($p in $all) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { continue }
        if ($cmd -notmatch 'bootstrap\.ps1') { continue }
        if ($p.ProcessId -eq $EntryPid) { continue }
        if ($Since -and $p.CreationDate -and $p.CreationDate -lt $Since.AddSeconds(-5)) { continue }
        $dup = $false
        foreach ($f in $found) { if ([int]$f.pid -eq [int]$p.ProcessId) { $dup = $true; break } }
        if ($dup) { continue }
        # M-12：沿 ParentProcessId 在本次 WMI 快照里向上走，记录真实父链，才能验证“工作台 → bootstrap”。
        $ancestry = New-Object System.Collections.ArrayList
        $curPid = [int]$p.ParentProcessId
        for ($hop = 0; $hop -lt 8 -and $curPid -gt 0; $hop++) {
          $par = $null
          foreach ($q in $all) { if ([int]$q.ProcessId -eq $curPid) { $par = $q; break } }
          if (-not $par) { [void]$ancestry.Add([ordered]@{ pid = $curPid; parentPid = 0; name = ''; resolved = $false }); break }
          [void]$ancestry.Add([ordered]@{ pid = [int]$par.ProcessId; parentPid = [int]$par.ParentProcessId; name = [string]$par.Name; resolved = $true })
          if ([int]$par.ProcessId -eq $EntryPid) { break }
          $curPid = [int]$par.ParentProcessId
        }
        [void]$found.Add([ordered]@{
          pid = [int]$p.ProcessId; parentPid = [int]$p.ParentProcessId
          name = [string]$p.Name; exe = [string]$p.ExecutablePath; cmd = $cmd
          createdAt = $(if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { '' })
          ancestry = @($ancestry)
        })
      }
    } catch { }
    if ($found.Count -gt 0) { break }
    Start-Sleep -Seconds 1
  }
  return @($found)
}

function Send-PhaseEvidence {
  <# M-25：逐文件上传必须有总预算，否则 final 阶段 55+ 个 check 串行 × 180s 会顶穿宿主 45min 上限。
     超预算的条目显式记为 skipped=budget（不静默丢弃），由 c0-evidence-upload 判 evidence-incomplete。 #>
  param([string[]]$Files, [int]$TimeoutSeconds = 60, [int]$MaxTotalSeconds = 900)
  $rows = New-Object System.Collections.ArrayList
  $budget = [Diagnostics.Stopwatch]::StartNew()
  foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $leaf = [IO.Path]::GetFileName($f)
    $name = $leaf
    if ($f -match '\\checks\\') { $name = 'check-' + $leaf }
    if ($budget.Elapsed.TotalSeconds -ge $MaxTotalSeconds) {
      [void]$rows.Add([ordered]@{ file = $f; name = $name; url = ''; httpStatus = 0; ok = $false; error = 'skipped: upload budget exceeded'; skipped = 'budget' })
      continue
    }
    $uri = $EvidenceUrl.TrimEnd('/') + '/' + $RunId + '/' + $Phase + '/' + [uri]::EscapeDataString($name)
    $code = -1
    $err = ''
    try {
      $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
      $resp = Invoke-WebRequest -Uri $uri -Method Post -InFile $f -ContentType 'application/octet-stream' `
        -Headers @{ 'X-MW-Sha256' = $sha } -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
      $code = [int]$resp.StatusCode
    } catch {
      $r = $null
      try { $r = $_.Exception.Response } catch { }
      if ($r) { $code = [int]$r.StatusCode }
      $err = $_.Exception.Message
    }
    [void]$rows.Add([ordered]@{
      file = $f; name = $name; url = $uri; httpStatus = $code; ok = ($code -ge 200 -and $code -lt 300); error = $err; skipped = ''
    })
  }
  return @($rows)
}

function Invoke-FinalPhase {
  Set-MwProgress -Step 'final-1 - 核对程序包版本/哈希/签名'
  $inst = Resolve-StagePath -NameOrPath $Installer31
  $instMeta = [ordered]@{ path = $inst; exists = (Test-Path -LiteralPath $inst) }
  if ($instMeta.exists) {
    $fi = Get-Item -LiteralPath $inst
    $instMeta.size = [long]$fi.Length
    $instMeta.sha256 = (Get-FileHash -LiteralPath $inst -Algorithm SHA256).Hash
    $instMeta.fileVersion = [string]$fi.VersionInfo.FileVersion
    $instMeta.productVersion = [string]$fi.VersionInfo.ProductVersion
    try {
      $sig = Get-AuthenticodeSignature -LiteralPath $inst
      $instMeta.signatureStatus = [string]$sig.Status
      $instMeta.signer = $(if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' })
    } catch { $instMeta.signatureStatus = 'ERROR: ' + $_.Exception.Message }
  }
  $instEv = Save-EvidenceJson -Name 'installer-metadata.json' -Object $instMeta
  Add-PhaseCheck -Id 'c13-installer-metadata' -Criterion 13 `
    -Requirement '记录安装包版本/大小/SHA256/签名状态' `
    -Steps @('读取安装包文件信息', '计算 SHA256', 'Get-AuthenticodeSignature') `
    -Assertion '字段齐全；签名状态如实记录（未签名不算通过其它项）' `
    -Expected 'size/sha256/version/signature 均有值' `
    -Actual ('size=' + $instMeta.size + '; version=' + $instMeta.fileVersion + '; sig=' + $instMeta.signatureStatus) `
    -Evidence @($instEv) `
    -Preconditions @('3.1 安装包在 stage 且 SHA256 与本轮清单一致') `
    -Status $(if ($instMeta.exists -and $instMeta.sha256 -and $instMeta.signatureStatus) { 'pass' } elseif (-not $instMeta.exists) { 'blocked-precondition' } else { 'evidence-incomplete' }) `
    -Detail '只记录签名状态，不要求必须已签名。' `
    -Data $instMeta

  # ---------- 项 13：静态解析 + 工作台子进程 + 技能包装
  Set-MwProgress -Step 'final-2 - 技能包装静态解析'
  $resolver = Join-Path $App 'skill\mingling-install\scripts\resolve-program-root.ps1'
  $skillBoot = Join-Path $App 'skill\mingling-install\scripts\bootstrap.ps1'
  $appBoot = Join-Path $App 'tools\bootstrap.ps1'
  $resolveRec = $null
  $resolved = ''
  if (Test-Path -LiteralPath $resolver) {
    $resolveRec = Invoke-Cap -Label 'resolve-program-root' -FilePath $resolver -TimeoutSeconds 120 `
      -StepText 'final-2 - resolve-program-root.ps1'
    $resolved = ([string]$resolveRec.stdoutText).Trim()
  }
  $resolveEv = Save-EvidenceJson -Name 'resolve-program-root.json' -Object ([ordered]@{
    resolver = $resolver; output = $resolved; expected = $App
    exitCode = $(if ($resolveRec) { $resolveRec.exitCode } else { $null })
  })
  Add-PhaseCheck -Id 'c13-entry-static' -Criterion 13 `
    -Requirement '技能包装的 resolve-program-root 解析到真实程序根' `
    -Steps @('运行 skill\mingling-install\scripts\resolve-program-root.ps1') `
    -Assertion '输出（Trim 后）等于 {App}' -Expected $App -Actual $resolved `
    -Evidence @($resolveEv, $(if ($resolveRec) { $resolveRec.stdoutPath } else { $resolveEv })) `
    -Preconditions @('程序目录与 tools 脚本已安装') `
    -Status $(if ($resolved -and [IO.Path]::GetFullPath($resolved).TrimEnd('\') -eq [IO.Path]::GetFullPath($App).TrimEnd('\')) { 'pass' } elseif (-not $resolveRec) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail '解析顺序：HKCU ProgramRoot → Uninstall 键 → %LOCALAPPDATA%\Programs；每个候选都要有 tools\bootstrap.ps1。' `
    -Data ([ordered]@{ output = $resolved; expected = $App })

  Set-MwProgress -Step 'final-3 - 工作台 --autosetup 子进程追踪'
  $trace = @()
  $autosetupRec = $null
  $entryPid = 0
  if (Test-Path -LiteralPath $AppExe) {
    $started = Get-Date
    $st = Start-MwCommand -Label 'autosetup' -FilePath $AppExe -Arguments @('--autosetup') `
      -EvidenceDir $script:EvidenceDir -RunId $RunId
    if ($st.Process) { $entryPid = $st.Process.Id }
    $trace = @(Get-BootstrapChildTrace -EntryPid $entryPid -Since $started -TimeoutSeconds 90)
    if ($st.Process -and -not $st.Process.HasExited) { [void](Stop-MwProcessTree -ProcessId $entryPid) }
    $autosetupRec = Complete-MwCommand -State $st -TimeoutSeconds 120 -EvidenceDir $script:EvidenceDir
    [void]$commands.Add($autosetupRec)
  }
  $traceEv = Save-EvidenceJson -Name 'autosetup-trace.json' -Object ([ordered]@{
    entryPid = $entryPid; startedVia = '--autosetup'; trace = $trace
    stdout = $(if ($autosetupRec) { $autosetupRec.stdoutPath } else { '' })
    stderr = $(if ($autosetupRec) { $autosetupRec.stderrPath } else { '' })
    exitCode = $(if ($autosetupRec) { $autosetupRec.exitCode } else { $null })
  })
  $traceOk = ($trace.Count -gt 0)
  $traceMatch = 0
  $chainOk = $false
  foreach ($t in $trace) {
    if ([string]$t.cmd -like ('*' + $appBoot + '*')) { $traceMatch++ }
    foreach ($a in @($t.ancestry)) { if ($entryPid -gt 0 -and [int]$a.pid -eq $entryPid) { $chainOk = $true } }
  }
  Add-PhaseCheck -Id 'c13-autosetup-trace' -Criterion 13 `
    -Requirement '真实工作台子进程（--autosetup）执行 bootstrap.ps1，路径落在程序根' `
    -Steps @('Start-Process MinglingWorkbench.exe --autosetup', '90s 内枚举 Win32_Process，按 CommandLine 匹配 bootstrap.ps1', '记录 PID/父 PID/ExecutablePath/CommandLine 与真实父链', '结束进程树') `
    -Assertion '抓到至少一条子进程记录；bootstrap.ps1 绝对路径等于 {App}\tools\bootstrap.ps1；父链能回到工作台 entryPid' `
    -Expected ($appBoot + ' 且 ancestry 含 entryPid=' + $entryPid) -Actual ('trace=' + $trace.Count + '; matchAppBoot=' + $traceMatch + '; chainOk=' + $chainOk + '; first=' + $(if ($traceOk) { [string]$trace[0].cmd } else { '无记录' })) `
    -Evidence @($traceEv, $(if ($autosetupRec) { $autosetupRec.stdoutPath } else { $traceEv })) `
    -Preconditions @('工作台 exe 存在且可启动 --autosetup') `
    -Status $(if ($traceOk -and $traceMatch -gt 0 -and $chainOk) { 'pass' } elseif (-not (Test-Path -LiteralPath $AppExe)) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail 'M-12：只看到“某个 bootstrap.ps1 在跑”不够——沿 ParentProcessId 在 WMI 快照里向上走最多 8 跳，必须回到 --autosetup 的 entryPid，才证明是工作台自己拉起的子进程（不是计划任务/残留进程）。抓到了进程但父链回不去或路径落点不对，记 fail-product。90s 窗口比旧夹具的 45s 宽。' `
    -Data ([ordered]@{ trace = $trace; entryPid = $entryPid; matchAppBoot = $traceMatch; chainOk = $chainOk; appBoot = $appBoot })

  Set-MwProgress -Step 'final-4 - 技能包装入口（真实 bootstrap 路径与哈希）'
  $wrapRec = $null
  $wrapPath = ''
  $appHashBefore = ''
  if (Test-Path -LiteralPath $appBoot) { $appHashBefore = (Get-FileHash -LiteralPath $appBoot -Algorithm SHA256).Hash }
  $wrapScriptText = ''
  if (Test-Path -LiteralPath $skillBoot) { $wrapScriptText = [string](Read-TextAuto -Path $skillBoot) }
  if (Test-Path -LiteralPath $skillBoot) {
    $wrapRec = Invoke-Long -Label 'skill-bootstrap-check' -FilePath $skillBoot `
      -Arguments @('-Base',$Ws,'-Workspace',$Ws,'-Bots',$BotsRoot,'-Check') -TimeoutSeconds 900 `
      -StepText 'final-4 - 技能包装 -Check'
    $wrapText = [string]$wrapRec.stdoutText + "`n" + [string]$wrapRec.stderrText
    $bm = [regex]::Match($wrapText, '##BOOTSTRAP\s+([^\r\n]+)')
    if ($bm.Success) { $wrapPath = $bm.Groups[1].Value.Trim() }
  }
  $appHash = $appHashBefore
  if (Test-Path -LiteralPath $appBoot) { $appHash = (Get-FileHash -LiteralPath $appBoot -Algorithm SHA256).Hash }
  $wrapHash = ''
  if ($wrapPath -and (Test-Path -LiteralPath $wrapPath)) { $wrapHash = (Get-FileHash -LiteralPath $wrapPath -Algorithm SHA256).Hash }
  # M-13：两处哈希都是现场算的，等价本身不构成独立证据；独立证据是“路径相等 + 运行前后未被替换 + 包装脚本文本确实调用 resolver”。
  $appStable = ([bool]$appHashBefore -and [bool]$appHash -and $appHashBefore -eq $appHash)
  $wrapCallsResolve = ($wrapScriptText -match 'resolve-program-root\.ps1')
  $shownInApp = ($wrapPath -and ([IO.Path]::GetFullPath($wrapPath).TrimEnd('\') -eq [IO.Path]::GetFullPath($appBoot).TrimEnd('\')))
  $shownInWs = ($wrapPath -and ([IO.Path]::GetFullPath($wrapPath).TrimEnd('\').ToLower().StartsWith(([IO.Path]::GetFullPath($Ws).TrimEnd('\') + '\').ToLower())))
  $wrapEv = Save-EvidenceJson -Name 'skill-wrapper.json' -Object ([ordered]@{
    wrapper = $skillBoot; shownPath = $wrapPath; appBoot = $appBoot; appSha256 = $appHash; shownSha256 = $wrapHash
    appHashBefore = $appHashBefore; appStable = $appStable; wrapCallsResolve = $wrapCallsResolve
    shownInApp = $shownInApp; shownInWs = $shownInWs
    exitCode = $(if ($wrapRec) { $wrapRec.exitCode } else { $null })
  })
  Add-PhaseCheck -Id 'c13-skill-wrapper' -Criterion 13 `
    -Requirement '技能包装入口执行同一个 bootstrap.ps1（同路径 + 同 SHA256）' `
    -Steps @('运行 skill\mingling-install\scripts\bootstrap.ps1 -Check', '从输出抓 ##BOOTSTRAP <path>', '比对路径与 SHA256') `
    -Assertion 'shownPath == {App}\tools\bootstrap.ps1；脚本运行前后 SHA256 未变；包装脚本文本调用 resolve-program-root.ps1；不落到工作区 tools' `
    -Expected ($appBoot + '；appStable=true；wrapCallsResolve=true；shownInWs=false') -Actual ('path=' + $wrapPath + '; stable=' + $appStable + '; callsResolve=' + $wrapCallsResolve + '; inApp=' + $shownInApp + '; inWs=' + $shownInWs + '; hashEqual=' + ($appHash -and $appHash -eq $wrapHash)) `
    -Evidence @($wrapEv, $skillBoot, $(if ($wrapRec) { $wrapRec.stdoutPath } else { $wrapEv })) `
    -Preconditions @('技能包装脚本与 resolve-program-root.ps1 已随包安装') `
    -Status $(if ($shownInApp -and $appStable -and $appHash -and $appHash -eq $wrapHash -and $wrapCallsResolve -and -not $shownInWs) { 'pass' } elseif (-not $wrapRec) { 'blocked-precondition' } else { 'fail-product' }) `
    -Detail 'M-13：appSha256 与 shownSha256 都是场内现算的，两者相等并不能证明“入口没换实现”——所以补充三条独立证据：① appStable（运行前后程序目录 bootstrap.ps1 哈希未变，排除运行中被替换）② wrapCallsResolve（包装脚本文本里确实调用 resolve-program-root.ps1）③ shownInWs=false（没有落回工作区 tools）。包装脚本先 resolve-program-root，再打 ##BOOTSTRAP，然后 & 同一个脚本。' `
    -Data ([ordered]@{ shownPath = $wrapPath; appSha256 = $appHash; shownSha256 = $wrapHash; appHashBefore = $appHashBefore; appStable = $appStable; wrapCallsResolve = $wrapCallsResolve; shownInApp = $shownInApp; shownInWs = $shownInWs; exit = $(if ($wrapRec) { $wrapRec.exitCode } else { $null }) })

  # ---------- 证据清单
  Set-MwProgress -Step 'final-5 - 汇总证据清单'
  $inv = New-Object System.Collections.ArrayList
  $totalBytes = [long]0
  $stagePrefix = (Join-Path $RunDir 'stage') + '\'
  foreach ($f in @(Get-ChildItem -LiteralPath $RunDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    if ($f.FullName -like ($stagePrefix + '*')) { continue }
    if ($f.Length -gt 67108864) { [void]$inv.Add([ordered]@{ path = $f.FullName; size = $f.Length; sha256 = 'skipped-large' }); continue }
    try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { $h = 'unreadable' }
    $totalBytes += $f.Length
    [void]$inv.Add([ordered]@{ path = $f.FullName; size = $f.Length; sha256 = $h })
  }
  $badRows = @($inv | Where-Object { [string]$_.sha256 -notmatch '^[0-9a-f]{64}$' -and [string]$_.sha256 -ne 'skipped-large' })
  $skippedLarge = @($inv | Where-Object { [string]$_.sha256 -eq 'skipped-large' }).Count
  $invEv = Save-EvidenceJson -Name 'evidence-inventory.json' -Object ([ordered]@{
    runDir = $RunDir; phase = $Phase; files = $inv.Count; totalBytes = $totalBytes; rows = @($inv)
  })
  Add-PhaseCheck -Id 'c13-evidence-inventory' -Criterion 13 `
    -Requirement '本 run 的证据清单与 SHA256 可复核' `
    -Steps @('递归枚举 run\<RunId>（排除 stage 大文件）', '逐文件 SHA256') `
    -Assertion '清单非空；每个文件都有 64hex sha256（skipped-large 显式豁免）；总字节>0' `
    -Expected 'files>0 且 badRows=0 且 totalBytes>0' -Actual ('files=' + $inv.Count + '; badRows=' + $badRows.Count + '; skippedLarge=' + $skippedLarge + '; bytes=' + $totalBytes) `
    -Evidence @($invEv) `
    -Preconditions @('本轮各阶段证据目录已生成') `
    -Status $(if ($inv.Count -gt 0 -and $badRows.Count -eq 0 -and $totalBytes -gt 0) { 'pass' } else { 'evidence-incomplete' }) `
    -Detail ('M-14：不再只判“非空”。每个条目必须是可复核的 64hex SHA256；读不了的文件（unreadable）计入 badRows 并让本项 evidence-incomplete。stage 下的安装包可达 88MB，不入清单以免拖慢；>64MB 的文件显式标记 skipped-large（当前 ' + $skippedLarge + ' 个）。') `
    -Data ([ordered]@{ files = $inv.Count; totalBytes = $totalBytes; badRows = @($badRows | Select-Object -First 40); badCount = $badRows.Count; skippedLarge = $skippedLarge })

  # ---------- 上传关键证据
  Set-MwProgress -Step 'final-6 - 上传证据到宿主'
  $uploadFiles = New-Object System.Collections.ArrayList
  foreach ($n in @('phase.json','results.jsonl','commands.jsonl','manifest.json','installer-metadata.json','autosetup-trace.json','skill-wrapper.json','resolve-program-root.json','evidence-inventory.json','done.json')) {
    $p = Join-Path $script:EvidenceDir $n
    if (Test-Path -LiteralPath $p) { [void]$uploadFiles.Add($p) }
  }
  $phDir = Join-Path $RunDir ('phases\' + $Phase)
  foreach ($n in @('phase.json','results.jsonl','commands.jsonl','manifest.json','manifest.json.sha256')) {
    $p = Join-Path $phDir $n
    if (Test-Path -LiteralPath $p) { [void]$uploadFiles.Add($p) }
  }
  # M-15：不再 Select-Object -First 40 截断——每个 check 的 checks/<id>.json 都要回传。
  foreach ($c in @(Get-ChildItem -LiteralPath (Join-Path $script:EvidenceDir 'checks') -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    [void]$uploadFiles.Add($c.FullName)
  }
  $upRows = @(Send-PhaseEvidence -Files @($uploadFiles) -TimeoutSeconds 20 -MaxTotalSeconds 900)
  $upEv = Save-EvidenceJson -Name 'upload-results.json' -Object ([ordered]@{
    evidenceUrl = $EvidenceUrl; runId = $RunId; phase = $Phase
    uploaded = @($upRows | Where-Object { $_.ok }).Count; failed = @($upRows | Where-Object { -not $_.ok }).Count
    rows = $upRows
  })
  $upOk = (@($upRows | Where-Object { -not $_.ok }).Count -eq 0 -and $upRows.Count -gt 0)
  Add-PhaseCheck -Id 'c0-evidence-upload' -Criterion 13 `
    -Preconditions @('本阶段证据文件已落盘（phases 目录存在）','宿主证据服务已启动且 /health 可达') `
    -Requirement '每阶段关键证据 POST 到宿主证据服务，并记录 HTTP 状态码' `
    -Steps @('POST $EvidenceUrl/<RunId>/<Phase>/<name>', '记录 httpStatus 与错误文本', '失败也不静默') `
    -Assertion '全量上传（不截断）；全部 2xx；失败/超预算条目在 upload-results.json 中逐条可见' `
    -Expected 'failed=0 且 skipped=0' -Actual ('uploaded=' + @($upRows | Where-Object { $_.ok }).Count + '; failed=' + @($upRows | Where-Object { -not $_.ok }).Count + '; skipped=' + @($upRows | Where-Object { $_.skipped }).Count) `
    -Evidence @($upEv) `
    -Status $(if ($upOk) { 'pass' } else { 'evidence-incomplete' }) `
    -Detail '用 Invoke-WebRequest（任务指定），不是库里的 curl 封装。M-15：checks/*.json 全量上传，不再只取前 40 个；M-25：单请求 20s、整段 900s 预算，超预算条目记 skipped=budget 而不是静默丢弃。' `
    -Data ([ordered]@{ rows = $upRows; total = $upRows.Count; skipped = @($upRows | Where-Object { $_.skipped }).Count })
}

# ================================================================ 阶段覆盖自检
function Get-ExpectedCheckIds {
  param([string]$ForPhase)
  $map = @{
    'pre' = @('c2-stage-assets','c2-stage-integrity','c3-normal-user-install','c3-program-exe-version','c3-program-workspace-separate','c4-chinese-space-paths','c1-manifest-schema','c1-dependency-dag','c1-source-hashes','c1-state-model','c2-source-real-chain','c2-tamper-reject','c5-check-before-components','c5-webview2-missing-branch','c11-pre-snowluma-manual')
    'full' = @('c9-full-install','c9-astrbot-init','c9-astrbot-process','c9-selfsetup-apply','c9-selfsetup-verify','c9-model-stub-protocol','c5-check-after-components','c2-download-cache-hashes','c6-idempotent-exit','c6-idempotent-files','c10-key-scan','c11-default-manual')
    'recovery' = @('c7-interrupt-observed','c7-offline-fails-after-interrupt','c7-online-recovers','c7-completed-not-reinstalled','c7-half-install-synthetic','c7-half-install-online-fix','c8-offline-valid-cache','c8-offline-empty-cache','c8-offline-bad-cache','c8-real-network-cut')
    'upgrade' = @('c12-custom-upgrade','c12-custom-protected','c12-custom-backup','c12-default-upgrade','c12-default-protected','c12-default-backup','c12-old-helper-upgrade','c12-old-helper-protected','c12-old-helper-backup')
    'final' = @('c13-installer-metadata','c13-entry-static','c13-autosetup-trace','c13-skill-wrapper','c13-evidence-inventory','c0-evidence-upload')
  }
  if ($map.ContainsKey($ForPhase)) { return @($map[$ForPhase]) }
  return @()
}

function Add-PhaseCoverageCheck {
  <# M-23：没有“应有检查集合”断言时，执行器漏跑一项也会静默通过。
     这里显式比对：缺失项在没有 blocked-precondition 的情况下必须让本阶段 evidence-incomplete。 #>
  $expected = @(Get-ExpectedCheckIds -ForPhase $Phase)
  if ($expected.Count -eq 0) { return }
  $actual = @($checks | ForEach-Object { [string]$_['id'] })
  $missing = @($expected | Where-Object { $actual -notcontains $_ })
  $extra = @($actual | Where-Object { $expected -notcontains $_ -and $_ -notlike 'c0-*' -and $_ -notlike 'selftest-*' })
  $blocked = @($checks | Where-Object { [string]$_['id'] -like 'c0-*-precondition' -and [string]$_['status'] -eq 'blocked-precondition' })
  $status = 'pass'
  if ($missing.Count -gt 0) { $status = $(if ($blocked.Count -gt 0) { 'not-run' } else { 'evidence-incomplete' }) }
  Add-PhaseCheck -Id 'c0-check-coverage' -Criterion 0 `
    -Preconditions @('阶段执行器按预期调用本阶段全部检查') `
    -Requirement '本阶段应执行的检查集合必须完整（漏跑不得静默通过）' `
    -Steps @('列出本阶段预期 check id', '与实际跑过的 check id 比对') `
    -Assertion '预期集合全部出现；缺失且无 blocked-precondition 时本项 evidence-incomplete' `
    -Expected ($expected.Count.ToString() + ' 项') -Actual ($actual.Count.ToString() + ' 项；missing=' + $missing.Count) `
    -Evidence @('inline:expected=' + ($expected -join ',')) `
    -Preconditions @('本阶段 checks 目录已创建（每条 check 都会落盘）') `
    -Status $status `
    -Detail ('缺失：' + $(if ($missing.Count -gt 0) { $missing -join ', ' } else { '无' }) + '；额外：' + $(if ($extra.Count -gt 0) { $extra -join ', ' } else { '无' }) + '；' + $(if ($blocked.Count -gt 0) { '阶段已被 c0 前置检查阻塞，缺失属预期，记 not-run。' } else { '没有阻塞却没有执行，说明夹具漏跑。' })) `
    -Data ([ordered]@{ expected = $expected; actual = $actual; missing = $missing; extra = $extra })
}

# ================================================================ 主调度
# 自测模式：只验证 Add-PhaseCheck 包装层（不进入任何阶段逻辑，不动产品）。
if ($script:SelfTestMode) {
  try {
    $script:EvidenceDir = Join-Path $GuestRoot 'selftest'
    if (-not (Test-Path -LiteralPath $script:EvidenceDir)) { New-Item -ItemType Directory -Force -Path $script:EvidenceDir | Out-Null }
    exit (Invoke-WrapperSelfTest)
  } catch {
    try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'mw-runner-selftest-error.txt'), $_.Exception.ToString()) } catch { }
    exit 1
  }
}
$fatalError = $null
try {
  Set-MwProgress -Step ('phase - 开始执行 ' + $Phase) -Command ('Invoke-Phase.ps1 ' + $Phase)
  switch ($Phase) {
    'pre'      { Invoke-PrePhase }
    'full'     { Invoke-FullPhase }
    'recovery' { Invoke-RecoveryPhase }
    'upgrade'  { Invoke-UpgradePhase }
    'final'    { Invoke-FinalPhase }
    default    { throw ('未知阶段：' + $Phase) }
  }
} catch {
  $fatalError = $_
  $msg = [string]$_.Exception.Message
  $stack = [string]$_.ScriptStackTrace
  Add-PhaseCheck -Id 'c0-harness-fatal' -Criterion 0 `
    -Requirement '夹具自身必须可执行；崩溃时不得留下假结果' `
    -Preconditions @('脚本已启动并加载验收库') `
    -Steps @('捕获未处理异常并记录消息与调用栈') `
    -Assertion '失败以 fail-fixture 呈现' -Expected '无异常' -Actual $msg `
    -Evidence @($script:EvidenceDir) `
    -Status 'fail-fixture' `
    -Detail ($msg + "`n" + $stack) `
    -Data ([ordered]@{ message = $msg; stack = $stack })
} finally {
  # M-23：先补“应有检查集合”断言，再做统计（漏跑的检查必须影响本阶段结论）。
  try { Add-PhaseCoverageCheck } catch { }
  $endedUtc = (Get-Date).ToUniversalTime().ToString('o')
  $counts = $null
  try { $counts = Get-MwCounts -Results $checks } catch { $counts = [ordered]@{} }
  $exitCode = 11
  try { $exitCode = Get-MwPhaseExitCode -Results $checks } catch { $exitCode = 11 }
  if ($fatalError) { $exitCode = 11 }
  $failedCount = 0
  if ($counts -and $counts.Contains('fail-product')) { $failedCount = [int]$counts['fail-product'] + [int]$counts['fail-fixture'] }
  $status = 'completed'
  if ($fatalError -or $failedCount -gt 0) { $status = 'failed' }

  $summary['counts'] = $counts
  $summary['exitCode'] = $exitCode
  $summary['status'] = $status
  $summary['endedUtc'] = $endedUtc
  $summary['fatal'] = $(if ($fatalError) { [string]$fatalError.Exception.Message } else { '' })
  $summary['commands'] = $commands.Count

  try { Complete-MwProgress -Status $status -Summary ('checks=' + $checks.Count + ' exit=' + $exitCode) } catch { }

  $save = $null
  $saveError = ''
  try { $save = Save-MwPhase -RunDir $RunDir -Phase $Phase -Summary $summary -Results $checks -Commands $commands } catch {
    $saveError = [string]$_.Exception.Message
    try { Add-Content -LiteralPath (Join-Path $script:EvidenceDir 'save-error.txt') -Value $saveError } catch { }
    try {
      Save-MwJson -Path (Join-Path $script:EvidenceDir 'save-phase-error.json') -Object ([ordered]@{
        phase = $Phase; runId = $RunId; error = $saveError; at = (Get-Date).ToUniversalTime().ToString('o')
        results = $checks.Count; commands = $commands.Count
      }) -Depth 8
    } catch { }
  }
  # M-22：phases\<Phase> 不在宿主 copyDirectoryFromGuestToHost 的回收范围里，所以 run 目录再留一份汇总。
  if ($save) {
    foreach ($n in @('phase.json', 'manifest.json', 'manifest.json.sha256', 'results.jsonl', 'commands.jsonl')) {
      try {
        $src = Join-Path $save.dir $n
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $script:EvidenceDir $n) -Force }
      } catch { }
    }
  }

  # M-22：阶段汇总没落盘就不能算“完成”，即使各项检查都过了也要暴露为 fail-fixture。
  if (-not $save) {
    $status = 'failed'
    if ($exitCode -eq 0) { $exitCode = 11 }
    $summary['status'] = $status
    $summary['exitCode'] = $exitCode
  }

  $done = [ordered]@{
    phase = $Phase; runId = $RunId; status = $status; exitCode = $exitCode
    startedUtc = $startedUtc; endedUtc = $endedUtc
    checks = $checks.Count
    counts = $counts
    failProduct = $(if ($counts -and $counts.Contains('fail-product')) { $counts['fail-product'] } else { 0 })
    failFixture = $(if ($counts -and $counts.Contains('fail-fixture')) { $counts['fail-fixture'] } else { 0 })
    blocked = $(if ($counts -and $counts.Contains('blocked-precondition')) { $counts['blocked-precondition'] } else { 0 })
    evidenceIncomplete = $(if ($counts -and $counts.Contains('evidence-incomplete')) { $counts['evidence-incomplete'] } else { 0 })
    phasesDir = $(if ($save) { $save.dir } else { '' })
    saveError = $saveError
    fatal = $(if ($fatalError) { [string]$fatalError.Exception.Message } else { '' })
    host = $env:COMPUTERNAME; user = $env:USERNAME
  }
  Save-MwJson -Path (Join-Path $script:EvidenceDir 'done.json') -Object $done -Depth 10

  # 每个阶段都回传证据（成功/失败都一样），不能等到 final 才拿得到日志。
  # 宿主机还有 copyDirectoryFromGuestToHost 作为主通道；这里是发生 VM 通道半坏时的兜底，
  # 上传回执（HTTP 状态 + 文件名）单独落盘，便于判定“到底是产物没生成还是没回传”。
  try {
    $uploadFiles = New-Object System.Collections.ArrayList
    if ($save) {
      foreach ($n in @('phase.json', 'results.jsonl', 'commands.jsonl', 'manifest.json', 'manifest.json.sha256')) {
        $up = Join-Path $save.dir $n
        if (Test-Path -LiteralPath $up) { [void]$uploadFiles.Add($up) }
      }
    }
    $upDone = Join-Path $script:EvidenceDir 'done.json'
    if (Test-Path -LiteralPath $upDone) { [void]$uploadFiles.Add($upDone) }
    $rows = @(Send-PhaseEvidence -Files @($uploadFiles))
    Save-MwJson -Path (Join-Path $script:EvidenceDir 'upload-phase.json') -Object $rows -Depth 8
  } catch {
    try { [IO.File]::WriteAllText((Join-Path $script:EvidenceDir 'upload-phase-error.txt'), $_.Exception.ToString(), (New-Object Text.UTF8Encoding($true))) } catch { }
  }

  exit $exitCode
}

