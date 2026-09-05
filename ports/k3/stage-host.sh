#!/bin/bash
# Prepare an isolated filesystem for a guarded Arch host trial on the K3.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root=/var/lib/machines/omarchy-k3
trial_dir=/var/lib/omarchy-k3-baremetal
rootfs="$trial_dir/rootfs"

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $source_root/.omarchy-k3-rootfs ]]; then
  echo "Run as root on the Bianbu K3 with the existing Arch staging filesystem." >&2
  exit 1
fi
[[ ! -e /run/nextroot ]]
if (( $# == 0 )); then
  [[ ! -e $trial_dir ]]
elif (( $# == 1 )) && [[ $1 == "--resume" ]]; then
  [[ -f $rootfs/.omarchy-k3-host-trial && ! -e $rootfs/.omarchy-k3-host-ready ]]
else
  echo "Usage: $0 [--resume]" >&2
  exit 1
fi
[[ $(uname -r) == "6.18.3-generic" ]]
[[ -x /usr/lib/systemd/systemd ]]
[[ -f $port_dir/boot-guard.c ]]
[[ -f $port_dir/systemd/omarchy-k3-boot-guard.service ]]
available_kib=$(df --output=avail /var/lib | tail -1)
(( available_kib > 20000000 ))
install -d -m700 "$trial_dir"
install -d -m755 "$rootfs"
echo "Copying Arch into the separate host trial filesystem."
rsync -aHAXx --numeric-ids \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/var/tmp/*' --exclude='/var/cache/pacman/pkg/*' \
  --exclude='/home/afonso/.cache/*' --exclude='/home/afonso/go/pkg/*' \
  --exclude='/home/afonso/.cargo/registry/*' --exclude='/home/afonso/.cargo/git/*' \
  "$source_root/" "$rootfs/"
touch "$rootfs/.omarchy-k3-host-trial"
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
dns = subprocess.check_output(['nmcli', '-g', 'IP4.DNS', 'device', 'show', 'end1'], text=True)
dns = dns.replace('|', ' ').replace(',', ' ').split()
dns = [str(ipaddress.ip_address(value)) for value in dns if value]
network = root / 'etc/systemd/network'
network.mkdir(parents=True, exist_ok=True)
settings = f'[Match]\nMACAddress={mac}\n\n[Link]\nRequiredForOnline=no\n\n[Network]\nAddress={cidr}\nGateway={gateway}\nIPv6AcceptRA=yes\n'
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
systemctl --root="$rootfs" disable omarchy-k3-desktop.service
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
