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
  # in the same session, so a signal to this shell's group does not reach it.
  # The wait is bounded by reading reports on a descriptor reserved before the
  # first privileged call, and a failed attempt is retried.
  # The keeper shares the revoker's process group. It reports that group, then
  # polls the revoker's PID, which cannot be reused while the keeper holds it as
  # the group ID, so "No such process" means the revoker exited and was reaped.
  # It then waits for this shell's release, so the group ID stays reserved
  # until the shell is finished with it. It runs without the caller's
  # environment, and exits 0, so the job status is the revoker's.
  ssh_migration_revoke_keeper='read -r _ _ _ _ group _ </proc/self/stat
  printf "group %s %s\n" "$group" "$1" >&3
  while status=$(kill -0 "$group" 2>&1) || [[ $status != *"No such process"* ]]; do
    read -r -t 0.2 -u 4 _ _ || true
  done
  printf "done - %s\n" "$1" >&3
  while read -r -u 4 word serial; do
    [[ $word != release || $serial != "$1" ]] || exit 0
  done'
  # Running out of descriptors for its reports leaves the migration pending
  # instead of its revocation unbounded.
  ssh_migration_clock=""
  ssh_migration_hold=""
  if ! { exec {ssh_migration_clock}<> <(:); } 2>/dev/null || ! { exec {ssh_migration_hold}<> <(:); } 2>/dev/null; then
    echo "Could not reserve a descriptor for the SSH migration's cleanup." >&2
    exit 1
  fi
  # Once cleanup starts, a signal is held rather than acted on: the exit
  # revocation must finish.
  ssh_migration_cleaning=false
  ssh_migration_wait_interrupted=false
  ssh_migration_revoke_serial=0
  handle_ssh_migration_signal() {
    if [[ $ssh_migration_cleaning == "true" ]]; then
      ssh_migration_wait_interrupted=true
      return
    fi
    ssh_migration_cleaning=true
    exit "$1"
  }
  # wait returns early when a trapped signal arrives; only then is it
  # repeated, never by probing a PID that may already belong to someone else.
  wait_for_ssh_migration_revoke() {
    local status=127 result
    while :; do
      ssh_migration_wait_interrupted=false
      wait "$1" && result=0 || result=$?
      (( result == 127 && status != 127 )) || status=$result
      [[ $ssh_migration_wait_interrupted == "true" && $result != 127 ]] || break
    done
    return "$status"
  }
  # Pauses up to a second, or until a signal arrives, without a child process.
  ssh_migration_pause() {
    read -r -t 1 -u "$ssh_migration_clock" _ || true
  }
  revoke_ssh_migration_sudo_once() {
    local - bound=30 serial keeper word value tag group="" finished=false started
    set -o pipefail
    ssh_migration_revoke_serial=$(( ssh_migration_revoke_serial + 1 ))
    serial=$ssh_migration_revoke_serial
    set -m
    /usr/bin/sudo -k >/dev/null 2>&1 |
      /usr/bin/env -i /usr/bin/bash -p -c "$ssh_migration_revoke_keeper" omarchy-revoke-keeper "$serial" 3>&"$ssh_migration_clock" 4<&"$ssh_migration_hold" &
    keeper=$!
    set +m
    started=$SECONDS
    while (( SECONDS - started < bound )); do
      read -r -t 1 -u "$ssh_migration_clock" word value tag || continue
      [[ $tag == "$serial" ]] || continue
      if [[ $word == "group" ]]; then
        group=$value
      elif [[ $word == "done" ]]; then
        finished=true
        break
      fi
    done
    if [[ $finished == "true" ]]; then
      printf 'release %s\n' "$serial" >&"$ssh_migration_hold"
      # Bash reports a job it started under job control; that report is noise.
      wait_for_ssh_migration_revoke "$keeper" 2>/dev/null
      return
    fi
    # Past the deadline, the group is killed while the keeper still reserves
    # its ID; without the keeper's report there is nothing safe to signal.
    [[ -n $group ]] || return 1
    kill -KILL -- "-$group" 2>/dev/null || true
    started=$SECONDS
    while kill -0 -- "-$group" 2>/dev/null && (( SECONDS - started < 2 )); do ssh_migration_pause; done
    # One that survives even this is abandoned rather than waited on forever.
    ! kill -0 -- "-$group" 2>/dev/null || return 1
    wait_for_ssh_migration_revoke "$keeper" 2>/dev/null || true
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
