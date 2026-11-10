#requires -Version 5.1
<#
  acceptance\lib\Progress.ps1 — 长任务进度（来宾侧写，宿主机侧轮询读取）

  为什么单独一层：安装/复验单阶段可能跑几十分钟，宿主机不能只"盲等 vmrun"。
  来宾每进入一步就原子写 progress.json（阶段、当前步骤、当前命令、已耗时、最近日志尾部），
  宿主机每 20~30 秒 copyFileFromGuestToHost 取一次并打印，既能看到进度，也能留下时间线证据。

  落盘字段：runId/phase/status/step/command/startedUtc/updatedUtc/elapsedSeconds/tail/counter
#>

$script:MwProgressState = @{
    Dir      = ''
    RunId    = ''
    Phase    = ''
    Started  = $null
    Steps    = 0
    LastTail = ''
    LastStep = ''
    LastCommand = ''
}

function Initialize-MwProgress {
    param([Parameter(Mandatory)][string]$Dir, [string]$Phase = '', [string]$RunId = '')
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $script:MwProgressState.Dir = $Dir
    $script:MwProgressState.Phase = $Phase
    $script:MwProgressState.RunId = $RunId
    $script:MwProgressState.Started = Get-Date
    $script:MwProgressState.Steps = 0
    $script:MwProgressState.LastTail = ''
    $script:MwProgressState.LastStep = ''
    $script:MwProgressState.LastCommand = ''
    Write-MwProgressPayload -Status 'running' -Step 'phase-start' -Command ''
}

function Write-MwProgressPayload {
    param([string]$Status = 'running', [string]$Step = '', [string]$Command = '', [string]$Tail = '')
    $dir = $script:MwProgressState.Dir
    if (-not $dir) { return }
    $now = Get-Date
    $elapsed = 0
    if ($script:MwProgressState.Started) { $elapsed = [int]($now - $script:MwProgressState.Started).TotalSeconds }
    if ($null -eq $Tail) { $Tail = '' }
    if (-not $Tail) { $Tail = $script:MwProgressState.LastTail }
    # 尾巴更新不能把当前步骤/命令清空：Add-MwProgressTail 只改日志尾部，
    # 这里回填最近一次 Set-MwProgress 的步骤与命令（之前 step/command 被写成空串，宿主只能看到空白）。
    if (-not $Step) { $Step = [string]$script:MwProgressState.LastStep }
    if (-not $Command) { $Command = [string]$script:MwProgressState.LastCommand }
    $payload = [ordered]@{
        runId          = $script:MwProgressState.RunId
        phase          = $script:MwProgressState.Phase
        status         = $Status
        step           = $Step
        command        = $Command
        steps          = $script:MwProgressState.Steps
        startedUtc     = if ($script:MwProgressState.Started) { $script:MwProgressState.Started.ToUniversalTime().ToString('o') } else { '' }
        updatedUtc     = $now.ToUniversalTime().ToString('o')
        elapsedSeconds = $elapsed
        tail           = $Tail
        pid            = $PID
    }
    $path = Join-Path $dir 'progress.json'
    $tmp = $path + '.tmp'
    try {
        ($payload | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch { }
}

function Set-MwProgress {
    <# 标记进入某一步；$Command 应是脱敏后的可读命令（不要塞密钥）。 #>
    param([Parameter(Mandatory)][string]$Step, [string]$Command = '')
    $script:MwProgressState.Steps++
    $script:MwProgressState.LastStep = $Step
    $script:MwProgressState.LastCommand = $Command
    Write-MwProgressPayload -Status 'running' -Step $Step -Command $Command
    Write-Host ('##PROGRESS ' + $Step + $(if ($Command) { ' | ' + $Command } else { '' }))
}

function Add-MwProgressTail {
    <# 记录最近日志尾部（调用方可传命令输出），供宿主机轮询时显示。 #>
    param([AllowEmptyString()][string]$Text = '', [int]$MaxChars = 4000)
    if (-not $Text) { return }
    if ($Text.Length -gt $MaxChars) { $Text = $Text.Substring($Text.Length - $MaxChars) }
    $script:MwProgressState.LastTail = $Text
    Write-MwProgressPayload -Status 'running' -Step '' -Command ''
}

function Complete-MwProgress {
    param([string]$Status = 'completed', [string]$Summary = '')
    $tail = $script:MwProgressState.LastTail
    if ($Summary) { $tail = ($Summary + "`n" + $tail).Trim() }
    Write-MwProgressPayload -Status $Status -Step 'phase-end' -Command '' -Tail $tail
}
