#!/bin/bash
# Select Arch for the next boot only after this physical desktop boot is healthy.
set -euo pipefail
if (( EUID != 0 )); then
  echo "Run as root on the physical Arch K3 host." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "arch" && $(uname -r) == "6.18.3-generic" ]]
[[ $(findmnt -no FSROOT /) == "/var/lib/omarchy-k3-baremetal/rootfs" ]]
[[ $(systemctl show -p Virtualization --value) == "" ]]
[[ $(systemctl show -p SoftRebootsCount --value) == "0" ]]
grep -qw 'omarchy.host_trial=1' /proc/cmdline

user_command() {
  runuser -u afonso -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"
}

host_ready() {
  systemctl is-active --quiet sshd.service systemd-networkd.service \
    systemd-resolved.service omarchy-k3-host-desktop.service || return 1
  user_command systemctl --user is-active --quiet graphical-session.target \
    omarchy-k3-wayvnc.service xdg-desktop-portal-hyprland.service elephant.service || return 1
  ip -4 route show default dev end1 | grep -q '^default via ' || return 1
  local signature
  signature=$(user_command hyprctl instances -j | jq -er 'first(.[]).instance') || return 1
  user_command hyprctl -i "$signature" monitors -j | \
    jq -e '.[] | select(.name == "K3-CLOUD" and .width == 1920 and .height == 1080 and .disabled == false)' >/dev/null || return 1
  python3 - <<'PY'
import socket
with socket.create_connection(('127.0.0.1', 5900), timeout=3) as connection:
  connection.settimeout(3)
  header = b''
  while len(header) < 12:
    data = connection.recv(12 - len(header))
    if not data:
      raise RuntimeError('VNC closed before its protocol header')
    header += data
  assert header == b'RFB 003.008\n', header
PY
}

for (( attempt = 0; attempt < 90; attempt++ )); do
  if host_ready; then
    break
  fi
  sleep 2
done
(( attempt < 90 ))

recovery_mount=/run/omarchy-k3-confirm-root
mounted_boot=0
mounted_recovery=0
cleanup() {
  if (( mounted_recovery )); then umount "$recovery_mount"; fi
  if (( mounted_boot )); then umount /boot; fi
}
trap cleanup EXIT
install -d -m700 "$recovery_mount"
! mountpoint -q "$recovery_mount"
mount /dev/disk/by-partuuid/7d6ad53b-30a7-4a45-a65b-b9340c0567e5 "$recovery_mount"
mounted_recovery=1
if ! mountpoint -q /boot; then
  mount /dev/disk/by-partuuid/dea91215-8a70-4045-82b5-33296f8be0ac /boot
  mounted_boot=1
fi
[[ $(findmnt -no PARTUUID /boot) == "dea91215-8a70-4045-82b5-33296f8be0ac" ]]
sha256sum -c "$recovery_mount/var/lib/omarchy-k3-boot-trials/physical-trial-kernel-sha256"

python3 - "$recovery_mount" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

recovery = Path(sys.argv[1])
records = recovery / 'var/lib/omarchy-k3-boot-trials'
trial_dir = recovery / 'var/lib/omarchy-k3-baremetal'
original = (records / 'env-before-physical-trial').read_bytes()
assert hashlib.sha256(original).hexdigest() == '9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a'
assert os.access(recovery / 'usr/local/lib/omarchy-k3/host-init', os.X_OK)
assert (trial_dir / 'rootfs/.omarchy-k3-host-ready').is_file()
lines = original.decode().splitlines()
trial = ('\n'.join(line + ' init=/usr/local/lib/omarchy-k3/host-init omarchy.host_trial=1 panic=30' if line.startswith('commonargs=') else line for line in lines) + '\n').encode()
assert hashlib.sha256(trial).hexdigest() == (records / 'physical-trial-env-hash').read_text().strip()
boot = Path('/boot/env_k3.txt')
assert boot.read_bytes() in (original, trial), 'Unexpected boot configuration; refusing to replace it'
with (trial_dir / 'armed').open('w') as marker:
  marker.write(Path('/proc/sys/kernel/random/boot_id').read_text())
  marker.flush()
  os.fsync(marker.fileno())
os.chmod(trial_dir / 'armed', 0o600)
os.sync()
pending = Path('/boot/.omarchy-env-confirmed')
with pending.open('x') as output:
  output.write(trial.decode())
  output.flush()
  os.fsync(output.fileno())
pending.chmod(0o644)
os.replace(pending, boot)
os.sync()
state = Path('/var/lib/omarchy-k3-boot-trials/confirmed-boot-id')
state.write_text(Path('/proc/sys/kernel/random/boot_id').read_text())
os.sync()
PY

if [[ -f /run/omarchy-k3-boot-guard.pid ]]; then
  read -r guard_pid < /run/omarchy-k3-boot-guard.pid
  if [[ $guard_pid =~ ^[0-9]+$ && -f /proc/$guard_pid/comm ]]; then
    [[ $(cat "/proc/$guard_pid/comm") == "boot-guard" ]]
    kill -TERM "$guard_pid"
  fi
fi
echo "Confirmed the physical Arch desktop; Arch is selected for the next boot and timed recovery is cancelled."
