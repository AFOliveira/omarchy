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
  cleanup_ssh_migration_sudo() {
    local status=$?
    trap - EXIT
    # A second signal must not interrupt the revocation; a handler rather than
    # an ignored disposition keeps sudo itself interruptible.
    trap ':' HUP INT TERM
    /usr/bin/sudo -k >/dev/null 2>&1 || status=1
    exit "$status"
  }
  # Traps first, so a failure or signal during the entry revocation still
  # revokes on the way out.
  trap cleanup_ssh_migration_sudo EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  /usr/bin/sudo -k
  /usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only
  /usr/bin/sudo -k
  trap - EXIT HUP INT TERM
fi
