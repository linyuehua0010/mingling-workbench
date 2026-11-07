@echo off
chcp 65001 >nul
"%~dp0python\pythonw.exe" -X utf8 "%~dp0qq_watch.py" --dir "%~dp0.."
