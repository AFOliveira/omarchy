#!/bin/bash
# Move the Omarchy root under LUKS and give the board an upstream-sized ESP.
# Runs from the vendor Bianbu system (Recovery entry), with the Omarchy partition
# unmounted:
#
#   1. shrink the Btrfs on the omarchy partition by 2 GiB + 64 MiB
#   2. shorten the partition, create a 2 GiB ESP after it, move the ESP there
#   3. cryptsetup reencrypt --encrypt the omarchy partition in place (LUKS2, a
#      keyfile that the initramfs carries, plus a passphrase as a second key)
#   4. in the Arch root: fstab, /etc/default/limine, mkinitcpio keyfile, then
#      limine-update inside the chroot so the UKI carries cryptdevice=
#
# Upstream Omarchy's root is LUKS with a passphrase typed at boot. This board can
# only be typed at through the portal's serial console and resets on its own, so
# the choice made was the same layout with a keyfile next to the loader:
# identical structure, unattended boots, no secrecy against someone with the disk.
set -euo pipefail

port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
esp_size_mib=${K3_ESP_MIB:-2048}
luks_reserve_mib=64
key_dir=${K3_KEY_DIR:-/root/omarchy-k3-luks}
gpt_backup=${K3_GPT_BACKUP:-/root/omarchy-k3-gpt-backup.bin}
step=${1:-all}

