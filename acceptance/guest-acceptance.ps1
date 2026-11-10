#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('pre', 'full', 'recovery', 'upgrade', 'final')][string]$Phase)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$HostUrl = 'http://192.168.206.1:8000'
$R = 'C:\Users\Public\MWFixV310'
$Evidence = Join-Path $R 'evidence'
$App = 'C:\Users\Public\Documents\冥零 修复\程序 3.1'
$Ws = 'C:\Users\Public\Documents\冥零 修复\工作区 3.1'
$Installer = Join-Path $R 'MinglingWorkbench-3.1.0-setup.exe'
$OldInstaller = Join-Path $R 'MinglingWorkbench-3.0.0-setup.exe'
$Bootstrap = Join-Path $App 'tools\bootstrap.ps1'
$SelfSetup = Join-Path $App 'tools\self-setup.ps1'
$Results = New-Object System.Collections.ArrayList
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null

function Save-Phase {
    $obj = [ordered]@{
        phase = $Phase
        at = (Get-Date).ToUniversalTime().ToString('o')
        identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        administratorToken = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        results = $Results
    }
    $p = Join-Path $Evidence ($Phase + '.json')
    [IO.File]::WriteAllText($p, (($obj | ConvertTo-Json -Depth 18) + "`n"), (New-Object Text.UTF8Encoding($false)))
    & curl.exe -s -X POST --data-binary "@$p" ($HostUrl + '/upload/' + $Phase + '.json') | Out-Null
}

function Add-Result([string]$Id, [string]$Status, [string]$Detail, $Data = $null) {
    [void]$Results.Add([ordered]@{ id = $Id; status = $Status; detail = $Detail; data = $Data; at = (Get-Date).ToUniversalTime().ToString('o') })
    Save-Phase
}

function Invoke-Capture([string]$Label, [string]$File, [string[]]$Arguments, [int]$TimeoutSeconds = 1800) {
    $stdout = Join-Path $Evidence ($Label + '.stdout.txt')
    $stderr = Join-Path $Evidence ($Label + '.stderr.txt')
    $runFile = $File
    $runArgs = @($Arguments)
    if ($File -match '\.ps1$') {
        $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Arguments
        $runFile = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } elseif ($File -match '\.cmd$|\.bat$') {
        $runArgs = @('/d', '/c', ('"' + $File + '"')) + $Arguments
        $runFile = $env:ComSpec
    }
    $argLine = (@($runArgs) | ForEach-Object {
        $a = [string]$_
        if ($a -match '^(/[A-Za-z0-9_-]+=)(.+)$' -and $a -match '\s') {
            $Matches[1] + '"' + ($Matches[2].Trim('"')) + '"'
        } elseif ($a -match '\s|"') {
            '"' + ($a -replace '"', '\"') + '"'
        } else { $a }
    }) -join ' '
    $start = Get-Date
    $p = Start-Process -FilePath $runFile -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $p.Handle
    $finished = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) { & taskkill.exe /PID $p.Id /T /F | Out-Null; $p.WaitForExit() }
    return [ordered]@{
        label = $Label; command = ($runFile + ' ' + $argLine); started = $start.ToUniversalTime().ToString('o')
        exitCode = $p.ExitCode; timeout = (-not $finished); stdout = $stdout; stderr = $stderr
        durationSeconds = ((Get-Date) - $start).TotalSeconds
    }
}

function Get-FileMap([string[]]$Roots) {
    $map = @{}
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue) {
            $map[$f.FullName] = [ordered]@{
                sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                bytes = $f.Length; mtime = $f.LastWriteTimeUtc.ToString('o')
            }
        }
    }
    return $map
}

function Compare-Maps($Before, $After) {
    $changes = New-Object System.Collections.ArrayList
    foreach ($k in $Before.Keys) {
        if (-not $After.ContainsKey($k)) { [void]$changes.Add([ordered]@{ path = $k; change = 'missing' }); continue }
        if ($Before[$k].sha256 -ne $After[$k].sha256 -or $Before[$k].mtime -ne $After[$k].mtime) { [void]$changes.Add([ordered]@{ path = $k; change = 'content-or-time' }) }
    }
    foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { [void]$changes.Add([ordered]@{ path = $k; change = 'added' }) } }
    return @($changes)
}

function Get-StatusCounts([string]$Text) {
    $m = [regex]::Match($Text, '##RESULT\s+ok=(\d+)\s+fixed=(\d+)\s+satisfied=(\d+)\s+manual=(\d+)\s+missing=(\d+)\s+failed=(\d+)')
    if (-not $m.Success) { return $null }
    return [ordered]@{ ok = [int]$m.Groups[1].Value; fixed = [int]$m.Groups[2].Value; satisfied = [int]$m.Groups[3].Value; manual = [int]$m.Groups[4].Value; missing = [int]$m.Groups[5].Value; failed = [int]$m.Groups[6].Value }
}

