echo "Remember Bluetooth on and off through the rfkill soft block"

marker=/var/lib/omarchy/migrations/1786380259
main_conf=/etc/bluetooth/main.conf

repair_machine() {
  local controllers="" controller details powered=0 daemon
  [[ ! -e $marker ]] || return 0

  # bluetoothd runs only with an adapter present and the service allowed.
  # With no daemon to ask, which is inactive (3) or no such unit (4), the
  # adapter has been off, and that is the state to keep. A running daemon
  # that cannot be asked, or an unknown service state, stays pending.
  /usr/bin/systemctl is-active --quiet bluetooth.service 2>/dev/null && daemon=0 || daemon=$?
  if (( daemon == 0 )); then
    controllers=$(/usr/bin/timeout 2s /usr/bin/bluetoothctl list) || {
      echo "Could not read Bluetooth power state; leaving the migration pending." >&2
      return 1
    }
  elif (( daemon != 3 && daemon != 4 )); then
    echo "Could not inspect bluetooth.service; leaving the migration pending." >&2
    return 1
  fi
  while read -r _ controller _; do
    [[ -n ${controller:-} ]] || continue
    details=$(/usr/bin/timeout 2s /usr/bin/bluetoothctl show "$controller") || {
      echo "Could not read Bluetooth controller $controller; leaving the migration pending." >&2
      return 1
    }
    [[ $details == *"Powered: yes"* ]] && powered=1
  done <<<"$controllers"

  if (( powered )); then
    /usr/bin/omarchy-bluetooth-power on || return 1
  else
    /usr/bin/omarchy-bluetooth-power off || return 1
  fi
  if [[ -f $main_conf ]]; then
    /usr/bin/sed -i 's/^AutoEnable=false$/#AutoEnable=true/' "$main_conf" || return 1
  fi
  /usr/bin/install -Dm644 /dev/null "$marker" || return 1
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
