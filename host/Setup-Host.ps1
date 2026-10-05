<#
.SYNOPSIS
  One-time host setup for the Bluetooth link to the Pi. Run as your normal user.

  1. Pairs with the Pi if not paired yet (no Settings UI needed).
  2. Adds an ssh alias (default 'pi-bt') to ~/.ssh/config.
  3. Turns off manual Internet Connection Sharing on other adapters if present
     (UAC prompt) - Windows ICS serves DHCP/NAT for one private network only,
     and Mobile hotspot needs it for the Bluetooth link.
  4. Turns on Mobile hotspot over Bluetooth with power saving off.
  5. Registers the logon task 'BtPi-Hotspot' (BtPi-Watchdog.ps1) that keeps it on.
.PARAMETER Uninstall
  Remove the logon task and turn the hotspot off (leaves pairing and ssh alias).
#>
param([switch]$Uninstall, [switch]$ElevatedIcsOff)

. "$PSScriptRoot\BtPiCommon.ps1"
$cfg = Get-BtPiConfig -Require PiBtAddress, SshUser
$taskName = "BtPi-Hotspot"

if ($ElevatedIcsOff) {
    # ---- elevated child: disable manual ICS (not the hotspot's own sharing) ----
    $hn = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in $hn.EnumEveryConnection) {
        $p = $hn.NetConnectionProps.Invoke($c)
        $s = $hn.INetSharingConfigurationForINetConnection.Invoke($c)
        if ($s.SharingEnabled -and $p.DeviceName -notlike "Bluetooth Device (Personal Area Network)*") {
            $s.DisableSharing()
            Write-Host "ICS disabled on '$($p.Name)'"
        }
    }
    Start-Sleep 2
    exit 0
}

function Step($msg) { Write-Host "[setup] $msg" -ForegroundColor Cyan }

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Step "Task '$taskName' removed"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$PSScriptRoot\BtPiCommon.ps1'; Invoke-HotspotSettingsUi -Off"
    Step "Mobile hotspot turned off"
    return
}

# 1. Pairing
if (-not (Test-BtPaired $cfg.PiBtAddress)) {
    Step "Pairing with $($cfg.PiName) ($($cfg.PiBtAddress))..."
    & "$PSScriptRoot\Pair-Pi.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Pairing failed - is the Pi powered and bt-autoconnect running?" }
} else {
    Step "Already paired with $($cfg.PiName)"
}

# 2. ssh alias (HostName starts at the Pi's IPv6 link-local; Connect-Pi.ps1 updates it)
$bt = Get-BtPanAdapter
if (-not $bt) { throw "No 'Bluetooth Device (Personal Area Network)' adapter - pair first" }
$sshCfg = Join-Path $env:USERPROFILE ".ssh\config"
$begin = "# >>> bt-pi-protocol >>>"
$end = "# <<< bt-pi-protocol <<<"
$block = @"
$begin
# Raspberry Pi over Bluetooth PAN (managed by bt-pi-protocol; HostName is
# updated by host\Connect-Pi.ps1 to the Pi's current Bluetooth-link address)
Host $($cfg.SshAlias)
    HostName $((Get-PiLinkLocal $cfg.PiBtAddress $bt.ifIndex) -replace '%', '%%')
    HostKeyAlias $($cfg.SshHostKeyAlias)
    User $($cfg.SshUser)
    IdentityFile $($cfg.SshIdentity)
    IdentitiesOnly yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 4
$end
"@
$text = if (Test-Path $sshCfg) { [IO.File]::ReadAllText($sshCfg) } else { "" }
$pattern = "(?s)" + [regex]::Escape($begin) + ".*?" + [regex]::Escape($end) + "\r?\n?"
if ($text -notmatch $pattern) {
    $text = $text.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    [IO.File]::WriteAllText($sshCfg, $text.TrimStart(), (New-Object Text.UTF8Encoding $false))
    Step "ssh alias '$($cfg.SshAlias)' added to $sshCfg"
} else {
    Step "ssh alias '$($cfg.SshAlias)' already present"
}

# 3. Manual ICS elsewhere blocks the hotspot's DHCP on the Bluetooth link.
#    (Reading ICS state needs admin, so look for the ICS address instead.)
$scope = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters -ErrorAction SilentlyContinue).ScopeAddress
$icsElsewhere = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $scope -and $_.InterfaceIndex -ne $bt.ifIndex }
if ($icsElsewhere) {
    Step "Manual Internet Connection Sharing is on for '$($icsElsewhere.InterfaceAlias)'; turning it off (UAC prompt)..."
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ElevatedIcsOff"
    if ($p.ExitCode -ne 0) { throw "Could not turn off ICS (exit $($p.ExitCode))" }
}

# 4. Hotspot over Bluetooth
Step "Turning on Mobile hotspot over Bluetooth..."
$s = Enable-BtHotspot
if ($s.Medium -ne 'Bluetooth') { throw "Mobile hotspot is '$($s.Medium)', expected Bluetooth" }
Step "Hotspot on over Bluetooth (host $($s.HostIp))"

# 5. Logon task keeping it on
$vbs = Join-Path $PSScriptRoot "run-hidden.vbs"
$watchdog = Join-Path $PSScriptRoot "BtPi-Watchdog.ps1"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`" `"$watchdog`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Force -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Keep Mobile hotspot shared over Bluetooth for the Raspberry Pi (bt-pi-protocol)" | Out-Null
Start-ScheduledTask -TaskName $taskName
Step "Logon task '$taskName' registered and started (log: $env:LOCALAPPDATA\bt-pi\watchdog.log)"
Step "Done. Connect with: $PSScriptRoot\Connect-Pi.ps1"
