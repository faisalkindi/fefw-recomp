@echo off
rem Windowed device-loss bisect (#81): put this file and windowed_bisect.ps1 in the game folder (next to fefw.exe) and double-click it.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windowed_bisect.ps1"
echo.
pause
