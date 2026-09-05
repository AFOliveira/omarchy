#!/bin/bash
set -euo pipefail

port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
source "$port_dir/kernel.env"
kernel_dir=${K3_KERNEL_DIR:-"$repo_dir/build/linux-k3"}
output_dir=${K3_OUTPUT_DIR:-"$repo_dir/build/k3-kernel"}
image=${K3_BUILD_IMAGE:-omarchy-k3-builder:trixie}
jobs=${K3_JOBS:-8}

if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
  echo "K3_JOBS must be a positive integer" >&2
  exit 1
fi

if [[ ! -d $kernel_dir/.git ]]; then
  git clone --depth 1 --single-branch --branch "$K3_KERNEL_BRANCH" "$K3_KERNEL_URL" "$kernel_dir"
fi
if [[ $(git -C "$kernel_dir" rev-parse HEAD) != "$K3_KERNEL_COMMIT" ]]; then
  echo "Kernel checkout must be at $K3_KERNEL_COMMIT; leaving the existing checkout unchanged." >&2
  exit 1
fi
if [[ -n $(git -C "$kernel_dir" status --porcelain) ]]; then
  echo "Kernel checkout has local changes; refusing to label it as the pinned BSP." >&2
  exit 1
fi

mkdir -p "$output_dir"
kernel_dir=$(realpath "$kernel_dir")
output_dir=$(realpath "$output_dir")
docker build -t "$image" "$port_dir"
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$kernel_dir:/src:ro" -v "$output_dir:/out" \
  -e K3_KERNEL_DEFCONFIG="$K3_KERNEL_DEFCONFIG" -e K3_KERNEL_COMMIT="$K3_KERNEL_COMMIT" -e K3_JOBS="$jobs" \
  "$image" bash -euo pipefail -c '
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- "$K3_KERNEL_DEFCONFIG"
    /src/scripts/config --file /out/.config --set-str LOCALVERSION "-omarchy-k3" --disable LOCALVERSION_AUTO
    /src/scripts/config --file /out/.config --disable DEBUG_INFO --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_BTF --enable DEBUG_INFO_NONE
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$K3_JOBS" Image dtbs modules
    make -C /src O=/out ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- INSTALL_MOD_PATH=/out/stage INSTALL_MOD_STRIP=1 modules_install
    mkdir -p /out/stage/boot
    cp /out/arch/riscv/boot/Image /out/stage/boot/
    cp /out/.config /out/stage/boot/config
    cp /out/System.map /out/stage/boot/
    cp -r /out/arch/riscv/boot/dts/spacemit /out/stage/boot/dtbs
    printf "%s\n" "$K3_KERNEL_COMMIT" > /out/stage/source-commit
    riscv64-linux-gnu-gcc --version > /out/stage/compiler-version
    cd /out/stage
    find boot -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    tar -czf /out/omarchy-k3-kernel.tar.gz .
  ' 2>&1 | tee "$output_dir/build.log"

echo "Staged kernel: $output_dir/omarchy-k3-kernel.tar.gz"
echo "No bootloader, installed kernel, or remote board has been changed."
