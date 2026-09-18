#!/bin/bash
# Point the vendor U-Boot at Limine, on a U-Boot whose EFI loader works.
#
# Since the firmware carries the patched boot_grub (../uboot/), nothing needs
# this: the NOR environment's compiled default already loads the device tree,
# hands the image to bootefi without a size and falls back to the vendor kernel.
# It stays for the case where the stock firmware is flashed back, where the
# override in env_k3.txt is the only way to reach a loader.
#
#   limine-boot.sh enable    give U-Boot a boot_grub that loads the device tree
#                            first, passes the image size, and falls back to the
#                            vendor kernel if the loader returns
#   limine-boot.sh disable   remove the boot_grub override (and the EFI binary
#                            if asked with --remove-efi)
#
# Two things about the vendor boot script are corrected here. Its `boot_grub`
# loads the EFI binary before the device tree, and both loads go through
# U-Boot's `load`, which sets `filesize` and the EFI boot device as a side
# effect — so `bootefi` without a size gets the device tree's size and a boot
# device pointing at the ext4 partition instead of the FAT one the loader came
# from. And when `bootefi` returns an error, `nor_boot` stops at the prompt
# instead of booting the kernel. The line below fixes the order, passes the
# size explicitly, and falls back to `boot_kernel`.
#
# None of this helps on the stock firmware, whose EFI start-up faults; see
# ../uboot/README.md. Run it only on the patched U-Boot.
set -euo pipefail
mode=${1:-}
remove_efi=${2:-}
# The vendor boot partition is not mounted permanently any more (the ESP is
# /boot, as upstream); it has a noauto fstab entry at /mnt/bootfs.
boot_file=${K3_BOOT_FILE:-/mnt/bootfs/env_k3.txt}
if [[ ! -f $boot_file && $boot_file == /mnt/bootfs/* ]]; then
  mount /mnt/bootfs 2>/dev/null || mount PARTLABEL=bootfs /mnt/bootfs 2>/dev/null || true
fi
esp=${K3_ESP_MOUNT:-/efi}
boot_grub='boot_grub=run detect_dtb; run loaddtb; if run load_grub; then if bootefi ${kernel_addr_r}:${filesize} ${fdt_addr_r}; then echo "== the boot loader returned =="; fi; fi; echo "== falling back to the vendor kernel =="; run boot_kernel;'

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the K3." >&2
  exit 1
fi
[[ -f $boot_file ]] || { echo "$boot_file is missing; is the vendor boot partition (PARTLABEL=bootfs) available?" >&2; exit 1; }

case $mode in
  enable)
    grep -v '^boot_grub=' "$boot_file" > "$boot_file.new"
    printf '%s\n' "$boot_grub" >> "$boot_file.new"
    sync "$boot_file.new"
    mv "$boot_file.new" "$boot_file"
    sync
    echo "boot_grub override written; U-Boot runs EFI/BOOT/BOOTRISCV64.EFI when it exists."
    ;;
  disable)
    grep -v '^boot_grub=' "$boot_file" > "$boot_file.new"
    sync "$boot_file.new"
    mv "$boot_file.new" "$boot_file"
    if [[ $remove_efi == "--remove-efi" ]] && mountpoint -q "$esp"; then
      rm -f "$esp/EFI/BOOT/BOOTRISCV64.EFI"
      echo "removed $esp/EFI/BOOT/BOOTRISCV64.EFI"
    fi
    sync
    echo "boot_grub override removed."
    ;;
  *)
    echo "Usage: $0 enable|disable [--remove-efi]" >&2
    exit 1
    ;;
esac
grep -c . "$boot_file" | xargs -I{} echo "{} lines in $boot_file"
