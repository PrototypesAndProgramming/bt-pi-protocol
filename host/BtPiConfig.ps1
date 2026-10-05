# Config loader for the host-side bt-pi scripts (dot-source this file).
# bt-pi.config.psd1 holds shared defaults; bt-pi.config.local.psd1 (git-ignored)
# holds this machine's values: Bluetooth addresses, ssh user, names.

function Get-BtPiConfig([string[]]$Require = @('PiBtAddress')) {
    $cfg = Import-PowerShellDataFile "$PSScriptRoot\bt-pi.config.psd1"
    $local = "$PSScriptRoot\bt-pi.config.local.psd1"
    if (-not (Test-Path $local)) {
        throw "Missing $local. Copy bt-pi.config.local.example.psd1 to bt-pi.config.local.psd1 and fill in your values."
    }
    $over = Import-PowerShellDataFile $local
    foreach ($k in $over.Keys) { $cfg[$k] = $over[$k] }
    if (-not $cfg.SshHostKeyAlias) { $cfg.SshHostKeyAlias = $cfg.SshAlias }
    foreach ($k in $Require) {
        if (-not $cfg[$k]) { throw "$k is not set in $local" }
        if ($k -like '*BtAddress' -and $cfg[$k] -notmatch '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$') {
            throw "$k '$($cfg[$k])' in $local is not a Bluetooth address (XX:XX:XX:XX:XX:XX)"
        }
    }
    $cfg
}
