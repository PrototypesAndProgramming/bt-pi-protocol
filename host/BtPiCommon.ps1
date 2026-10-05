# Shared helpers for the host-side bt-pi scripts (dot-source this file).

. "$PSScriptRoot\BtPiConfig.ps1"

function Get-BtPanAdapter {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like "Bluetooth Device (Personal Area Network)*" } |
        Select-Object -First 1
}

function ConvertTo-BtAddress([string]$Mac) {
    [Convert]::ToUInt64(($Mac -replace '[:-]', ''), 16)
}

# The Pi's IPv6 link-local address on the Bluetooth link: EUI-64 of its BT
# address (pan0 on the Pi uses the BT address as its MAC).
function Get-PiLinkLocal([string]$Mac, [int]$IfIndex) {
    $b = $Mac -split '[:-]' | ForEach-Object { [Convert]::ToInt32($_, 16) }
    "fe80::{0:x}:{1:x}:{2:x}:{3:x}%{4}" -f ((($b[0] -bxor 2) -shl 8) + $b[1]), (($b[2] -shl 8) + 0xff),
        (0xfe00 + $b[3]), (($b[4] -shl 8) + $b[5]), $IfIndex
}

# ---- WinRT plumbing ---------------------------------------------------------
# Windows PowerShell 5.1 projects WinRT types natively; async operations are
# awaited through WindowsRuntimeSystemExtensions.AsTask<T>.

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

$script:AsTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRT($Operation, [Type]$ResultType, [int]$TimeoutSec = 60) {
    $task = $script:AsTaskOp.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutSec * 1000)) { throw "WinRT operation timed out after ${TimeoutSec}s" }
    $task.Result
}

# The PairingRequested callback fires on a WinRT thread pool thread, where a
# PowerShell scriptblock can't run. This shim accepts the request via
# reflection, so it compiles without any WinRT references.
if (-not ("BtPi.PairingAcceptor" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Reflection;
namespace BtPi {
    public class PairingAcceptor {
        public string Pin = "0000";
        public string LastKind;
        public void Handle(object sender, object args) {
            Type t = args.GetType();
            LastKind = t.GetProperty("PairingKind").GetValue(args, null).ToString();
            if (LastKind == "ProvidePin")
                t.GetMethod("Accept", new[] { typeof(string) }).Invoke(args, new object[] { Pin });
            else
                t.GetMethod("Accept", Type.EmptyTypes).Invoke(args, null);
        }
        public Delegate For(Type handlerType) {
            return Delegate.CreateDelegate(handlerType, this, GetType().GetMethod("Handle"));
        }
    }
}
'@
}

function Get-BtDeviceInfo([string]$Mac) {
    $op = [Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync((ConvertTo-BtAddress $Mac))
    $dev = Wait-WinRT $op ([Windows.Devices.Bluetooth.BluetoothDevice])
    if ($dev) { $dev.DeviceInformation }
}

function Test-BtPaired([string]$Mac) {
    $di = Get-BtDeviceInfo $Mac
    [bool]($di -and $di.Pairing.IsPaired)
}

# Returns a DevicePairingResultStatus name: Paired, AlreadyPaired, Failed, ...
function Invoke-BtPair([string]$Mac) {
    $di = Get-BtDeviceInfo $Mac
    if (-not $di) { return "NotFound" }
    if ($di.Pairing.IsPaired) { return "AlreadyPaired" }
    $custom = $di.Pairing.Custom
    $acceptor = New-Object BtPi.PairingAcceptor
    $handlerType = $custom.GetType().GetEvent("PairingRequested").EventHandlerType
    $null = $custom.add_PairingRequested($acceptor.For($handlerType))
    $kinds = [Windows.Devices.Enumeration.DevicePairingKinds]'ConfirmOnly, ConfirmPinMatch, DisplayPin, ProvidePin'
    $op = $custom.PairAsync($kinds, [Windows.Devices.Enumeration.DevicePairingProtectionLevel]::Default)
    $res = Wait-WinRT $op ([Windows.Devices.Enumeration.DevicePairingResult]) 90
    if ($acceptor.LastKind) { Write-Verbose "pairing kind: $($acceptor.LastKind)" }
    "$($res.Status)"
}

# ---- Mobile hotspot over Bluetooth -------------------------------------------
# Windows only shares its internet over Bluetooth (as a PAN NAP with DHCP +
# NAT) through Mobile hotspot with "Share over: Bluetooth". The public
# tethering API always starts the Wi-Fi medium on Windows 10, so the hotspot is
# switched on through the Settings page with UI Automation instead.

$null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
$null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]

function Get-BtTetheringManager {
    $prof = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $prof) { return $null }   # no internet: nothing to share
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($prof)
}

