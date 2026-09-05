#!/bin/bash
# Temporarily replace the host userspace; a proven timer restores stock boot.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rootfs=/var/lib/omarchy-k3-baremetal/rootfs
unit=omarchy-k3-boot-guard.service
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $rootfs/.omarchy-k3-host-ready ]]; then
  echo "Run as root on the K3 after stage-host.sh completes." >&2
  exit 1
fi
[[ ! -e /run/nextroot ]]
[[ $(cat /sys/kernel/kexec_loaded) == "0" ]]
[[ $(uname -r) == "6.18.3-generic" ]]
boot_hash=$(sha256sum /boot/env_k3.txt)
[[ ${boot_hash%% *} == "9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a" ]]
grep -q 'expired pid=.* mode=reboot' /var/lib/omarchy-k3-boot-trials/guard.log
! systemctl is-active --quiet "$unit"
chroot "$rootfs" /usr/bin/sshd -t
install -m644 "$port_dir/systemd/$unit" "/etc/systemd/system/$unit"
install -d "/run/systemd/system/$unit.d"
cat > "/run/systemd/system/$unit.d/10-trial.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/lib/omarchy-k3/boot-guard 300 reboot
EOF
systemctl daemon-reload
[[ $(systemctl show "$unit" -p SurviveFinalKillSignal --value) == "yes" ]]
cat /proc/sys/kernel/random/boot_id > /var/lib/omarchy-k3-boot-trials/host-trial-boot-id
date --iso-8601=seconds > /var/lib/omarchy-k3-boot-trials/host-trial-start

cleanup_error() {
  if [[ -L /run/nextroot && $(readlink /run/nextroot) == "$rootfs" ]]; then
    rm -f -- /run/nextroot
  fi
  systemctl stop "$unit" || true
}
trap cleanup_error ERR
ln -s "$rootfs" /run/nextroot
systemctl start "$unit"
systemctl is-active "$unit"
guard_pid=$(cat /run/omarchy-k3-boot-guard.pid)
kill -0 "$guard_pid"
echo "Starting the Arch host trial with recovery process $guard_pid and a 300-second deadline."
sync
systemctl soft-reboot
