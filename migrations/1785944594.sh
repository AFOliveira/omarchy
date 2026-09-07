echo "Update T2 Mac suspend, Touch Bar, and fan defaults"

limine_conf=/etc/limine-entry-tool.d/t2-mac.conf
fan_conf=/etc/t2fand.conf
running_cmdline=/proc/cmdline
repair_marker=/var/lib/omarchy/migrations/1785944594

is_t2_mac() {
  local devices
  devices=$(/usr/bin/lspci -nn) || return 2
  [[ $devices =~ 106b:180[12] ]]
}

tiny_dfr_installed() {
  local packages
  packages=$(/usr/bin/pacman -Qq) || return 2
  [[ $'\n'$packages$'\n' == *$'\ntiny-dfr\n'* ]]
}

needs_machine_repair() {
  local status
  if is_t2_mac; then
    :
  else
    status=$?
    (( status == 1 )) && return 1
    return 2
  fi
  [[ ! -e $repair_marker ]] || return 1
  if [[ -f $limine_conf ]] && /usr/bin/grep -q 'pcie_ports=compat' "$limine_conf"; then return 0; fi
  if [[ -f $fan_conf ]] && ! /usr/bin/grep -Eq '^[[:space:]]*\[Fan2\][[:space:]]*$' "$fan_conf"; then return 0; fi
  if tiny_dfr_installed; then
    return 0
  else
    status=$?
    (( status == 1 )) || return 2
  fi
  if [[ -f $limine_conf ]] && /usr/bin/grep -q 'pm_async=off' "$limine_conf" &&
    /usr/bin/grep -q 'mem_sleep_default=deep' "$limine_conf" &&
    { [[ ! -r $running_cmdline ]] || ! /usr/bin/grep -Eq '(^| )pm_async=off( |$)' "$running_cmdline" ||
      ! /usr/bin/grep -Eq '(^| )mem_sleep_default=deep( |$)' "$running_cmdline"; }; then return 0; fi
  return 1
}

repair_machine() {
  local rebuild=0
  local status
  if needs_machine_repair; then
    :
  else
    status=$?
    (( status == 1 )) && return 0
    echo "Could not inspect T2 hardware or packages; leaving the repair pending." >&2
    return 1
  fi
  if [[ -f $limine_conf ]] && /usr/bin/grep -q 'pcie_ports=compat' "$limine_conf"; then
    /usr/bin/sed -i 's/pcie_ports=compat/pm_async=off mem_sleep_default=deep/' "$limine_conf"
    rebuild=1
  fi
  if [[ -f $fan_conf ]] && ! /usr/bin/grep -Eq '^[[:space:]]*\[Fan2\][[:space:]]*$' "$fan_conf"; then
    /usr/bin/tee -a "$fan_conf" >/dev/null <<'EOF'

[Fan2]
low_temp=55
high_temp=75
speed_curve=linear
always_full_speed=false
EOF
  fi
  if tiny_dfr_installed; then
    /usr/bin/systemctl disable --now tiny-dfr.service || true
    /usr/bin/env OMARCHY_UPDATE_PACMAN=1 /usr/bin/pacman -Rns --noconfirm -- tiny-dfr
  else
    status=$?
    if (( status != 1 )); then
      echo "Could not inspect installed packages; leaving the T2 repair pending." >&2
      return 1
    fi
  fi
  if [[ -f $limine_conf ]] && /usr/bin/grep -q 'pm_async=off' "$limine_conf" &&
    /usr/bin/grep -q 'mem_sleep_default=deep' "$limine_conf" &&
    { [[ ! -r $running_cmdline ]] || ! /usr/bin/grep -Eq '(^| )pm_async=off( |$)' "$running_cmdline" ||
      ! /usr/bin/grep -Eq '(^| )mem_sleep_default=deep( |$)' "$running_cmdline"; }; then rebuild=1; fi
  if (( rebuild )); then /usr/bin/limine-mkinitcpio; fi
  /usr/bin/install -Dm644 /dev/null "$repair_marker"
}

if (( $# == 0 )); then
  if needs_machine_repair; then
    :
  else
    status=$?
    (( status == 1 )) && exit 0
    echo "Could not inspect T2 hardware or packages; leaving the repair pending." >&2
    exit 1
  fi
  /usr/bin/sudo -N -- /usr/bin/flock --exclusive --no-fork /run/omarchy-t2-hardware-migration.lock \
    /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/bash -p -euo pipefail /usr/share/omarchy/migrations/1785944594.sh --machine
elif (( $# == 1 && EUID == 0 )) && [[ $1 == "--machine" ]]; then
  repair_machine
else
  echo "This migration accepts no arguments; its machine phase requires root." >&2
  exit 1
fi
