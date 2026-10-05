@{
    # Copy this file to bt-pi.config.local.psd1 (git-ignored) and fill it in.
    # Any key from bt-pi.config.psd1 can also be overridden here.

    # Pi's Bluetooth controller address (on the Pi: bluetoothctl show, or btmgmt info)
    PiBtAddress   = 'AA:BB:CC:DD:EE:FF'
    # This PC's Bluetooth address (Get-NetAdapter "Bluetooth Network Connection" |
    # Select MacAddress, with '-' replaced by ':'). deploy-pi.ps1 installs it on
    # the Pi as HOST_MAC, the only device allowed to pair.
    HostBtAddress = '11:22:33:44:55:66'

    PiName        = 'Raspberry Pi'
    SshUser       = 'pi'
    SshIdentity   = '~/.ssh/id_ed25519'

    # ssh alias deploy-pi.ps1 uses when -Target isn't given (any alias that
    # reaches the Pi, e.g. over Ethernet or Wi-Fi for the first install).
    DeployTarget  = 'raspberrypi'
}
