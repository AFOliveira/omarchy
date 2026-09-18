echo "Upgrade Omarchy-managed SSH hardening to a machine-validated key-only policy"

legacy_config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf

# The machine phase only repairs the file old Omarchy wrote. Once one account
# has converted the machine, or on a machine that never had that file, later
# accounts finish here without privileges instead of prompting, or failing
# outright when they cannot use sudo.
if [[ ! -e $legacy_config && ! -L $legacy_config ]]; then
  exit 0
fi

if ((EUID == 0)); then
  /usr/bin/omarchy-migrate-sshd-key-only
else
  /usr/bin/sudo -k
  cleanup_ssh_migration_sudo() {
    local status=$?
    trap - EXIT HUP INT TERM
    /usr/bin/sudo -k >/dev/null 2>&1 || status=1
    exit "$status"
  }
  trap cleanup_ssh_migration_sudo EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  /usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only
  /usr/bin/sudo -k
  trap - EXIT HUP INT TERM
fi
