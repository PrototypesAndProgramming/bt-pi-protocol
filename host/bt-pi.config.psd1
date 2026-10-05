@{
    # Shared defaults. Your own values (Bluetooth addresses, ssh user, names)
    # go in bt-pi.config.local.psd1, which is git-ignored and overrides these.
    # Start from bt-pi.config.local.example.psd1.

    PiName      = 'Raspberry Pi'

    # ssh_config Host alias managed by Setup-Host.ps1; Connect-Pi.ps1 keeps its
    # HostName pointed at the Pi's current address on the Bluetooth link.
    SshAlias    = 'pi-bt'
    SshIdentity = '~/.ssh/id_ed25519'
    # Name the Pi's host key is stored under in known_hosts. Empty = SshAlias.
    # Set it to an existing alias for the Pi to reuse the host key already known for it.
    SshHostKeyAlias = ''
}
