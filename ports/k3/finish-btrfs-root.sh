#!/bin/bash
# Finish the move of the Omarchy root onto Btrfs, and boot it.
#
# Run from Bianbu after run-maintenance.sh all has created the Btrfs filesystem
# and copied the Omarchy root into its subvolumes. This writes the new root's
# fstab, configures Snapper the way upstream Omarchy does, and points
# /boot/env_k3.txt at the new root.
#
# The board cannot recover from a root that does not mount, so the boot file is
# only rewritten after the new root has been mounted and inspected here, and the
# command line carries omarchy.guard=1 so the vendor initramfs puts the stock
# boot file back if the root turns out not to mount after all.
set -euo pipefail
newroot=${K3_NEWROOT:-/run/omarchy-btrfs}
part=${K3_OMARCHY_PART:-/dev/sda4}
release=${K3_VENDOR_RELEASE:-6.18.3-generic}
stock=/etc/omarchy-k3/env_k3.stock

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the K3." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "bianbu" ]]
[[ -b $part ]]
[[ $(blkid -s TYPE -o value "$part") == "btrfs" ]]
[[ -f $stock ]]

root_partuuid=$(blkid -s PARTUUID -o value "$part")
boot_device=$(findmnt -no SOURCE /boot)
boot_partuuid=$(blkid -s PARTUUID -o value "$boot_device")
bianbu_partuuid=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE / | sed 's/\[.*//')")
[[ -n $root_partuuid && -n $boot_partuuid && -n $bianbu_partuuid ]]

install -d -m700 "$newroot"
mountpoint -q "$newroot" || mount -o subvol=@,compress=zstd "$part" "$newroot"
[[ -f $newroot/.omarchy-k3-rootfs ]]
for pair in "home:@home" "var/log:@log" "var/cache/pacman/pkg:@pkg" ".snapshots:@snapshots"; do
  target="$newroot/${pair%%:*}"
  install -d "$target"
  mountpoint -q "$target" || mount -o "subvol=${pair##*:},compress=zstd" "$part" "$target"
done
install -d "$newroot/boot"
mountpoint -q "$newroot/boot" || mount "$boot_device" "$newroot/boot"

echo "Writing the new root's fstab."
cat > "$newroot/etc/fstab" <<EOF
# Omarchy on the K3. Upstream mounts the EFI system partition at /boot; this
# board boots from U-Boot rather than EFI, so /boot is the vendor boot
# partition, which holds the kernel, the initramfs and env_k3.txt.
PARTUUID=$root_partuuid  /                      btrfs  rw,noatime,compress=zstd,subvol=@           0 0
PARTUUID=$root_partuuid  /home                  btrfs  rw,noatime,compress=zstd,subvol=@home       0 0
PARTUUID=$root_partuuid  /var/log               btrfs  rw,noatime,compress=zstd,subvol=@log        0 0
PARTUUID=$root_partuuid  /var/cache/pacman/pkg  btrfs  rw,noatime,compress=zstd,subvol=@pkg        0 0
PARTUUID=$root_partuuid  /.snapshots            btrfs  rw,noatime,compress=zstd,subvol=@snapshots  0 0
PARTUUID=$boot_partuuid  /boot                  ext4   rw,noatime                                  0 2
EOF

printf 'BOOT_PARTUUID=%s\nBIANBU_PARTUUID=%s\nOMARCHY_PARTUUID=%s\n' \
  "$boot_partuuid" "$bianbu_partuuid" "$root_partuuid" > "$newroot/etc/omarchy-k3-boot-layout"

echo "Configuring Snapper the way upstream Omarchy does."
install -d -m755 "$newroot/etc/snapper/configs" "$newroot/etc/conf.d"
# The same settings as upstream Omarchy's default/snapper/root.
cat > "$newroot/etc/snapper/configs/root" <<'EOF'
# Omarchy snapshots root only for pre-update recovery — kept to 5, no timeline
SUBVOLUME="/"
FSTYPE="btrfs"

NUMBER_LIMIT="5"
NUMBER_LIMIT_IMPORTANT="5"

TIMELINE_CREATE="no"
EOF
chmod 640 "$newroot/etc/snapper/configs/root"
# create-config would want to make its own .snapshots subvolume; this layout
# already has @snapshots mounted there, so the config is registered by hand.
install -d -m750 "$newroot/.snapshots"
printf 'SNAPPER_CONFIGS="root"\n' > "$newroot/etc/conf.d/snapper"

echo "Rebuilding the vendor initramfs with Btrfs and the boot guard."
grep -qx btrfs /etc/initramfs-tools/modules 2>/dev/null || echo btrfs >> /etc/initramfs-tools/modules
update-initramfs -u -k "$release"

echo "Pointing env_k3.txt at the Omarchy root."
{
  sed -n '1,/^loglevel=/p' "$stock" | grep -v '^commonargs='
  printf 'commonargs=setenv bootargs plymouth.prefer-fbcon plymouth.ignore-serial-consoles splash'
  printf ' console=ttyS0,115200 clk_ignore_unused rw rootfstype=btrfs rootflags=subvol=@'
  printf ' root=PARTUUID=%s bootfs=PARTUUID=%s omarchy.guard=1\n' "$root_partuuid" "$boot_partuuid"
  # The vendor script appends its own root= after ours, from the partition named
  # "rootfs", and forces rootfstype=ext4. Both are replaced here.
  printf 'set_root_arg=echo "omarchy: the root comes from env_k3.txt"\n'
  printf 'set_nor_args=setenv bootargs "${bootargs}" mtdparts=${mtdparts}\n'
} > /boot/.env_k3.new
grep -q "rootflags=subvol=@ root=PARTUUID=$root_partuuid" /boot/.env_k3.new
sync /boot/.env_k3.new
mv /boot/.env_k3.new /boot/env_k3.txt
sync

echo
cat /boot/env_k3.txt
echo
findmnt -no TARGET,SOURCE,FSTYPE "$newroot" "$newroot/home" "$newroot/.snapshots" "$newroot/boot"
echo "Restart to boot Omarchy from Btrfs."
