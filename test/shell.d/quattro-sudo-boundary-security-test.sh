#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"
copy_boundary_file bin/omarchy-upgrade-to-quattro
for command in omarchy-migrate omarchy-update-aur-pkgs; do
  rm "$SUDO_TEST_ROOT/bin/$command"
  copy_boundary_file "bin/$command"
done
export OMARCHY_MIGRATION_STATE="$boundary_tmp/migrations-done"
mkdir -p "$SUDO_TEST_ROOT/migrations"
printf '%s\n' 'sudo /usr/bin/true' 'printf "%s\n" migration:complete >>"$SUDO_TEST_LOG"' >"$SUDO_TEST_ROOT/migrations/100-test.sh"

cat >"$SUDO_TEST_ROOT/mock/getent" <<'STUB'
#!/bin/bash
printf 'fixture:x:1000:1000:fixture:%s:/bin/bash\n' "$SUDO_TEST_HOME"
STUB
cat >"$SUDO_TEST_ROOT/mock/id" <<'STUB'
#!/bin/bash
printf '%s\n' 1000
STUB
cat >"$SUDO_TEST_ROOT/mock/runuser" <<'STUB'
#!/bin/bash
[[ $1 == "-u" && $3 == "--" ]] || exit 90
shift 3
exec "$@"
STUB
cat >"$SUDO_TEST_ROOT/mock/snapper" <<'STUB'
#!/bin/bash
printf 'snapper:%s\n' "$*" >>"$SUDO_TEST_LOG"
if [[ $* == "--csvout list-configs" ]]; then
  printf '%s\n' 'Config,Subvolume' 'root,/'
fi
STUB
cat >"$SUDO_TEST_ROOT/mock/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl:%s\n' "$*" >>"$SUDO_TEST_LOG"
STUB
chmod +x "$SUDO_TEST_ROOT/mock/"*
for command in omarchy-refresh-applications omarchy-bar; do
  ln -s test-step "$SUDO_TEST_ROOT/bin/$command"
done

# Preserve the actual bootstrap, orchestration, credential gates, snapshot,
# migration/AUR integration, cleanup, and reboot request. Substitute harmless
# operation bodies for system installation and desktop transitions. Refuse an
# unknown lifecycle call so future additions cannot reach the host by accident.
python3 - "$SUDO_TEST_ROOT/bin/omarchy-upgrade-to-quattro" "$SUDO_TEST_ROOT" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]);root=Path(sys.argv[2]);s=p.read_text()
for command in ['getent','id','runuser','systemctl']:
 s=s.replace('/usr/bin/'+command,str(root/'mock'/command))
s=s.replace('/usr/share/omarchy',str(root)).replace('HOME=', 'SUDO_TEST_HOME=')
root_steps='configure_pacman_channel install_keyrings remove_legacy_installer_package remove_legacy_limine_configs remove_conflicting_legacy_packages install_omarchy_quattro_packages install_hardware_transition_packages normalize_limine_config preserve_kernel_cmdline_root configure_snapper_policy configure_lock_authentication migrate_1password_beta_package apply_system_transition cleanup_retired_services remove_retired_default_packages run_final_system_package_upgrade'.split()
user_steps='cleanup_legacy_user_paths apply_user_transition apply_user_hardware_transition cleanup_retired_user_services ensure_sleep_lock_service refresh_current_theme_after_upgrade'.split()
start=s.index('upgrade_started=1\n');end=s.index('upgrade_completed=1\n',start)
calls=set(re.findall(r'^([a-z_]+)(?:\s|$)',s[start:end],re.M))
allowed=set(root_steps+user_steps+['open_privilege_window','close_privilege_window','suppress_hyprland_config_reload','restore_hyprland_config_reload','create_pre_upgrade_snapshot','run_as_user_omarchy','run_post_upgrade_migrations','run_cold_aur_update','run_post_upgrade_update_steps'])
assert not calls-allowed, f'Unmocked lifecycle calls: {calls-allowed}'
definition='''
record_phase() {
  printf 'phase:%s:%s\\n' "$1" "$2" >>"$SUDO_TEST_LOG"
  if [[ ${SUDO_TEST_PHASE_FAIL:-} == "$2" ]]; then
    touch "$SUDO_TEST_CACHE"
    exit 23
  fi
  if [[ ${SUDO_TEST_PHASE_SIGNAL:-} == "$2" ]]; then
    touch "$SUDO_TEST_CACHE"
    kill -"${SUDO_TEST_SIGNAL:-TERM}" "$$"
  fi
}
suppress_hyprland_config_reload() { hyprland_config_reload_suppressed=1; }
restore_hyprland_config_reload() { hyprland_config_reload_suppressed=0; }
'''
for name in root_steps:
 definition+=f'{name}() {{ record_phase root {name}; as_root /usr/bin/true; }}\n'
for name in user_steps:
 definition+=f'{name}() {{\n  [[ ! -e $SUDO_TEST_CACHE ]] || exit 91\n  record_phase user {name}\n'
 if name=='apply_user_transition':
  definition+='''  case ${SUDO_TEST_LATE_CALL:-} in
    as_root) as_root /usr/bin/true ;;
    reopen) open_privilege_window ;;
  esac
'''
 if name=='refresh_current_theme_after_upgrade':
  definition+='''  if [[ ${SUDO_TEST_FINAL_REVOKE_FAIL:-0} == "1" ]]; then
    touch "$SUDO_TEST_ROOT/revoke-fail"
  fi
'''
 definition+='}\n'
