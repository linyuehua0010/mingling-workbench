; 冥零工作台 v2 安装包（NSIS 3.10，Unicode）
; 编译：installer\build-installer.bat
; 设计要点：
;   - 每用户安装到 %LOCALAPPDATA%\Programs\MinglingWorkbench，不要管理员权限
;   - 工作区单独选，写进 %APPDATA%\MinglingWorkbench\settings.json（已有则不动）
;   - 卸载只删程序，不删工作区里的 out/tmp/logs
Unicode true
!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "StrFunc.nsh"
!include "..\build\parts\parts.nsh"

!define APPNAME "冥零工作台"
!define APPVERSION "2.2.0"
!define REGKEY "Software\MinglingWorkbench"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\MinglingWorkbench"

Name "${APPNAME}"
OutFile "..\dist\MinglingWorkbench-${APPVERSION}-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\MinglingWorkbench"
InstallDirRegKey HKCU "${REGKEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor zlib
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "2.2.0.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} 安装程序"
VIAddVersionKey "FileVersion" "2.2.0"
VIAddVersionKey "ProductVersion" "2.2.0"
VIAddVersionKey "LegalCopyright" "MIT / 第三方见 THIRD-PARTY.md"

Var WorkspaceDir
Var BaseDir
Var WorkspaceField
Var WorkspaceNote
Var DesktopChk

!define MUI_ICON "..\win32\res\app.ico"
!define MUI_UNICON "..\win32\res\app.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "安装冥零工作台 v2"
!define MUI_WELCOMEPAGE_TEXT "一个窗口搞定 QQ 机器人和看 B 站。$\r$\n$\r$\n安装包已自带 Node、ffmpeg 和看片组件，干净电脑也能直接用；不需要 DSH、Python、WebView2。$\r$\n$\r$\n下一步选择装在哪、以及产物放哪。"
!define MUI_DIRECTORYPAGE_TEXT_TOP "程序装到这里（默认当前用户，不需要管理员）："
!define MUI_FINISHPAGE_TITLE "装好了"
!define MUI_FINISHPAGE_TEXT "工作区：$WorkspaceDir$\r$\n$\r$\n看 B 站的产物、台账、日志都在这个目录下的 out\tmp\logs。$\r$\n卸载不会删除它们。$\r$\n$\r$\n同一个 exe 只会开一个窗口：重复双击会把已有窗口提到前面。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\MinglingWorkbench.exe"
!define MUI_FINISHPAGE_RUN_TEXT "现在启动冥零工作台"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\docs\THIRD-PARTY.md"
!insertmacro MUI_PAGE_DIRECTORY
Page custom WorkspacePageCreate WorkspacePageLeave
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  StrCpy $WorkspaceDir "$DOCUMENTS\冥零工作台"
  StrCpy $BaseDir "$DOCUMENTS"
FunctionEnd

Function WorkspacePageCreate
  !insertmacro MUI_HEADER_TEXT "选择工作区" "看 B 站的产物、台账、日志都会放在这里。"
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 34u "工作区是数据目录，不是程序目录。建议放在空间大的盘，例如 D:\冥零工作区。$\r$\n它下面会自动建 out\、tmp\、logs\。"
  Pop $0

  ${NSD_CreateDirRequest} 0 40u 78% 13u "$WorkspaceDir"
  Pop $WorkspaceField
  ${NSD_OnChange} $WorkspaceField WorkspaceChanged

  ${NSD_CreateBrowseButton} 79% 40u 21% 13u "浏览…"
  Pop $0
  ${NSD_OnClick} $0 WorkspaceBrowse

  ${NSD_CreateLabel} 0 58u 100% 22u "默认是「文档\冥零工作台」。如果这台机器已经装过，安装程序不会覆盖现有设置。"
  Pop $WorkspaceNote

  nsDialogs::Show
FunctionEnd

Function WorkspaceBrowse
  nsDialogs::SelectFolderDialog "选择工作区" "$WorkspaceDir"
  Pop $0
  ${If} $0 != error
    ${NSD_SetText} $WorkspaceField "$0"
  ${EndIf}
FunctionEnd

Function WorkspaceChanged
  ${NSD_GetText} $WorkspaceField $WorkspaceDir
FunctionEnd

Function WorkspacePageLeave
  ${NSD_GetText} $WorkspaceField $WorkspaceDir
  ${If} $WorkspaceDir == ""
    MessageBox MB_ICONEXCLAMATION "工作区不能为空。"
    Abort
  ${EndIf}
  ${GetParent} "$WorkspaceDir" $BaseDir
FunctionEnd

