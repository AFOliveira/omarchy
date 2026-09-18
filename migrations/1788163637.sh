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

# One root phase through sudo -N, which may use an authorization sudo already
# has but never creates or refreshes one, so the migration leaves nothing
# cached to revoke.
if ((EUID == 0)); then
  /usr/bin/omarchy-migrate-sshd-key-only
else
  /usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only
fi
