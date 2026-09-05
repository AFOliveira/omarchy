#!/bin/bash
# Read-only board inventory. Run on the assigned instance before changing it.
set -uo pipefail

section() { printf '\n## %s\n' "$1"; }
section "Kernel and OS"
uname -a
cat /etc/os-release
section "Board model and compatible strings"
for name in model compatible; do
  if [[ -r /sys/firmware/devicetree/base/$name ]]; then
    tr '\0' '\n' < "/sys/firmware/devicetree/base/$name"
  fi
done
section "CPU and ISA"
lscpu
cat /proc/cpuinfo
section "Memory and storage"
free -h
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
findmnt / /boot /boot/efi
df -h / /boot
section "Boot command line"
cat /proc/cmdline
section "Kernel configuration relevant to bring-up"
if [[ -r /proc/config.gz ]]; then
  zcat /proc/config.gz | grep -E 'CONFIG_(SOC_SPACEMIT|RISCV|KEXEC|IKCONFIG|NAMESPACES|USER_NS|CGROUP|DEVTMPFS|DRM|IMG_POWERVR|VIRTIO|EXT4|BTRFS|OVERLAY_FS)'
elif [[ -r /boot/config-$(uname -r) ]]; then
  grep -E 'CONFIG_(SOC_SPACEMIT|RISCV|KEXEC|IKCONFIG|NAMESPACES|USER_NS|CGROUP|DEVTMPFS|DRM|IMG_POWERVR|VIRTIO|EXT4|BTRFS|OVERLAY_FS)' "/boot/config-$(uname -r)"
fi
section "Graphics devices and drivers"
ls -l /dev/dri 2>/dev/null || true
lsmod
section "Build and container tools"
for cmd in gcc clang git make pacman apt-get systemd-nspawn docker podman; do
  command -v "$cmd" || true
done
