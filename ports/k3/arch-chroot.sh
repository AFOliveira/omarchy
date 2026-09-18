#!/bin/bash
# Run a command inside the staged Arch root from Bianbu.
#
# The port builds Arch things — kernels, modules, initramfs images — with Arch's
# own tools, which means running them in the staged root rather than on the
# vendor system. This mounts what pacman and mkinitcpio need, keeps the host's
# resolver, and leaves nothing mounted afterwards.
#
#   arch-chroot.sh 'pacman -S --noconfirm --needed mkinitcpio'
set -euo pipefail
newroot=${K3_NEWROOT:-/var/lib/omarchy-k3-baremetal/rootfs}
command=${1:-}

if (( EUID != 0 )); then
  echo "Run as root." >&2
  exit 1
fi
[[ -n $command ]] || { echo "Usage: $0 'command'" >&2; exit 1; }
[[ -f $newroot/.omarchy-k3-rootfs ]]

mounted=()
cleanup() {
  local target
  for (( i = ${#mounted[@]} - 1; i >= 0; i-- )); do
    target=${mounted[i]}
    umount -R "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || true
  done
}
trap cleanup EXIT

for directory in proc sys dev run; do
  install -d "$newroot/$directory"
  if ! mountpoint -q "$newroot/$directory"; then
    mount --rbind "/$directory" "$newroot/$directory"
    mount --make-rslave "$newroot/$directory"
    mounted+=("$newroot/$directory")
  fi
done
# pacman needs to resolve names; the staged root has its own resolved that is
# not running here. With /run bind-mounted, a stub-resolv.conf symlink already
# points at the host's file, so only copy when it would be a different one.
if ! [[ $newroot/etc/resolv.conf -ef /etc/resolv.conf ]]; then
  cp -L /etc/resolv.conf "$newroot/etc/resolv.conf"
fi

chroot "$newroot" /usr/bin/env -i \
  HOME=/root TERM="${TERM:-dumb}" LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin \
  /bin/bash -lc "$command"
