#!/bin/bash
# A userspace-only check. The extracted files are not a provisioned installation.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
archive=archriscv-2026-08-27.tar.zst
digest=a2045c8b62232db2f60d8e4db610dbb5d9e12856dab0ba08634ad3d7cb7ad498
output="$repo_dir/build"
mkdir -p "$output/downloads"
if [[ ! -f $output/downloads/$archive ]]; then
  curl --fail --location --retry 2 --max-time 300 \
    "https://archriscv.felixc.at/images/$archive" -o "$output/downloads/$archive.partial"
  mv "$output/downloads/$archive.partial" "$output/downloads/$archive"
fi
printf '%s  %s\n' "$digest" "$output/downloads/$archive" | sha256sum --check

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$output:/out" -e ARCHIVE="$archive" \
  "${K3_BUILD_IMAGE:-omarchy-k3-builder:trixie}" bash -euo pipefail -c '
    if [[ ! -f /out/arch-rootfs/.extracted-for-smoke ]]; then
      if [[ -e /out/arch-rootfs ]]; then
        echo "Existing unmarked arch-rootfs directory; leaving it unchanged." >&2
        exit 1
      fi
      staging=$(mktemp -d /out/.arch-smoke.XXXXXX)
      trap '\''rm -rf -- "$staging"'\'' EXIT
      tar --zstd --no-same-owner --warning=no-unknown-keyword -xf "/out/downloads/$ARCHIVE" -C "$staging"
      chmod u+w "$staging"
      touch "$staging/.extracted-for-smoke"
      mv "$staging" /out/arch-rootfs
      trap - EXIT
    fi
    qemu-riscv64 -cpu sifive-u54 -L /out/arch-rootfs /out/arch-rootfs/usr/bin/bash -c '\''echo Arch-RISC-V-bash-PASS; echo "BASH_VERSION=$BASH_VERSION"'\''
    qemu-riscv64 -cpu sifive-u54 -L /out/arch-rootfs /out/arch-rootfs/usr/bin/pacman --root /out/arch-rootfs -Q bash glibc pacman
  ' 2>&1 | tee "$output/arch-smoke.log"
