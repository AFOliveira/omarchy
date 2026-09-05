#!/bin/bash
# A separate generic-virt test kernel. This is not a K3 deployment artifact.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
source "$port_dir/kernel.env"
kernel_dir=${K3_KERNEL_DIR:-"$repo_dir/build/linux-k3"}
output_dir="$repo_dir/build/qemu-kernel"
[[ $(git -C "$kernel_dir" rev-parse HEAD) == "$K3_KERNEL_COMMIT" ]]
mkdir -p "$output_dir"
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$kernel_dir:/src:ro" -v "$output_dir:/out" \
  "${K3_BUILD_IMAGE:-omarchy-k3-builder:trixie}" bash -euo pipefail -c '
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig
    /src/scripts/config --file /out/.config --set-str LOCALVERSION "-omarchy-qemu" \
      --disable LOCALVERSION_AUTO --disable DEBUG_INFO --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
      --disable DEBUG_INFO_BTF --enable DEBUG_INFO_NONE --enable DRM_VIRTIO_GPU
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j8 Image
  ' > "$output_dir/build.log" 2>&1
echo "Generic QEMU kernel: $output_dir/arch/riscv/boot/Image"
