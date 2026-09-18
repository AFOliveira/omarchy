#!/bin/bash
# Prepare an isolated filesystem for a guarded Arch host trial on the K3.
#   stage-host.sh                     copy the Arch staging container
#   stage-host.sh --resume            continue an interrupted container copy
#   stage-host.sh --from-host DEST    copy a working physical Arch K3 host over SSH
# K3_SSH_CONFIG selects an ssh_config for DEST; K3_RSYNC_EXCLUDE_FROM adds excludes.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root=/var/lib/machines/omarchy-k3
trial_dir=/var/lib/omarchy-k3-baremetal
rootfs="$trial_dir/rootfs"
mode=container

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the Bianbu K3." >&2
  exit 1
fi
[[ ! -e /run/nextroot && ! -e $trial_dir/armed ]]
if (( $# == 0 )); then
  [[ ! -e $trial_dir ]]
elif (( $# == 1 )) && [[ $1 == "--resume" ]]; then
  [[ -f $rootfs/.omarchy-k3-host-trial && ! -e $rootfs/.omarchy-k3-host-ready ]]
elif (( $# == 2 )) && [[ $1 == "--from-host" ]]; then
  mode=host
  source_host=$2
  # A partial earlier copy may exist; a prepared root must not be overwritten.
  [[ ! -e $rootfs/.omarchy-k3-host-ready || ! -e $rootfs/.omarchy-k3-migrated ]]
else
  echo "Usage: $0 [--resume | --from-host SSH_DESTINATION]" >&2
  exit 1
fi
if [[ $mode == "container" && ! -f $source_root/.omarchy-k3-rootfs ]]; then
  echo "The Arch staging container is missing; use --from-host to copy an existing host." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "bianbu" ]]
[[ $(uname -r) == "6.18.3-generic" ]]
[[ -x /usr/lib/systemd/systemd ]]
[[ -f $port_dir/boot-guard.c ]]
[[ -f $port_dir/systemd/omarchy-k3-boot-guard.service ]]

# Record this allocation's partitions. Each provider allocation has its own IDs.
uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
boot_partuuid=$(findmnt -no PARTUUID /boot)
bianbu_partuuid=$(findmnt -no PARTUUID /)
[[ $boot_partuuid =~ $uuid_pattern && $bianbu_partuuid =~ $uuid_pattern && $boot_partuuid != "$bianbu_partuuid" ]]
[[ -f /boot/env_k3.txt ]]

available_kib=$(df --output=avail /var/lib | tail -1)
(( available_kib > 20000000 ))
install -d -m700 "$trial_dir"
install -d -m755 "$rootfs"
excludes=(
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*'
  --exclude='/tmp/*' --exclude='/var/tmp/*' --exclude='/var/cache/pacman/pkg/*'
  --exclude='/home/afonso/.cache/*' --exclude='/home/afonso/go/pkg/*'
  --exclude='/home/afonso/.cargo/registry/*' --exclude='/home/afonso/.cargo/git/*'
)
if [[ -n ${K3_RSYNC_EXCLUDE_FROM:-} ]]; then
  excludes+=(--exclude-from="$K3_RSYNC_EXCLUDE_FROM")
fi
if [[ $mode == "container" ]]; then
  echo "Copying Arch into the separate host trial filesystem."
  rsync -aHAXx --numeric-ids "${excludes[@]}" "$source_root/" "$rootfs/"
else
  ssh_command=(ssh)
  if [[ -n ${K3_SSH_CONFIG:-} ]]; then
    ssh_command+=(-F "$K3_SSH_CONFIG")
  fi
  # The source must be a booted physical Arch K3 host, not a container or Bianbu.
  "${ssh_command[@]}" "$source_host" \
    'source /etc/os-release && [[ $ID == "arch" && -f /.omarchy-k3-rootfs && $(findmnt -no FSROOT /) == "/var/lib/omarchy-k3-baremetal/rootfs" ]]'
  echo "Copying the physical Arch host from $source_host."
  # Host identity and board records belong to the source allocation.
  rsync -aHAXx --numeric-ids "${excludes[@]}" \
    --exclude='/var/log/journal/*' --exclude='/var/lib/systemd/random-seed' \
    --exclude='/var/lib/omarchy-k3-boot-trials/*' \
    -e "${ssh_command[*]}" "$source_host:/" "$rootfs/"
  [[ -f $rootfs/.omarchy-k3-rootfs && -x $rootfs/usr/lib/systemd/systemd ]]
  rm -f "$rootfs/.omarchy-k3-host-ready" "$rootfs/etc/systemd/network/10-k3-trial.network"
  rm -f "$rootfs/etc/machine-id"
  systemd-machine-id-setup --root="$rootfs"
  touch "$rootfs/.omarchy-k3-migrated"
fi
touch "$rootfs/.omarchy-k3-host-trial"
printf 'BOOT_PARTUUID=%s\nBIANBU_PARTUUID=%s\n' "$boot_partuuid" "$bianbu_partuuid" \
  > "$rootfs/etc/omarchy-k3-boot-layout"
for device in null:3 zero:5 random:8 urandom:9; do
  if [[ ! -e $rootfs/dev/${device%%:*} ]]; then
    mknod -m666 "$rootfs/dev/${device%%:*}" c 1 "${device##*:}"
  fi
done

install -d "$rootfs/usr/lib/modules" "$rootfs/usr/lib/firmware"
rsync -a "/usr/lib/modules/$(uname -r)/" "$rootfs/usr/lib/modules/$(uname -r)/"
rsync -a /usr/lib/firmware/ "$rootfs/usr/lib/firmware/"

# Keep this first trial on the address already assigned to this board. A later
# persistent installation must validate DHCP and the provider's lease behavior.
python3 - "$rootfs" <<'PY'
import ipaddress
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
links = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show', 'dev', 'end1']))
address = next(a for a in links[0]['addr_info'] if a['scope'] == 'global')
cidr = str(ipaddress.ip_interface(f"{address['local']}/{address['prefixlen']}"))
routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'default', 'dev', 'end1']))
gateway = str(ipaddress.ip_address(routes[0]['gateway']))
mac = Path('/sys/class/net/end1/address').read_text().strip()
assert len(mac.split(':')) == 6 and all(len(p) == 2 and int(p, 16) >= 0 for p in mac.split(':'))
# mac is recorded for the boot-time device tree, not for interface matching
dns = subprocess.check_output(['nmcli', '-g', 'IP4.DNS', 'device', 'show', 'end1'], text=True)
dns = dns.replace('|', ' ').replace(',', ' ').split()
dns = [str(ipaddress.ip_address(value)) for value in dns if value]
network = root / 'etc/systemd/network'
network.mkdir(parents=True, exist_ok=True)
# Match the board's single wired interface by name rather than by address:
# its kernel name and its MAC both depend on the kernel and the boot loader.
settings = f'[Match]\nName=e*\n\n[Link]\nRequiredForOnline=routable\n\n[Network]\nAddress={cidr}\nGateway={gateway}\nIPv6AcceptRA=yes\n'
settings += ''.join(f'DNS={value}\n' for value in dns)
(network / '10-k3-trial.network').write_text(settings)
resolv = root / 'etc/resolv.conf'
if resolv.exists() or resolv.is_symlink():
  resolv.unlink()
resolv.symlink_to('/run/systemd/resolve/stub-resolv.conf')
(root / 'etc/hostname').write_text('omarchy-k3-host\n')
# Preserve root's existing authentication state without exposing any hash.
host_root = next(line for line in Path('/etc/shadow').read_text().splitlines() if line.startswith('root:'))
shadow = root / 'etc/shadow'
lines = shadow.read_text().splitlines()
shadow.write_text('\n'.join(host_root if line.startswith('root:') else line for line in lines) + '\n')
shadow.chmod(0o600)
PY

systemctl --root="$rootfs" unmask systemd-networkd.service systemd-networkd.socket systemd-resolved.service
systemctl --root="$rootfs" enable systemd-networkd.service systemd-resolved.service sshd.service
if [[ $mode == "container" ]]; then
  systemctl --root="$rootfs" disable omarchy-k3-desktop.service
elif [[ -f $rootfs/usr/local/lib/omarchy-k3/confirm-host-boot.sh ]]; then
  # A migrated host keeps its enabled desktop; refresh the installed port files
  # so its boot confirmation uses this allocation's recorded partitions.
  install -m755 "$port_dir/confirm-host-boot.sh" "$rootfs/usr/local/lib/omarchy-k3/confirm-host-boot.sh"
  install -m755 "$port_dir/omarchy-k3-host-session" "$rootfs/usr/local/bin/omarchy-k3-host-session"
  install -m755 "$port_dir/omarchy-k3-output" "$rootfs/usr/local/bin/omarchy-k3-output"
  for name in host-desktop cloud-vnc confirm-host-boot; do
    install -m644 "$port_dir/systemd/omarchy-k3-$name.service" "$rootfs/etc/systemd/system/omarchy-k3-$name.service"
  done
fi
install -d -m700 "$rootfs/root/.ssh"
install -m600 /root/.ssh/authorized_keys "$rootfs/root/.ssh/authorized_keys"
for key in /etc/ssh/ssh_host_*; do
  [[ -f $key ]] || continue
  cp -a "$key" "$rootfs/etc/ssh/"
done
cat > "$rootfs/etc/ssh/sshd_config.d/10-k3.conf" <<'EOF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
install -d "$rootfs/etc/systemd/system/sshd.service.d" "$rootfs/run/sshd"
cat > "$rootfs/etc/systemd/system/sshd.service.d/10-runtime.conf" <<'EOF'
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
EOF

install -d -m700 "$rootfs/var/lib/omarchy-k3-boot-trials"
install -d -m755 "$rootfs/usr/local/lib/omarchy-k3"
gcc -O2 -Wall -Wextra -Werror -static -march=rv64gc -mabi=lp64d \
  "$port_dir/boot-guard.c" -o "$rootfs/usr/local/lib/omarchy-k3/boot-guard"
install -m644 "$port_dir/systemd/omarchy-k3-boot-guard.service" \
  "$rootfs/etc/systemd/system/omarchy-k3-boot-guard.service"
chroot "$rootfs" /usr/bin/sshd -t
chroot "$rootfs" /usr/bin/systemctl --version
chroot "$rootfs" /usr/bin/bash -c '[[ -x /usr/lib/systemd/systemd-networkd && -x /usr/lib/systemd/systemd-resolved ]]'
touch "$rootfs/.omarchy-k3-host-ready"
echo "Prepared $rootfs; no boot selection or running host service was changed."
