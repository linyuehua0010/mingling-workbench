; 冥零工作台 v2 安装脚本（Inno Setup 6）
; 编译：installer\build-installer.bat  →  dist\MinglingWorkbench-<版本>-setup.exe
; 版本号来自 win32\src\version.h（build-installer.bat 每次重新生成 version_auto.iss）
#include "version_auto.iss"
#define AppExe "MinglingWorkbench.exe"

; ── 可选：把 QQ 登录端的官方原版包一起打进安装包 ──────────────────────────────
; 默认不内置（BundleLogin=0），装完由 bootstrap.ps1 联网下载，和以前一样。
; 想出内置版就 build-installer.bat -BundleLogin；那份片段由
; installer\prepare-login.ps1 生成（会先从 tools\components.json 抄校验值，
; 再确认本地那份 zip 的 SHA256，对不上就拒绝出包）。
; 为什么不做成默认：上游许可协议第 5.4 条把「并入第三方安装包」列为须事先取得
; 书面授权的行为，所以这条通道必须由出包的人逐个明确开启，并自负授权责任。
#if FileExists(AddBackslash(SourcePath) + "login_auto.iss")
  #include "login_auto.iss"
#endif
#ifndef BundleLogin
  #define BundleLogin 0
#endif
; 内置版的产物换个文件名：不然它和官方正式包同名，跑一次 -BundleLogin 就会
; 把 dist\ 里那份要发出去的 88 MB 正式包悄悄覆盖掉（只差几十 MB，很难看出来）。
#if BundleLogin
  #define OutSuffix "-login"
#else
  #define OutSuffix ""
#endif

; ── 通道分流：正式版和快照版必须能同装一台机器、互不覆盖 ──────────────────────
; 决定权在 version.h 的 APP_SNAPSHOT（build-installer.bat 抄进 version_auto.iss）。
; 快照版换掉 AppId、安装目录、卸载项、快捷方式和设置目录，其余内容完全一样。
#ifndef AppSnapshot
  #define AppSnapshot 0
#endif

#if AppSnapshot
  #define AppIdValue "{{4F0C7D93-2A61-4B8E-9D35-6E1A8B2C4F70}"
  #define AppTitle "冥零工作台（快照）"
  #define AppDir "MinglingWorkbench-snapshot"
  #define AppUninstKey "MinglingWorkbench_snapshot_is1"
  #define AppStateSub "snapshot"
  #define AppOutSuffix "-snapshot"
#else
  #define AppIdValue "{{8E1B7C42-5D3A-4F0E-9C21-7B6A1D3E5F80}"
  #define AppTitle "冥零工作台"
  #define AppDir "MinglingWorkbench"
  #define AppUninstKey "MinglingWorkbench_is1"
  #define AppStateSub ""
  #define AppOutSuffix ""
#endif

