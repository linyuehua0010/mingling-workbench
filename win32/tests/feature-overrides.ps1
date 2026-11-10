# 在隔离工作区运行真实 Do-Plugins，模拟后台接口，不连接运行中的机器人。
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$repo\tools\self-setup.ps1",[ref]$tokens,[ref]$errors)
if($errors){throw 'self-setup syntax error'}
foreach($fn in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $fn.Extent.Text
}
$Base=Join-Path $repo 'tmp\feature-overrides-test'
New-Item -ItemType Directory -Path "$Base\private" -Force | Out-Null
@{sing=@{backend='soulx';root='F:\sing';server_url='http://127.0.0.1:18620';tries=3};pet=@{recent_count=6;recent_hours=4;redirect_reminders=$false}} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$Base\private\feature-settings.json" -Encoding UTF8
'fixture-token' | Set-Content -LiteralPath "$Base\private\volc-token.txt" -Encoding UTF8
'fixture-app' | Set-Content -LiteralPath "$Base\private\volc-app-id.txt" -Encoding UTF8
$packRaw=Get-Content -LiteralPath "$repo\pack\mingling-pack\pack.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$PackDir=Join-Path $repo 'pack\mingling-pack'
$DryRun=$false
$script:written=@{}
function Resolve-Placeholder($value){return $value}
function Api($Method,$Path,$Body=$null,$Timeout=60){
    if($Method -eq 'GET' -and $Path -eq '/plugins') {
        return @{data=@($packRaw.plugins.items|ForEach-Object{@{name=$_.name}})}
    }
    if($Method -eq 'GET' -and $Path.StartsWith('/plugins/config')){return @{data=@{config=[pscustomobject]@{}}}}
    if($Method -eq 'PUT' -and $Path -eq '/plugins/config'){
        if($script:rejectWrite){return $null}
        $script:written[$Body.plugin_id]=$Body.config
    }
    return @{status='ok';data=@{}}
}
if(-not (Do-Plugins)){throw 'Plugin settings failed'}
$sing=$script:written['astrbot_plugin_dafeiyu_sing']
$pet=$script:written['astrbot_plugin_dafeiyu_petlink']
if($sing.backend -ne 'soulx' -or $sing.server_url -ne 'http://127.0.0.1:18620' -or $sing.doubao_tries -ne 3){throw 'Singing route was overwritten'}
if($sing.doubao_access_token -ne 'fixture-token'){throw 'Shared singing credentials not applied'}
if($pet.redirect_reminders -isnot [bool] -or $pet.redirect_reminders -ne $false -or $pet.recent_count -ne 6){throw 'Pet settings lost their types'}
'PASS: self-setup preserves SoulX route, applies shared credentials, preserves boolean/numeric pet settings'
$script:rejectWrite=$true
if(Do-Plugins){throw 'Rejected backend writes must fail the operation'}
'PASS: rejected backend writes are reported as failures'