# On/Medium of the hotspot. A Wi-Fi hotspot runs on a Wi-Fi Direct virtual
# adapter; otherwise it is the Bluetooth one. HostIp is the host's address on
# the Bluetooth link (ICS's manual x.x.x.1), only visible while the Pi is linked.
function Get-BtHotspotStatus {
    $tm = Get-BtTetheringManager
    $on = [bool]($tm -and "$($tm.TetheringOperationalState)" -eq 'On')
    $wifiDirect = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -like 'Microsoft Wi-Fi Direct Virtual Adapter*' -and $_.Status -eq 'Up' }
    $bt = Get-BtPanAdapter
    $ip = if ($bt) {
        Get-NetIPAddress -InterfaceIndex $bt.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Manual' -and $_.IPAddress -like '*.1' } |
            Select-Object -First 1 -ExpandProperty IPAddress
    }
    [pscustomobject]@{
        On       = $on
        Medium   = if (-not $on) { 'Off' } elseif ($wifiDirect -and -not $ip) { 'WiFi' } else { 'Bluetooth' }
        HostIp   = $ip
        Internet = [bool]$tm
    }
}

function Invoke-HotspotSettingsUi([switch]$On, [switch]$Off) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AE = [Windows.Automation.AutomationElement]
    function ById($root, $id) {
        $root.FindAll([Windows.Automation.TreeScope]::Descendants,
            (New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)))
    }
    function Wait-For([scriptblock]$probe, [int]$sec = 15) {
        $deadline = (Get-Date).AddSeconds($sec)
        do { $r = & $probe; if ($r) { return $r }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
        $null
    }
    $mainId = 'SystemSettings_Connections_InternetSharingEnabled_ToggleSwitch'

    Start-Process "ms-settings:network-mobilehotspot"
    $win = Wait-For {
        $AE::RootElement.FindAll([Windows.Automation.TreeScope]::Children,
            (New-Object Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'ApplicationFrameWindow'))) |
            Where-Object { (ById $_ $mainId).Count -gt 0 } | Select-Object -First 1
    }
    if (-not $win) { throw "Mobile hotspot settings page did not appear (is the session locked?)" }
    try {
        $toggle = (ById $win $mainId)[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        $isOn = { "$($toggle.Current.ToggleState)" -eq 'On' }

        # Power saving: never auto-off (a Bluetooth client doesn't count as "connected").
        foreach ($e in ById $win 'SystemSettings_Connections_InternetSharingAutoTurnOff_ToggleSwitch') {
            $p = $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
            if ("$($p.Current.ToggleState)" -eq 'On') { $p.Toggle() }
        }
        if ($Off) {
            if (& $isOn) { $toggle.Toggle() }
            return
        }
        $radios = ById $win 'SystemSettings_Connections_InternetSharingRadioType_RadioButton'
        $btRadio = $radios | Where-Object { $_.Current.Name -match 'Bluetooth' } | Select-Object -First 1
        if (-not $btRadio) { throw "No 'Share over: Bluetooth' option on the Mobile hotspot page" }
        $sel = $btRadio.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        if (-not $sel.Current.IsSelected) {
            if (& $isOn) { $toggle.Toggle(); $null = Wait-For { -not (& $isOn) } 20 }
            $sel.Select()
            Start-Sleep -Milliseconds 500
        }
        if ($On -and -not (& $isOn)) { $toggle.Toggle() }
        $null = Wait-For { & $isOn } 20
    } finally {
        try { $win.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close() } catch {}
    }
}

# Make sure the hotspot is on and shared over Bluetooth. Returns the status.
function Enable-BtHotspot([int]$TimeoutSec = 30) {
    try { [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::DisableNoConnectionsTimeout() } catch {}
    $s = Get-BtHotspotStatus
    if ($s.Medium -eq 'Bluetooth') { return $s }
    if (-not $s.Internet) { Write-Warning "No internet connection to share"; return $s }
    # UI Automation runs in a fresh process: some PowerShell hosts can't see the Settings window.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '$PSScriptRoot\BtPiCommon.ps1'; Invoke-HotspotSettingsUi -On"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep 1
        $s = Get-BtHotspotStatus
    } while ($s.Medium -ne 'Bluetooth' -and (Get-Date) -lt $deadline)
    $s
}

function Invoke-BtUnpair([string]$Mac) {
    $di = Get-BtDeviceInfo $Mac
    if (-not $di) { return "NotFound" }
    $res = Wait-WinRT ($di.Pairing.UnpairAsync()) ([Windows.Devices.Enumeration.DeviceUnpairingResult])
    "$($res.Status)"
}