[Setup]
AppId={#AppIdValue}
AppName={#AppTitle}
; 显示版本用完整串（V3-snapshot-2）：「应用和功能」那一列直接读它
AppVersion={#AppVerTag}
AppVerName={#AppTitle} {#AppVerTag}
; 文件版本必须是四段数字（资源管理器 → 属性 → 详细信息）
VersionInfoVersion={#AppVer}
VersionInfoProductVersion={#AppVer}
VersionInfoProductTextVersion={#AppVerTag}
VersionInfoCompany=冥零工作台
VersionInfoDescription={#AppTitle} 安装程序
AppPublisher=冥零工作台
DefaultDirName={code:DefaultInstallDir}
DefaultGroupName={#AppTitle}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\dist
OutputBaseFilename=MinglingWorkbench-{#AppVerShort}-setup{#OutSuffix}
SetupIconFile=..\win32\res\app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppTitle}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\docs\THIRD-PARTY.md
ShowLanguageDialog=no
AllowNoIcons=yes
CreateUninstallRegKey=no

[Languages]
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Dirs]
; 密钥目录：和工作区同级（默认 <Base>\secrets），在 {app} 之外，卸载不删

[Files]
Source: "..\bin\WebView2Loader.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\win32\vendor\webview2\LICENSE.txt"; DestDir: "{app}\docs\webview2"; Flags: ignoreversion
Source: "..\win32\vendor\webview2\NOTICE.txt"; DestDir: "{app}\docs\webview2"; Flags: ignoreversion
Source: "..\bin\{#AppExe}"; DestDir: "{app}"; DestName: "MinglingWorkbench.new.exe"; Flags: ignoreversion
Source: "..\tools\backup-install.ps1"; Flags: dontcopy
Source: "..\tools\finish-update.ps1"; Flags: dontcopy
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\art\*"; DestDir: "{app}\art"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\plugin\astrbot_plugin_bili_bridge\*"; DestDir: "{app}\plugin\astrbot_plugin_bili_bridge"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\sidecar\*"; DestDir: "{app}\sidecar"; Flags: ignoreversion recursesubdirs createallsubdirs
; 安装 Skill（冥零自己的那份）：装在 {app}\skill 下，工作台第一次启动时铺到
; %USERPROFILE%\.agents\skills\mingling-install，并写下 tools\skill-home.txt / skill-version.json。
; 没有它，Agent 就只会照大肥鱼那份说明书干活。
Source: "..\skill\mingling-install\*"; DestDir: "{app}\skill\mingling-install"; Flags: ignoreversion recursesubdirs createallsubdirs
; 人设注入用的清单和人设正文（导入冥零人设要读 plugin\mingling_skill\mingling_skill.json）
Source: "..\plugin\mingling_skill\*"; DestDir: "{app}\plugin\mingling_skill"; Flags: ignoreversion recursesubdirs createallsubdirs
; 工作台跑活要用的脚本：自设定（self-setup）、一键自动配置、体检、备份、掉线提醒、人设导入、桌宠
Source: "..\tools\*.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\*.py"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\*.cmd"; DestDir: "{app}\tools"; Flags: ignoreversion
; tools\*.txt 是运行时生成的（skill-home.txt 等），源码树里可能没有；没有就跳过，不能因此拒绝出包
Source: "..\tools\*.txt"; DestDir: "{app}\tools"; Flags: ignoreversion skipifsourcedoesntexist; Excludes: "skill-home.txt,pet-name-mine.txt,pet-persona-mine.txt"
; 组件清单：bootstrap.ps1 按 components.json 决定装什么、怎么验。上面只带 *.ps1/*.py/*.cmd/*.txt，
; 漏了这份 json，「一键自动配置」就不知道该装哪几样。
Source: "..\tools\components.json"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\astrbot-requirements.txt"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\edge-tts-requirements.txt"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\tools\source-manifests\*.json"; DestDir: "{app}\tools\source-manifests"; Flags: ignoreversion
; 掉线提醒用的那个 pythonw（工作台按 tools\python\pythonw.exe 找）；全量包不带这个目录时跳过
Source: "..\tools\python\*"; DestDir: "{app}\tools\python"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
; 配置包：自设定读 pack\mingling-pack\pack.json（tools\self-setup.ps1 按 <根>\pack\ 找）
Source: "..\pack\mingling-pack\*"; DestDir: "{app}\pack\mingling-pack"; Flags: ignoreversion recursesubdirs createallsubdirs
; 全依赖哈希锁里唯一没有 PyPI wheel 的 aiocqhttp，由固定 sdist（锁里有源码哈希）构建为 wheel，安装时只读这个本地经校验文件。
Source: "..\pack\mingling-vendor\*"; DestDir: "{app}\pack\mingling-vendor"; Flags: ignoreversion recursesubdirs createallsubdirs
; 密钥目录里放一份说明；已经有的不覆盖（用户的密钥在同一个文件夹里）

; ── 内置的 QQ 登录端原版包（只在 -BundleLogin 出包时有） ────────────────────
; 落到 {app}\pack\login\ 之后，装完的 bootstrap.ps1 -Check / 一键自动配置会先看
; 这里有没有校验通过的那份，有就直接解压，不再联网下载（tools\bootstrap.ps1 的
; Find-BundledPackage，按目录 pack\<组件id> 找）。文件是上游发布的原版 zip，
; 一个字节都没改，只落了中性文件名。
#if BundleLogin
Source: "{#LoginZip}"; DestDir: "{app}\pack\login"; Flags: ignoreversion
#endif

[Icons]
Name: "{group}\{#AppTitle}"; Filename: "{app}\{#AppExe}"
Name: "{group}\使用说明"; Filename: "{app}\docs\使用说明.md"
Name: "{group}\她会做的事"; Filename: "{app}\docs\她会做的事.md"
Name: "{group}\B 站部署教程"; Filename: "{app}\docs\deploy-bili.md"
Name: "{group}\QQ 机器人部署教程"; Filename: "{app}\docs\deploy-qq.md"
Name: "{group}\自动配置与组件清单"; Filename: "{app}\docs\setup-automation.md"
Name: "{group}\项目总览"; Filename: "{app}\docs\项目总览.md"
Name: "{group}\卸载 {#AppTitle}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppTitle}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; 旧版命令行 / 独立更新助手从“正在运行”的旧 exe 发起时，主程序文件被占用。
; 安装器只落 .new，等旧进程退出后由这个脚本做同目录原子替换；fresh/unlocked 安装同步等待。
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{tmp}\finish-update.ps1"" -AppDir ""{app}"" -WaitSeconds 180 -ManifestLog ""{tmp}\finish-update-last.log"""; Flags: runhidden waituntilterminated; Check: CanWriteMainExe
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{tmp}\finish-update.ps1"" -AppDir ""{app}"" -WaitSeconds 180 -ManifestLog ""{tmp}\finish-update-last.log"""; Flags: runhidden nowait; Check: not CanWriteMainExe
Filename: "{app}\{#AppExe}"; Description: "启动 {#AppTitle}"; Flags: nowait postinstall skipifsilent
; 装完做一次只检测的组件体检：不下载、不安装，缺什么写进日志。
; -Check 有缺项时退出码是 2；Inno 的 [Run] 默认忽略退出码，所以不会把安装判成失败。
; 工作区不一定是 {app}（用户可能选在别的盘），所以走 WorkspacePath 这个脚本常量。
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\bootstrap.ps1"" -Base ""{code:WorkspacePath}"" -Workspace ""{code:WorkspacePath}"" -Bots ""{code:WorkspacePath}\bots"" -Check -LogFile ""{app}\logs\setup\installer-check.log"""; StatusMsg: "正在检查组件（只检测，不下载）……"; Flags: runhidden waituntilterminated

[UninstallRun]

Filename: "{cmd}"; Parameters: "/c reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppUninstKey}"" /f >nul 2>&1"; Flags: runhidden


[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
var
  WsPage: TInputDirWizardPage;
  WsPath: String;
  DetectedDir: String;
  DetectedWorkspace: String;
  HadExistingApp: Boolean;

function DefaultInstallDir(Param: String): String;
var
  Existing: String;
begin
  if DetectedDir <> '' then
    Result := DetectedDir
  else if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\MinglingWorkbench_is1', 'InstallLocation', Existing)
    and (Existing <> '') and FileExists(AddBackslash(Existing) + '{#AppExe}') then
    Result := Existing
  else
    Result := ExpandConstant('{localappdata}\Programs\{#AppDir}');
end;

{ 旧版 V3.0 的 --wb-update 不传 /DIR /WORKSPACE：
  1) 从调用进程/旧更新助手的命令行找回原 exe 路径；
  2) 从 settings.json 读工作区；
  把结果放 HKCU 临时键，Inno 再以 Unicode 读回。这样中文路径不经过 ANSI 解码。 }
procedure DetectLegacyLayout;
var
  Code: Integer;
  Script: String;
begin
  DetectedDir := '';
  DetectedWorkspace := '';
  Script :=
    '$ErrorActionPreference=''SilentlyContinue'';' +
    '$q=Get-CimInstance Win32_Process -Filter (''ProcessId=''+$PID);' +
    '$c=Get-CimInstance Win32_Process -Filter (''ProcessId=''+$q.ParentProcessId);' +
    '$cand='''';' +
    'if($c.ExecutablePath -and ($c.ExecutablePath -match ''MinglingWorkbench\.exe$'')){$cand=$c.ExecutablePath};' +
    'if($c.CommandLine -match ''--wb-update-run''){$m=[regex]::Matches($c.CommandLine,''"([^"]*MinglingWorkbench\.exe)"'');if($m.Count){$cand=$m[$m.Count-1].Groups[1].Value}};' +
    'if(-not $cand){$p=Get-CimInstance Win32_Process -Filter "Name=''MinglingWorkbench.exe''" | Where-Object {$_.ExecutablePath -notmatch ''setup''} | Select-Object -First 1;if($p){$cand=$p.ExecutablePath}};' +
    '$dir='''';if($cand){$dir=Split-Path -Parent $cand};' +
    'New-Item -Path ''HKCU:\Software\MinglingWorkbench\Installer'' -Force | Out-Null;' +
    'Set-ItemProperty -Path ''HKCU:\Software\MinglingWorkbench\Installer'' -Name InstallLocation -Value $dir;' +
    '$ws='''';foreach($f in @((Join-Path $env:APPDATA ''MinglingWorkbench\settings.json''),(Join-Path $env:APPDATA ''MinglingWorkbench\snapshot\settings.json''))){if(Test-Path -LiteralPath $f){try{$j=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)|ConvertFrom-Json;if($j.workspace){$ws=[string]$j.workspace;break}}catch{}}};' +
    'if($ws -and -not (Test-Path -LiteralPath $ws -PathType Container)){$ws=''''};' +
    'Set-ItemProperty -Path ''HKCU:\Software\MinglingWorkbench\Installer'' -Name Workspace -Value $ws;';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Script + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
  RegQueryStringValue(HKCU, 'Software\MinglingWorkbench\Installer', 'InstallLocation', DetectedDir);
  RegQueryStringValue(HKCU, 'Software\MinglingWorkbench\Installer', 'Workspace', DetectedWorkspace);
end;

function CanWriteMainExe: Boolean;
var
  Code: Integer;
  Target: String;
  Cmd: String;
begin
  Target := ExpandConstant('{app}\{#AppExe}');
  if not FileExists(Target) then
  begin
    Result := True;
    Exit;
  end;
  { Inno 6.0 没有 FileOpen；用 PowerShell 以 FileShare.None 试开，运行中的 exe 会拒绝写。 }
  Cmd := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try{$s=[IO.File]::Open(''' +
         Target + ''',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$s.Dispose();exit 0}catch{exit 1}"';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Cmd, '', SW_HIDE,
          ewWaitUntilTerminated, Code) then
    Result := (Code = 0)
  else
    Result := False;
end;

{ [Run] 里那条 bootstrap -Check 要的是真工作区（可能在别的盘），不是安装目录。
  工作区在 InitializeSetup 里定好；万一没定（理论上不会），退回和安装器一样的默认值。 }
function WorkspacePath(Param: String): String;
begin
  if WsPath = '' then
    Result := ExpandConstant('{userdocs}\冥零工作台')
  else
    Result := WsPath;
end;

{ 设置目录：正式版 %APPDATA%\MinglingWorkbench，快照版再下一层 \snapshot。
  必须和 win32\src\paths.cpp 的 StateDir() 是同一句话，否则装完 exe 读不到安装器写的 settings.json。 }
function StateDirPath: String;
begin
  Result := ExpandConstant('{userappdata}\MinglingWorkbench');
  if '{#AppStateSub}' <> '' then
    Result := Result + '\' + '{#AppStateSub}';
end;

{ 目录名不能带 Windows 禁用字符（盘符那个冒号除外）。 }
function PathUsable(const s: String): Boolean;
begin
  Result := (Length(s) >= 3) and (s[2] = ':') and ((s[3] = '\') or (s[3] = '/'))
    and (Pos('"', s) = 0) and (Pos('*', s) = 0) and (Pos('?', s) = 0)
    and (Pos('<', s) = 0) and (Pos('>', s) = 0) and (Pos('|', s) = 0);
end;

{ 把一条路径收拾干净：去引号残留、\\ 还原成 \、/ 归成 \、去首尾空格。 }
function CleanPath(s: String): String;
var
  p: Integer;
begin
  p := Pos('"', s);
  if p > 0 then s := Copy(s, 1, p - 1);
  StringChangeEx(s, '\\', '\', False);
  StringChangeEx(s, '/', '\', True);
  Result := Trim(s);
end;

{ 为什么不在这里读工作台的 settings.json 猜工作区：
  那是 UTF-8 的 JSON，而 Inno 6.0 的脚本里没有可用的 UTF-8 解码（MultiByteToWideChar 是 6.1 才有的），
  中文路径会被按 ANSI 拆错字，解析出的路径带着尾巴，最后表现为
  「文件夹名不能包含下列任何字符: / : * ? " < > |」——静默安装直接失败，日志里还看不出为什么。
  现在的做法：安装器不去读它。已经有 settings.json 就一个字都不动，工作区交给工作台自己认；
  只有首次安装（没有 settings.json）时才写一份新的，用的是用户在向导里选的那条路径。 }

function InitializeSetup: Boolean;
begin
  DetectLegacyLayout;
  if (DetectedDir <> '') and (not PathUsable(DetectedDir)) then DetectedDir := '';
  if (DetectedWorkspace <> '') and (not PathUsable(DetectedWorkspace)) then DetectedWorkspace := '';
  WsPath := CleanPath(Trim(ExpandConstant('{param:WORKSPACE|}')));
  if not PathUsable(WsPath) then WsPath := '';
  if (WsPath = '') and (DetectedWorkspace <> '') then WsPath := CleanPath(DetectedWorkspace);
  if WsPath = '' then WsPath := ExpandConstant('{userdocs}\冥零工作台');
  Log('WsPath=[' + WsPath + ']');
  Result := True;
end;

{ 安装器不建 secrets 目录、也不放 README：工作台第一次启动时 EnsureSecrets() 会按自己的约定
  （<Base>\secrets，Base 从 settings.json 来）建好目录和 README。安装器在这里猜不出真正的 Base，
  猜错就会在「文档」下面凭空多一个 secrets 文件夹。 }

procedure InitializeWizard;
begin
  WsPage := CreateInputDirPage(wpSelectDir, '选择工作区',
    'B 站产物、台账和日志都放在工作区里。',
    '默认放在“文档”下的「冥零工作台」。已经装过的话这里选什么都不影响——已有的工作区会原样保留。',
    False, '');
  WsPage.Add('');
  WsPage.Values[0] := WsPath;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = WsPage.ID then
  begin
    WsPath := CleanPath(Trim(WsPage.Values[0]));
    if WsPath = '' then
    begin
      MsgBox('请选择一个工作区目录。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not PathUsable(WsPath) then
    begin
      MsgBox('工作区要写成完整路径，例如 D:\MinglingWorkbench。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not DirExists(WsPath) then
    begin
      if not ForceDirectories(WsPath) then
      begin
        MsgBox('无法创建目录：' + WsPath, mbError, MB_OK);
        Result := False;
        Exit;
      end;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  cfg, dir, js, b, w1, w2: String;
  ResultCode: Integer;
  Cmd: String;
begin
  if CurStep = ssInstall then
  begin
    HadExistingApp := FileExists(ExpandConstant('{app}\{#AppExe}'));
    { 在任何程序文件被覆盖前，先把本安装器会碰到的旧文件逐字节备份。
      备份脚本不进入 bots/private/secrets/out/logs，也不覆盖旧版备份。 }
    ExtractTemporaryFile('backup-install.ps1');
    ExtractTemporaryFile('finish-update.ps1');
    Cmd := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\backup-install.ps1') +
           '" -AppDir "' + ExpandConstant('{app}') + '" -Workspace "' + WorkspacePath('') + '" -Reason install';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Cmd, '', SW_HIDE,
                ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      RaiseException('覆盖前备份失败（退出码 ' + IntToStr(ResultCode) + '），安装已中止，旧程序没有被改动。');
  end;
  if CurStep = ssPostInstall then
  begin
    { 技能/助手解析程序根目录，不再把 <工作区>\tools\bootstrap.ps1 当成程序入口。 }
    RegWriteStringValue(HKCU, 'Software\MinglingWorkbench', 'ProgramRoot', ExpandConstant('{app}'));
    RegWriteStringValue(HKCU, 'Software\MinglingWorkbench', 'WorkspaceRoot', WsPath);
    if HadExistingApp then
      RegWriteDWordValue(HKCU, 'Software\MinglingWorkbench\Installer', 'SuppressStartupWrites', 1);
    dir := StateDirPath;
    cfg := dir + '\settings.json';
    { 已有 settings.json：一个字都别动。那份是工作台自己写的，里面还有别的键；
       工作区、base、密钥目录它都认得，装完直接接着用。 }
    if FileExists(cfg) then exit;
    if WsPath = '' then WsPath := ExpandConstant('{userdocs}\冥零工作台');
    ForceDirectories(WsPath + '\out');
    ForceDirectories(WsPath + '\tmp');
    ForceDirectories(WsPath + '\logs\jobs');
    ForceDirectories(dir);
    { 工作区自己就是机器人根（下面已经有 private\ / answers.json / bots\）时，base 就是它自己。
      老布局（工作区是 <机器人根>\bili）才取上一级。猜错的话自设定会去 <上一级>\private\backend.txt
      找登录信息，后台永远连不上。 }
    if DirExists(WsPath + '\private') or DirExists(WsPath + '\bots') or FileExists(WsPath + '\answers.json') then
      b := WsPath
    else
    begin
      b := ExtractFileDir(WsPath);
      if b = '' then b := WsPath;
    end;
    w1 := WsPath;
    w2 := b;
    StringChangeEx(w1, '\', '/', True);
    StringChangeEx(w2, '\', '/', True);
    js := '{"workspace": "' + w1 + '", "base": "' + w2 + '"}';
    { 按 ANSI 写（工作台读 settings.json 时先试 UTF-8、不通再按系统编码解，中文路径照样认）；
       不要在这里塞 UTF-8 BOM——BOM 后面跟 GBK 字节反而会让它解错。 }
    SaveStringToFile(cfg, js, False);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    MsgBox('程序已卸载。' + #13#10 +
           '你的看片产物、台账和日志都还在工作区里，没有删除；' + #13#10 +
           '工作区旁边的 secrets 文件夹（密钥）也保留着。' + #13#10 + #13#10 +
           '重装回来就能直接用——重装时工作区选哪里都不影响，' + #13#10 +
           '工作台会照旧读它自己记着的那份 settings.json。' + #13#10 + #13#10 +
           '需要彻底清理时，手动删除工作区和 secrets 两个目录即可。', mbInformation, MB_OK);
end;
