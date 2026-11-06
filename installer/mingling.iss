; 冥零工作台 v2 安装脚本（Inno Setup 6）
; 编译：installer\build-installer.bat  →  dist\MinglingWorkbench-2.2.0-setup.exe
#define AppName "冥零工作台"
; 版本号来自 win32\src\version.h（build-installer.bat 每次重新生成 version_auto.iss）
#include "version_auto.iss"
#define AppExe "MinglingWorkbench.exe"

[Setup]
AppId={{8E1B7C42-5D3A-4F0E-9C21-7B6A1D3E5F80}
AppName={#AppName}
AppVersion={#AppVer}
AppVerName={#AppName} {#AppVerTag}
AppPublisher=冥零工作台
DefaultDirName={localappdata}\Programs\MinglingWorkbench
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\dist
OutputBaseFilename=MinglingWorkbench-{#AppVer}-setup
SetupIconFile=..\win32\res\app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
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
Name: "{code:GetSecretsDir}"; Permissions: users-modify

[Files]
Source: "..\bin\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\art\*"; DestDir: "{app}\art"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\plugin\astrbot_plugin_bili_bridge\*"; DestDir: "{app}\plugin\astrbot_plugin_bili_bridge"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\sidecar\*"; DestDir: "{app}\sidecar"; Flags: ignoreversion recursesubdirs createallsubdirs
; 密钥目录里放一份说明；已经有的不覆盖（用户的密钥在同一个文件夹里）
Source: "..\installer\secrets-README.txt"; DestDir: "{code:GetSecretsDir}"; DestName: "README.txt"; Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\使用说明"; Filename: "{app}\docs\使用说明.md"
Name: "{group}\B 站部署教程"; Filename: "{app}\docs\deploy-bili.md"
Name: "{group}\QQ 机器人部署教程"; Filename: "{app}\docs\deploy-qq.md"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]

Filename: "{cmd}"; Parameters: "/c reg delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\MinglingWorkbench_is1"" /f >nul 2>&1"; Flags: runhidden


[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
var
  WsPage: TInputDirWizardPage;
  WsPath: String;

{ 从 JSON 文本里取一个字符串值。全程用绝对下标，不叠加相对偏移。 }
function JsonStringValue(const raw: AnsiString; const key: String): String;
var
  txt, k, rest: String;
  p, q: Integer;
begin
  Result := '';
  txt := String(raw);
  k := '"' + key + '"';
  p := Pos(k, txt);
  if p = 0 then exit;
  rest := Copy(txt, p + Length(k), Length(txt));
  p := Pos(':', rest);
  if p = 0 then exit;
  rest := Copy(rest, p + 1, Length(rest));
  p := Pos('"', rest);
  if p = 0 then exit;
  rest := Copy(rest, p + 1, Length(rest));
  q := Pos('"', rest);
  if q = 0 then exit;
  Result := Trim(Copy(rest, 1, q - 1));
end;

{ 只有 X:\ 或 X:/ 形态才认，避免把半截字符串写进向导。 }
function LooksLikePath(const s: String): Boolean;
begin
  Result := (Length(s) >= 3) and (s[2] = ':') and ((s[3] = '\') or (s[3] = '/'));
end;

function ExistingWorkspace: String;
var
  cfg: String;
  raw: AnsiString;
  ws: String;
begin
  Result := '';
  cfg := ExpandConstant('{userappdata}\MinglingWorkbench\settings.json');
  if not FileExists(cfg) then exit;
  if not LoadStringFromFile(cfg, raw) then exit;
  ws := JsonStringValue(raw, 'workspace');
  StringChangeEx(ws, '/', '\', True);
  ws := Trim(ws);
  if LooksLikePath(ws) then Result := ws;
end;

function InitializeSetup: Boolean;
begin
  WsPath := Trim(ExpandConstant('{param:WORKSPACE|}'));
  if WsPath = '' then WsPath := ExistingWorkspace;
  if WsPath = '' then WsPath := ExpandConstant('{userdocs}\冥零工作台');
  Result := True;
end;

{ 密钥目录 = 工作区上一级的 secrets（工作区 D:\MinglingWorkbench → F:\secrets）。
  安装器和服务读的是同一个约定，见 win32\src\paths.cpp 的 SecretsDir。 }
function GetSecretsDir(Param: String): String;
var
  ws, b: String;
begin
  ws := WsPath;
  if not LooksLikePath(ws) then ws := ExpandConstant('{userdocs}\冥零工作台');
  b := ExtractFileDir(ws);
  if (b <> '') and (Copy(b, Length(b), 1) = '\') then b := Copy(b, 1, Length(b) - 1);
  if (b = '') or (not LooksLikePath(b)) then b := Copy(ws, 1, 2);
  Result := b + '\secrets';
end;

procedure InitializeWizard;
begin
  WsPage := CreateInputDirPage(wpSelectDir, '选择工作区',
    'B 站产物、台账和日志都放在工作区里。',
    '默认放在“文档”下的「冥零工作台」。以后可在工作台「B站」页或「维护」页更换；更换不会自动搬走旧数据。',
    False, '');
  WsPage.Add('');
  WsPage.Values[0] := WsPath;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = WsPage.ID then
  begin
    WsPath := Trim(WsPage.Values[0]);
    if WsPath = '' then
    begin
      MsgBox('请选择一个工作区目录。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not LooksLikePath(WsPath) then
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
    ForceDirectories(WsPath + '\out');
    ForceDirectories(WsPath + '\tmp');
    ForceDirectories(WsPath + '\logs\jobs');
  end;
end;


procedure CurStepChanged(CurStep: TSetupStep);
var
  cfg, dir, js, b, w1, w2: String;
begin
  if CurStep = ssPostInstall then
  begin
    if WsPath = '' then WsPath := ExpandConstant('{userdocs}\冥零工作台');
    ForceDirectories(WsPath + '\out');
    ForceDirectories(WsPath + '\tmp');
    ForceDirectories(WsPath + '\logs\jobs');
    dir := ExpandConstant('{userappdata}\MinglingWorkbench');
    cfg := dir + '\settings.json';
    ForceDirectories(dir);
    begin
      b := ExtractFileDir(WsPath);
      if b = '' then b := WsPath;
      w1 := WsPath;
      w2 := b;
      StringChangeEx(w1, '\', '/', True);
      StringChangeEx(w2, '\', '/', True);
      js := '{"workspace": "' + w1 + '", "base": "' + w2 + '"}';
      SaveStringToFile(cfg, js, False);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  cfg: String;
  raw: AnsiString;
  txt, ws: String;
  a, b: Integer;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    cfg := ExpandConstant('{userappdata}\MinglingWorkbench\settings.json');
    ws := '';
    if FileExists(cfg) then
    begin
      if LoadStringFromFile(cfg, raw) then
      begin
        txt := raw;
        a := Pos('"workspace"', txt);
        if a > 0 then
        begin
          a := Pos('"', Copy(txt, a + 11, Length(txt)));
          if a > 0 then
          begin
            txt := Copy(txt, Pos('"workspace"', txt) + 11, Length(txt));
            a := Pos('"', txt);
            if a > 0 then
            begin
              txt := Copy(txt, a + 1, Length(txt));
              b := Pos('"', txt);
              if b > 0 then ws := Copy(txt, 1, b - 1);
            end;
          end;
        end;
      end;
    end;
    if ws = '' then ws := ExpandConstant('{userdocs}\冥零工作台');
    StringChangeEx(ws, '/', '\', True);
    MsgBox('程序已卸载。' + #13#10 +
           '你的看片产物、台账和日志没有删除：' + #13#10 + ws + #13#10 + #13#10 +
           '密钥文件夹也保留了：' + #13#10 + GetSecretsDir('') + #13#10 +
           '重装回来就能直接用。' + #13#10 + #13#10 +
           '需要彻底清理时，手动删除上面两个目录即可。', mbInformation, MB_OK);
  end;
end;
