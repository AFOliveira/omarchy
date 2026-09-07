echo "Separate printer discovery from root and print-filter access"

machine_marker=/var/lib/omarchy/migrations/1787815267

cups_installed() { /usr/bin/pacman -Qq cups &>/dev/null; }

repair_machine() {
  local account="" group="" uid="" gid="" description="" home="" shell="" group_gid="" members="" other_primary_user=""
  [[ ! -e $machine_marker ]] || return 0

  if cups_installed; then
    account=$(/usr/bin/getent passwd cups-browsed || true)
    group=$(/usr/bin/getent group cups-browsed || true)
    if [[ -n $account || -n $group ]]; then
      IFS=: read -r _ _ uid gid description home shell <<<"$account"
      IFS=: read -r _ _ group_gid members <<<"$group"
      other_primary_user=$(/usr/bin/getent passwd | /usr/bin/awk -F: -v gid="$gid" '$1 != "cups-browsed" && $4 == gid { print $1; exit }')
      if [[ ! $uid =~ ^[0-9]+$ || ! $group_gid =~ ^[0-9]+$ ]] ||
        (( uid <= 0 || uid >= 1000 )) || [[ $gid != "$group_gid" ]] ||
        [[ $description != "CUPS printer discovery" || $home != "/" || $shell != "/usr/bin/nologin" ]] ||
        [[ -n $members || -n $other_primary_user ]]; then
        echo "Cannot harden printer discovery: the existing cups-browsed user or group is not a dedicated system account." >&2
        return 1
      fi
    fi
  fi

  if /usr/bin/pacman -Qq cups-pdf &>/dev/null; then
    /usr/bin/env OMARCHY_UPDATE_PACMAN=1 /usr/bin/pacman -Rns --noconfirm -- cups-pdf
  fi
  if cups_installed && ! /usr/bin/pacman -Qq cups-pk-helper &>/dev/null; then
    /usr/bin/env OMARCHY_UPDATE_PACMAN=1 /usr/bin/pacman -S --needed --noconfirm -- cups-pk-helper
  fi
  if /usr/bin/systemctl is-active --quiet cups-browsed.service 2>/dev/null; then
    /usr/bin/systemctl stop cups-browsed.service
  fi
  if cups_installed; then
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl try-reload-or-restart cups.service
  fi
  if /usr/bin/systemctl is-enabled --quiet cups-browsed.service 2>/dev/null; then
    /usr/bin/systemctl restart cups-browsed.service
  fi
  /usr/bin/install -Dm644 /dev/null "$machine_marker"
}

if (( $# == 0 )); then
  [[ ! -e $machine_marker ]] || exit 0
  /usr/bin/sudo -N -- /usr/bin/flock --exclusive --no-fork /run/omarchy-cups-hardening-migration.lock \
    /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/bash -p -euo pipefail /usr/share/omarchy/migrations/1787815267.sh --machine
elif (( $# == 1 && EUID == 0 )) && [[ $1 == "--machine" ]]; then
  repair_machine
else
  echo "This migration accepts no arguments; its machine phase requires root." >&2
  exit 1
fi
