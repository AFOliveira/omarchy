echo "Upgrade Omarchy-managed SSH hardening to a machine-validated key-only policy"

legacy_config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf
key_only_config=/etc/ssh/sshd_config.d/00-omarchy-key-only.conf
completion_marker=/var/lib/omarchy/migrations/1788163637

# The machine phase repairs the file old Omarchy wrote and validates a
# key-only file that was never certified, such as one an interrupted setup
# left behind. With neither, or once a validated conversion is recorded, later
# accounts finish here without privileges instead of prompting, or failing
# outright when they cannot use sudo.
if [[ ! -e $legacy_config && ! -L $legacy_config ]]; then
  if [[ ! -e $key_only_config && ! -L $key_only_config ]]; then
    exit 0
  fi
  if [[ -f $completion_marker && ! -L $completion_marker && $(/usr/bin/stat -c %u -- "$completion_marker" 2>/dev/null) == 0 ]]; then
    exit 0
  fi
fi

if ((EUID == 0)); then
  /usr/bin/omarchy-migrate-sshd-key-only
else
  # Once cleanup starts, a signal is held rather than acted on: the exit
  # revocation must finish, and timeout bounds it instead. timeout runs sudo
  # in its own process group, and an attempt that fails anyway is retried.
  ssh_migration_cleaning=false
  handle_ssh_migration_signal() {
    [[ $ssh_migration_cleaning == "true" ]] && return
    ssh_migration_cleaning=true
    exit "$1"
  }
  cleanup_ssh_migration_sudo() {
    local status=$? attempt revoke revoke_status=1
    ssh_migration_cleaning=true
    trap - EXIT
    for attempt in 1 2 3; do
      /usr/bin/timeout -k 5 30 /usr/bin/sudo -k >/dev/null 2>&1 &
      revoke=$!
      while :; do
        wait "$revoke" && revoke_status=0 || revoke_status=$?
        kill -0 "$revoke" 2>/dev/null || break
      done
      (( revoke_status != 0 )) || break
    done
    (( revoke_status == 0 )) || status=1
    exit "$status"
  }
  # Traps first, so a failure or signal during the entry revocation still
  # revokes on the way out.
  trap cleanup_ssh_migration_sudo EXIT
  trap 'handle_ssh_migration_signal 129' HUP
  trap 'handle_ssh_migration_signal 130' INT
  trap 'handle_ssh_migration_signal 143' TERM
  /usr/bin/sudo -k
  /usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only
  /usr/bin/sudo -k
  trap - EXIT HUP INT TERM
fi