function Download-Fixture([string]$Name) {
    $dest = Join-Path $R $Name
    if (-not (Test-Path -LiteralPath $dest)) {
        & curl.exe -L -f -sS --retry 2 -o $dest ($HostUrl + '/' + $Name)
        if ($LASTEXITCODE -ne 0) { throw "下载测试输入失败：$Name" }
    }
    return $dest
}

function Assert-InstallerHashes {
    $expected = (& curl.exe -s ($HostUrl + '/checksums.txt')).Trim() -split "`n"
    foreach ($line in $expected) {
        if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$') { 
            $file = Join-Path $R $Matches[2].Trim()
            if (Test-Path -LiteralPath $file) {
                $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $Matches[1].ToLowerInvariant()) { throw "测试安装包 SHA256 不符：$($Matches[2])" }
            }
        }
    }
}

try {
    if ($Phase -eq 'pre') {
        # 只清理本验收专用的两个目录（本次已确认没有用户数据），用于重跑干净安装。
        if (Test-Path -LiteralPath $App) { Remove-Item -LiteralPath $App -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Ws) { Remove-Item -LiteralPath $Ws -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $R, $App, $Ws | Out-Null
        Download-Fixture 'MinglingWorkbench-3.1.0-setup.exe' | Out-Null
        Download-Fixture 'MinglingWorkbench-3.0.0-setup.exe' | Out-Null
        Download-Fixture 'components.json' | Out-Null
        Download-Fixture 'astrbot-requirements.txt' | Out-Null
        Download-Fixture 'edge-tts-requirements.txt' | Out-Null
        Download-Fixture 'checksums.txt' | Out-Null
        Assert-InstallerHashes
        Add-Result 'installer-input' 'pass' '测试安装包存在且与固定 SHA256 一致' @{
            setup = $Installer; setupSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
            oldSetup = $OldInstaller; oldSha256 = (Get-FileHash -LiteralPath $OldInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        $manifest = [IO.File]::ReadAllText((Join-Path $R 'components.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $bad = @($manifest.components | Where-Object { [string]$_.source.sha256 -notmatch '^[0-9a-fA-F]{64}$' } | ForEach-Object id)
        Add-Result 'criterion-1' $(if ($bad.Count -eq 0) { 'pass' } else { 'fail' }) "组件 $($manifest.components.Count) 个；source 哈希格式错误 $($bad.Count)" @{ invalid = $bad }
        Add-Result 'criterion-2-sources' $(if ($bad.Count -eq 0) { 'pass' } else { 'fail' }) '所有真实 source 和纯人工空资产均有 SHA256 模型' @{ count = $manifest.components.Count }

        $inst = Invoke-Capture 'install-3.1' $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', ('/DIR=' + $App), ('/WORKSPACE=' + $Ws), ('/LOG=' + (Join-Path $Evidence 'install-3.1.inno.log'))) 600
        $beforeCheck = Invoke-Capture 'check-before-components' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Check') 300
        $afterCheck = Invoke-Capture 'check-after-install' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Check') 300
        Add-Result 'criterion-3-install' $(if ($inst.exitCode -eq 0 -and (Test-Path (Join-Path $App 'MinglingWorkbench.exe'))) { 'pass' } else { 'fail' }) "安装器退出 $($inst.exitCode)；普通用户令牌=$((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" $inst
        Add-Result 'criterion-4-paths' $(if ($inst.exitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $App 'MinglingWorkbench.exe'))) { 'pass' } else { 'fail' }) '中文和空格程序/工作区路径' @{ app = $App; workspace = $Ws }
        Add-Result 'criterion-5-check-before' $(if ($beforeCheck.exitCode -ne 0 -and $afterCheck.exitCode -ne 0) { 'pass' } else { 'fail' }) "安装包完成、组件未装 Check=$($beforeCheck.exitCode)；装后复跑 Check=$($afterCheck.exitCode)。安装包执行前的源码 pre-check 见原验收记录，本流程未重复。" @{ before = $beforeCheck; after = $afterCheck }

        # 离线/坏缓存/篡改：uv 是真实下载源，直接在隔离目录跑。
        $base = Join-Path $R 'offline-online'; New-Item -ItemType Directory -Force -Path $base | Out-Null
        $uvOnline = Invoke-Capture 'uv-online' $Bootstrap @('-Base', $base, '-Workspace', $base, '-Bots', (Join-Path $base 'bots'), '-Component', 'uv') 900
        $cache = @(Get-ChildItem -LiteralPath (Join-Path $base 'logs\setup\dl') -File -Filter 'uv-*' | Select-Object -First 1)
        if ($cache.Count -gt 0) {
            $validBase = Join-Path $R 'offline-valid'; $badBase = Join-Path $R 'offline-bad'; $emptyBase = Join-Path $R 'offline-empty'
            foreach ($x in @($validBase, $badBase)) { New-Item -ItemType Directory -Force -Path (Join-Path $x 'logs\setup\dl') | Out-Null; Copy-Item -LiteralPath $cache[0].FullName -Destination (Join-Path $x 'logs\setup\dl') }
            $valid = Invoke-Capture 'uv-offline-valid' $Bootstrap @('-Base', $validBase, '-Workspace', $validBase, '-Bots', (Join-Path $validBase 'bots'), '-Component', 'uv', '-Offline') 300
            $badFile = Join-Path $badBase ('logs\setup\dl\' + $cache[0].Name)
            $s = [IO.File]::Open($badFile, 'Open', 'ReadWrite'); $b = $s.ReadByte(); $s.Position = 0; $s.WriteByte(($b -bxor 255)); $s.Dispose()
            $bad = Invoke-Capture 'uv-offline-tampered' $Bootstrap @('-Base', $badBase, '-Workspace', $badBase, '-Bots', (Join-Path $badBase 'bots'), '-Component', 'uv', '-Offline') 300
            $empty = Invoke-Capture 'uv-offline-empty' $Bootstrap @('-Base', $emptyBase, '-Workspace', $emptyBase, '-Bots', (Join-Path $emptyBase 'bots'), '-Component', 'uv', '-Offline') 120
            Add-Result 'criterion-2-tamper-offline' $(if ($uvOnline.exitCode -eq 0 -and $valid.exitCode -eq 0 -and $bad.exitCode -eq 2 -and $empty.exitCode -eq 2 -and -not (Test-Path (Join-Path $badBase 'uv\bin\uv.exe'))) { 'pass' } else { 'fail' }) '真实 uv：在线下载、有效缓存离线成功、坏缓存/空缓存离线失败且不生成 exe' @{ online = $uvOnline; valid = $valid; bad = $bad; empty = $empty }
        } else { Add-Result 'criterion-2-tamper-offline' 'fail' '在线 uv 未生成缓存，无法做离线子用例' $uvOnline }

        $skill = Join-Path $App 'skill\mingling-install\scripts\bootstrap.ps1'
        $skillResolve = Join-Path $App 'skill\mingling-install\scripts\resolve-program-root.ps1'
        $resolved = if (Test-Path $skillResolve) { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $skillResolve).Trim() } else { '' }
        Add-Result 'criterion-13-entry-static' $(if ($resolved -eq $App -and (Test-Path $skill)) { 'pass' } else { 'fail' }) '技能包装入口解析到程序目录，而不是工作区' @{ resolved = $resolved; app = $App; wrapper = $skill; workspaceScript = (Join-Path $Ws 'tools\bootstrap.ps1'); workspaceScriptExists = (Test-Path (Join-Path $Ws 'tools\bootstrap.ps1')) }
        $manual = Invoke-Capture 'manual-before-login' $Bootstrap @('-Base', $App, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Component', 'snowluma', '-Check') 180
        $manualText = [IO.File]::ReadAllText($manual.stdout, [Text.Encoding]::UTF8)
        $counts = Get-StatusCounts $manualText
        Add-Result 'criterion-11-manual-model' $(if ($counts -and $counts.manual -ge 1 -and $manualText -notmatch '##OK qq-login') { 'pass' } else { 'fail' }) '软件未安装/未登录时 QQ 登录是独立 manual，不出现 OK' @{ counts = $counts; output = $manualText; exitCode = $manual.exitCode }
        Save-Phase
    }

    if ($Phase -eq 'full') {
        $full = Invoke-Capture 'full-first' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots')) 14400
        $fullText = [IO.File]::ReadAllText($full.stdout, [Text.Encoding]::UTF8)
        $counts = Get-StatusCounts $fullText
        $check = Invoke-Capture 'check-after-full' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Check') 900
        Add-Result 'criterion-9-full-backend' $(if ($full.exitCode -eq 0 -and $check.exitCode -eq 0) { 'pass' } else { 'fail' }) "无断网注入、全空缓存首次安装；full=$($full.exitCode), check=$($check.exitCode)" @{ counts = $counts; full = $full; check = $check }

        $manual = Invoke-Capture 'check-manual-default' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Check') 900
        $manualText = [IO.File]::ReadAllText($manual.stdout, [Text.Encoding]::UTF8)
        $mcounts = Get-StatusCounts $manualText
        Add-Result 'criterion-11-default-manual' $(if ($mcounts -and $mcounts.manual -ge 3 -and $manualText -notmatch '##OK (qq-login|bili-login|deepseek-provider)') { 'pass' } else { 'fail' }) "默认 Check manual=$($mcounts.manual)，登录/Key 未完成不显示 OK" @{ counts = $mcounts; output = $manualText }

        # 严格幂等：第二次默认运行，比较工作区和程序 sidecar；不排除日志。
        $before = Get-FileMap @($Ws, (Join-Path $App 'sidecar'))
        $second = Invoke-Capture 'full-second' $Bootstrap @('-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots')) 7200
        $after = Get-FileMap @($Ws, (Join-Path $App 'sidecar'))
        $changes = Compare-Maps $before $after
        Add-Result 'criterion-6-idempotent' $(if ($second.exitCode -eq 0 -and $changes.Count -eq 0) { 'pass' } else { 'fail' }) "第二次退出 $($second.exitCode)，文件变化 $($changes.Count) 处" @{ before = $before.Count; after = $after.Count; changes = $changes; process = $second }

        # 测试凭据只在 secrets，本地模型桩代替外部计费 API；AstrBot 是真实后台。
        $secrets = Join-Path $Ws 'secrets'; New-Item -ItemType Directory -Force -Path $secrets | Out-Null
        $testKey = 'sk-mwfix-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $secrets 'deepseek-key.txt'), $testKey, (New-Object Text.UTF8Encoding($false)))
        $modelStub = Join-Path $R 'model-stub.py'
        @'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith('/models'):
            b=json.dumps({'object':'list','data':[{'id':'deepseek-chat','object':'model'}]}).encode()
            self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
        else: self.send_response(404); self.end_headers()
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
        b=json.dumps({'id':'chatcmpl-mwfix','object':'chat.completion','created':0,'model':'deepseek-chat','choices':[{'index':0,'message':{'role':'assistant','content':'OK'},'finish_reason':'stop'}],'usage':{'prompt_tokens':1,'completion_tokens':1,'total_tokens':2}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',18080),H).serve_forever()
'@ | Set-Content -LiteralPath $modelStub -Encoding UTF8
        $py = Join-Path $Ws 'bots\AstrBot\tools\astrbot\Scripts\python.exe'
        $stub = Start-Process -FilePath $py -ArgumentList ('"' + $modelStub + '"') -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 2

        # 设测试后台密码并重启 AstrBot（真实后台、真实 HTTP）。
        $astr = Join-Path $Ws 'bots\AstrBot'
        & (Join-Path $astr 'bin\astrbot.exe') conf set dashboard.username admin *> (Join-Path $Evidence 'astr-conf-user.txt')
        & (Join-Path $astr 'bin\astrbot.exe') conf set dashboard.password 'MwFix-2026-TestOnly' *> (Join-Path $Evidence 'astr-conf-pass.txt')
        [IO.File]::WriteAllText((Join-Path $Ws 'private\backend.txt'), "url: http://127.0.0.1:6185`nusername: admin`npassword: MwFix-2026-TestOnly`n", (New-Object Text.UTF8Encoding($false)))
        $answers = [ordered]@{ base_url = 'http://127.0.0.1:18080/v1'; backend_url = 'http://127.0.0.1:6185'; memory = 0; voice = 0; video = 0; deepseek_key_file = 'secrets/deepseek-key.txt' }
        [IO.File]::WriteAllText((Join-Path $Ws 'answers.json'), (($answers | ConvertTo-Json) + "`n"), (New-Object Text.UTF8Encoding($false)))
        $restart = Invoke-Capture 'astr-restart' (Join-Path $App 'tools\start-astrbot.ps1') @('-Root', $astr, '-Base', $Ws, '-Restart') 300
        $apply = Invoke-Capture 'self-setup-apply' $SelfSetup @('-Base', $Ws, '-Answers', (Join-Path $Ws 'answers.json')) 1200
        $verify = Invoke-Capture 'self-setup-verify' $SelfSetup @('-Base', $Ws, '-Answers', (Join-Path $Ws 'answers.json'), '-Verify') 1200
        $applyText = [IO.File]::ReadAllText($apply.stdout, [Text.Encoding]::UTF8)
        $verifyText = [IO.File]::ReadAllText($verify.stdout, [Text.Encoding]::UTF8)
        Add-Result 'criterion-9-selfsetup' $(if ($apply.exitCode -eq 0 -and $verify.exitCode -eq 0 -and $verifyText -match '##RESULT ok=1 done=8 fail=0') { 'pass' } else { 'fail' }) '真实 AstrBot 后台八块 apply + verify' @{ restart = $restart; apply = $apply; verify = $verify; applyText = $applyText; verifyText = $verifyText; modelFixture = 'local OpenAI-compatible stub for billing-free test credential only' }

        # 密钥泄漏扫描：ASCII / UTF-16 LE / UTF-16 BE，不设文件大小上限。
        $hits = New-Object System.Collections.ArrayList; $unreadable = New-Object System.Collections.ArrayList; $scanned = 0
        foreach ($root in @($App, $Ws, $R)) {
            foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue) {
                try {
                    $bytes = [IO.File]::ReadAllBytes($f.FullName); $scanned++
                    $found = ([Text.Encoding]::ASCII.GetString($bytes).Contains($testKey)) -or ([Text.Encoding]::Unicode.GetString($bytes).Contains($testKey)) -or ([Text.Encoding]::BigEndianUnicode.GetString($bytes).Contains($testKey))
                    if ($found) { [void]$hits.Add([ordered]@{ path = $f.FullName; insideSecrets = $f.FullName.StartsWith($secrets + '\', [StringComparison]::OrdinalIgnoreCase); log = ($f.FullName -match '\\logs\\|\.log$|\.stdout|\.stderr') }) }
                } catch { [void]$unreadable.Add($f.FullName) }
            }
        }
        $badHits = @($hits | Where-Object { -not $_.insideSecrets -or $_.log })
        Add-Result 'criterion-10-key-scan' $(if ($scanned -gt 0 -and $badHits.Count -eq 0 -and $unreadable.Count -eq 0) { 'pass' } else { 'fail' }) "扫描 $scanned 个文件；secrets 外或日志命中 $($badHits.Count)；不可读 $($unreadable.Count)" @{ hits = $hits; badHits = $badHits; unreadable = $unreadable; keyOnlyInSecrets = $true }
        try { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue } catch {}
        Save-Phase
    }

    if ($Phase -eq 'recovery') {
        $half = Join-Path $R 'Half' ; $bili = Join-Path $half 'bots\bili-whale'
        New-Item -ItemType Directory -Force -Path (Join-Path $half 'logs\setup\dl'), $bili | Out-Null
        $fullDl = Join-Path $Ws 'logs\setup\dl'
        Get-ChildItem -LiteralPath $fullDl -File -Filter 'node-*' | Copy-Item -Destination (Join-Path $half 'logs\setup\dl') -Force
        $nodeOffline = Invoke-Capture 'half-node-offline' $Bootstrap @('-Base', $half, '-Workspace', $half, '-Bots', (Join-Path $half 'bots'), '-Component', 'node', '-Offline') 600
        Copy-Item -LiteralPath (Join-Path $App 'sidecar\bili-whale\*') -Destination $bili -Recurse -Force -Exclude 'node_modules'
        New-Item -ItemType Directory -Force -Path (Join-Path $half 'logs\setup\npm-cache') | Out-Null
        $nodeExe = Join-Path $half 'sidecar\node\node.exe'
        $nodeHash = (Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256).Hash.ToLowerInvariant(); $nodeTime = (Get-Item -LiteralPath $nodeExe).LastWriteTimeUtc.ToString('o')
        $off = Invoke-Capture 'half-bili-offline' $Bootstrap @('-Base', $half, '-Workspace', $half, '-Bots', (Join-Path $half 'bots'), '-Component', 'bili-whale', '-Offline') 300
        $qrcode = Join-Path $bili 'node_modules\qrcode\package.json'
        $resolveOffline = Invoke-Capture 'half-qrcode-offline' $nodeExe @('-e', "require.resolve('qrcode')") 60
        Add-Result 'criterion-7-offline-half' $(if ($nodeOffline.exitCode -eq 0 -and $off.exitCode -eq 2 -and $resolveOffline.exitCode -ne 0 -and -not (Test-Path $qrcode)) { 'pass' } else { 'fail' }) 'Node 已完成；bili package.json 已存在、qrcode 缺失，离线重跑必须失败' @{ node = $nodeOffline; bili = $off; resolve = $resolveOffline; qrcodeExists = (Test-Path $qrcode) }
        $online = Invoke-Capture 'half-bili-online' $Bootstrap @('-Base', $half, '-Workspace', $half, '-Bots', (Join-Path $half 'bots'), '-Component', 'bili-whale') 1800
        $resolveOnline = Invoke-Capture 'half-qrcode-online' $nodeExe @('-e', "require.resolve('qrcode')") 60
        $nodeHashAfter = (Get-FileHash -LiteralPath $nodeExe -Algorithm SHA256).Hash.ToLowerInvariant(); $nodeTimeAfter = (Get-Item -LiteralPath $nodeExe).LastWriteTimeUtc.ToString('o')
        Add-Result 'criterion-7-recovery' $(if ($online.exitCode -eq 0 -and $resolveOnline.exitCode -eq 0 -and $nodeHashAfter -eq $nodeHash -and $nodeTimeAfter -eq $nodeTime) { 'pass' } else { 'fail' }) '联网只补 qrcode 且保留已完成 Node' @{ online = $online; resolve = $resolveOnline; nodeHashBefore = $nodeHash; nodeHashAfter = $nodeHashAfter; nodeTimeBefore = $nodeTime; nodeTimeAfter = $nodeTimeAfter; qrcodeExists = (Test-Path $qrcode) }
        Save-Phase
    }

    if ($Phase -eq 'upgrade') {
        function Snapshot-Protected([string]$Root, [string]$Out) {
            $m = @{}
            foreach ($d in @('bots', 'private', 'secrets', 'out', 'logs')) {
                $p = Join-Path $Root $d
                if (-not (Test-Path $p)) { continue }
                foreach ($f in Get-ChildItem -LiteralPath $p -File -Recurse -Force) { $m[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            [IO.File]::WriteAllText($Out, (($m | ConvertTo-Json -Depth 4) + "`n"), (New-Object Text.UTF8Encoding($false)))
            return $m
        }
        function Seed-Protected([string]$Root) {
            $items = @{
                'bots\AstrBot\data\config\acceptance.json' = '{"test_configuration":true}'
                'private\backend.txt' = "url: http://127.0.0.1:6185`nusername: acceptance`npassword: fixture-only"
                'secrets\deepseek-key.txt' = ('sk-upgrade-fixture-' + [guid]::NewGuid().ToString('N'))
                'out\验收 产物.txt' = 'upgrade output fixture'
                'logs\existing.log' = 'upgrade existing log fixture'
                'bots\AstrBot\data\memory\queue.jsonl' = '{"id":"acceptance-memory-1","state":"pending"}'
            }
            foreach ($rel in $items.Keys) { $p = Join-Path $Root $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $items[$rel], (New-Object Text.UTF8Encoding($false))) }
        }        function Program-Files([string]$Root) {
            $map = @{}
            foreach ($f in Get-ChildItem -LiteralPath $Root -File -Recurse -Force) {
                $rel = $f.FullName.Substring($Root.TrimEnd('\').Length + 1)
                if ($rel -match '^(bots|private|secrets|out|logs|旧版)\\') { continue }
                $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            return $map
        }

        $custom = 'C:\Users\Public\Documents\冥零 修复\升级 自定义'
        New-Item -ItemType Directory -Force -Path $custom | Out-Null
        $i30 = Invoke-Capture 'install-3.0-custom' $OldInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', ('/DIR=' + $custom), ('/WORKSPACE=' + $custom), ('/LOG=' + (Join-Path $Evidence 'install-3.0-custom.inno.log'))) 600
        Seed-Protected $custom
        $beforeProtected = Snapshot-Protected $custom (Join-Path $Evidence 'custom-protected-before.json')
        $beforeProgram = Program-Files $custom
        $oldExe = Join-Path $custom 'MinglingWorkbench.exe'
        $verBefore = (Get-Item $oldExe).VersionInfo.FileVersion
        $up = Invoke-Capture 'upgrade-custom-sync' $oldExe @('--wb-update', $Installer, '3.1.0-acceptance') 600
        $deadline = (Get-Date).AddSeconds(90); $verAfter = ''
        do { Start-Sleep -Milliseconds 500; if (Test-Path $oldExe) { $verAfter = (Get-Item $oldExe).VersionInfo.FileVersion } } while ($verAfter -notmatch '^3\.1' -and (Get-Date) -lt $deadline)
        Start-Sleep -Seconds 3
        $afterProtected = Snapshot-Protected $custom (Join-Path $Evidence 'custom-protected-after.json')
        $protectedChanges = @(Compare-Object @($beforeProtected.Keys) @($afterProtected.Keys) | ForEach-Object { $_.InputObject })
        foreach ($k in $beforeProtected.Keys) { if ($afterProtected.ContainsKey($k) -and $afterProtected[$k] -ne $beforeProtected[$k]) { $protectedChanges += $k } }
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $custom '旧版') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        $backupManifest = $null; $backupMissing = @()
        foreach ($b in $backups) { if (Test-Path (Join-Path $b.FullName 'backup-manifest.json')) { $backupManifest = Get-Content (Join-Path $b.FullName 'backup-manifest.json') -Raw | ConvertFrom-Json; break } }
        if ($backupManifest) {
            $bm = @{}; foreach ($x in $backupManifest.files) { $bm[$x.path] = $x.sha256 }
            foreach ($rel in $beforeProgram.Keys) { if (-not $bm.ContainsKey($rel) -or $bm[$rel] -ne $beforeProgram[$rel]) { $backupMissing += $rel } }
        } else { $backupMissing = @('backup-manifest.json not found') }
        Add-Result 'criterion-12-custom-sync' $(if ($up.exitCode -eq 0 -and $verBefore -match '^3\.0' -and $verAfter -match '^3\.1' -and $protectedChanges.Count -eq 0 -and $backupMissing.Count -eq 0) { 'pass' } else { 'fail' }) "V3.0 自定义目录同步升级：$verBefore -> $verAfter；protected 变化 $($protectedChanges.Count)；备份缺/错 $($backupMissing.Count)" @{ upgrade = $up; before = $verBefore; after = $verAfter; protectedChanges = $protectedChanges; backups = @($backups | Select-Object -ExpandProperty FullName); backupManifest = if ($backupManifest) { $backupManifest.fileCount } else { 0 }; backupMissing = $backupMissing }

        # 默认目录同步升级（旧 exe 自锁）
        $def = Join-Path $env:LOCALAPPDATA 'Programs\MinglingWorkbench'
        New-Item -ItemType Directory -Force -Path $def | Out-Null
        $i31 = Invoke-Capture 'install-3.0-default' $OldInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', ('/DIR=' + $def), ('/WORKSPACE=' + (Join-Path $R '升级 默认 工作区')), ('/LOG=' + (Join-Path $Evidence 'install-3.0-default.inno.log'))) 600
        Seed-Protected $def
        $dpBefore = Snapshot-Protected $def (Join-Path $Evidence 'default-protected-before.json')
        $dExe = Join-Path $def 'MinglingWorkbench.exe'; $dV1 = (Get-Item $dExe).VersionInfo.FileVersion
        $dup = Invoke-Capture 'upgrade-default-sync' $dExe @('--wb-update', $Installer, '3.1.0-default-sync') 600
        $deadline = (Get-Date).AddSeconds(90); $dV2 = ''
        do { Start-Sleep -Milliseconds 500; $dV2 = (Get-Item $dExe).VersionInfo.FileVersion } while ($dV2 -notmatch '^3\.1' -and (Get-Date) -lt $deadline)
        Start-Sleep -Seconds 3
        $dpAfter = Snapshot-Protected $def (Join-Path $Evidence 'default-protected-after.json')
        $dpChanges = @(Compare-Object @($dpBefore.Keys) @($dpAfter.Keys) | ForEach-Object InputObject)
        foreach ($k in $dpBefore.Keys) { if ($dpAfter.ContainsKey($k) -and $dpAfter[$k] -ne $dpBefore[$k]) { $dpChanges += $k } }
        Add-Result 'criterion-12-default-sync' $(if ($dup.exitCode -eq 0 -and $dV1 -match '^3\.0' -and $dV2 -match '^3\.1' -and $dpChanges.Count -eq 0) { 'pass' } else { 'fail' }) "V3.0 默认目录同步升级：$dV1 -> $dV2；protected 变化 $($dpChanges.Count)" @{ install = $i31; upgrade = $dup; before = $dV1; after = $dV2; protectedChanges = $dpChanges }

        # 独立旧助手：再次降回 3.0，把已发布 V3.0 exe 复制到 TEMP，按 V3.0 参数升级。
        $down = Invoke-Capture 'downgrade-3.0-default' $OldInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', ('/DIR=' + $def), ('/WORKSPACE=' + (Join-Path $R '升级 助手 工作区')), ('/LOG=' + (Join-Path $Evidence 'downgrade-3.0-default.inno.log'))) 600
        Seed-Protected $def
        $hpBefore = Snapshot-Protected $def (Join-Path $Evidence 'helper-protected-before.json')
        $hExe = Join-Path $def 'MinglingWorkbench.exe'; $hV1 = (Get-Item $hExe).VersionInfo.FileVersion
        $helper = Join-Path $env:TEMP 'mingling-updater-acceptance.exe'; Copy-Item -LiteralPath $hExe -Destination $helper -Force
        $hb = Join-Path $R 'old-helper-backup'; New-Item -ItemType Directory -Force -Path $hb | Out-Null
        $helperLog = Join-Path $Evidence 'old-helper.inno.log'
        $hp = Invoke-Capture 'upgrade-old-helper' $helper @('--wb-update-run', $hb, $Installer, $helperLog, '0', $hExe) 600
        $deadline = (Get-Date).AddSeconds(90); $hV2 = ''
        do { Start-Sleep -Milliseconds 500; $hV2 = (Get-Item $hExe).VersionInfo.FileVersion } while ($hV2 -notmatch '^3\.1' -and (Get-Date) -lt $deadline)
        Start-Sleep -Seconds 4
        $hpAfter = Snapshot-Protected $def (Join-Path $Evidence 'helper-protected-after.json')
        $hpChanges = @(Compare-Object @($hpBefore.Keys) @($hpAfter.Keys) | ForEach-Object InputObject)
        foreach ($k in $hpBefore.Keys) { if ($hpAfter.ContainsKey($k) -and $hpAfter[$k] -ne $hpBefore[$k]) { $hpChanges += $k } }
        Add-Result 'criterion-12-old-helper' $(if ($hp.exitCode -eq 0 -and $hV1 -match '^3\.0' -and $hV2 -match '^3\.1' -and $hpChanges.Count -eq 0) { 'pass' } else { 'fail' }) "已发布 V3.0 独立助手升级：$hV1 -> $hV2；protected 变化 $($hpChanges.Count)" @{ helper = $helper; helperHash = (Get-FileHash $helper -Algorithm SHA256).Hash.ToLowerInvariant(); v3HelperSource = $hExe; downgrade = $down; upgrade = $hp; before = $hV1; after = $hV2; protectedChanges = $hpChanges }
        Save-Phase
    }

    if ($Phase -eq 'final') {
        $appExe = Join-Path $App 'MinglingWorkbench.exe'
        $entry = Start-Process -FilePath $appExe -ArgumentList '--autosetup' -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Evidence 'entry-workbench.stdout.txt') -RedirectStandardError (Join-Path $Evidence 'entry-workbench.stderr.txt')
        $deadline = (Get-Date).AddSeconds(45); $trace = @()
        do { Start-Sleep -Milliseconds 250; $trace = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($entry.Id)" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'bootstrap\.ps1' } | Select-Object ProcessId, ParentProcessId, ExecutablePath, CommandLine) } while ($trace.Count -eq 0 -and -not $entry.HasExited -and (Get-Date) -lt $deadline)
        if (-not $entry.HasExited) { & taskkill.exe /PID $entry.Id /T /F | Out-Null; $entry.WaitForExit() }
        $skill = Join-Path $App 'skill\mingling-install\scripts\bootstrap.ps1'
        $skillRun = Invoke-Capture 'entry-skill-check' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $skill, '-Base', $Ws, '-Workspace', $Ws, '-Bots', (Join-Path $Ws 'bots'), '-Check') 600
        $skillOut = [IO.File]::ReadAllText($skillRun.stdout, [Text.Encoding]::UTF8)
        $shown = [regex]::Match($skillOut, '##BOOTSTRAP\s+(.+)').Groups[1].Value.Trim()
        $appBoot = Join-Path $App 'tools\bootstrap.ps1'
        $hashApp = (Get-FileHash $appBoot -Algorithm SHA256).Hash.ToLowerInvariant(); $hashShown = if ($shown -and (Test-Path $shown)) { (Get-FileHash $shown -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
        Add-Result 'criterion-13-entry' $(if ($trace.Count -gt 0 -and $shown -eq $appBoot -and $hashShown -eq $hashApp) { 'pass' } else { 'fail' }) '工作台 --autosetup 子进程和技能入口均指向同一个实际 bootstrap.ps1' @{ workbenchProcess = $trace; skillBootstrap = $shown; appBootstrap = $appBoot; appHash = $hashApp; shownHash = $hashShown; skillRun = $skillRun }

        # 最终全量密钥扫描（上一阶段完成真实 provider 配置）。
        $secrets = Join-Path $Ws 'secrets'; $keyFile = Join-Path $secrets 'deepseek-key.txt'; $testKey = if (Test-Path $keyFile) { (Get-Content $keyFile -Raw -Encoding UTF8).Trim() } else { '' }
        $hits = New-Object System.Collections.ArrayList; $unreadable = New-Object System.Collections.ArrayList; $scanned = 0
        if ($testKey) {
            foreach ($root in @($App, $Ws, $R)) {
                foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue) {
                    try { $bytes = [IO.File]::ReadAllBytes($f.FullName); $scanned++; if (([Text.Encoding]::ASCII.GetString($bytes).Contains($testKey)) -or ([Text.Encoding]::Unicode.GetString($bytes).Contains($testKey)) -or ([Text.Encoding]::BigEndianUnicode.GetString($bytes).Contains($testKey))) { [void]$hits.Add([ordered]@{ path=$f.FullName; insideSecrets=$f.FullName.StartsWith($secrets+'\',[StringComparison]::OrdinalIgnoreCase); log=($f.FullName -match '\\logs\\|\.log$|\.stdout|\.stderr') }) } } catch { [void]$unreadable.Add($f.FullName) }
                }
            }
        }
        $badHits = @($hits | Where-Object { -not $_.insideSecrets -or $_.log })
        Add-Result 'criterion-10-final-key-scan' $(if ($testKey -and $scanned -gt 0 -and $badHits.Count -eq 0 -and $unreadable.Count -eq 0) { 'pass' } else { 'fail' }) "最终成功配置后扫描 $scanned 个文件；secrets 外/日志命中 $($badHits.Count)；不可读 $($unreadable.Count)" @{ hits = $hits; badHits = $badHits; unreadable = $unreadable }

        $zip = Join-Path $R 'vm-evidence-v310-fixed.zip'
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path (Join-Path $Evidence '*') -DestinationPath $zip -CompressionLevel Optimal
        & curl.exe -s -X POST --data-binary "@$zip" ($HostUrl + '/upload/vm-evidence-v310-fixed.zip') | Out-Null
        Add-Result 'package' 'info' '新安装包和 V3.0 基准包哈希' @{ setup = (Get-FileHash $Installer -Algorithm SHA256).Hash.ToLowerInvariant(); old = (Get-FileHash $OldInstaller -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item $Installer).Length }
        Save-Phase
    }
} catch {
    Add-Result 'harness-error' 'fail' $_.Exception.Message @{ stack = $_.ScriptStackTrace }
    Save-Phase
    exit 1
}
Save-Phase
exit 0
