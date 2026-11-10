@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Store-VmSecrets.ps1"
if errorlevel 1 echo.
echo Close this window after you see "Saved to ...".
pause
