#!/bin/bash
# Enable a native desktop container after package and CLI checks pass.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rootfs=/var/lib/machines/omarchy-k3
desktop=true
if [[ ${1:-} == "--cli-only" ]] && (( $# == 1 )); then
  desktop=false
elif (( $# > 0 )); then
  echo "Usage: $0 [--cli-only]" >&2
  exit 1
fi
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $rootfs/etc/omarchy-k3 ]]; then
  echo "Run as root on the K3 with the staged Omarchy profile." >&2
  exit 1
fi
(( $(chroot "$rootfs" id -u afonso) == 1000 ))
chroot "$rootfs" pacman -Q systemd openssh uwsm
if [[ $desktop == "true" ]]; then
  chroot "$rootfs" pacman -Q hyprland walker elephant omarchy-nvim wayvnc
  command -v socat >/dev/null || apt-get install --no-install-recommends -y socat
fi
install -d /usr/local/share/omarchy-k3
cp -a "$port_dir/." /usr/local/share/omarchy-k3/
install -Dm755 "$port_dir/wait-parent-wayland.sh" /usr/local/lib/omarchy-k3/wait-parent-wayland.sh
install -Dm755 "$port_dir/omarchy-shell" /usr/local/bin/omarchy-shell
install -Dm644 "$port_dir/systemd/omarchy-k3.service" /etc/systemd/system/omarchy-k3.service
install -Dm755 "$port_dir/omarchy-k3-session" "$rootfs/usr/local/bin/omarchy-k3-session"
install -Dm755 "$port_dir/omarchy-k3-output" "$rootfs/usr/local/bin/omarchy-k3-output"
install -Dm644 "$port_dir/systemd/omarchy-k3-desktop.service" "$rootfs/etc/systemd/system/omarchy-k3-desktop.service"
install -Dm755 "$port_dir/wait-cloud-output.sh" "$rootfs/usr/local/lib/omarchy-k3/wait-cloud-output.sh"
install -Dm644 "$port_dir/systemd/omarchy-k3-wayvnc.service" "$rootfs/etc/systemd/user/omarchy-k3-wayvnc.service"

# Networking remains managed by the Bianbu host in this shared network namespace.
systemctl --root="$rootfs" mask systemd-networkd.service systemd-networkd.socket \
  systemd-resolved.service NetworkManager.service iwd.service ufw.service
install -d "$rootfs/var/lib/systemd/linger" "$rootfs/etc/ssh/sshd_config.d"
touch "$rootfs/var/lib/systemd/linger/afonso"
cat > "$rootfs/etc/ssh/sshd_config.d/10-k3.conf" <<'EOF'
Port 2223
ListenAddress 127.0.0.1
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
cat > "$rootfs/etc/ssh/sshd_config.d/20-omarchy-env.conf" <<'EOF'
Match User afonso
  SetEnv OMARCHY_PATH=/home/afonso/.local/share/omarchy PATH=/home/afonso/.local/share/omarchy/bin:/home/afonso/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin EDITOR=nvim
Match all
EOF
install -d -m700 -o1000 -g1000 "$rootfs/home/afonso/.ssh"
install -m600 -o1000 -g1000 /home/bianbu/.ssh/authorized_keys "$rootfs/home/afonso/.ssh/authorized_keys"
if [[ $(machinectl show omarchy-k3 --property=RootDirectory --value 2>/dev/null) == "$rootfs" ]]; then
  systemd-run --machine=omarchy-k3 --wait --pipe --collect \
    /bin/bash -euo pipefail -c 'ssh-keygen -A; install -d -m755 /run/sshd; /usr/bin/sshd -t'
else
  systemd-nspawn --quiet --console=pipe --register=no --directory="$rootfs" \
    /bin/bash -euo pipefail -c 'ssh-keygen -A; install -d -m755 /run/sshd; /usr/bin/sshd -t'
fi
systemctl --root="$rootfs" enable sshd.service

# Replace the initial user-unit prototype with a PAM login session. UWSM needs
# login session metadata even when its compositor uses the cloud Wayland socket.
rm -f "$rootfs/home/afonso/.config/systemd/user/default.target.wants/omarchy-k3-desktop.service"
rm -f "$rootfs/etc/systemd/user/omarchy-k3-desktop.service"
if [[ $desktop == "true" ]]; then
  systemctl --root="$rootfs" enable omarchy-k3-desktop.service
fi
cat > "$rootfs/home/afonso/.config/hypr/k3.conf" <<'EOF'
exec-once = uwsm finalize WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
source = ~/.config/hypr/hyprland.conf
monitor = K3-CLOUD,1920x1080@60,0x0,1
monitor = WAYLAND-1,disable
EOF
chown 1000:1000 "$rootfs/home/afonso/.config/hypr/k3.conf"
systemctl daemon-reload
systemctl enable --now omarchy-k3.service
# The nspawn notification precedes the guest D-Bus socket becoming usable.
guest_ready=false
for (( attempt = 0; attempt < 60; attempt++ )); do
  if systemctl --machine=omarchy-k3 is-active --quiet dbus.service 2>/dev/null; then
    guest_ready=true
    break
  fi
  sleep 1
done
[[ $guest_ready == "true" ]] || { echo "The Arch system bus did not become ready." >&2; exit 1; }
systemd-run --machine=omarchy-k3 --wait --pipe --collect /usr/bin/sshd -t
systemctl --machine=omarchy-k3 reload-or-restart sshd.service
if [[ $desktop == "true" ]]; then
  systemctl --machine=omarchy-k3 daemon-reload
  systemctl --machine=omarchy-k3 start omarchy-k3-desktop.service
  session_ready=false
  for (( attempt = 0; attempt < 60; attempt++ )); do
    if systemctl --user --machine=afonso@omarchy-k3 is-active --quiet graphical-session.target 2>/dev/null; then
      session_ready=true
      break
    fi
    sleep 1
  done
  [[ $session_ready == "true" ]] || { echo "The graphical session did not become ready." >&2; exit 1; }
  systemctl --user --machine=afonso@omarchy-k3 daemon-reload
  systemctl --user --machine=afonso@omarchy-k3 enable --now omarchy-k3-wayvnc.service
  systemd-run --user --machine=afonso@omarchy-k3 --wait --pipe --collect \
    /bin/bash /run/omarchy-port/configure-session.sh
  # Retain the provider's original port and cloud authentication path.
  install -Dm644 "$port_dir/systemd/cloud-vnc-proxy.conf" /etc/systemd/system/wayvnc.service.d/50-omarchy-k3.conf
  systemctl daemon-reload
  systemctl restart wayvnc.service
fi
