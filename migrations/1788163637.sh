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
  # revocation must finish. It stays a direct child of this shell, since under
  # timestamp_type=ppid, and without a terminal, sudo keys the cached
  # authorization by its parent. Its stdout is a pipe only it holds, so its
  # exit arrives as end-of-file and read's own timeout bounds it, with no
  # watchdog process to lose or leave behind. A failed attempt, such as one a
  # signal to the whole group killed, is retried.
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
  revoke_pipe_closed() {
    local started=$SECONDS status
    while (( SECONDS - started < $2 )); do
      read -r -t 1 -u "$1" _ && continue
      status=$?
      (( status > 128 )) || return 0
    done
    return 1
  }
  revoke_ssh_migration_sudo_once() {
    local bound=30 pipe="" reader="" writer="" revoke
    # Without descriptors for the pipe, revoke unbounded rather than not at all.
    if ! { exec {pipe}<> <(:); } 2>/dev/null; then
      /usr/bin/sudo -k >/dev/null 2>&1
      return
    fi
    { exec {reader}<"/dev/fd/$pipe"; } 2>/dev/null || reader=""
    [[ -z $reader ]] || { exec {writer}>"/dev/fd/$pipe"; } 2>/dev/null || writer=""
    exec {pipe}>&-
    if [[ -z $reader || -z $writer ]]; then
      [[ -z $reader ]] || exec {reader}<&-
      /usr/bin/sudo -k >/dev/null 2>&1
      return
    fi
    /usr/bin/sudo -k 2>/dev/null >&"$writer" {reader}<&- &
    revoke=$!
    exec {writer}>&-
    if revoke_pipe_closed "$reader" "$bound"; then
      exec {reader}<&-
      wait_for_ssh_migration_revoke "$revoke"
      return
    fi
    # The pipe is still open, so its only holder is alive and the PID its own.
    kill -KILL "$revoke" 2>/dev/null || true
    # A revoker that does not go even then is abandoned, not waited on forever.
    if revoke_pipe_closed "$reader" 2; then
      exec {reader}<&-
      wait_for_ssh_migration_revoke "$revoke" || true
    else
      exec {reader}<&-
    fi
    return 1
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
