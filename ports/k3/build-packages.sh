#!/bin/bash
# Build reviewed source packages as an ordinary user inside native Arch.
set -euo pipefail

port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (( EUID == 0 )) && [[ $(uname -m) == "riscv64" && -f /.omarchy-k3-rootfs ]] &&
  [[ $(findmnt -no FSROOT /) == "/var/lib/omarchy-k3-baremetal/rootfs" ]]; then
  exec /bin/bash "$port_dir/build-native-packages.sh" "$@"
fi
rootfs=${K3_ROOTFS_DIR:-/var/lib/machines/omarchy-k3}
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $rootfs/.omarchy-k3-rootfs ]]; then
  echo "Run as root on the board after installing desktop packages." >&2
  exit 1
fi

if [[ $(machinectl show omarchy-k3 --property=RootDirectory --value 2>/dev/null) == "$rootfs" ]]; then
  install -d /usr/local/share/omarchy-k3
  cp -a "$port_dir/." /usr/local/share/omarchy-k3/
  systemd-run --machine=omarchy-k3 --wait --pipe --collect \
    /bin/bash /run/omarchy-port/build-native-packages.sh "$@"
else
  systemd-nspawn --quiet --console=pipe --register=no --directory="$rootfs" \
    --bind-ro="$port_dir:/run/omarchy-port" \
    /bin/bash /run/omarchy-port/build-native-packages.sh "$@"
fi