s=s[:start]+definition+s[start:]
p.write_text(s)
PY

run_upgrade() {
  "$SUDO_TEST_ROOT/bin/omarchy-upgrade-to-quattro" --yes --reboot --user fixture >"$boundary_tmp/output" 2>&1
}
reset_upgrade() {
  reset_boundary
  rm -rf "$OMARCHY_MIGRATION_STATE"
  unset SUDO_TEST_PHASE_FAIL SUDO_TEST_PHASE_SIGNAL SUDO_TEST_SIGNAL SUDO_TEST_LATE_CALL SUDO_TEST_FINAL_REVOKE_FAIL
}

reset_upgrade
touch "$SUDO_TEST_CACHE"
run_upgrade || fail "combined upgrade failed" "$(<"$boundary_tmp/output")"
assert_boundary_cold "combined Quattro upgrade"
python3 - "$SUDO_TEST_LOG" <<'PY'
import sys
s=open(sys.argv[1]).read().splitlines()
assert s[0]=='sudo -k',s
first_user=next(i for i,l in enumerate(s) if l.startswith('phase:user:'))
assert not any(l.startswith('phase:root:') for l in s[first_user:]),s
assert any(l.startswith('snapper:-c root create ') for l in s),s
assert 'migration:complete' in s,s
assert any(l.startswith('step:yay --sudo ') for l in s),s
assert 'systemctl:reboot' in s,s
assert not any(l.startswith('sudo ') and not l.startswith(('sudo -N ', 'sudo -k', 'sudo -h')) for l in s),s
PY
pass "Quattro snapshots and finishes system work before user phases, then uses the real protected migration/AUR paths"

for phase in configure_pacman_channel apply_user_transition; do
  reset_upgrade
  export SUDO_TEST_PHASE_FAIL=$phase
  if run_upgrade; then fail "$phase failure must fail the upgrade"; fi
  assert_boundary_cold "failed Quattro $phase"
  if grep -q '^systemctl:reboot$' "$SUDO_TEST_LOG"; then fail "failed upgrade requested reboot"; fi
  pass "Quattro revokes after $phase failure and does not reboot"
done

for signal in TERM HUP INT; do
  reset_upgrade
  export SUDO_TEST_PHASE_SIGNAL=configure_pacman_channel SUDO_TEST_SIGNAL=$signal
  if run_upgrade; then fail "$signal must interrupt the upgrade"; fi
  assert_boundary_cold "Quattro $signal"
  if grep -q '^phase:user:' "$SUDO_TEST_LOG"; then fail "interrupted privileged phase resumed user work"; fi
  pass "Quattro $signal revokes credentials and stops the upgrade"
done

for call in as_root reopen; do
  reset_upgrade
  export SUDO_TEST_LATE_CALL=$call
  if run_upgrade; then fail "late $call must be rejected"; fi
  assert_boundary_cold "late Quattro $call"
  grep -q 'Internal error:' "$boundary_tmp/output" || fail "late privileged work failed without enforcing its gate"
  pass "Quattro rejects $call after the user-code boundary"
done

reset_upgrade
export SUDO_TEST_FINAL_REVOKE_FAIL=1
if run_upgrade; then fail "failed final revocation must fail the upgrade"; fi
grep -q 'Could not invalidate cached sudo authorization during upgrade cleanup' "$boundary_tmp/output" || fail "cleanup failure was silent"
if grep -q '^systemctl:reboot$' "$SUDO_TEST_LOG"; then fail "failed final revocation requested reboot"; fi
pass "Quattro reports failed final credential revocation without rebooting"

reset_upgrade
if /usr/bin/bash "$SUDO_TEST_ROOT/bin/omarchy-upgrade-to-quattro" -p >"$boundary_tmp/output" 2>&1; then fail "Quattro accepted ordinary Bash with a decoy -p"; fi
[[ ! -s $SUDO_TEST_LOG ]] || fail "Quattro reached sudo after an unsafe interpreter launch"
pass "Quattro rejects a decoy privileged-mode argument"

reset_upgrade
printf '%s\n' 'touch "$SUDO_TEST_ROOT/startup-marker"' >"$boundary_tmp/startup"
BASH_ENV="$boundary_tmp/startup" ENV="$boundary_tmp/startup" run_upgrade || fail "Quattro failed with inherited startup state" "$(<"$boundary_tmp/output")"
[[ ! -e $SUDO_TEST_ROOT/startup-marker ]] || fail "Quattro propagated startup files to children"
pass "Quattro discards inherited startup files before child interpreters"

reset_upgrade
function printf() { /usr/bin/touch "$SUDO_TEST_ROOT/function-marker"; }
export -f printf
run_upgrade || fail "Quattro failed with an exported function" "$(<"$boundary_tmp/output")"
unset -f printf
[[ ! -e $SUDO_TEST_ROOT/function-marker ]] || fail "Quattro propagated an exported function to children"
pass "Quattro removes exported function records before starting helpers"
