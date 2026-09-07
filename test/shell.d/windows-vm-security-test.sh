#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export OMARCHY_WINDOWS_DIR="$test_dir/runtime"
mkdir -p "$HOME"

set -- help
source "$ROOT/bin/omarchy-windows-vm" >/dev/null

first_password=$(generate_password)
second_password=$(generate_password)
[[ $first_password != "$second_password" ]] || fail "fresh generated Windows passwords are unique"
for generated in "$first_password" "$second_password"; do
  valid_password "$generated" || fail "generated Windows password satisfies Omarchy validation"
  (( ${#generated} >= 32 && ${#generated} <= 64 )) ||
    fail "generated Windows password has a compatible bounded length"
  [[ $generated =~ [A-Z] && $generated =~ [a-z] && $generated =~ [0-9] && $generated =~ [^A-Za-z0-9] ]] ||
    fail "generated Windows password satisfies Windows complexity classes"
  [[ $generated != admin ]] || fail "generated Windows password is not the public Dockur default"
done
pass "fresh generated Windows passwords are unique, compatible, and high entropy"

# prompt_windows_password runs gum in command substitutions, so use a file as
# the deterministic cross-subshell queue: one invalid value, then a valid one.
prompt_count="$test_dir/prompt-count"
printf '0\n' >"$prompt_count"
expected_prompt_password='  p@$$ word;"\[]{}!?  '
gum() {
  local count
  read -r count <"$prompt_count"
  count=$((count + 1))
  printf '%s\n' "$count" >"$prompt_count"
  if ((count == 1)); then
    printf '%065d\n' 0
  else
    printf '%s\n' "$expected_prompt_password"
  fi
}
prompt_windows_password >"$test_dir/prompt.output" 2>&1
[[ $(<"$prompt_count") == 2 ]] || fail "invalid explicit Windows password is reprompted"
[[ $PASSWORD == "$expected_prompt_password" && $PASSWORD_DISPLAY == "(user-defined)" ]] ||
  fail "valid reprompted Windows password is preserved exactly"
grep -q 'Invalid password' "$test_dir/prompt.output" || fail "invalid explicit password reports rejection"
[[ $PASSWORD != admin ]] || fail "invalid explicit password cannot select the public fallback"
pass "invalid explicit passwords reprompt without weakening to a known default"

gum() { printf '\n'; }
prompt_windows_password
valid_password "$PASSWORD" || fail "blank password input produces a valid generated password"
[[ $PASSWORD != admin && $PASSWORD_DISPLAY == "(securely generated; stored privately)" ]] ||
  fail "blank password input does not select the public default"
generated_from_prompt=$PASSWORD
pass "blank password input generates a fresh private credential"

password_generation_marker="$test_dir/password-generation-after-cancel"
gum() { return 1; }
generate_password() {
  : >"$password_generation_marker"
  printf 'generated-after-cancel\n'
}
set +e
prompt_windows_password >"$test_dir/cancel.output" 2>&1
prompt_status=$?
set -e
(( prompt_status != 0 )) || fail "cancelled Windows password prompt succeeds"
[[ ! -e $password_generation_marker ]] ||
  fail "cancelled Windows password prompt silently generates a credential"
pass "cancelled Windows password prompt aborts without generating a credential"

CREDENTIALS_FILE="$HOME/.config/windows/credentials"
write_credentials generated-user "$generated_from_prompt"
[[ $(stat -c '%a' "${CREDENTIALS_FILE%/*}") == 700 ]] || fail "credential directory is private"
[[ $(stat -c '%a' "$CREDENTIALS_FILE") == 600 ]] || fail "credential file is private"
[[ $(read_credential USERNAME) == generated-user ]] || fail "stored Windows username round-trips"
[[ $(read_credential PASSWORD) == "$generated_from_prompt" ]] || fail "stored generated password round-trips"
pass "generated credentials use the existing private storage boundary"

stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/xfreerdp3" <<'STUB'
#!/bin/bash
if [[ $# == 1 && $1 == /args-from:stdin ]]; then
  while IFS= read -r argument; do
    printf '%s\0' "$argument"
  done >"$FREERDP_ARGV_FILE"
else
  printf '%s\0' "$@" >"$FREERDP_ARGV_FILE"
fi
STUB
cat >"$stub_bin/hyprctl" <<'STUB'
#!/bin/bash
printf '[{"focused":true,"scale":1}]\n'
STUB
chmod +x "$stub_bin"/*
export PATH="$stub_bin:$PATH"
export FREERDP_ARGV_FILE="$test_dir/freerdp.argv"

COMPOSE_FILE="$OMARCHY_WINDOWS_DIR/docker-compose.yml"
lifecycle_log="$test_dir/lifecycle.log"
migrate_legacy_compose() { return 0; }
priv() { printf '%s\n' "$*" >>"$lifecycle_log"; }
gum() { :; }

launch_windows --keep-alive >"$test_dir/launch.output"
grep -qxF 'up_wait' "$lifecycle_log" || fail "valid generated credentials allow VM launch"
mapfile -d '' -t freerdp_args <"$FREERDP_ARGV_FILE"
[[ ${freerdp_args[0]} == /u:generated-user ]] || fail "launch uses the configured Windows username"
[[ ${freerdp_args[1]} == "/p:$generated_from_prompt" ]] || fail "launch uses the generated Windows password"
pass "launch consumes the generated credential instead of a public fallback"

mkdir -p "$OMARCHY_WINDOWS_DIR"
cat >"$COMPOSE_FILE" <<'COMPOSE'
services:
  windows:
    environment:
      USERNAME: "recovered-user"
      PASSWORD: "  Compo$$e\"Pass\\word1  "
COMPOSE
recovered_password='  Compo$e"Pass\word1  '
for broken in password username missing; do
  case $broken in
    password) write_credentials stale-user "$(printf '%065d' 0)" ;;
    username) write_credentials 'invalid user' stale-password ;;
    missing) write_credentials '' stale-password ;;
  esac
  : >"$lifecycle_log"
  launch_windows --keep-alive >"$test_dir/recovery-$broken.output"
  mapfile -d '' -t freerdp_args <"$FREERDP_ARGV_FILE"
  [[ ${freerdp_args[0]} == /u:recovered-user && ${freerdp_args[1]} == "/p:$recovered_password" ]] ||
    fail "compose recovery mixes private and recovered credentials for $broken"
done
pass "invalid or incomplete private credentials recover a complete compatible compose pair"

printf '      USERNAME: "invalid user"\n      PASSWORD: "unusable-pair"\n' >"$COMPOSE_FILE"
: >"$lifecycle_log"
if (launch_windows --keep-alive) >"$test_dir/invalid-recovery.output" 2>&1; then
  fail "invalid compose recovery permits launch"
fi
[[ ! -s $lifecycle_log ]] || fail "invalid recovered credentials start the VM"
pass "unusable recovered credentials fail before VM startup"

rm -f "$CREDENTIALS_FILE" "$COMPOSE_FILE"
: >"$lifecycle_log"
if (launch_windows --keep-alive) >"$test_dir/missing.output" 2>&1; then
  fail "launch without recoverable credentials succeeds"
fi
[[ ! -s $lifecycle_log ]] || fail "missing credentials start the VM before failing closed"
grep -q 'refusing to use public defaults' "$test_dir/missing.output" ||
  fail "missing credentials do not explain the fail-closed behavior"
! rg -q 'docker/admin|use default: admin' "$test_dir/missing.output" ||
  fail "missing credentials suggest the public default"
pass "missing credentials fail closed before VM startup"

! rg -n 'PASSWORD="admin"|WIN_PASS="admin"|use default: admin|Using default: admin' \
  "$ROOT/bin/omarchy-windows-vm" >/dev/null ||
  fail "Windows VM source retains the public password fallback"
pass "Windows VM source contains no public password fallback"
