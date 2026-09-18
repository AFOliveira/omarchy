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
  # The keeper is the second process of each bounded job, so it shares the
  # command's process group, whose ID is the command's PID and stays reserved
  # while the keeper lives. It polls that PID, treating only "No such process"
  # as gone, and at its deadline kills its own group, which cannot be anyone
  # else's. It ignores job-control signals, so neither an interrupt at the
  # terminal nor this shell's death leaves the command unbounded. It runs
  # without the caller's environment and fails fast without /proc.
  ssh_migration_keeper='trap "" HUP INT QUIT TERM TSTP TTIN TTOU
  read -r _ _ _ _ group _ </proc/self/stat || exit 3
  [[ $group =~ ^[0-9]+$ ]] || exit 3
  started=$SECONDS
  while status=$(kill -0 "$group" 2>&1) || [[ $status != *"No such process"* ]]; do
    (( SECONDS - started < $1 )) || kill -KILL -- "-$group"
    /usr/bin/sleep 0.2
  done'
  # Runs a command as a foreground job under job control: a direct child of
  # this shell, which sudo needs under timestamp_type=ppid or without a
  # terminal, in a process group of its own, so a signal to this shell's group
  # does not reach it. A signal to this shell waits for the job, which the
  # keeper bounds. Its status is the command's.
  run_ssh_migration_bounded() {
    local - bound=$1 status
    shift
    set -m
    "$@" >&2 | /usr/bin/env -i /usr/bin/bash -p -c "$ssh_migration_keeper" omarchy-cleanup-keeper "$bound"
    status=("${PIPESTATUS[@]}")
    set +m
    (( status[1] == 0 )) || return 125
    return "${status[0]}"
  }
  # An environment without bounded jobs leaves the migration pending before
  # anything privileged instead of its revocation unbounded.
  if ! run_ssh_migration_bounded 5 /usr/bin/true 2>/dev/null; then
    echo "Could not start a bounded job for the SSH migration's cleanup." >&2
    exit 1
  fi
  # Once cleanup starts, a signal is held rather than acted on: the exit
  # revocation must finish, and its job bounds it.
  ssh_migration_cleaning=false
  ssh_migration_revoke_bound=30
  handle_ssh_migration_signal() {
    [[ $ssh_migration_cleaning != "true" ]] || return 0
    ssh_migration_cleaning=true
    exit "$1"
  }
  cleanup_ssh_migration_sudo() {
    local status=$ssh_migration_status attempt revoked=false
    trap - EXIT
    for attempt in 1 2 3; do
      if run_ssh_migration_bounded "$ssh_migration_revoke_bound" /usr/bin/sudo -k 2>/dev/null; then
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
