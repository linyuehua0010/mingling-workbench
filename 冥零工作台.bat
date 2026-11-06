@echo off
chcp 65001 >nul
rem 冥零工作台 —— 双击这个开窗口
rem 原生 Win32 + GDI+，一个 exe，不挂浏览器内核，占几十兆内存
rem 只会有一个窗口：重复双击不会多开，第二次只是把已有窗口提到前面
start "" "%~dp0bin\MinglingWorkbench.exe"
