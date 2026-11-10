#requires -Version 5.1
<#
  acceptance\v2\host\New-GuestStandardUser.ps1 — 在来宾里建立“普通用户”验收身份

  为什么需要：第 3/4 项要求“普通用户安装”，断言里必须出现 administratorToken=false。
  来宾目前只有管理员 冥零，所以先用管理员通道建一个标准用户 MWAcceptance，
  把它的口令存进 DPAPI（std-user-password.dpapi / std-user.txt），
  后续阶段用 -GuestUser MWAcceptance 走同一个 vmrun 通道，令牌自然是非提升的。

  口令只在本机生成、只进 DPAPI；控制台只打印长度、SID、组，不打印口令。
#>

. (Join-Path $PSScriptRoot 'VmChannel.ps1')
. (Join-Path $PSScriptRoot 'GuestScript.ps1')

function New-MwRandomPassword {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_#%'
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] ($Length * 4)
    $rng.GetBytes($bytes)
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        [void]$sb.Append($chars[([BitConverter]::ToUInt32($bytes, $i * 4)) % $chars.Length])
    }
    $sb.ToString()
}

function Get-MwGuestIdentity {
    <# 用当前通道跑身份探测，返回 user/sid/isAdmin/groups。 #>
    param([Parameter(Mandatory)][string]$EvidenceDir, [Parameter(Mandatory)][string]$RunId, [string]$EvidenceUrl = '', [string]$Phase = 'identity')
    $body = @'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p = New-Object Security.Principal.WindowsPrincipal -ArgumentList ($id)
$R.data.user = $id.Name
$R.data.sid = $id.User.Value
$R.data.isAdmin = [bool]$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$R.data.integrity = (whoami /groups | Select-String -Pattern 'Mandatory Label' | ForEach-Object { $_.Line.Trim() })
$R.data.groups = @($id.Groups | ForEach-Object { try { $_.Translate([Security.Principal.NTAccount]).Value } catch { $_.Value } })
$R.ok = $true
'@
    $r = Invoke-MwGuestScript -Name 'identity' -Body $body -GuestDir ((Join-Path $script:MwVm.GuestRoot 'probe')) -EvidenceDir $EvidenceDir -RunId $RunId -EvidenceUrl $EvidenceUrl -Phase $Phase -TimeoutSeconds 120
    if (-not $r.fetched -or -not $r.obj) { throw ('身份探测没有取回结果：exit=' + $r.exitCode) }
    if (-not $r.obj.ok) { throw ('身份探测失败：' + $r.obj.error) }
    $r.obj.data
}

function New-MwGuestStandardUser {
    <# 建立/重置标准用户并保存 DPAPI 口令。返回用户信息（不含口令）。 #>
    param(
        [string]$UserName = 'MWAcceptance',
        [Parameter(Mandatory)][string]$EvidenceDir,
        [Parameter(Mandatory)][string]$RunId,
        [string]$EvidenceUrl = ''
    )
    $pw = New-MwRandomPassword 24
    $body = @"
`$u = '$UserName'
`$p = ConvertTo-SecureString -String '$pw' -AsPlainText -Force
`$existing = Get-LocalUser -Name `$u -ErrorAction SilentlyContinue
if (`$existing) {
  Set-LocalUser -Name `$u -Password `$p -PasswordNeverExpires `$true
  `$created = `$false
} else {
  New-LocalUser -Name `$u -Password `$p -PasswordNeverExpires `$true -Description 'MinglingWorkbench acceptance standard user' | Out-Null
  `$created = `$true
}
Add-LocalGroupMember -Group 'Users' -Member `$u -ErrorAction SilentlyContinue
`$acct = Get-LocalUser -Name `$u
`$sid = `$acct.SID.Value
# 确保不在管理员组（有就移除）
foreach (`$g in @('Administrators')) {
  `$m = @(Get-LocalGroupMember -Group `$g -ErrorAction SilentlyContinue | Where-Object { `$_.SID.Value -eq `$sid })
  foreach (`$x in `$m) { Remove-LocalGroupMember -Group `$g -Member `$x.Name -ErrorAction SilentlyContinue }
}
`$R.data.user = `$u
`$R.data.created = `$created
`$R.data.sid = `$sid
`$R.data.enabled = `$acct.Enabled
`$R.data.groups = @('Users','Administrators','Remote Desktop Users' | ForEach-Object {
  `$g = `$_
  [ordered]@{ group = `$g; member = [bool](@(Get-LocalGroupMember -Group `$g -ErrorAction SilentlyContinue | Where-Object { `$_.SID.Value -eq `$sid })).Count }
})
`$R.ok = `$true
"@
    $r = Invoke-MwGuestScript -Name 'create-standard-user' -Body $body -GuestDir ((Join-Path $script:MwVm.GuestRoot 'probe')) -EvidenceDir $EvidenceDir -RunId $RunId -EvidenceUrl $EvidenceUrl -Phase 'setup' -TimeoutSeconds 300
    if (-not $r.fetched -or -not $r.obj) { throw ('建立标准用户没有取回结果：exit=' + $r.exitCode) }
    if (-not $r.obj.ok) { throw ('建立标准用户失败：' + $r.obj.error) }

    $dir = $script:MwVm.SecretsDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sec = ConvertTo-SecureString -String $pw -AsPlainText -Force
    $enc = ConvertFrom-SecureString -SecureString $sec
    Set-Content -LiteralPath (Join-Path $dir 'std-user-password.dpapi') -Value $enc -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dir 'std-user.txt') -Value $UserName -Encoding UTF8
    [pscustomobject]@{
        ok = $true; user = $UserName; sid = $r.obj.data.sid; created = $r.obj.data.created
        groups = $r.obj.data.groups; secretsDir = $dir; passwordLength = $pw.Length
    }
}