(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
[[ -f /etc/os-release ]] && grep -q "Bianbu" /etc/os-release || { echo "run from the vendor Bianbu system" >&2; exit 1; }
for tool in cryptsetup sgdisk mkfs.fat btrfs partprobe zstd; do
  command -v $tool >/dev/null || { echo "missing: $tool (apt-get install cryptsetup gdisk dosfstools btrfs-progs zstd)" >&2; exit 1; }
done

disk=/dev/sda

# The vendor kernel has no dm-crypt; the same 6.18.3-generic kernel boots this
# vendor system, so the modules from linux-spacemit-k3-dm-crypt (built against
# the vendor headers) load here as well. They are read from the still-plain
# Omarchy root before it is encrypted, and kept under /root for later runs.
load_dm_modules() {
  lsmod | grep -q "^dm_crypt" && return 0
  local dir=/root/omarchy-k3-dm-modules mnt
  if [[ ! -f $dir/dm-crypt.ko ]]; then
    mnt=$(mktemp -d); install -d "$dir"
    mount -o ro,subvol=@ "$(findfs PARTLABEL=omarchy)" "$mnt"
    local ko; for ko in "$mnt"/usr/lib/modules/6.18.3-generic/extramodules/*.ko.zst; do
      zstd -dq "$ko" -o "$dir/$(basename "${ko%.zst}")"
    done
    umount "$mnt"; rmdir "$mnt"
  fi
  modprobe xor
  local m; for m in async_tx async_xor dm-bufio dm-crypt dm-integrity; do
    insmod "$dir/$m.ko" 2>/dev/null || true
  done
  lsmod | grep -q "^dm_crypt" || { echo "dm-crypt could not be loaded" >&2; exit 1; }
}
omarchy_dev=$(findfs PARTLABEL=omarchy)
old_esp_dev=$(findfs PARTLABEL=ESP)
bootfs_dev=$(findfs PARTLABEL=bootfs)
omarchy_num=${omarchy_dev##*[a-z]}
omarchy_partuuid=$(blkid -o value -s PARTUUID "$omarchy_dev")
! findmnt -rn -S "$omarchy_dev" >/dev/null || { echo "$omarchy_dev is mounted" >&2; exit 1; }

log() { printf '\n== %s  %s\n' "$(date -Is)" "$*"; }

shrink_btrfs() {
  log "shrinking the Btrfs on $omarchy_dev"
  local mnt; mnt=$(mktemp -d)
  mount -o subvolid=5 "$omarchy_dev" "$mnt"
  local size_bytes; size_bytes=$(blockdev --getsize64 "$omarchy_dev")
  local new_bytes=$(( size_bytes - (esp_size_mib + luks_reserve_mib) * 1024 * 1024 ))
  btrfs filesystem resize "$new_bytes" "$mnt"
  btrfs filesystem usage -T "$mnt" | grep -E "Device size|Used:" | head -2
  umount "$mnt"; rmdir "$mnt"
}

repartition() {
  log "shortening partition $omarchy_num and creating the new ESP"
  [[ -f $gpt_backup ]] || sgdisk --backup="$gpt_backup" "$disk" >/dev/null
  # This disk reports 4096-byte logical sectors, so a MiB is 256 sectors, not the
  # 2048 a 512-byte disk would give; taking it from the device keeps both right.
  local start end sectors_per_mib
  sectors_per_mib=$(( 1024 * 1024 / $(blockdev --getss "$disk") ))
  local align=$(( 1024 * 1024 / $(blockdev --getss "$disk") ))
  start=$(sgdisk -i "$omarchy_num" "$disk" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  end=$(sgdisk -i "$omarchy_num" "$disk" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
  local esp_sectors=$(( esp_size_mib * sectors_per_mib ))
  local new_end=$(( end - esp_sectors ))
  new_end=$(( new_end - (new_end + 1) % align ))   # keep the next partition 1 MiB aligned
  local esp_start=$(( new_end + 1 ))
  local new_esp_num=$(( omarchy_num + 1 ))
  echo "sector size $(blockdev --getss "$disk") B; ESP ${esp_size_mib} MiB = ${esp_sectors} sectors; $omarchy_num now ends at $new_end"
  sgdisk -d "$omarchy_num" \
    -n "$omarchy_num:$start:$new_end" -t "$omarchy_num:8309" -c "$omarchy_num:omarchy" -u "$omarchy_num:$omarchy_partuuid" \
    -n "$new_esp_num:$esp_start:$end" -t "$new_esp_num:EF00" -c "$new_esp_num:ESP" \
    -c "${old_esp_dev##*[a-z]}:esp-old" "$disk"
  partprobe "$disk"; sleep 2
  sgdisk -p "$disk" | tail -6
  local new_esp_dev="${disk}${new_esp_num}"
  log "formatting $new_esp_dev and copying the ESP"
  mkfs.fat -F32 -n ESP "$new_esp_dev" >/dev/null
  local src dst; src=$(mktemp -d); dst=$(mktemp -d)
  mount "$old_esp_dev" "$src"; mount "$new_esp_dev" "$dst"
  cp -a "$src/." "$dst/"
  df -h "$dst" | tail -1
  umount "$src" "$dst"; rmdir "$src" "$dst"
}

encrypt() {
  load_dm_modules
  log "encrypting $omarchy_dev in place (software AES on this CPU: expect ~20 min)"
  install -d -m700 "$key_dir"
  [[ -f $key_dir/crypto_keyfile.bin ]] || { dd if=/dev/urandom of="$key_dir/crypto_keyfile.bin" bs=512 count=1 status=none; chmod 600 "$key_dir/crypto_keyfile.bin"; }
  [[ -f $key_dir/passphrase ]] || { tr -dc 'a-z0-9' </dev/urandom | head -c 24 > "$key_dir/passphrase"; chmod 600 "$key_dir/passphrase"; }
  cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size "${luks_reserve_mib}M" \
    --key-file "$key_dir/crypto_keyfile.bin" --batch-mode --progress-frequency 60 "$omarchy_dev"
  cryptsetup luksAddKey --key-file "$key_dir/crypto_keyfile.bin" "$omarchy_dev" "$key_dir/passphrase"
  cryptsetup luksDump "$omarchy_dev" | grep -E "^Version|Keyslots|^  [0-9]+: luks2" | head -4
}

configure() {
  load_dm_modules
  log "configuring the Arch root under /dev/mapper/root"
  cryptsetup status root >/dev/null 2>&1 || cryptsetup open --key-file "$key_dir/crypto_keyfile.bin" "$omarchy_dev" root
  local root=/mnt/omarchy-root esp_dev btrfs_uuid esp_partuuid
  esp_dev=$(findfs PARTLABEL=ESP)
  esp_partuuid=$(blkid -o value -s PARTUUID "$esp_dev")
  btrfs_uuid=$(blkid -o value -s UUID /dev/mapper/root)
  install -d "$root"
  mountpoint -q "$root" || mount -o subvol=@,compress=zstd /dev/mapper/root "$root"
  for sub in home:@home var/log:@log var/cache/pacman/pkg:@pkg .snapshots:@snapshots; do
    mountpoint -q "$root/${sub%%:*}" || mount -o "subvol=${sub##*:},compress=zstd" /dev/mapper/root "$root/${sub%%:*}"
  done
  mountpoint -q "$root/boot" || mount "$esp_dev" "$root/boot"

  # fstab: every Btrfs line by the filesystem UUID (unchanged by encryption, and
  # it resolves to the mapper once the root is open), /boot by the new ESP.
  python3 - "$root/etc/fstab" "$btrfs_uuid" "$esp_partuuid" <<'PY'
import re, sys
path, uuid, esp = sys.argv[1:4]
out = []
for line in open(path):
    f = line.split()
    if len(f) >= 3 and not line.lstrip().startswith('#'):
        if f[2] == 'btrfs':
            f[0] = 'UUID=' + uuid
            line = '  '.join(f) + '\n'
        elif f[1] == '/boot':
            f[0] = 'PARTUUID=' + esp
            line = '  '.join(f) + '\n'
    out.append(line)
open(path, 'w').write(''.join(out))
PY
  grep -E "btrfs|/boot" "$root/etc/fstab"

  # the keyfile the initramfs carries, as the encrypt hook's cryptkey=rootfs:/path reads it
  install -m600 "$key_dir/crypto_keyfile.bin" "$root/crypto_keyfile.bin"
  cat > "$root/etc/mkinitcpio.conf.d/omarchy_k3_cryptkey.conf" <<'EOF'
# The LUKS key the encrypt hook unlocks the root with (cryptkey=rootfs:/crypto_keyfile.bin).
# Upstream types a passphrase instead; this board's only console is the provider's
# serial terminal, so the key travels inside the initramfs and the boot stays unattended.
FILES+=(/crypto_keyfile.bin)
EOF
  chmod 600 "$root/etc/mkinitcpio.conf.d/omarchy_k3_cryptkey.conf"

  # the command line: upstream's encrypted-root form
  python3 - "$root/etc/default/limine" "$omarchy_partuuid" <<'PY'
import re, sys
path, partuuid = sys.argv[1:3]
s = open(path).read()
s = re.sub(r'root=PARTUUID=' + re.escape(partuuid),
           'cryptdevice=PARTUUID=%s:root cryptkey=rootfs:/crypto_keyfile.bin root=/dev/mapper/root' % partuuid,
           s, count=1)
open(path, 'w').write(s)
PY
  grep -n "cryptdevice" "$root/etc/default/limine" | cut -c1-170

  log "rebuilding the UKI and the entries inside the Arch root"
  # limine-update rewrites the menu; keep the default entry install-limine.sh chose.
  K3_NEWROOT="$root" bash "$port_dir/arch-chroot.sh" 'default=$(grep -m1 "^default_entry:" /boot/limine.conf); limine-update && limine-snapper-sync || true; [[ -n $default ]] && sed -i "s|^default_entry: .*|$default|" /boot/limine.conf; grep -n "^default_entry" /boot/limine.conf; df -h /boot | tail -1; grep -nE "cmdline:" /boot/limine.conf | head -3 | cut -c1-150'
  umount -R "$root"
  cryptsetup close root
  log "done; reboot into the Omarchy entry"
}

case $step in
  shrink) shrink_btrfs ;;
  repartition) repartition ;;
  encrypt) encrypt ;;
  configure) configure ;;
  all) shrink_btrfs; repartition; encrypt; configure ;;
  *) echo "usage: $0 [shrink|repartition|encrypt|configure|all]" >&2; exit 1 ;;
esac
