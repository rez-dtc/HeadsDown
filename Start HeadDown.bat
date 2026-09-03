@echo off
start "HeadDown" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HeadDown.ps1"
exit /b