Section "冥零工作台（必需）" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "..\bin\MinglingWorkbench.exe"
  File "..\README.md"

  SetOutPath "$INSTDIR\art"
  File /r "..\art\*.*"

  SetOutPath "$INSTDIR\docs"
  File "..\docs\THIRD-PARTY.md"
  File "..\docs\deploy-qq.md"
  File "..\docs\deploy-bili.md"
  File "..\docs\CHANGES.md"
  File "..\docs\ACCEPTANCE.md"

  SetOutPath "$INSTDIR\sidecar"
  File "..\sidecar\bili-whale.config.template.json"
  SetOutPath "$INSTDIR\sidecar\bili-whale"
  File /r /x ffmpeg.exe "..\sidecar\bili-whale\*.*"
  ; node.exe / ffmpeg.exe 切成小块带进来，安装时拼回去（32 位 makensis 有映射上限）
  SetOutPath "$INSTDIR\sidecar\node"
  !insertmacro ML_PART_FILES
  !insertmacro ML_PART_ASSEMBLE

  SetOutPath "$INSTDIR\plugin"
  File /r "..\plugin\astrbot_plugin_bili_bridge\*.*"

  CreateDirectory "$SMPROGRAMS\冥零工作台"
  CreateShortcut "$SMPROGRAMS\冥零工作台\冥零工作台.lnk" "$INSTDIR\MinglingWorkbench.exe" "" "$INSTDIR\MinglingWorkbench.exe" 0
  CreateShortcut "$SMPROGRAMS\冥零工作台\卸载冥零工作台.lnk" "$INSTDIR\uninstall.exe"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${REGKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${REGKEY}" "Workspace" "$WorkspaceDir"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\MinglingWorkbench.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "冥零"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1

  ; 只写一次设置：升级/重装不覆盖用户已经选好的工作区
  IfFileExists "$APPDATA\MinglingWorkbench\settings.json" settings_done
    CreateDirectory "$APPDATA\MinglingWorkbench"
    ${StrRep} $0 "$WorkspaceDir" "\" "/"
    ${StrRep} $1 "$BaseDir" "\" "/"
    FileOpen $2 "$APPDATA\MinglingWorkbench\settings.json" w
    FileWrite $2 '{"workspace": "$0", "base": "$1"}$\r$\n'
    FileClose $2
    CreateDirectory "$WorkspaceDir"
    CreateDirectory "$WorkspaceDir\out"
    CreateDirectory "$WorkspaceDir\tmp"
    CreateDirectory "$WorkspaceDir\logs"
    CreateDirectory "$WorkspaceDir\logs\jobs"
  settings_done:
SectionEnd

Section "桌面快捷方式" SecDesktop
  CreateShortcut "$DESKTOP\冥零工作台.lnk" "$INSTDIR\MinglingWorkbench.exe" "" "$INSTDIR\MinglingWorkbench.exe" 0
SectionEnd

LangString DESC_SecMain ${LANG_SIMPCHINESE} "主程序、界面资源、内置 node/ffmpeg/bili-whale、文档与 QQ 插件。"
LangString DESC_SecDesktop ${LANG_SIMPCHINESE} "在桌面放一个「冥零工作台」快捷方式。"

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} $(DESC_SecMain)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} $(DESC_SecDesktop)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  ; 先读一下工作区，卸载完告诉用户数据在哪
  ReadRegStr $0 HKCU "${REGKEY}" "Workspace"

  Delete "$DESKTOP\冥零工作台.lnk"
  Delete "$SMPROGRAMS\冥零工作台\冥零工作台.lnk"
  Delete "$SMPROGRAMS\冥零工作台\卸载冥零工作台.lnk"
  RMDir "$SMPROGRAMS\冥零工作台"

  Delete "$INSTDIR\MinglingWorkbench.exe"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR\art"
  RMDir /r "$INSTDIR\docs"
  RMDir /r "$INSTDIR\sidecar"
  RMDir /r "$INSTDIR\plugin"

  ; 只删空目录；如果用户把工作区选在安装目录里，数据会保留在这里
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "${REGKEY}"

  ${If} $0 != ""
    MessageBox MB_ICONINFORMATION|MB_OK "程序已卸载。$\r$\n$\r$\n工作区数据保留在：$\r$\n$0$\r$\n$\r$\n里面的 out\tmp\logs 没有删除；确认不要了可以手动删。$\r$\n设置和 B 站状态保留在 %APPDATA%\MinglingWorkbench。"
  ${Else}
    MessageBox MB_ICONINFORMATION|MB_OK "程序已卸载。工作区数据没有被删除。"
  ${EndIf}
SectionEnd
