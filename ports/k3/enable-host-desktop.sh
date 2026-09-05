#!/bin/bash
# Install the direct DRM session and confirm future boots on the tested K3.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (( EUID != 0 )); then
  echo "Run as root after the physical Arch CLI trial succeeds." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "arch" && $(uname -m) == "riscv64" ]]
[[ $(findmnt -no FSROOT /) == "/var/lib/omarchy-k3-baremetal/rootfs" ]]
[[ $(systemctl show -p SoftRebootsCount --value) == "0" ]]
[[ -f /opt/spacemit/env && -x /usr/bin/socat && -x /usr/bin/Hyprland ]]
[[ $(id -u afonso) == "1000" ]]
install -m755 "$port_dir/omarchy-k3-host-session" /usr/local/bin/omarchy-k3-host-session
install -m755 "$port_dir/omarchy-k3-output" /usr/local/bin/omarchy-k3-output
install -m755 "$port_dir/confirm-host-boot.sh" /usr/local/lib/omarchy-k3/confirm-host-boot.sh
for name in host-desktop cloud-vnc confirm-host-boot; do
  install -m644 "$port_dir/systemd/omarchy-k3-$name.service" "/etc/systemd/system/omarchy-k3-$name.service"
done
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/omarchy-k3-host-desktop.service \
  /etc/systemd/system/omarchy-k3-cloud-vnc.service \
  /etc/systemd/system/omarchy-k3-confirm-host-boot.service
systemctl disable --now omarchy-k3-desktop.service
systemctl enable --now omarchy-k3-host-desktop.service omarchy-k3-cloud-vnc.service
systemctl enable --now omarchy-k3-confirm-host-boot.service
systemctl is-active omarchy-k3-confirm-host-boot.service
