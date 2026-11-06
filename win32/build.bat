@echo off
rem Build Mingling Workbench (Win32 + GDI+, static, single exe)
setlocal
cd /d "%~dp0"
set "OUTDIR=%~dp0..\bin"

rem MinGW: prefer %MINGW_BIN%, then build.local.bat (git-ignored), then g++/windres from PATH
if not "%MINGW_BIN%"=="" goto mingw_ready
if exist "%~dp0build.local.bat" call "%~dp0build.local.bat"
:mingw_ready
set "GXX=g++"
set "WINDRES=windres"
if not "%MINGW_BIN%"=="" set "GXX=%MINGW_BIN%\g++.exe"
if not "%MINGW_BIN%"=="" set "WINDRES=%MINGW_BIN%\windres.exe"
if not exist "%GXX%" set "GXX=g++"
if not exist "%WINDRES%" set "WINDRES=windres"

if not exist "build" mkdir "build"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem 版本自检：version.h 里的数字和字符串必须一致（没有 PowerShell 就跳过）
where powershell >nul 2>nul
if errorlevel 1 ( echo [版本] 没有 powershell，跳过自检 & goto version_ok )
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\check-version.ps1"
if errorlevel 1 ( echo [ERROR] version.h 的数字和字符串对不上，先修好再编译。 & exit /b 1 )
:version_ok

echo [1/3] resources
"%WINDRES%" -I res -I src -O coff -o build\app.res.o res\app.rc
if errorlevel 1 goto fail

echo [2/3] compile
"%GXX%" -std=c++17 -O2 -Wall -DUNICODE -D_UNICODE -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00 -fno-ident -ffunction-sections -fdata-sections src\main.cpp src\util.cpp src\paths.cpp src\whale.cpp src\ui.cpp src\her\her_json.cpp src\her\her_probe.cpp src\her\her_sqlite.cpp src\her\her_config.cpp src\her\her_astr.cpp src\her\her_status.cpp src\her\her_actions.cpp src\her\her_setup.cpp build\app.res.o -o build\MinglingWorkbench.exe -Wl,--gc-sections -static -static-libgcc -static-libstdc++ -s -mwindows -lgdiplus -lwinhttp -lole32 -loleaut32 -luuid -lshell32 -lshlwapi -lcomdlg32 -lcomctl32 -lws2_32 -liphlpapi -lgdi32 -luser32 -ladvapi32
if errorlevel 1 goto fail

echo [3/3] copy
copy /y build\MinglingWorkbench.exe "%OUTDIR%\MinglingWorkbench.exe" >nul
if errorlevel 1 goto copylocked
echo.
echo OK: %OUTDIR%\MinglingWorkbench.exe
for %%F in ("%OUTDIR%\MinglingWorkbench.exe") do echo size: %%~zF bytes
exit /b 0

:copylocked
echo.
echo COPY FAILED: %OUTDIR%\MinglingWorkbench.exe is locked.
echo Close the running app (it is started from bin\) and run build.bat again.
echo What is in bin\ right now is still the OLD exe.
exit /b 1

:fail
echo.
echo BUILD FAILED - see errors above.
exit /b 1
