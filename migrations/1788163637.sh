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
  # The final revocation stays a direct child of this shell: under
  # timestamp_type=ppid, and without a terminal, sudo keys the cached
  # authorization by its parent, so an intermediary would revoke some other
  # record and still succeed. Job control gives it a process group of its own
  # in the same session, so a signal to this shell's group does not reach it,
  # and the group ID stays reserved while it or anything it started lives.
  # The wait is bounded by polling that group, pausing on a descriptor
  # reserved before the first privileged call; no watchdog process is involved.
  # A failed attempt is retried. Running out of descriptors for that pause
  # leaves the migration pending instead of its revocation unbounded.
  ssh_migration_clock=""
  if ! { exec {ssh_migration_clock}<> <(:); } 2>/dev/null; then
    echo "Could not reserve a descriptor for the SSH migration's cleanup." >&2
    exit 1
  fi
  # Once cleanup starts, a signal is held rather than acted on: the exit
  # revocation must finish.
  ssh_migration_cleaning=false
  handle_ssh_migration_signal() {
    [[ $ssh_migration_cleaning == "true" ]] && return
    ssh_migration_cleaning=true
    exit "$1"
  }
  wait_for_ssh_migration_revoke() {
    local status
    while :; do
      wait "$1" && status=0 || status=$?
      kill -0 "$1" 2>/dev/null || break
    done
    return "$status"
  }
  # Pauses up to a second, or until a signal arrives, without a child process.
  ssh_migration_pause() {
    read -r -t 1 -u "$ssh_migration_clock" _ || true
  }
  revoke_ssh_migration_sudo_once() {
    local bound=30 revoke started
    set -m
    /usr/bin/sudo -k >/dev/null 2>&1 &
    revoke=$!
    set +m
    started=$SECONDS
    while kill -0 -- "-$revoke" 2>/dev/null && (( SECONDS - started < bound )); do ssh_migration_pause; done
    if kill -0 -- "-$revoke" 2>/dev/null; then
      # A live group keeps its ID reserved, so this reaches only the revoker
      # and anything it left behind. One that survives even this is abandoned
      # rather than waited on forever.
      kill -KILL -- "-$revoke" 2>/dev/null || true
      started=$SECONDS
      while kill -0 -- "-$revoke" 2>/dev/null && (( SECONDS - started < 2 )); do ssh_migration_pause; done
      ! kill -0 -- "-$revoke" 2>/dev/null || return 1
    fi
    wait_for_ssh_migration_revoke "$revoke"
  }
  cleanup_ssh_migration_sudo() {
    local status=$ssh_migration_status attempt revoked=false
    trap - EXIT
    for attempt in 1 2 3; do
      if revoke_ssh_migration_sudo_once; then
        revoked=true
        break
      fi
    done
    [[ $revoked == "true" ]] || status=1
    exit "$status"
  }
  # Traps first, so a failure or signal during the entry revocation still
  # revokes on the way out. One assignment-only command records the status
  # and marks cleanup active, so no handler can run between the two.
  trap 'ssh_migration_status=$? ssh_migration_cleaning=true; cleanup_ssh_migration_sudo' EXIT
  trap 'handle_ssh_migration_signal 129' HUP
  trap 'handle_ssh_migration_signal 130' INT
  trap 'handle_ssh_migration_signal 143' TERM
  /usr/bin/sudo -k
  /usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only
  /usr/bin/sudo -k
  trap - EXIT HUP INT TERM
fi
