<#
.SYNOPSIS
  Background keeper (scheduled task 'BtPi-Hotspot', runs at logon): keeps
  Mobile hotspot sharing this PC's internet over Bluetooth, so a Pi that
  powers on finds a NAP to dial. Windows turns the hotspot off on reboot,
  sleep and network changes; this turns it back on.

  Pause it:   Disable-ScheduledTask BtPi-Hotspot ; Stop-ScheduledTask BtPi-Hotspot
  Log:        %LOCALAPPDATA%\bt-pi\watchdog.log
#>
param([int]$IntervalSec = 60)
. "$PSScriptRoot\BtPiCommon.ps1"

$logDir = Join-Path $env:LOCALAPPDATA "bt-pi"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir "watchdog.log"
function Log($msg) {
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
    Add-Content -Path $log -Value ("{0:s} {1}" -f (Get-Date), $msg)
}

Log "watchdog started (interval ${IntervalSec}s)"
$failures = 0
$last = $null
while ($true) {
    $sleep = $IntervalSec
    try {
        $s = Get-BtHotspotStatus
        $state = "$($s.Medium)/$($s.Internet)"
        if ($state -ne $last) { Log "hotspot: $($s.Medium), host internet: $($s.Internet), host IP: $($s.HostIp)"; $last = $state }
        if ($s.Internet -and $s.Medium -ne 'Bluetooth') {
            Log "enabling Mobile hotspot over Bluetooth"
            $s = Enable-BtHotspot
            if ($s.Medium -eq 'Bluetooth') { Log "hotspot on over Bluetooth ($($s.HostIp))"; $failures = 0 }
            else { throw "hotspot still $($s.Medium)" }
        } else { $failures = 0 }
    } catch {
        $failures++
        # e.g. session locked: Settings UI can't be driven; back off up to 10 min
        $sleep = [Math]::Min($IntervalSec * [Math]::Pow(2, [Math]::Min($failures, 4)), 600)
        Log "error: $($_.Exception.Message) (retry in ${sleep}s)"
    }
    Start-Sleep -Seconds $sleep
}
