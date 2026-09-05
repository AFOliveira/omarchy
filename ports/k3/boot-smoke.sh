#!/bin/bash
# Boots the built BSP on QEMU virt. This does not emulate the K3 peripherals.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
kernel_output=${K3_OUTPUT_DIR:-"$repo_dir/build/k3-kernel"}
smoke_output="$repo_dir/build/rv64gc"

"$port_dir/smoke-rv64gc.sh"
cat > "$smoke_output/initramfs.list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
file /init $smoke_output/rv64gc-smoke 0755 0 0
EOF
"$kernel_output/usr/gen_init_cpio" "$smoke_output/initramfs.list" | gzip -n > "$smoke_output/initramfs.cpio.gz"

set +e
timeout 30 qemu-system-riscv64 \
  -machine virt -cpu sifive-u54 -smp 2 -m 1024 -nographic -no-reboot \
  -bios default -kernel "$kernel_output/arch/riscv/boot/Image" \
  -initrd "$smoke_output/initramfs.cpio.gz" \
  -append "console=ttyS0 earlycon=sbi rdinit=/init panic=-1 K3_SMOKE_POWEROFF=1" \
  2>&1 | tee "$smoke_output/boot.log"
qemu_status=${PIPESTATUS[0]}
set -e
# The BSP may lack QEMU's poweroff driver. A timeout is acceptable only after
# userspace succeeds and the kernel explicitly reaches its power-down path.
if (( qemu_status != 0 && qemu_status != 124 )); then
  exit "$qemu_status"
fi
grep -q 'RV64GC smoke: PASS' "$smoke_output/boot.log"
grep -q 'reboot: Power down' "$smoke_output/boot.log"
if grep -q 'Kernel panic' "$smoke_output/boot.log"; then
  exit 1
fi
