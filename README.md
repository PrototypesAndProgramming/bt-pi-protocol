# bt-pi-protocol

Shell access, file transfer and internet for a Raspberry Pi over Bluetooth only,
with no Ethernet or Wi-Fi on the Pi. Power the Pi on and within about 15 s of boot it has
joined the PC's Bluetooth network, has internet through the PC, and accepts SSH.

Tested with Pi 5 / Ubuntu 26.04 (BlueZ 5.85, systemd-networkd) and a
Windows 10 Home 22H2 laptop (Intel AC 7265 Bluetooth).

## How it works

```
 Windows PC (BT HostBtAddress)                            Raspberry Pi (BT PiBtAddress)
 ┌─────────────────────────────────────────┐              ┌───────────────────────────────────────────┐
 │ Wi-Fi ── ICS NAT ── Bluetooth PAN        │   BNEP over  │ bnep0 ──► bridge pan0                     │
 │          (Mobile hotspot,                │◄────────────►│           DHCP: 192.168.138.x, gw .1      │
 │           "Share over: Bluetooth")       │   Bluetooth  │           IPv6 link-local from BT address │
 │          NAP + DHCP + DNS at 192.168.138.1│             │ bt-autoconnect.service dials the PC's NAP │
 │ BtPi-Hotspot task keeps hotspot on       │              │ sshd                                      │
 │ Connect-Pi.ps1 → ssh pi-bt               │              │                                           │
 └─────────────────────────────────────────┘              └───────────────────────────────────────────┘
```

* **Windows is the network access point (NAP).** Windows only shares internet
  over Bluetooth through **Mobile hotspot with "Share over: Bluetooth"**. That
  makes the PC advertise a PAN NAP service and run DHCP, DNS and NAT for the link.
  Plain ICS refuses the Bluetooth adapter (`E_UNEXPECTED`), and WinNAT
  (`New-NetNat`) isn't available on Windows 10 Home.
* **The Pi dials the PC.** `bt-autoconnect` (Python, D-Bus/BlueZ) powers the
  adapter on and connects to the PC's NAP whenever no link is up, with backoff
  up to 60 s. It also:
  * falls back to the PC's PANU service when the hotspot is off. That gives a
    point-to-point link, so SSH over IPv6 link-local still works but there's no internet;
  * refreshes BlueZ's cached SDP record when the PC toggles hotspot. Windows swaps
    its NAP and PANU records, and BlueZ would otherwise answer `NotSupported`;
  * re-kicks DHCP if a link has no IPv4 lease after 20 s;
  * runs a pairing agent that accepts **only** `HOST_MAC`, and makes the Pi
    discoverable only until the PC has paired.
* **The PC keeps the hotspot on.** The public tethering API always starts the
  Wi-Fi hotspot on Windows 10, so the logon task `BtPi-Hotspot` flips the
  switch on the Settings page through UI Automation whenever Windows turns the
  hotspot off (reboot, sleep, network change). The Settings window flashes
  for about 2 s when that happens. It also disables the hotspot's "turn off when
  no devices are connected" timeout, because a Bluetooth client doesn't count as connected.

## Files

| Path | Where it runs | What it does |
|---|---|---|
| `pi/usr/local/sbin/bt-autoconnect` | Pi | The daemon described above |
| `pi/etc/systemd/system/bt-autoconnect.service` | Pi | Starts it at boot, restarts on failure |
| `pi/etc/default/bt-autoconnect` | Pi | `HOST_MAC` (filled in by `install.sh`), pairing mode, intervals |
| `pi/etc/systemd/network/05-pan0.{netdev,network}`, `05-bnep.network` | Pi | `pan0` bridge (fixed MAC = BT address) with DHCP; `bnep*` links join it |
| `pi/etc/bluetooth/main.conf` | Pi | Class "network AP", no discoverable or pairable timeouts (original saved as `main.conf.orig`) |
| `pi/etc/sysctl.d/60-bt-pan.conf` | Pi | Ignore routes on links that are down |
| `pi/install.sh` | Pi | Installs or updates all of the above (idempotent) |
| `deploy-pi.ps1` | PC | Copies `pi/` to the Pi and runs `install.sh` (works over Bluetooth) |
| `host/Setup-Host.ps1` | PC | One-time host setup (see below) |
| `host/Connect-Pi.ps1`, `Connect-Pi.cmd` | PC | One-click launcher |
| `host/Pair-Pi.ps1` | PC | Pair or unpair without the Settings UI (WinRT custom pairing) |
| `host/BtPi-Watchdog.ps1`, `host/run-hidden.vbs` | PC | The `BtPi-Hotspot` logon task |
| `host/BtPiCommon.ps1`, `host/BtPiConfig.ps1` | PC | Shared helpers and config loader |
| `host/bt-pi.config.psd1` | PC | Shared defaults (ssh alias, identity file) |
| `host/bt-pi.config.local.example.psd1` | PC | Template for your own `bt-pi.config.local.psd1` |

## Configuration

Values specific to your machines (Bluetooth addresses, ssh user, names) live in
**`host/bt-pi.config.local.psd1`**. Git ignores this file, so it never gets committed.
Create it from the template:

```powershell
Copy-Item host\bt-pi.config.local.example.psd1 host\bt-pi.config.local.psd1
notepad host\bt-pi.config.local.psd1
```

