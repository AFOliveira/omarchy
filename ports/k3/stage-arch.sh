#!/bin/bash
# Stage a native Arch userspace alongside the board's existing Bianbu system.
set -euo pipefail
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the RISC-V board." >&2
  exit 1
fi
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_dir=${K3_STATE_DIR:-/home/bianbu/omarchy-port}
rootfs=${K3_ROOTFS_DIR:-/var/lib/machines/omarchy-k3}
archive="$state_dir/downloads/archriscv-2026-08-27.tar.zst"
digest=a2045c8b62232db2f60d8e4db610dbb5d9e12856dab0ba08634ad3d7cb7ad498
command -v systemd-nspawn >/dev/null
printf '%s  %s\n' "$digest" "$archive" | sha256sum --check

if [[ ! -f $rootfs/.omarchy-k3-rootfs ]]; then
  if [[ -e $rootfs ]]; then
    echo "Existing unmarked rootfs at $rootfs; leaving it unchanged." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$rootfs")"
  staging=$(mktemp -d "${rootfs}.staging.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  tar --zstd --numeric-owner --xattrs --acls --warning=no-unknown-keyword -xf "$archive" -C "$staging"
  printf '%s\n' "$digest" > "$staging/.omarchy-k3-rootfs"
  # The archive's resolver is not useful until a resolver daemon runs inside it.
  rm -f "$staging/etc/resolv.conf"
  cp -L /etc/resolv.conf "$staging/etc/resolv.conf"
  : > "$staging/etc/machine-id"
  printf 'omarchy-k3\n' > "$staging/etc/hostname"
  printf 'LANG=en_US.UTF-8\n' > "$staging/etc/locale.conf"
  mv "$staging" "$rootfs"
  trap - EXIT
fi

# Native RISC-V processes, using the host's working kernel and network.
systemd-nspawn --quiet --console=pipe --register=no --directory="$rootfs" \
  --bind-ro="$port_dir:/run/omarchy-port" \
  /bin/bash -euo pipefail -c '
    pacman-key --init
    pacman-key --populate archlinux
    mapfile -t packages < /run/omarchy-port/headless.packages
    pacman -Syu --noconfirm --needed "${packages[@]}"
    sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    if ! id afonso >/dev/null 2>&1; then
      useradd --create-home --groups wheel --shell /bin/bash afonso
    fi
    uname -m
    gcc --version | head -1
    nvim --version | head -1
    pacman -Q bash glibc pacman
  '
