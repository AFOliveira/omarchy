#!/bin/bash
# Choose whether the K3 starts Omarchy or the vendor system.
#
#   select-boot.sh omarchy   boot the Omarchy Btrfs root
#   select-boot.sh vendor    boot the vendor Bianbu system (the stock boot file)
#
# There is no boot menu on this board — U-Boot cannot run an EFI loader, see
# arch-kernel/BOOT-LOADER.md — so the choice is this file. Runs from either
# system; /boot is the vendor boot partition in both.
#
# The vendor file written here is the stock one, digest checked. The Omarchy
# file carries omarchy.guard=1, which makes the vendor initramfs put the stock
# file back if the Omarchy root will not mount.
set -euo pipefail
mode=${1:-}
# The vendor boot partition is not mounted permanently any more (the ESP is
# /boot, as upstream); it has a noauto fstab entry at /mnt/bootfs.
boot_file=${K3_BOOT_FILE:-/mnt/bootfs/env_k3.txt}
if [[ ! -f $boot_file && $boot_file == /mnt/bootfs/* ]]; then
  mount /mnt/bootfs 2>/dev/null || mount PARTLABEL=bootfs /mnt/bootfs 2>/dev/null || true
fi
layout=/etc/omarchy-k3-boot-layout
stock_hash=9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the K3." >&2
  exit 1
fi
[[ -f $boot_file ]] || { echo "$boot_file is missing; is the vendor boot partition (PARTLABEL=bootfs) available?" >&2; exit 1; }

stock_contents() {
  cat <<'EOF'
knl_name=vmlinuz-6.18.3-generic
ramdisk_name=initrd.img-6.18.3-generic
dtb_dir=spacemit/6.18.3-generic
ramdisk_addr=0x130000000
loglevel=8
commonargs=setenv bootargs plymouth.prefer-fbcon plymouth.ignore-serial-consoles splash
EOF
}

write_boot_file() {
  printf '%s' "$1" > "$boot_file.new"
  # Keep the Limine hand-off (see limine/limine-boot.sh) across either choice;
  # it only matters when EFI/BOOT/BOOTRISCV64.EFI exists, and dropping it would
  # leave U-Boot with its own broken boot_grub the next time it does.
  grep '^boot_grub=' "$boot_file" >> "$boot_file.new" 2>/dev/null || true
  sync "$boot_file.new"
  mv "$boot_file.new" "$boot_file"
  sync
}

case $mode in
  vendor)
    contents=$(stock_contents)
    [[ $(printf '%s\n' "$contents" | sha256sum | cut -d' ' -f1) == "$stock_hash" ]]
    write_boot_file "$contents
"
    echo "The next restart starts the vendor Bianbu system (with Limine installed, pick the Recovery entry instead)."
    ;;
  omarchy)
    [[ -f $layout ]] || layout=/var/lib/omarchy-k3-baremetal/rootfs/etc/omarchy-k3-boot-layout
    omarchy_partuuid=$(sed -n 's/^OMARCHY_PARTUUID=//p' "$layout")
    boot_partuuid=$(sed -n 's/^BOOT_PARTUUID=//p' "$layout")
    # The vendor system's copy of the layout predates the Omarchy partition, so
    # fall back to the filesystem label the migration gives it.
    [[ -n $omarchy_partuuid ]] ||
      omarchy_partuuid=$(blkid -s PARTUUID -o value "$(blkid -L omarchy)" 2>/dev/null || true)
    [[ -n $boot_partuuid ]] || boot_partuuid=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /boot)")
    [[ -n $omarchy_partuuid && -n $boot_partuuid ]]
    [[ -b /dev/disk/by-partuuid/$omarchy_partuuid ]]
    [[ $(blkid -s TYPE -o value "/dev/disk/by-partuuid/$omarchy_partuuid") == "btrfs" ]]
    write_boot_file "$(stock_contents | grep -v '^commonargs=')
commonargs=setenv bootargs plymouth.prefer-fbcon plymouth.ignore-serial-consoles splash console=ttyS0,115200 clk_ignore_unused rw rootfstype=btrfs rootflags=subvol=@ root=PARTUUID=$omarchy_partuuid bootfs=PARTUUID=$boot_partuuid omarchy.guard=1
set_root_arg=echo \"omarchy: the root comes from env_k3.txt\"
set_nor_args=setenv bootargs \"\${bootargs}\" mtdparts=\${mtdparts}
"
    echo "The next restart starts Omarchy from the Btrfs root."
    ;;
  *)
    echo "Usage: $0 omarchy|vendor" >&2
    exit 1
    ;;
esac
grep -c . "$boot_file" | xargs -I{} echo "{} lines in $boot_file"
