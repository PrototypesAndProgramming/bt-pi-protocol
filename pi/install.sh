#!/bin/bash
# Install bt-autoconnect on the Pi. Run from the directory containing this script:
#   sudo HOST_MAC=<PC Bluetooth address> ./install.sh
# HOST_MAC may be left out on reinstall to keep the one already installed.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

# Files may arrive from Windows with CRLF line endings.
find . -type f -exec sed -i 's/\r$//' {} +

export DEBIAN_FRONTEND=noninteractive
dpkg -s bluez bluez-tools python3-dbus python3-gi >/dev/null 2>&1 ||
    { apt-get update -qq; apt-get install -y -qq bluez bluez-tools python3-dbus python3-gi; }

BT_MAC=$(btmgmt --index 0 info 2>/dev/null | awk '/addr /{print tolower($2); exit}')
[ -n "$BT_MAC" ] || { echo "could not read Bluetooth address of hci0"; exit 1; }
echo "Pi Bluetooth address: $BT_MAC"

# Keep an existing config on reinstall; set HOST_MAC if one was given.
MAC_RE='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
CONF=/etc/default/bt-autoconnect
[ -f $CONF ] || install -m 0644 etc/default/bt-autoconnect $CONF
if [ -n "${HOST_MAC:-}" ]; then
    [[ $HOST_MAC =~ $MAC_RE ]] || { echo "HOST_MAC '$HOST_MAC' is not a Bluetooth address"; exit 1; }
    if grep -q '^HOST_MAC=' $CONF; then sed -i "s/^HOST_MAC=.*/HOST_MAC=$HOST_MAC/" $CONF
    else echo "HOST_MAC=$HOST_MAC" >> $CONF; fi
fi
grep -Eq "^HOST_MAC=${MAC_RE#^}" $CONF ||
    { echo "HOST_MAC is not set: run with HOST_MAC=<PC Bluetooth address>, or set it in $CONF"; exit 1; }
echo "Host Bluetooth address: $(sed -n 's/^HOST_MAC=//p' $CONF)"

[ -f /etc/bluetooth/main.conf.orig ] || cp -a /etc/bluetooth/main.conf /etc/bluetooth/main.conf.orig
install -m 0644 etc/bluetooth/main.conf /etc/bluetooth/main.conf

install -m 0755 usr/local/sbin/bt-autoconnect /usr/local/sbin/bt-autoconnect
install -m 0644 etc/systemd/system/bt-autoconnect.service /etc/systemd/system/
sed "s/@BT_MAC@/$BT_MAC/" etc/systemd/network/05-pan0.netdev > /etc/systemd/network/05-pan0.netdev
install -m 0644 etc/systemd/network/05-pan0.network etc/systemd/network/05-bnep.network /etc/systemd/network/
chmod 0644 /etc/systemd/network/05-pan0.netdev

install -m 0644 etc/sysctl.d/60-bt-pan.conf /etc/sysctl.d/
sysctl -q -p /etc/sysctl.d/60-bt-pan.conf

echo bnep > /etc/modules-load.d/bnep.conf
modprobe bnep

systemctl daemon-reload
networkctl reload
systemctl enable --now bluetooth.service
systemctl enable bt-autoconnect.service
# Restarting bluetoothd drops the PAN link -- and with it this SSH session when
# deploying over Bluetooth -- so do it detached, a few seconds from now.
if [ "${RESTART_BT:-1}" = 1 ]; then
    systemd-run --quiet --collect --on-active=3 --unit=bt-autoconnect-reinstall \
        /bin/sh -c 'systemctl restart bluetooth.service; systemctl restart bt-autoconnect.service; networkctl reconfigure pan0'
    echo "bluetooth + bt-autoconnect restart scheduled (PAN link will drop briefly)"
else
    systemctl restart bt-autoconnect.service
fi
echo "install OK"
