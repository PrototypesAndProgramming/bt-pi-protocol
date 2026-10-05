@echo off
rem One-click: bring up the Bluetooth link to the Pi and open a shell on it.
rem Extra arguments are passed through, e.g.  Connect-Pi.cmd -Code
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0host\Connect-Pi.ps1" %*
if errorlevel 1 pause
