@echo off
rem Opens the Brave custom profile photo tool. Arguments are passed through,
rem e.g.  "Brave Custom Avatar.cmd" -List
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Brave-CustomAvatar.ps1" %*
if errorlevel 1 pause
