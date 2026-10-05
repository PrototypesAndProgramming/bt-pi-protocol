' Starts a PowerShell script with no console window (used by the scheduled task).
' Usage: wscript.exe run-hidden.vbs <script.ps1>
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """", 0, False
