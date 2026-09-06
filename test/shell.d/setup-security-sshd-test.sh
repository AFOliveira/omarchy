#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"
test_dir="$boundary_tmp"
stub_bin="$SUDO_TEST_ROOT/bin"
copy_boundary_file bin/omarchy-setup-security-sshd

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
printf 'pkg %s\n' "$*" >>"${CALL_LOG:?}"
STUB
cat >"$stub_bin/omarchy-cmd-missing" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"${CALL_LOG:?}"
STUB
cat >"$stub_bin/sshd" <<'STUB'
#!/bin/bash
case $1 in
-t)
  [[ ${SSHD_SYNTAX_VALID:-1} == 1 ]]
  ;;
-T)
  # OpenSSH 10.x dumps keywords in CamelCase; 9.x dumped them lowercase.
  if [[ ${SSHD_DUMP_LOWERCASE:-0} == 1 ]]; then
    printf 'passwordauthentication %s\n' "${SSHD_PASSWORD_AUTH:-no}"
    printf 'kbdinteractiveauthentication %s\n' "${SSHD_KBD_AUTH:-no}"
  else
    printf 'PasswordAuthentication %s\n' "${SSHD_PASSWORD_AUTH:-no}"
    printf 'KbdInteractiveAuthentication %s\n' "${SSHD_KBD_AUTH:-no}"
  fi
  ;;
*)
  exit 2
  ;;
esac
STUB
cat >"$stub_bin/install" <<'STUB'
#!/bin/bash
destination="${TEST_ROOT:?}${3:?}"
/usr/bin/mkdir -p "${destination%/*}"
/usr/bin/install -Dm644 /dev/stdin "$destination"
STUB
cat >"$stub_bin/rm" <<'STUB'
#!/bin/bash
/usr/bin/rm -f "${TEST_ROOT:?}${2:?}"
STUB
chmod +x "$stub_bin"/*

ssh-keygen -q -t ed25519 -N "" -f "$test_dir/key"
public_key=$(<"$test_dir/key.pub")

run_setup() {
  local scenario="$1"
  local scenario_home="$test_dir/$scenario/home"
  local root="$test_dir/$scenario/root"

  mkdir -p "$scenario_home" "$root"
  : >"$test_dir/$scenario.calls"

  SUDO_TEST_HOME="$scenario_home" TEST_ROOT="$root" CALL_LOG="$test_dir/$scenario.calls" \
    SSHD_SYNTAX_VALID="${SSHD_SYNTAX_VALID:-1}" \
    SSHD_PASSWORD_AUTH="${SSHD_PASSWORD_AUTH:-no}" \
    SSHD_KBD_AUTH="${SSHD_KBD_AUTH:-no}" \
    PATH="$stub_bin:$PATH" \
    "$SUDO_TEST_ROOT/bin/omarchy-setup-security-sshd" --key="$public_key"
}

output=$(run_setup success)
config="$test_dir/success/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"
grep -qxF "PasswordAuthentication no" "$config" || fail "SSH setup disables password authentication"
grep -qxF "KbdInteractiveAuthentication no" "$config" || fail "SSH setup disables keyboard-interactive authentication"
grep -qxF "systemctl reload sshd.service" "$test_dir/success.calls" || fail "SSH setup reloads the validated config"
grep -q "Password logins are off" <<<"$output" || fail "SSH setup reports hardening after it succeeds"
pass "SSH setup authorizes a key and disables password logins"

output=$(SSHD_DUMP_LOWERCASE=1 run_setup success-legacy)
config="$test_dir/success-legacy/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"
[[ -e $config ]] || fail "SSH setup accepts the lowercase sshd -T dump of OpenSSH 9.x"
grep -q "Password logins are off" <<<"$output" || fail "SSH setup reports hardening on OpenSSH 9.x"
pass "SSH setup verifies settings across sshd -T keyword casings"

if SSHD_PASSWORD_AUTH=yes run_setup ineffective >"$test_dir/ineffective.output" 2>&1; then
  fail "SSH setup must fail when password authentication remains effective"
fi
[[ ! -e $test_dir/ineffective/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf ]] ||
  fail "SSH setup removes an ineffective hardening config"
! grep -qF "systemctl reload sshd.service" "$test_dir/ineffective.calls" ||
  fail "SSH setup must not reload ineffective hardening"
! grep -q "Password logins are off" "$test_dir/ineffective.output" ||
  fail "SSH setup must not claim ineffective hardening succeeded"
pass "SSH setup verifies the effective daemon settings"

if SSHD_SYNTAX_VALID=0 run_setup invalid >"$test_dir/invalid.output" 2>&1; then
  fail "SSH setup must fail when sshd rejects its config"
fi
[[ ! -e $test_dir/invalid/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf ]] ||
  fail "SSH setup removes a rejected hardening config"
! grep -qF "systemctl reload sshd.service" "$test_dir/invalid.calls" ||
  fail "SSH setup must not reload a rejected config"
! grep -q "Password logins are off" "$test_dir/invalid.output" ||
  fail "SSH setup must not claim rejected hardening succeeded"
pass "SSH setup fails safely when sshd rejects the config"

reset_boundary
if /usr/bin/bash "$SUDO_TEST_ROOT/bin/omarchy-setup-security-sshd" -p >"$test_dir/decoy.out" 2>&1; then
  fail "SSH setup accepted an ordinary Bash launch"
fi
[[ ! -s $SUDO_TEST_LOG ]] || fail "unsafe SSH interpreter reached sudo"
pass "SSH setup rejects a decoy privileged-mode argument"

reset_boundary
printf '%s\n' 'touch "$SUDO_TEST_ROOT/ssh-startup"' >"$test_dir/startup-env"
BASH_ENV="$test_dir/startup-env" ENV="$test_dir/startup-env" run_setup startup >"$test_dir/startup.out"
[[ ! -e $SUDO_TEST_ROOT/ssh-startup ]] || fail "SSH setup propagated inherited startup code"
assert_boundary_cold "SSH setup"
if grep -E '^sudo ' "$SUDO_TEST_LOG" | grep -Ev '^sudo (-N |-k$|-h$)'; then
  fail "SSH setup published reusable sudo authorization"
fi
pass "SSH setup and its helpers start cold, use no-update authentication, and revoke at exit"
