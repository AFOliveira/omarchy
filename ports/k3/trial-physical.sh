#!/bin/bash
# One physical Arch boot with the vendor kernel, followed by timed stock boot.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
trial_dir=/var/lib/omarchy-k3-baremetal
records=/var/lib/omarchy-k3-boot-trials
rootfs="$trial_dir/rootfs"
stock_hash=9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ $(uname -r) != "6.18.3-generic" ]]; then
  echo "Run as root on the Bianbu K3 with its known-working vendor kernel." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "bianbu" ]]
[[ -f $rootfs/.omarchy-k3-host-ready && ! -e $trial_dir/armed && ! -e /run/nextroot ]]
[[ $(cat /sys/kernel/kexec_loaded) == "0" ]]
[[ $(findmnt -no PARTUUID /boot) == "dea91215-8a70-4045-82b5-33296f8be0ac" ]]
boot_hash=$(sha256sum /boot/env_k3.txt)
[[ ${boot_hash%% *} == "$stock_hash" ]]
grep -q 'expired pid=.* mode=reboot' "$records/guard.log"
! systemctl is-active --quiet omarchy-k3-boot-guard.service
[[ -x /usr/bin/switch_root ]]
chroot "$rootfs" /usr/bin/sshd -t
chroot "$rootfs" /usr/bin/systemctl --version

install -d /usr/local/lib/omarchy-k3
for program in host-init boot-guard; do
  gcc -O2 -Wall -Wextra -Werror -static -march=rv64gc -mabi=lp64d \
    "$port_dir/$program.c" -o "/usr/local/lib/omarchy-k3/$program.new"
  chmod 755 "/usr/local/lib/omarchy-k3/$program.new"
  mv -f "/usr/local/lib/omarchy-k3/$program.new" "/usr/local/lib/omarchy-k3/$program"
done
set +e
/usr/local/lib/omarchy-k3/host-init
init_status=$?
set -e
(( init_status == 2 ))
[[ ! -e /boot/.omarchy-env-restore ]]
cp -a /boot/env_k3.txt "$records/env-before-physical-trial"
sha256sum /boot/vmlinuz-6.18.3-generic /boot/initrd.img-6.18.3-generic \
  > "$records/physical-trial-kernel-sha256"
cat /proc/sys/kernel/random/boot_id > "$records/physical-trial-previous-boot-id"

# This second restorer covers a vendor-initramfs fallback to Bianbu's init.
cat > /usr/local/lib/omarchy-k3/restore-physical-trial <<'EOF'
#!/bin/bash
set -euo pipefail
records=/var/lib/omarchy-k3-boot-trials
current=$(sha256sum /boot/env_k3.txt)
saved=$(sha256sum "$records/env-before-physical-trial")
[[ ${saved%% *} == "9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a" ]]
if [[ ${current%% *} == "$(cat "$records/physical-trial-env-hash")" ]]; then
  cp "$records/env-before-physical-trial" /boot/.omarchy-env-fallback
  sync /boot/.omarchy-env-fallback
  mv /boot/.omarchy-env-fallback /boot/env_k3.txt
  sync /boot
elif [[ ${current%% *} != "${saved%% *}" ]]; then
  echo "Boot selection changed unexpectedly; refusing to overwrite it." >&2
  exit 1
fi
rm -f /var/lib/omarchy-k3-baremetal/armed
EOF
chmod 755 /usr/local/lib/omarchy-k3/restore-physical-trial
cat > /etc/systemd/system/omarchy-k3-restore-physical-trial.service <<'EOF'
[Unit]
Description=Restore the normal boot after a temporary Arch host trial
ConditionKernelCommandLine=omarchy.host_trial=1
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/omarchy-k3/restore-physical-trial

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable omarchy-k3-restore-physical-trial.service

python3 - <<'PY'
import hashlib
import os
from pathlib import Path

boot = Path('/boot/env_k3.txt')
original = boot.read_text()
assert hashlib.sha256(original.encode()).hexdigest() == '9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a'
lines = original.splitlines()
assert sum(line.startswith('commonargs=') for line in lines) == 1
trial = '\n'.join(line + ' init=/usr/local/lib/omarchy-k3/host-init omarchy.host_trial=1 panic=30' if line.startswith('commonargs=') else line for line in lines) + '\n'
Path('/var/lib/omarchy-k3-boot-trials/physical-trial-env-hash').write_text(hashlib.sha256(trial.encode()).hexdigest() + '\n')
Path('/var/lib/omarchy-k3-baremetal/armed').touch(mode=0o600)
pending = boot.with_name('.omarchy-env-trial')
with pending.open('x') as output:
  output.write(trial)
  output.flush()
  os.fsync(output.fileno())
pending.chmod(0o644)
os.replace(pending, boot)
os.sync()
PY
echo "Starting a physical Arch host trial; the startup program restores stock boot and arms 600-second recovery."
systemctl reboot
