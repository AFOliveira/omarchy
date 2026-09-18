#!/bin/bash
# Prepare an Arch Linux RISC-V kernel boot set for the K3.
#
# Run as root on the Bianbu system, with the staged Arch root present. The Arch
# kernel package is installed inside that root; this script only adds what the
# board needs on top of it: the SpacemiT UFS host driver as an out-of-tree
# module, a board device tree with a UFS node, and an initramfs that can reach
# the Omarchy root. The vendor kernel and its boot selection are not touched.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
arch_dir="$port_dir/arch-kernel"
rootfs=/var/lib/omarchy-k3-baremetal/rootfs
chroot_helper=${K3_ARCH_CHROOT:-/root/arch-chroot.sh}
linux_src=${K3_LINUX_SRC:-/root/src/linux-7.2.6}
vendor_src=${K3_VENDOR_SRC:-/root/src/linux-6.18}
release=${K3_ARCH_KERNEL_RELEASE:-7.2.6-arch2-1}
boot_mount=/run/k3-boot

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]]; then
  echo "Run as root on the K3." >&2
  exit 1
fi
source /etc/os-release
[[ $ID == "bianbu" ]]
[[ -f $rootfs/.omarchy-k3-rootfs ]]
[[ -x $chroot_helper ]]
[[ -d $linux_src/arch/riscv/boot/dts/spacemit ]]
[[ -f $vendor_src/drivers/ufs/host/ufs-spacemit.c ]]
[[ -f $arch_dir/ufs-spacemit-linux-7.2.patch ]]

echo "Installing the Arch kernel and initramfs tooling."
"$chroot_helper" "pacman -S --noconfirm --needed linux linux-headers mkinitcpio \
  mkinitcpio-netconf mkinitcpio-tinyssh mkinitcpio-nfs-utils dtc"
[[ -f $rootfs/usr/lib/modules/$release/vmlinuz ]]

echo "Building the SpacemiT UFS host driver against the Arch kernel."
install -d "$rootfs/root/ufs-spacemit"
install -m644 "$vendor_src/drivers/ufs/host/ufs-spacemit.c" \
  "$vendor_src/drivers/ufs/host/ufs-spacemit.h" "$rootfs/root/ufs-spacemit/"
install -m644 "$linux_src/drivers/ufs/host/ufshcd-pltfrm.h" "$rootfs/root/ufs-spacemit/"
patch -d "$rootfs/root/ufs-spacemit" -p0 --forward < "$arch_dir/ufs-spacemit-linux-7.2.patch" || true
cat > "$rootfs/root/ufs-spacemit/Makefile" <<EOF
obj-m += ufs-spacemit.o
KDIR ?= /usr/lib/modules/$release/build
all:
	\$(MAKE) -C \$(KDIR) M=\$(CURDIR) modules
EOF
"$chroot_helper" "cd /root/ufs-spacemit && make"
install -d "$rootfs/usr/lib/modules/$release/updates"
install -m644 "$rootfs/root/ufs-spacemit/ufs-spacemit.ko" \
  "$rootfs/usr/lib/modules/$release/updates/ufs-spacemit.ko"
"$chroot_helper" "depmod $release"

echo "Compiling the board device tree."
install -m644 "$arch_dir/k3-com260-cloud.dts" "$linux_src/arch/riscv/boot/dts/spacemit/"
( cd "$linux_src" && cpp -nostdinc -Iinclude -Iarch/riscv/boot/dts \
  -Iarch/riscv/boot/dts/spacemit -undef -x assembler-with-cpp -D__DTS__ \
  arch/riscv/boot/dts/spacemit/k3-com260-cloud.dts > "$rootfs/root/k3-com260-cloud.dts.pre" )
"$chroot_helper" "dtc -I dts -O dtb -o /root/k3-com260-cloud.dtb /root/k3-com260-cloud.dts.pre"

echo "Building the initramfs."
install -d "$rootfs/etc/initcpio/install" "$rootfs/etc/initcpio/hooks" "$rootfs/etc/tinyssh"
install -m644 "$arch_dir/mkinitcpio/install/omarchy-k3-subroot" "$rootfs/etc/initcpio/install/"
install -m644 "$arch_dir/mkinitcpio/hooks/omarchy-k3-subroot" "$rootfs/etc/initcpio/hooks/"
install -m644 "$arch_dir/mkinitcpio-k3.conf" "$rootfs/root/mkinitcpio-k3.conf"
install -m600 "$rootfs/root/.ssh/authorized_keys" "$rootfs/etc/tinyssh/root_key"
"$chroot_helper" "mkinitcpio -c /root/mkinitcpio-k3.conf -k $release -g /boot/initramfs-k3-arch.img"

echo "Staging the boot set on the boot partition."
boot_partuuid=$(sed -n 's/^BOOT_PARTUUID=//p' "$rootfs/etc/omarchy-k3-boot-layout")
[[ -n $boot_partuuid ]]
install -d -m700 "$boot_mount"
mountpoint -q "$boot_mount" || mount "/dev/disk/by-partuuid/$boot_partuuid" "$boot_mount"
install -d "$boot_mount/omarchy-arch/dtbs"
install -m644 "$rootfs/usr/lib/modules/$release/vmlinuz" "$boot_mount/omarchy-arch/vmlinuz"
install -m644 "$rootfs/boot/initramfs-k3-arch.img" "$boot_mount/omarchy-arch/initramfs.img"
install -m644 "$rootfs/root/k3-com260-cloud.dtb" "$boot_mount/omarchy-arch/dtbs/k3_com260.dtb"
sync
ls -l "$boot_mount/omarchy-arch"
umount "$boot_mount"
echo "Arch kernel boot set ready. Select it with select-arch-kernel.sh."
