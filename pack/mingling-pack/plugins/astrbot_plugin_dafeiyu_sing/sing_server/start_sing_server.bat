@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\..\..\tools\setup-singing.ps1" -Base "%~dp0..\..\..\..\.." -Action start
pause
