<#
.SYNOPSIS
  One-time Bluetooth pairing of this PC with the Pi, without the Settings UI.
  The Pi's bt-autoconnect agent auto-accepts this PC (and only this PC).
.EXAMPLE
  .\Pair-Pi.ps1                       # uses PiBtAddress from bt-pi.config.local.psd1
  .\Pair-Pi.ps1 -PiBtAddress AA:BB:CC:DD:EE:FF
  .\Pair-Pi.ps1 -Unpair
#>
[CmdletBinding()]
param(
    [string]$PiBtAddress,
    [switch]$Unpair
)
. "$PSScriptRoot\BtPiCommon.ps1"
if (-not $PiBtAddress) { $PiBtAddress = (Get-BtPiConfig).PiBtAddress }

if ($Unpair) { $r = Invoke-BtUnpair $PiBtAddress } else { $r = Invoke-BtPair $PiBtAddress }
Write-Host "$PiBtAddress : $r"
if ($r -notin 'Paired', 'AlreadyPaired', 'Unpaired', 'AlreadyUnpaired') { exit 1 }