| Key | Required | What to put there |
|---|---|---|
| `PiBtAddress` | yes | The Pi's Bluetooth address. On the Pi: `bluetoothctl show` (the `Controller` line). |
| `HostBtAddress` | for `deploy-pi.ps1` | This PC's Bluetooth address: `(Get-NetAdapter "Bluetooth Network Connection").MacAddress -replace '-', ':'`. It becomes `HOST_MAC` on the Pi, the only device allowed to pair. |
| `SshUser` | for `Setup-Host.ps1` | Your login on the Pi. |
| `DeployTarget` | no | ssh alias `deploy-pi.ps1` uses when `-Target` isn't given. |
| `PiName` | no | Display name in messages. |
| `SshAlias`, `SshIdentity`, `SshHostKeyAlias` | no | Override the defaults in `bt-pi.config.psd1` (alias `pi-bt`, key `~/.ssh/id_ed25519`). |

The scripts stop with an error naming the missing key if a required value isn't set.
On the Pi, `HOST_MAC` is stored in `/etc/default/bt-autoconnect`. The copy in
this repo leaves it empty, and `install.sh` fills it in.

## Setup

Prerequisites: the Pi runs a systemd-networkd based Linux with SSH enabled.
Key-based SSH login from the PC must work (put the key's path in `SshIdentity`).

1. **Config**: create `host/bt-pi.config.local.psd1` as described under
   [Configuration](#configuration).
2. **Pi** (needs a network connection once, to install `bluez`): from the PC run
   `.\deploy-pi.ps1 -Target <ssh-alias>`, or set `DeployTarget` and leave out `-Target`.
   It prompts for the sudo password, or reads it from `$env:PI_SUDO_PASS`.
   It copies `pi/` to the Pi and runs `install.sh` with `HOST_MAC` set to
   `HostBtAddress`. Without the script, copy `pi/` over yourself and run
   `sudo HOST_MAC=<PC address> ./install.sh` on the Pi.
3. **PC**: `.\host\Setup-Host.ps1`. It pairs with the Pi, adds the
   ssh alias (`pi-bt` by default) to `~/.ssh/config`, turns off any manual Internet
   Connection Sharing on other adapters (one UAC prompt, only if present;
   ICS serves one private network only), turns on Mobile hotspot over
   Bluetooth, and registers the `BtPi-Hotspot` logon task.

## Daily use

* Double-click **`Connect-Pi.cmd`**, or run `.\host\Connect-Pi.ps1`. It makes sure
  the hotspot is on, waits for the Pi (up to 120 s), points the ssh alias at the
  Pi's current address and opens a shell.
  * `-Code` opens a VS Code Remote-SSH window on the Pi instead.
  * `-Command "…"` runs a single command.
  * `-NoConnect` only brings the link up and updates the alias.
* After that, plain `ssh pi-bt` and `scp file pi-bt:` work, and so does VS Code
  Remote-SSH with host `pi-bt` (or whatever `SshAlias` you set).
* The Pi's address comes from the hotspot's DHCP (e.g. 192.168.138.243) and can
  change. The launcher re-resolves it each time. The IPv6 link-local address
  always works while the link is up, even without DHCP. It is the EUI-64 of
  `PiBtAddress` plus `%<ifIndex of Bluetooth Network Connection>`, e.g.
  `AA:BB:CC:DD:EE:FF` → `fe80::a8bb:ccff:fedd:eeff%12`.

## Verified (2026-10-01)

* Pi reboot → NAP link up 8.5 s after kernel start → SSH reachable ~42 s after
  the reboot command, with no action on the PC.
* With `eth0` down: only route is `default via 192.168.138.1 dev pan0`;
  `ping 1.1.1.1` 0 % loss, DNS OK, `sudo apt update` OK.
* Hotspot switched off → watchdog switched it back on within 60 s → Pi re-dialed
  by itself.
* Re-deploying the Pi over the Bluetooth link itself works.
* Throughput about 125 KB/s (~1 Mbit/s); RTT to the internet 40–90 ms.

## Troubleshooting

| Symptom | Check |
|---|---|
| Launcher waits forever | On the Pi: `journalctl -u bt-autoconnect -f`. On the PC: is "Bluetooth Network Connection" Up? Is the hotspot on with Share over = Bluetooth? |
| Pi linked but no internet | Hotspot off (the Pi falls back to a PANU link). See `%LOCALAPPDATA%\bt-pi\watchdog.log`. The watchdog can't drive the Settings UI while the PC is locked. |
| `dial host failed (NAP: NotSupported …)` | Normal for up to 60 s after the PC toggles hotspot; the daemon refreshes BlueZ's SDP cache itself. |
| Re-pair from scratch | PC: `.\host\Pair-Pi.ps1 -Unpair`. Pi: `bluetoothctl remove <HostBtAddress>`. Restart `bt-autoconnect` (the Pi becomes discoverable), then run `.\host\Pair-Pi.ps1`. |
| Stop the PC from forcing the hotspot on | `Disable-ScheduledTask BtPi-Hotspot`, or `.\host\Setup-Host.ps1 -Uninstall` |

## Notes

* The Windows hotspot runs only while you're logged in. Without it, the Pi still
  links (PANU) for SSH over IPv6 link-local, but it has no internet.
* Manual ICS (e.g. Wi-Fi shared to the Pi over Ethernet) can't run at the same
  time as the Bluetooth hotspot, so `Setup-Host.ps1` turns it off. With a cable
  plugged in, the Pi's Ethernet is still reachable over its IPv6 link-local
  address (`fe80::…%<ifIndex of Ethernet>`).
* Security: SSH is key-only (`PasswordAuthentication no`); the Pi accepts
  pairing only from `HOST_MAC` and stops being discoverable once paired.
