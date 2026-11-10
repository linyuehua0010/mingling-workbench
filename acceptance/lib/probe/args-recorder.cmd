@echo off
setlocal enabledelayedexpansion
set "OUT=%MW_PROBE_OUT%"
if not defined OUT set "OUT=%TEMP%\mw-probe-cmd.txt"
break > "%OUT%"
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "A4=%~4"
set "A5=%~5"
set "A6=%~6"
set "A7=%~7"
set "A8=%~8"
set "A9=%~9"
>>"%OUT%" echo A1=[!A1!]
>>"%OUT%" echo A2=[!A2!]
>>"%OUT%" echo A3=[!A3!]
>>"%OUT%" echo A4=[!A4!]
>>"%OUT%" echo A5=[!A5!]
>>"%OUT%" echo A6=[!A6!]
>>"%OUT%" echo A7=[!A7!]
>>"%OUT%" echo A8=[!A8!]
>>"%OUT%" echo A9=[!A9!]
>>"%OUT%" echo END
if defined MW_PROBE_EXIT exit /b %MW_PROBE_EXIT%
exit /b 0
