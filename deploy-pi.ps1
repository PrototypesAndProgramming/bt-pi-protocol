# Copy pi/ to the Pi and run its installer.
#   .\deploy-pi.ps1 [-Target <ssh-alias>]
# Target defaults to DeployTarget, and the Pi's HOST_MAC is set from HostBtAddress,
# both from host\bt-pi.config.local.psd1.
# Prompts for the Pi's sudo password unless $env:PI_SUDO_PASS is set.
param([string]$Target)
. "$PSScriptRoot\host\BtPiConfig.ps1"
$cfg = Get-BtPiConfig -Require HostBtAddress
if (-not $Target) { $Target = $cfg.DeployTarget }
if (-not $Target) { throw "No -Target given and DeployTarget is not set in host\bt-pi.config.local.psd1" }
$pass = $env:PI_SUDO_PASS
if (-not $pass) {
    $sec = Read-Host "sudo password for $Target" -AsSecureString
    $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
ssh $Target "rm -rf /tmp/bt-pi"
scp -q -r "$PSScriptRoot\pi" "${Target}:/tmp/bt-pi"
if ($LASTEXITCODE -ne 0) { throw "scp to $Target failed" }
ssh $Target "sed -i 's/\r$//' /tmp/bt-pi/install.sh; echo '$pass' | sudo -S -p '' env HOST_MAC=$($cfg.HostBtAddress) bash /tmp/bt-pi/install.sh"
if ($LASTEXITCODE -ne 0) { throw "install.sh failed on $Target" }
