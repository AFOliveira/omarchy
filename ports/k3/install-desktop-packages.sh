#!/bin/bash
# Install the RISC-V repository packages into the staged Arch userspace.
set -euo pipefail

port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rootfs=${K3_ROOTFS_DIR:-/var/lib/machines/omarchy-k3}
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $rootfs/.omarchy-k3-rootfs ]]; then
  echo "Run as root on the board after stage-arch.sh." >&2
  exit 1
fi

systemd-nspawn --quiet --console=pipe --register=no --directory="$rootfs" \
  --bind-ro="$port_dir:/run/omarchy-port" \
  /bin/bash -euo pipefail -c '
    mapfile -t packages < /run/omarchy-port/desktop.packages
    pacman -Syu --needed --noconfirm "${packages[@]}"
    pacman -Q alacritty waybar chromium mesa
  '
