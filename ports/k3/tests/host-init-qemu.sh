#!/bin/bash
# Exercise the actual startup wrapper, switch_root, and recovery timer in QEMU.
# Copy the K3 switch_root executable and its two runtime libraries into test_dir
# first. The emulated kernel must have ext4 and virtio-blk built in.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
test_dir="$repo_dir/build/host-init-test"
kernel=${K3_TEST_KERNEL:-"$repo_dir/build/qemu-kernel/arch/riscv/boot/Image"}
mkdir -p "$test_dir"
for file in switch_root libc.so.6 ld-linux-riscv64-lp64d.so.1; do
  [[ -f $test_dir/$file ]]
done

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$port_dir:/src:ro" -v "$test_dir:/out" \
  "${K3_BUILD_IMAGE:-omarchy-k3-builder:trixie}" bash -euo pipefail -c '
  common=(-O2 -static -march=rv64gc -mabi=lp64d -Wall -Wextra -Werror)
  riscv64-linux-gnu-gcc "${common[@]}" /src/host-init.c -o /out/host-init
  riscv64-linux-gnu-gcc "${common[@]}" -DBOOT_DEVICE=\"/dev/vdb\" -DGUARD_SECONDS=\"30\" /src/host-init.c -o /out/host-init-qemu
  riscv64-linux-gnu-gcc "${common[@]}" /src/boot-guard.c -o /out/boot-guard
  riscv64-linux-gnu-gcc "${common[@]}" /src/tests/host-init-fixture.c -o /out/fixture
  '

for scenario in success missing-root; do
  python3 - "$test_dir" "$scenario" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys

test = Path(sys.argv[1])
scenario = sys.argv[2]
tree = test / f'{scenario}-tree'
if tree.exists():
  shutil.rmtree(tree)
tree.mkdir()
arch = tree / 'var/lib/omarchy-k3-baremetal/rootfs'
for root in (tree, arch):
  for path in ('dev', 'proc', 'sys', 'run', 'boot', 'sbin', 'usr/bin', 'usr/lib/systemd', 'usr/local/lib/omarchy-k3', 'var/lib/omarchy-k3-boot-trials'):
    (root / path).mkdir(parents=True, exist_ok=True)
shutil.copy2(test / 'fixture', tree / 'bootstrap')
shutil.copy2(test / 'fixture', tree / 'sbin/init')
shutil.copy2(test / 'fixture', arch / 'usr/lib/systemd/systemd')
(arch / 'arch-fixture').touch()
if scenario == 'success':
  (arch / '.omarchy-k3-host-ready').touch()
(arch.parent / 'armed').touch()
shutil.copy2(test / 'host-init-qemu', tree / 'usr/local/lib/omarchy-k3/host-init')
shutil.copy2(test / 'boot-guard', tree / 'usr/local/lib/omarchy-k3/boot-guard')
shutil.copy2(test / 'switch_root', tree / 'usr/bin/switch_root')
(tree / 'lib/riscv64-linux-gnu').mkdir(parents=True)
shutil.copy2(test / 'libc.so.6', tree / 'lib/riscv64-linux-gnu/libc.so.6')
shutil.copy2(test / 'ld-linux-riscv64-lp64d.so.1', tree / 'lib/ld-linux-riscv64-lp64d.so.1')
boot_tree = test / f'{scenario}-boot-tree'
boot_tree.mkdir(exist_ok=True)
(boot_tree / 'env_k3.txt').write_text('commonargs=setenv bootargs omarchy.host_trial=1\n')
for name, source, size in (('root', tree, 128 << 20), ('boot', boot_tree, 32 << 20)):
  image = test / f'{scenario}-{name}.ext4'
  with image.open('wb') as output:
    output.truncate(size)
  subprocess.run(['mkfs.ext4', '-q', '-F', '-d', str(source), str(image)], check=True)
PY

  timeout 75 qemu-system-riscv64 \
    -machine virt -cpu rv64,v=true,vlen=256,zcb=true,zicond=true,zfa=true -smp 2 -m 1024 -nographic -no-reboot \
    -bios default -kernel "$kernel" \
    -drive "file=$test_dir/$scenario-root.ext4,format=raw,if=none,id=root" \
    -device virtio-blk-device,drive=root \
    -drive "file=$test_dir/$scenario-boot.ext4,format=raw,if=none,id=boot" \
    -device virtio-blk-device,drive=boot \
    -append 'console=ttyS0 root=/dev/vda rootwait ro init=/bootstrap panic=10' \
    > "$test_dir/$scenario.log" 2>&1
  ! grep -q 'Kernel panic' "$test_dir/$scenario.log"
  debugfs -R 'cat /env_k3.txt' "$test_dir/$scenario-boot.ext4" \
    > "$test_dir/$scenario-restored-env.txt" 2>/dev/null
  boot_hash=$(sha256sum "$test_dir/$scenario-restored-env.txt")
  [[ ${boot_hash%% *} == "9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a" ]]
  if [[ $scenario == "success" ]]; then
    grep -q 'HOST_INIT_TEST: Arch root reached as PID 1' "$test_dir/$scenario.log"
    debugfs -R 'cat /var/lib/omarchy-k3-boot-trials/guard.log' \
      "$test_dir/$scenario-root.ext4" > "$test_dir/guard.log" 2>/dev/null
    grep -q 'expired pid=.* mode=reboot' "$test_dir/guard.log"
    grep -q 'reboot: Restarting system' "$test_dir/$scenario.log"
  else
    grep -q 'HOST_INIT_TEST: Bianbu fallback reached as PID 1' "$test_dir/$scenario.log"
    ! grep -q 'HOST_INIT_TEST: Arch root reached' "$test_dir/$scenario.log"
  fi
  echo "PASS: $scenario (stock boot restored, expected PID 1 and recovery behavior)"
done
