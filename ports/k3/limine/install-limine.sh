#!/bin/bash
# Put the K3 on upstream Omarchy's boot tooling, as install/login/limine-snapper.sh
# does on x86: limine-mkinitcpio-hook builds the unified kernel image and the menu
# entries from pacman hooks, limine-snapper-sync keeps one entry per Snapper
# snapshot, and the vendor kernel is an ordinary kernel package. The board's own
# differences live in drop-ins: /etc/limine-entry-tool.d/omarchy-k3.conf for the
# kernel arguments and a Recovery entry for the vendor system.
#
# Runs as root on the board. Expects the three packages built by
# ../build-packages.sh (linux-spacemit-k3 limine-mkinitcpio-hook limine-snapper-sync)
# in the artifacts directory, or already installed.
set -euo pipefail

port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
omarchy_dir=${OMARCHY_PATH:-/home/afonso/.local/share/omarchy}
artifacts=${K3_ARTIFACTS:-/home/afonso/.cache/omarchy-k3/packages/artifacts}
vendor_release=${K3_VENDOR_RELEASE:-6.18.3-generic}

(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
[[ -d $omarchy_dir/default/limine ]] || { echo "$omarchy_dir/default/limine is missing" >&2; exit 1; }

esp_dev=$(findfs PARTLABEL=ESP)
bootfs_dev=$(findfs PARTLABEL=bootfs)
esp_partuuid=$(blkid -o value -s PARTUUID "$esp_dev")
bootfs_partuuid=$(blkid -o value -s PARTUUID "$bootfs_dev")
root_partuuid=$(findmnt -no PARTUUID /)
vendor_root_partuuid=$(blkid -o value -s PARTUUID "$(findfs PARTLABEL=rootfs)")

# --- The Recovery entry's payloads are copied onto the ESP. Limine faults in
# linux_load when the kernel is read from the ext4 boot partition through
# guid(), and the vendor keeps the kernel gzip-wrapped as vmlinuz, while Limine
# wants the Image itself.
stage_recovery() {
  local tmp; tmp=$(mktemp -d)
  mount -o ro "$bootfs_dev" "$tmp"
  install -d /boot/vendor
  [[ -f /boot/vendor/Image-$vendor_release ]] || zcat "$tmp/vmlinuz-$vendor_release" > "/boot/vendor/Image-$vendor_release"
  cp -n "$tmp/initrd.img-$vendor_release" /boot/vendor/
  umount "$tmp"; rmdir "$tmp"
}

# --- The ESP is /boot, as upstream. The vendor's ext4 boot partition (U-Boot's
# device tree and environment) is no longer mounted permanently; the kernel
# package's install script and the boot-selection helpers mount it when needed.
if [[ $(findmnt -no SOURCE /boot 2>/dev/null) == "$bootfs_dev" ]]; then
  umount /boot
fi
if [[ $(findmnt -no SOURCE /efi 2>/dev/null) == "$esp_dev" ]]; then
  umount /efi
fi
mountpoint -q /boot || mount -o rw,noatime,fmask=0137,dmask=0027 "$esp_dev" /boot
[[ $(findmnt -no SOURCE /boot) == "$esp_dev" ]]
sed -i "\|[[:space:]]/boot[[:space:]]|d; \|[[:space:]]/efi[[:space:]]|d; \|[[:space:]]/mnt/bootfs[[:space:]]|d" /etc/fstab
cat >> /etc/fstab <<EOF
PARTUUID=$esp_partuuid  /boot  vfat  rw,noatime,fmask=0137,dmask=0027  0 2
PARTUUID=$bootfs_partuuid  /mnt/bootfs  ext4  rw,noatime,noauto  0 0
EOF
install -d /mnt/bootfs
rmdir /efi 2>/dev/null || true

# --- mkinitcpio configuration, upstream's limine-snapper.sh hook list. microcode
# only warns on RISC-V. encrypt is added only once the kernel has dm-crypt (the
# vendor build has no CONFIG_DM_CRYPT; linux-spacemit-k3-dm-crypt provides it):
# with the module missing mkinitcpio fails and the tool installs no UKI at all.
# Upstream's thunderbolt_module.conf is left out: an x86-only module fails the
# same way here.
install -d /etc/mkinitcpio.conf.d
hooks="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"
if ! modinfo -k "$vendor_release" dm-crypt &>/dev/null; then
  hooks=${hooks/ encrypt/}
  echo "note: this kernel has no dm-crypt; building without the encrypt hook"
fi
cat > /etc/mkinitcpio.conf.d/omarchy_hooks.conf <<EOF
HOOKS=($hooks)
FILES+=(/etc/vconsole.conf)
EOF
rm -f /etc/mkinitcpio.conf.d/thunderbolt_module.conf
# Mainline kernels (Arch's linux): the UFS host from ufs-spacemit-dkms and the
# clock and reset drivers it sits behind. autodetect cannot find them while
# SpacemiT's kernel runs, because its device tree names the hardware
# differently; the trailing ? makes them optional for SpacemiT's kernel, which
# has all of this built in.
cat > /etc/mkinitcpio.conf.d/omarchy_k3_mainline.conf <<'EOF'
MODULES+=(ufs-spacemit? spacemit-ccu-k3? reset-spacemit-k3?)
EOF
[[ -f /etc/vconsole.conf ]] || printf 'KEYMAP=us\n' > /etc/vconsole.conf
if [[ $(plymouth-set-default-theme 2>/dev/null) != "omarchy" ]]; then
  cp -r "$omarchy_dir/default/plymouth" /usr/share/plymouth/themes/omarchy
  plymouth-set-default-theme omarchy
fi

# --- The board's kernel arguments, as a drop-in the way hardware fixes add theirs.
install -d /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/omarchy-k3.conf <<EOF
# SpacemiT K3: the vendor kernel needs the boot partition, the SPI NOR layout
# (without it /dev/mtd3, U-Boot's environment, disappears), the boot medium and
# the SBI early console; plymouth must leave the serial console alone.
# SpacemiT's own arguments also carry plymouth.prefer-fbcon, which upstream does
# not set and which makes Omarchy's script theme crash in plymouth 26.134.222
# (ply_console_viewer_hide on a NULL viewer, fixed upstream by 88c8dd8 after
# that release), so it is left out.
# reboot=warm: this firmware's OpenSBI only does a warm system reset, and a
# mainline kernel restarts through SBI (SpacemiT's kernel uses its watchdog
# driver instead, and ignores the mode), so a cold restart request just hangs.
# systemd.tty.*: the serial console is a web terminal whose replies to systemd's
# terminal-type and size queries come back after systemd stops waiting, and then
# land in the login prompt. Stating the answers skips the queries: vt220 is what
# systemd falls back to when nothing replies, and 80x24 is what programs assume
# on a serial line with no size set.
KERNEL_CMDLINE[default]+=" reboot=warm bootfs=PARTUUID=$bootfs_partuuid clk_ignore_unused console=ttyS0,115200 mtdparts=d420c000.spi:128K@0(bootinfo),512K@128K(fsbl),64K@640K(env),1M@704K(esos),384K@1728K(opensbi),-@2112K(uboot) boot_mode=nor earlycon=sbi random.trust_bootloader=1 unaligned_scalar_speed=fast unaligned_vector_speed=fast plymouth.ignore-serial-consoles"
KERNEL_CMDLINE[default]+=" systemd.tty.term.console=vt220 systemd.tty.rows.console=24 systemd.tty.columns.console=80 systemd.tty.term.ttyS0=vt220 systemd.tty.rows.ttyS0=24 systemd.tty.columns.ttyS0=80"
EOF

# --- /etc/default/limine: upstream's file with this root's command line.
# Upstream reuses the arguments the existing configuration boots with (it reads
# them from the limine.conf archinstall wrote); here that is the first
# KERNEL_CMDLINE line of a previous run, which after luks-root.sh is the
# cryptdevice= form. A first install has none and boots the plain Btrfs root.
cmdline=""
if [[ -f /etc/default/limine ]]; then
  cmdline=$(grep -m1 '^KERNEL_CMDLINE\[default\]+="' /etc/default/limine | sed 's/^KERNEL_CMDLINE\[default\]+="\(.*\)"$/\1/')
  [[ $cmdline == *"root="* ]] || cmdline=""
fi
if [[ -z $cmdline ]]; then
  [[ -n $root_partuuid ]] || { echo "/ has no partition UUID and /etc/default/limine names no root" >&2; exit 1; }
  cmdline="root=PARTUUID=$root_partuuid rw rootfstype=btrfs rootflags=subvol=@"
fi
cp "$omarchy_dir/default/limine/default.conf" /etc/default/limine
sed -i "s|@@CMDLINE@@|$cmdline|g" /etc/default/limine
for dropin in /etc/limine-entry-tool.d/*.conf; do
  [[ -f $dropin ]] && cat "$dropin" >> /etc/default/limine
done

# --- The menu: upstream's limine.conf at the ESP root; the tool adds the entries.
rm -f /boot/EFI/BOOT/limine.conf /boot/EFI/limine/limine.conf
cp "$omarchy_dir/default/limine/limine.conf" /boot/limine.conf
# Upstream's numeric default_entry indexes a menu whose order differs here (the
# tool nests the kernel under an OS directory and adds Snapshots, the EFI
# fallback and Recovery), so the number picks the wrong entry. Limine also
# accepts an entry path, which says exactly what should boot.
# Arch's own kernel is the default; SpacemiT's stays in the menu.
sed -i "s|^default_entry: .*|default_entry: Omarchy/linux|" /boot/limine.conf

# --- Retire the port's own generator, preset and hook copies; the packages own these now.
systemctl disable --now omarchy-k3-snapshot-entries.path omarchy-k3-snapshot-entries.service 2>/dev/null || true
rm -f /etc/systemd/system/omarchy-k3-snapshot-entries.{path,service} /usr/local/bin/omarchy-k3-snapshot-entries
rm -f /etc/mkinitcpio.d/linux-spacemit-k3.preset /etc/kernel/cmdline
rm -f /boot/loader/entries/* /boot/EFI/Linux/omarchy-fallback.efi /boot/vendor/initramfs-linux-spacemit-k3.img /boot/vendor/k3_com260.dtb
rmdir /boot/loader/entries /boot/loader 2>/dev/null || true
# The btrfs-overlayfs hook is left alone: the port installed its own copy of
# upstream's file at the same path, and limine-mkinitcpio-hook now owns it.
# Removing it here made mkinitcpio fail and the board boot into an empty menu.
for f in /usr/lib/initcpio/hooks/btrfs-overlayfs /usr/lib/initcpio/install/btrfs-overlayfs; do
  [[ -f $f ]] || { echo "$f is missing; reinstall limine-mkinitcpio-hook" >&2; exit 1; }
done
systemctl daemon-reload

# --- Packages. Upstream installs with mkinitcpio's stock hooks disabled and
# re-enables them afterwards; the limine package brings its own replacement.
if pacman -Q linux-spacemit-k3 limine-mkinitcpio-hook limine-snapper-sync &>/dev/null; then
  echo "packages already installed"
else
  mapfile -t pkgs < <(ls "$artifacts"/linux-spacemit-k3-*.pkg.tar.zst "$artifacts"/limine-mkinitcpio-hook-*.pkg.tar.zst "$artifacts"/limine-snapper-sync-*.pkg.tar.zst)
  (( ${#pkgs[@]} == 3 ))
  for hook in 90-mkinitcpio-install 60-mkinitcpio-remove; do
    [[ -f /usr/share/libalpm/hooks/$hook.hook ]] && mv /usr/share/libalpm/hooks/$hook.hook /usr/share/libalpm/hooks/$hook.hook.disabled
  done
  pacman -U --noconfirm --overwrite "/usr/lib/modules/$vendor_release/*" "${pkgs[@]}"
  for hook in 90-mkinitcpio-install 60-mkinitcpio-remove; do
    [[ -f /usr/share/libalpm/hooks/$hook.hook.disabled ]] && mv /usr/share/libalpm/hooks/$hook.hook.disabled /usr/share/libalpm/hooks/$hook.hook
  done
fi

# --- UEFI variables. The firmware keeps them in ubootefi.var on the ESP and lets
# Linux change them at runtime in memory; this writes such changes back, from
# pacman (after limine registers its boot option) and at shutdown.
install -Dm755 "$port_dir/limine/omarchy-k3-efivars-sync" /usr/local/bin/omarchy-k3-efivars-sync
install -Dm644 "$port_dir/limine/omarchy-k3-efivars-sync.service" /etc/systemd/system/omarchy-k3-efivars-sync.service
install -Dm644 "$port_dir/limine/95-omarchy-k3-efivars-sync.hook" /etc/pacman.d/hooks/95-omarchy-k3-efivars-sync.hook
systemctl daemon-reload
systemctl enable --now omarchy-k3-efivars-sync.service

# --- Snapper as upstream configures it, then the loader, the UKI and the entries.
snapper list-configs 2>/dev/null | grep -q "^root" || snapper -c root create-config /
cp "$omarchy_dir/default/snapper/root" /etc/snapper/configs/root
btrfs quota disable / 2>/dev/null || true
# limine-install with upstream's EFI_REGISTER=yes: copies Limine to EFI/limine
# and EFI/BOOT and registers the "Limine" boot option with efibootmgr, as on a PC.
limine-install
omarchy-k3-efivars-sync
limine-update
[[ -f /boot/EFI/Linux/omarchy_linux-spacemit-k3.efi ]] || { echo "limine-update produced no UKI; the old omarchy.efi is kept" >&2; exit 1; }
rm -f /boot/EFI/Linux/omarchy.efi

# Only this board's Recovery entry is added by hand, after the tool's block so
# that upstream's default_entry keeps pointing at the desktop: the vendor's own
# kernel and initramfs, read straight from the ext4 boot partition.
stage_recovery
if ! grep -q "^/Recovery: vendor Bianbu system" /boot/limine.conf; then
  cat >> /boot/limine.conf <<EOF

/Recovery: vendor Bianbu system
    comment: The provider's own system on the third partition, for recovery and serial sessions
    protocol: linux
    kernel_path: boot():/vendor/Image-$vendor_release
    module_path: boot():/vendor/initrd.img-$vendor_release
    cmdline: root=PARTUUID=$vendor_root_partuuid rw rootfstype=ext4 rootwait bootfs=PARTUUID=$bootfs_partuuid clk_ignore_unused console=ttyS0,115200 mtdparts=d420c000.spi:128K@0(bootinfo),512K@128K(fsbl),64K@640K(env),1M@704K(esos),384K@1728K(opensbi),-@2112K(uboot) boot_mode=nor earlycon=sbi random.trust_bootloader=1 unaligned_scalar_speed=fast unaligned_vector_speed=fast
EOF
fi
limine-snapper-sync || true
systemctl enable --now limine-snapper-sync.service

echo
grep -q "^/+" /boot/limine.conf && echo "boot entries present" || { echo "no boot entries in /boot/limine.conf" >&2; exit 1; }
df -h /boot | tail -1
grep -nE "^/|^    (protocol|path|kernel_path|cmdline):" /boot/limine.conf | cut -c1-140
