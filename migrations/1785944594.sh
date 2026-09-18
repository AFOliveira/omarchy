echo "Update T2 Mac suspend, Touch Bar, and fan defaults"

limine_conf=/etc/limine-entry-tool.d/t2-mac.conf
fan_conf=/etc/t2fand.conf
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

# Only active lines count: a commented-out parameter is not configured. A
# read error is reported as such rather than as an empty configuration.
limine_active_lines() {
  local status=0
  /usr/bin/grep -v '^[[:space:]]*#' "$limine_conf" || status=$?
  (( status <= 1 )) || return 2
}

# 0 when every given parameter is an exact command-line token, 1 when one is
# not, 2 when the drop-in cannot be read. Tokens are delimited by whitespace
# and quotes, as in KERNEL_CMDLINE[default]+=" ... pm_async=off ...".
limine_has_tokens() {
  local active wanted token found
  local -a tokens
  active=$(limine_active_lines) || return 2
  active=${active//[\"\']/ }
  read -r -a tokens <<<"${active//$'\n'/ }"
  for wanted in "$@"; do
    found=1
    for token in "${tokens[@]}"; do
      [[ $token == "$wanted" ]] && { found=0; break; }
    done
    (( found == 0 )) || return 1
  done
}

# Decide without privileges whether any repair remains, so a later account
# with nothing to do never prompts. An unreadable file is left to the root
# phase, which rechecks everything with full access.
needs_machine_repair() {
  local status
  if is_t2_mac; then
    :
  else
    status=$?
    (( status == 1 )) && return 1
    return 2
  fi
  if [[ -e $limine_conf && ! -r $limine_conf ]] || [[ -e $fan_conf && ! -r $fan_conf ]]; then
    return 0
  fi
  if [[ -f $limine_conf ]]; then
    limine_has_tokens pcie_ports=compat && return 0 || { status=$?; (( status == 1 )) || return 2; }
  fi
  if [[ -f $fan_conf ]] && ! /usr/bin/grep -Eq '^[[:space:]]*\[Fan2\][[:space:]]*$' "$fan_conf"; then return 0; fi
  if tiny_dfr_installed; then
    return 0
  else
    status=$?
    (( status == 1 )) || return 2
  fi
  # The marker records a successful rebuild of the new parameters and nothing
  # else, so a rebuild is pending only while they are configured without it.
  if [[ -f $limine_conf ]] && [[ ! -e $repair_marker ]]; then
    limine_has_tokens pm_async=off mem_sleep_default=deep && return 0 || { status=$?; (( status == 1 )) || return 2; }
  fi
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
  if [[ -f $limine_conf ]]; then
    if limine_has_tokens pcie_ports=compat; then
      /usr/bin/sed -E -i '/^[[:space:]]*#/!s/(^|[[:space:]"'"'"'])pcie_ports=compat($|[[:space:]"'"'"'])/\1pm_async=off mem_sleep_default=deep\2/g' "$limine_conf" || return 1
      rebuild=1
    else
      status=$?
      (( status == 1 )) || return 1
    fi
  fi
  if [[ -f $fan_conf ]] && ! /usr/bin/grep -Eq '^[[:space:]]*\[Fan2\][[:space:]]*$' "$fan_conf"; then
    /usr/bin/tee -a "$fan_conf" >/dev/null <<'EOF' || return 1

[Fan2]
low_temp=55
high_temp=75
speed_curve=linear
always_full_speed=false
EOF
  fi
  if tiny_dfr_installed; then
    /usr/bin/systemctl disable --now tiny-dfr.service || true
    /usr/bin/env OMARCHY_UPDATE_PACMAN=1 /usr/bin/pacman -Rns --noconfirm -- tiny-dfr || return 1
  else
    status=$?
    if (( status != 1 )); then
      echo "Could not inspect installed packages; leaving the T2 repair pending." >&2
      return 1
    fi
  fi
  if [[ -f $limine_conf ]] && [[ ! -e $repair_marker ]]; then
    if limine_has_tokens pm_async=off mem_sleep_default=deep; then
      rebuild=1
    else
      status=$?
      (( status == 1 )) || return 1
    fi
  fi
  # Publish completion only for a successful rebuild of the new parameters.
  # Without them there is nothing to certify, and a marker would stop a later
  # run from rebuilding once they are configured.
  if (( rebuild )); then
    /usr/bin/limine-mkinitcpio || return 1
    limine_has_tokens pm_async=off mem_sleep_default=deep || return 1
    /usr/bin/install -Dm644 /dev/null "$repair_marker" || return 1
  fi
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
