#!/bin/bash
# Install the migration into the vendor initramfs and arm one boot of it.
#
#   run-maintenance.sh install   add the hook and rebuild the vendor initramfs
#   run-maintenance.sh recon     arm a boot that only reports the layout
#   run-maintenance.sh all       arm the shrink, repartition and copy
#
# The armed boot is the board's ordinary boot — same kernel, same initramfs,
# same device tree — with one extra argument on the kernel command line. That is
# the whole point: the board cannot recover from a boot that does not start, so
# the migration rides along with the boot that already works. The initramfs puts
# the stock env_k3.txt back before it touches anything.
set -euo pipefail
mode=${1:-}
newroot=${K3_NEWROOT:-/var/lib/omarchy-k3-baremetal/rootfs}
release=${K3_VENDOR_RELEASE:-6.18.3-generic}
disk=${K3_DISK:-/dev/sda}
boot_file=/boot/env_k3.txt
stock=/etc/omarchy-k3/env_k3.stock
stock_hash=9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the K3." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "bianbu" ]]

geometry() {
  start=$(sgdisk -i 3 "$disk" | awk '/First sector/ {print $3}')
  last=$(sgdisk -p "$disk" | awk '/last usable sector/ {print $10}')
  p3uuid=$(sgdisk -i 3 "$disk" | awk '/Partition unique GUID/ {print $4}')
  # 4096-byte sectors: 10485760 of them is 40 GiB, and one ext4 block is one
  # sector, so the filesystem shrinks to just under the new partition.
  p3end=$(( start + 10485760 - 1 ))
  p4start=$(( p3end + 1 ))
  p4end=$last
  fsblocks=10223616
  [[ -n $start && -n $last && -n $p3uuid ]]
  (( start == 134144 ))
  (( p4end > p4start ))
}

case $mode in
  install)
    install -d /etc/omarchy-k3
    if [[ ! -f $stock ]]; then
      [[ $(sha256sum "$boot_file" | cut -d' ' -f1) == "$stock_hash" ]] ||
        { echo "$boot_file is not the stock file; refusing to record it." >&2; exit 1; }
      install -m644 "$boot_file" "$stock"
    fi
    install -m755 "$here/initramfs-hook" /etc/initramfs-tools/hooks/omarchy-k3-maintenance
    install -d /etc/initramfs-tools/scripts/init-premount
    install -m755 "$here/initramfs-premount" /etc/initramfs-tools/scripts/init-premount/omarchy-k3-maintenance
    install -m755 "$here/initramfs-guard" /etc/initramfs-tools/scripts/init-premount/omarchy-k3-guard
    install -m755 "$here/initramfs-noresize" /etc/initramfs-tools/scripts/init-premount/resize_partition
    grep -qx btrfs /etc/initramfs-tools/modules 2>/dev/null || echo btrfs >> /etc/initramfs-tools/modules
    update-initramfs -u -k "$release"
    ls -l "/boot/initrd.img-$release"
    echo "Installed. The ordinary boot is unchanged until a step is armed."
    ;;
  recon|all)
    [[ -f /etc/initramfs-tools/scripts/init-premount/omarchy-k3-maintenance ]] ||
      { echo "Run '$0 install' first." >&2; exit 1; }
    [[ -f $newroot/.omarchy-k3-rootfs ]]
    geometry
    echo "Vendor root  sectors ${start}..${p3end}   (PARTUUID ${p3uuid})"
    echo "Omarchy      sectors ${p4start}..${p4end}"
    extra="omarchy.migrate=${mode} omarchy.p3end=${p3end} omarchy.p4start=${p4start}"
    extra+=" omarchy.p4end=${p4end} omarchy.p3uuid=${p3uuid} omarchy.fsblocks=${fsblocks}"
    sed "s|^commonargs=.*|& ${extra}|" "$stock" > /boot/.env_k3.new
    grep -q "omarchy.migrate=${mode}" /boot/.env_k3.new
    sync /boot/.env_k3.new
    mv /boot/.env_k3.new "$boot_file"
    sync
    echo "Armed. Restart to run the '${mode}' step; it restores the stock boot file first."
    ;;
  *)
    echo "Usage: $0 install|recon|all" >&2
    exit 1
    ;;
esac
