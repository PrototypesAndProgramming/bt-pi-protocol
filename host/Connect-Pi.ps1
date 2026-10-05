<#
.SYNOPSIS
  One-click launcher: bring up the Bluetooth link to the Pi and open a shell on it.

  1. Pairs with the Pi if needed.
  2. Makes sure Mobile hotspot is sharing this PC's internet over Bluetooth.
  3. Waits for the Pi to dial in (it does so by itself after boot), finds its
     address on the Bluetooth link and points the ssh alias (default
     'pi-bt') at it, so `ssh pi-bt` and VS Code Remote-SSH work too.
  4. Opens an interactive ssh session (or VS Code, or runs one command).
.EXAMPLE
  .\Connect-Pi.ps1                  # interactive shell
  .\Connect-Pi.ps1 -Code            # VS Code Remote-SSH window on the Pi
  .\Connect-Pi.ps1 -Command "uptime"
  .\Connect-Pi.ps1 -NoConnect       # just bring the link up and update the alias
#>
param(
    [switch]$Code,
    [string]$Command,
    [switch]$NoConnect,
    [switch]$NoHotspot,
    [int]$WaitSec = 120
)
. "$PSScriptRoot\BtPiCommon.ps1"
$cfg = Get-BtPiConfig

function Step($msg) { Write-Host "[bt-pi] $msg" -ForegroundColor Cyan }

function Test-Ssh([string]$Address, [int]$TimeoutMs = 2000) {
    $c = New-Object Net.Sockets.TcpClient($(if ($Address -like '*:*') { 'InterNetworkV6' } else { 'InterNetwork' }))
    try {
        $ar = $c.BeginConnect([Net.IPAddress]::Parse($Address), 22, $null, $null)
        $ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected
    } catch { $false } finally { $c.Close() }
}

# Pi's addresses on the Bluetooth link: ICS keeps a permanent ARP entry for its
# DHCP lease; the IPv6 link-local address follows from the Pi's BT address.
function Get-PiCandidates($bt) {
    $mac = $cfg.PiBtAddress.ToUpper() -replace ':', '-'
    Get-NetNeighbor -InterfaceIndex $bt.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.LinkLayerAddress -eq $mac -and $_.State -ne 'Unreachable' } |
        ForEach-Object { $_.IPAddress }
    Get-PiLinkLocal $cfg.PiBtAddress $bt.ifIndex
}

function Set-SshAliasHost([string]$Address) {
    $sshCfg = Join-Path $env:USERPROFILE ".ssh\config"
    if (-not (Test-Path $sshCfg)) { return }
    $text = [IO.File]::ReadAllText($sshCfg)
    $hostName = $Address -replace '%', '%%'   # '%' starts a token in ssh_config
    $pattern = "(?s)(# >>> bt-pi-protocol >>>.*?\n\s*HostName )[^\r\n]*"
    $new = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + $hostName })
    if ($new -ne $text) { [IO.File]::WriteAllText($sshCfg, $new, (New-Object Text.UTF8Encoding $false)) }
}

# 1. Pairing
if (-not (Test-BtPaired $cfg.PiBtAddress)) {
    Step "Pairing with $($cfg.PiName)..."
    & "$PSScriptRoot\Pair-Pi.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Pairing failed. Is the Pi powered on?" }
}

# 2. Internet sharing
if (-not $NoHotspot) {
    $hs = Get-BtHotspotStatus
    if ($hs.Medium -ne 'Bluetooth') {
        Step "Turning on Mobile hotspot over Bluetooth..."
        $hs = Enable-BtHotspot
    }
    if ($hs.Medium -eq 'Bluetooth') { Step "Internet shared over Bluetooth" }
    else { Write-Warning "Hotspot is not sharing over Bluetooth ($($hs.Medium)); the Pi will have no internet." }
}

# 3. Wait for the Pi
Step "Waiting for $($cfg.PiName) on the Bluetooth link (up to ${WaitSec}s)..."
$deadline = (Get-Date).AddSeconds($WaitSec)
$addr = $null
do {
    $bt = Get-BtPanAdapter
    if ($bt -and $bt.Status -eq 'Up') {
        foreach ($a in Get-PiCandidates $bt) { if (Test-Ssh $a) { $addr = $a; break } }
    }
    if (-not $addr) { Start-Sleep 2 }
} while (-not $addr -and (Get-Date) -lt $deadline)
if (-not $addr) {
    throw "Pi not reachable over Bluetooth. Is it powered on? Check on the Pi: journalctl -u bt-autoconnect"
}
Set-SshAliasHost $addr
Step "$($cfg.PiName) is at $addr  (ssh $($cfg.SshAlias))"

# 4. Connect
if ($NoConnect) { return }
if ($Code) {
    & code --remote "ssh-remote+$($cfg.SshAlias)" "/home/$($cfg.SshUser)"
} elseif ($Command) {
    # Show remote stderr as plain text (Windows PowerShell wraps it in error records).
    & ssh $cfg.SshAlias $Command 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
    }
    exit $LASTEXITCODE
} else {
    & ssh $cfg.SshAlias
}
