; 冥零工作台 v2 安装脚本（Inno Setup 6）
; 编译：installer\build-installer.bat  →  dist\MinglingWorkbench-<版本>-setup.exe
; 版本号来自 win32\src\version.h（build-installer.bat 每次重新生成 version_auto.iss）
#include "version_auto.iss"
#define AppExe "MinglingWorkbench.exe"

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
AppVersion={#AppVer}
AppVerName={#AppTitle} {#AppVerTag}
AppPublisher=冥零工作台
DefaultDirName={localappdata}\Programs\{#AppDir}
DefaultGroupName={#AppTitle}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\dist
OutputBaseFilename=MinglingWorkbench-{#AppVer}{#AppOutSuffix}-setup
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
Source: "..\bin\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\art\*"; DestDir: "{app}\art"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\plugin\astrbot_plugin_bili_bridge\*"; DestDir: "{app}\plugin\astrbot_plugin_bili_bridge"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\sidecar\*"; DestDir: "{app}\sidecar"; Flags: ignoreversion recursesubdirs createallsubdirs
; 安装 Skill（冥零自己的那份）：装在 {app}\skill 下，工作台第一次启动时铺到
; %USERPROFILE%\.agents\skills\mingling-install，并写下 tools\skill-home.txt / skill-version.json。
; 没有它，Agent 就只会照大肥鱼那份说明书干活。
Source: "..\skill\mingling-install\*"; DestDir: "{app}\skill\mingling-install"; Flags: ignoreversion recursesubdirs createallsubdirs
; 密钥目录里放一份说明；已经有的不覆盖（用户的密钥在同一个文件夹里）

[Icons]
Name: "{group}\{#AppTitle}"; Filename: "{app}\{#AppExe}"
Name: "{group}\使用说明"; Filename: "{app}\docs\使用说明.md"
Name: "{group}\B 站部署教程"; Filename: "{app}\docs\deploy-bili.md"
Name: "{group}\QQ 机器人部署教程"; Filename: "{app}\docs\deploy-qq.md"
Name: "{group}\卸载 {#AppTitle}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppTitle}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 {#AppTitle}"; Flags: nowait postinstall skipifsilent

[UninstallRun]

Filename: "{cmd}"; Parameters: "/c reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppUninstKey}"" /f >nul 2>&1"; Flags: runhidden


[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
var
  WsPage: TInputDirWizardPage;
  WsPath: String;

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
  WsPath := CleanPath(Trim(ExpandConstant('{param:WORKSPACE|}')));
  if not PathUsable(WsPath) then WsPath := '';
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
begin
  if CurStep = ssPostInstall then
  begin
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
