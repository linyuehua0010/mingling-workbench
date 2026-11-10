#requires -Version 5.1
<#
  acceptance\lib\Check.ps1 — 验收断言模型：状态分类、前置条件、证据完整性、退出码。

  为什么要分类：旧夹具只有 pass/fail，产品失败、夹具写错、机器不可用、证据缺失全混成一个 fail，
  于是“fail 之后执行器仍认为本阶段通过”和“环境没通就把项目判通过”都可能发生。

  状态（机器可读，写进 results.jsonl 的 status 字段）：
    pass                 断言成立，且前置条件齐全、证据存在
    fail-product         产品行为不符合要求（有失败证据）
    fail-fixture         验收夹具自身错误（脚本异常、断言写错、探针缺失）
    blocked-precondition 前置条件缺失（例如未先完成安装、组件未启用）
    blocked-env          环境阻塞（VM/凭据/网络/权限不可用）
    evidence-incomplete  断言声称通过但证据缺失或读不到
    manual-pending       需要人工完成的项（真实登录、付费 Key 等），不算通过也不算失败
    not-run              未执行

  退出码（阶段级）：0 无常规失败；10 产品失败；11 夹具失败；12 前置条件缺失；13 环境阻塞；14 证据不完整。
  优先级：fixture > product > precondition > env > evidence（环境/前置导致的“未测”不应掩盖真实产品失败）。
#>

$script:MwStatuses = @('pass', 'fail-product', 'fail-fixture', 'blocked-precondition', 'blocked-env', 'evidence-incomplete', 'manual-pending', 'not-run')
$script:MwExitMap = [ordered]@{
    'fail-fixture'        = 11
    'fail-product'        = 10
    'blocked-precondition' = 12
    'blocked-env'         = 13
    'evidence-incomplete' = 14
}

function New-MwCheck {
    <#
      构造一条断言记录。pass 会被强制校验：必须有前置条件（非空）、必须有存在的证据；
      否则自动降级为 evidence-incomplete，避免“空口通过”。
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
        [string]$Status = 'pass',
        [string]$Detail = '',
        $Data = $null
    )

    if ($script:MwStatuses -notcontains $Status) { throw "未知状态：$Status" }

    $problems = @()
    if ($Status -eq 'pass') {
        if (@($Preconditions).Count -eq 0) { $problems += '缺少前置条件' }
        if (@($Evidence).Count -eq 0) { $problems += '缺少证据引用' }
        $missing = @()
        foreach ($e in @($Evidence)) {
            if ($e -like 'inline:*') { continue }
            if (-not (Test-Path -LiteralPath $e)) { $missing += $e }
        }
        if ($missing.Count -gt 0) { $problems += ('证据不存在：' + ($missing -join '; ')) }
        if ($problems.Count -gt 0) {
            $Status = 'evidence-incomplete'
            $Detail = (($Detail + ' | ') + ($problems -join '; ')).Trim(' ', '|')
        }
    }

    return [ordered]@{
        id = $Id
        criterion = $Criterion
        requirement = $Requirement
        preconditions = @($Preconditions)
        steps = @($Steps)
        assertion = $Assertion
        expected = $Expected
        actual = $Actual
        evidence = @($Evidence)
        status = $Status
        detail = $Detail
        data = $Data
        at = (Get-Date).ToUniversalTime().ToString('o')
        tool = 'acceptance/lib/Check.ps1'
        version = '3.1.0-harness2'
    }
}

function Get-MwCounts {
    param($Results)

    $c = [ordered]@{ total = 0; pass = 0; 'fail-product' = 0; 'fail-fixture' = 0; 'blocked-precondition' = 0; 'blocked-env' = 0; 'evidence-incomplete' = 0; 'manual-pending' = 0; 'not-run' = 0 }
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $c.total++
        $s = [string]$r.status
        if ($c.Contains($s)) { $c[$s]++ } else { $c['not-run']++ }
    }
    return $c
}

function Get-MwPhaseExitCode {
    <# 阶段退出码：按优先级取第一个命中的状态。全部 pass / manual-pending / not-run 时为 0。 #>
    param($Results)

    $c = Get-MwCounts -Results $Results
    foreach ($s in @('fail-fixture', 'fail-product', 'blocked-precondition', 'blocked-env', 'evidence-incomplete')) {
        if ($c[$s] -gt 0) { return $script:MwExitMap[$s] }
    }
    return 0
}

function Test-MwPhaseComplete {
    <# 只有“无 fail、无 blocked、无 evidence-incomplete”才算本阶段完整通过；manual-pending 不阻塞但必须单列。 #>
    param($Results)

    $c = Get-MwCounts -Results $Results
    return ($c['fail-product'] -eq 0 -and $c['fail-fixture'] -eq 0 -and $c['blocked-precondition'] -eq 0 -and
        $c['blocked-env'] -eq 0 -and $c['evidence-incomplete'] -eq 0)
}
