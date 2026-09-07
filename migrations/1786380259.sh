echo "Remember Bluetooth on and off through the rfkill soft block"

marker=/var/lib/omarchy/migrations/1786380259
main_conf=/etc/bluetooth/main.conf

repair_machine() {
  [[ ! -e $marker ]] || return 0
  if /usr/bin/omarchy-bluetooth-power is-on; then
    /usr/bin/omarchy-bluetooth-power on
  else
    /usr/bin/omarchy-bluetooth-power off
  fi
  if [[ -f $main_conf ]]; then
    /usr/bin/sed -i 's/^AutoEnable=false$/#AutoEnable=true/' "$main_conf"
  fi
  /usr/bin/install -Dm644 /dev/null "$marker"
}

if (( $# == 0 )); then
  [[ ! -e $marker ]] || exit 0
  /usr/bin/sudo -N -- /usr/bin/flock --exclusive --no-fork /run/omarchy-bluetooth-state-migration.lock \
    /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/bash -p -euo pipefail /usr/share/omarchy/migrations/1786380259.sh --machine
elif (( $# == 1 && EUID == 0 )) && [[ $1 == "--machine" ]]; then
  repair_machine
else
  echo "This migration accepts no arguments; its machine phase requires root." >&2
  exit 1
fi
