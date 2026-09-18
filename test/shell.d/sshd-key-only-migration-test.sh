#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command unshare
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT

unshare --user --map-root-user --mount /usr/bin/bash -s "$ROOT" "$t" <<'NAMESPACE'
set -euo pipefail
repo=$1 t=$2; b="$t/bin"; mapped="$t/omarchy"; mkdir -p "$b" "$mapped/bin" "$t/run"; chmod 0755 "$t/run"
cat >"$b/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >>"$EVENTS"
case $1 in
is-active) [[ ${ACTIVE_QUERY_ERROR:-0} != 1 ]] || exit 2; [[ ${UNIT_MISSING:-0} != 1 ]] || { echo inactive; exit 4; }; [[ -e $STATE/active ]] && { echo active; exit 0; } || { echo inactive; exit 3; };;
is-enabled) [[ ${ENABLED_QUERY_ERROR:-0} != 1 ]] || exit 2; [[ ${UNIT_MISSING:-0} != 1 ]] || { echo not-found; exit 4; }; [[ -e $STATE/enabled ]] && { echo enabled; exit 0; } || { echo disabled; exit 1; };;
reload) if [[ ${SLOW_RELOAD:-0} == 1 ]]; then mkdir "$STATE/held" 2>/dev/null || touch "$STATE/overlap"; sleep .15; rmdir "$STATE/held" 2>/dev/null || true; fi; [[ ${RELOAD_FAIL:-0} != 1 ]];;
disable) rm -f "$STATE/active" "$STATE/enabled";; esac
SH
cat >"$b/passwd" <<'SH'
#!/bin/bash
[[ $1 == -S && $2 == -- ]] || exit 2
[[ ${PASSWD_QUERY_ERROR:-0} != 1 ]] || exit 2
status=P; [[ ${LOCKED_USER:-} != "$3" ]] || status=L
printf '%s %s 2026-01-01 -1 -1 -1 -1\n' "$3" "$status"
SH
cat >"$b/id" <<'SH'
#!/bin/bash
[[ $1 == -Gn && $2 == -- ]] || exit 2
[[ ${GROUP_QUERY_ERROR:-0} != 1 ]] || exit 2
case $3 in keyed) echo 'keyed sshers';; later) echo 'later users';; *\$) echo "$3 sshers";; *) exit 1;; esac
SH
cat >"$b/ssh-keygen" <<'SH'
#!/bin/bash
[[ ${1:-} != -A ]] || { echo hostkeys >>"$EVENTS"; exit "${HOSTKEY_FAIL:-0}"; }
exec /usr/bin/ssh-keygen "$@"
SH
cat >"$b/sshd" <<'SH'
#!/bin/bash
[[ ${1:-} != -t ]] || exit "${T_FAIL:-0}"
user=; for arg in "$@"; do [[ $arg != user=* ]] || { user=${arg#user=}; user=${user%%,*}; }; done
password=no; [[ -z ${MATCH_BAD_USER:-} || $user != "$MATCH_BAD_USER" ]] || password=yes
echo "PasswordAuthentication $password"; echo 'KbdInteractiveAuthentication no'; echo 'AuthenticationMethods publickey'; echo 'PubkeyAuthentication yes'; echo 'AuthorizedKeysFile .ssh/authorized_keys'
echo "PubkeyAcceptedAlgorithms ${ACCEPTED_ALGORITHMS:-ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256}"; echo "RequiredRSASize ${REQUIRED_RSA_SIZE:-1024}"
[[ -z ${REVOKED_KEYS:-} ]] || echo "RevokedKeys $REVOKED_KEYS"
echo "RefuseConnection ${REFUSE_CONNECTION:-no}"; echo "ForceCommand ${FORCE_COMMAND:-none}"
[[ -z ${ALLOW_USERS:-} ]] || echo "AllowUsers $ALLOW_USERS"
[[ -z ${DENY_USERS:-} ]] || echo "DenyUsers $DENY_USERS"
[[ -z ${ALLOW_GROUPS:-} ]] || echo "AllowGroups $ALLOW_GROUPS"
[[ -z ${DENY_GROUPS:-} ]] || echo "DenyGroups $DENY_GROUPS"
SH
chmod 0755 "$b"/*; cp "$repo/bin/omarchy-security-functions" "$repo/bin/omarchy-sshd-functions" "$mapped/bin/"
sed -e "s#legacy_config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf#legacy_config=\$TEST_ROOT/etc/ssh/sshd_config.d/10-omarchy-hardening.conf#" \
 -e "s#key_only_config=/etc/ssh/sshd_config.d/00-omarchy-key-only.conf#key_only_config=\$TEST_ROOT/etc/ssh/sshd_config.d/00-omarchy-key-only.conf#" \
 -e "s#main_config=/etc/ssh/sshd_config#main_config=\$TEST_ROOT/etc/ssh/sshd_config#" -e "s#dropin_dir=/etc/ssh/sshd_config.d#dropin_dir=\$TEST_ROOT/etc/ssh/sshd_config.d#" \
 -e "s#passwd_file=/etc/passwd#passwd_file=\$TEST_ROOT/etc/passwd#" -e "s#login_defs=/etc/login.defs#login_defs=\$TEST_ROOT/etc/login.defs#" \
 -e "s#machine_lock=/run/omarchy-sshd-key-only-migration.lock#machine_lock=$t/run/lock#" \
 -e "s#completion_marker=/var/lib/omarchy/migrations/1788163637#completion_marker=\$TEST_ROOT/var/lib/omarchy/migrations/1788163637#" \
 -e "s#-- /run#-- $t/run#g" -e "s#-L /run#-L $t/run#g" -e "s#== /run#== $t/run#g" \
 -e "s#/usr/bin/systemctl#$b/systemctl#g" -e "s#/usr/bin/ssh-keygen#$b/ssh-keygen#g" -e "s#/usr/bin/sshd#$b/sshd#g" \
 -e "s#/usr/bin/passwd#$b/passwd#g" -e "s#/usr/bin/id#$b/id#g" \
 "$repo/bin/omarchy-migrate-sshd-key-only" >"$mapped/bin/omarchy-migrate-sshd-key-only"; chmod 0755 "$mapped/bin/"*
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$t/key"; key=$(<"$t/key.pub")
prepare() { local d="$t/$1"; mkdir -p "$d/root/etc/ssh/sshd_config.d" "$d/root/home/keyed/.ssh" "$d/root/home/later" "$d/state"; chmod 700 "$d/root/home/"{keyed,keyed/.ssh,later}; printf '%s\n' "$key" >"$d/root/home/keyed/.ssh/authorized_keys"; chmod 600 "$d/root/home/keyed/.ssh/authorized_keys"; cat >"$d/root/etc/passwd" <<EOF
root:x:0:0:root:/root:/usr/bin/nologin
keyed:x:1000:1000:Keyed:$d/root/home/keyed:/usr/bin/bash
later:x:1001:1001:Later:$d/root/home/later:/usr/bin/bash
daemon:x:2:2:Daemon:/sbin:/usr/bin/nologin
EOF
 echo 'UID_MIN 1000' >"$d/root/etc/login.defs"; echo 'Include /etc/ssh/sshd_config.d/*.conf' >"$d/root/etc/ssh/sshd_config"; printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >"$d/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"; : >"$d/events"; }
run() { REFUSE_CONNECTION="${REFUSE_CONNECTION:-}" FORCE_COMMAND="${FORCE_COMMAND:-}" ACCEPTED_ALGORITHMS="${ACCEPTED_ALGORITHMS:-}" REQUIRED_RSA_SIZE="${REQUIRED_RSA_SIZE:-}" REVOKED_KEYS="${REVOKED_KEYS:-}" UNIT_MISSING="${UNIT_MISSING:-0}" TEST_ROOT="$t/$1/root" STATE="$t/$1/state" EVENTS="$t/$1/events" MATCH_BAD_USER="${MATCH_BAD_USER:-}" ALLOW_USERS="${ALLOW_USERS:-}" DENY_USERS="${DENY_USERS:-}" ALLOW_GROUPS="${ALLOW_GROUPS:-}" DENY_GROUPS="${DENY_GROUPS:-}" LOCKED_USER="${LOCKED_USER:-}" PASSWD_QUERY_ERROR="${PASSWD_QUERY_ERROR:-0}" GROUP_QUERY_ERROR="${GROUP_QUERY_ERROR:-0}" ACTIVE_QUERY_ERROR="${ACTIVE_QUERY_ERROR:-0}" ENABLED_QUERY_ERROR="${ENABLED_QUERY_ERROR:-0}" SLOW_RELOAD="${SLOW_RELOAD:-0}" RELOAD_FAIL="${RELOAD_FAIL:-0}" HOSTKEY_FAIL="${HOSTKEY_FAIL:-0}" T_FAIL="${T_FAIL:-0}" "$mapped/bin/omarchy-migrate-sshd-key-only"; }
prepare shared; touch "$t/shared/state/"{active,enabled}; run shared; run shared; [[ -e $t/shared/state/active ]]; ! grep -q 'systemctl disable' "$t/shared/events"
[[ -f $t/shared/root/var/lib/omarchy/migrations/1788163637 ]] || { echo "a validated conversion did not record completion" >&2; exit 1; }
prepare no-key; rm "$t/no-key/root/home/keyed/.ssh/authorized_keys"; touch "$t/no-key/state/"{active,enabled}; run no-key; [[ ! -e $t/no-key/state/active ]]
[[ ! -e $t/no-key/root/var/lib/omarchy/migrations/1788163637 ]] || { echo "a disabled machine recorded a completed conversion" >&2; exit 1; }
prepare matched; touch "$t/matched/state/"{active,enabled}; MATCH_BAD_USER=later run matched; [[ ! -e $t/matched/state/active ]]
for rule in allow-user deny-user allow-group deny-group locked; do
  prepare "$rule"; touch "$t/$rule/state/"{active,enabled}
  case $rule in allow-user) ALLOW_USERS=later;; deny-user) DENY_USERS=keyed;; allow-group) ALLOW_GROUPS=users;; deny-group) DENY_GROUPS=sshers;; locked) LOCKED_USER=keyed;; esac
  run "$rule"; [[ ! -e $t/$rule/state/active ]] || exit 1
  unset ALLOW_USERS DENY_USERS ALLOW_GROUPS DENY_GROUPS LOCKED_USER
done
prepare admitted; touch "$t/admitted/state/"{active,enabled}; ALLOW_USERS=keyed ALLOW_GROUPS=sshers DENY_USERS=later DENY_GROUPS=users run admitted; [[ -e $t/admitted/state/active ]]
for error in passwd groups; do prepare "admission-error-$error"; touch "$t/admission-error-$error/state/"{active,enabled}; if [[ $error == passwd ]]; then PASSWD_QUERY_ERROR=1; else GROUP_QUERY_ERROR=1; fi; run "admission-error-$error"; [[ ! -e $t/admission-error-$error/state/active ]]; unset PASSWD_QUERY_ERROR GROUP_QUERY_ERROR; done
prepare query-error; touch "$t/query-error/state/"{active,enabled}; ACTIVE_QUERY_ERROR=1; if run query-error; then exit 1; fi; unset ACTIVE_QUERY_ERROR; [[ -e $t/query-error/state/active && -e $t/query-error/state/enabled && ! -e $t/query-error/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf && -e $t/query-error/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf ]]
prepare unsafe-query-error; rm "$t/unsafe-query-error/root/home/keyed/.ssh/authorized_keys"; touch "$t/unsafe-query-error/state/"{active,enabled}; ENABLED_QUERY_ERROR=1; if run unsafe-query-error; then exit 1; fi; unset ENABLED_QUERY_ERROR; [[ -e $t/unsafe-query-error/state/active && -e $t/unsafe-query-error/state/enabled ]]
prepare symlink-key; mv "$t/symlink-key/root/home/keyed/.ssh/authorized_keys" "$t/symlink-key/root/home/key"; ln -s ../key "$t/symlink-key/root/home/keyed/.ssh/authorized_keys"; touch "$t/symlink-key/state/"{active,enabled}; run symlink-key; [[ ! -e $t/symlink-key/state/active ]]
prepare stopped; touch "$t/stopped/state/enabled"; run stopped; [[ -e $t/stopped/state/enabled ]]; ! grep -q 'systemctl reload' "$t/stopped/events"
prepare reload-fail; touch "$t/reload-fail/state/"{active,enabled}; RELOAD_FAIL=1 run reload-fail; [[ ! -e $t/reload-fail/state/active && ! -e $t/reload-fail/state/enabled && -e $t/reload-fail/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf ]]
prepare syntax-fail; touch "$t/syntax-fail/state/"{active,enabled}; T_FAIL=1 run syntax-fail; [[ ! -e $t/syntax-fail/state/active && ! -e $t/syntax-fail/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf ]]
prepare concurrent; touch "$t/concurrent/state/"{active,enabled}; SLOW_RELOAD=1 run concurrent & a=$!; SLOW_RELOAD=1 run concurrent & c=$!; wait "$a"; wait "$c"; [[ ! -e $t/concurrent/state/overlap ]]
prepare admin; echo 'PasswordAuthentication yes' >"$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"; touch "$t/admin/state/"{active,enabled}; before=$(sha256sum "$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"); run admin; after=$(sha256sum "$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"); [[ $before == "$after" && -e $t/admin/state/active && ! -s $t/admin/events ]]
# ssh-keygen -lf accepts these, but none proves a usable administrative login.
n=0
for opt in 'cert-authority' 'command="false"' 'from="!*,*"' 'expiry-time="20200101"' 'restrict' 'no-pty' 'permitopen="host:22"' ',' 'no-agent-forwarding,bogus'; do
  n=$((n+1)); prepare "restricted-$n"; printf '%s %s\n' "$opt" "$key" >"$t/restricted-$n/root/home/keyed/.ssh/authorized_keys"; touch "$t/restricted-$n/state/"{active,enabled}
  run "restricted-$n"; [[ ! -e $t/restricted-$n/state/active ]] || { echo "restricted key counted as usable: $opt" >&2; exit 1; }
done
prepare flags; printf 'no-agent-forwarding,No-Port-Forwarding %s\n' "$key" >"$t/flags/root/home/keyed/.ssh/authorized_keys"; touch "$t/flags/state/"{active,enabled}; run flags; [[ -e $t/flags/state/active ]]
# A key that parses but that the account's effective policy refuses proves no
# login: its algorithm is excluded, an RSA key is under RequiredRSASize, or the
# key is listed in RevokedKeys.
prepare algorithm; touch "$t/algorithm/state/"{active,enabled}; ACCEPTED_ALGORITHMS=ecdsa-sha2-nistp256,rsa-sha2-512 run algorithm; [[ ! -e $t/algorithm/state/active ]]
/usr/bin/ssh-keygen -q -t rsa -b 2048 -N '' -f "$t/rsa"
prepare rsa-size; cp "$t/rsa.pub" "$t/rsa-size/root/home/keyed/.ssh/authorized_keys"; touch "$t/rsa-size/state/"{active,enabled}; REQUIRED_RSA_SIZE=3072 run rsa-size; [[ ! -e $t/rsa-size/state/active ]]
prepare rsa-ok; cp "$t/rsa.pub" "$t/rsa-ok/root/home/keyed/.ssh/authorized_keys"; touch "$t/rsa-ok/state/"{active,enabled}; run rsa-ok; [[ -e $t/rsa-ok/state/active ]]
/usr/bin/ssh-keygen -q -k -f "$t/krl" "$t/key.pub"
prepare revoked; touch "$t/revoked/state/"{active,enabled}; REVOKED_KEYS="$t/krl" run revoked; [[ ! -e $t/revoked/state/active ]]
# RevokedKeys may also be a plain list of public keys, which ssh-keygen -Q
# cannot read; it must still revoke the listed key and only that one.
printf '# revoked\n%s\n' "$key" >"$t/revoked.txt"; cp "$t/rsa.pub" "$t/other-revoked.txt"
prepare revoked-text; touch "$t/revoked-text/state/"{active,enabled}; REVOKED_KEYS="$t/revoked.txt" run revoked-text; [[ ! -e $t/revoked-text/state/active ]]
prepare unrevoked-text; touch "$t/unrevoked-text/state/"{active,enabled}; REVOKED_KEYS="$t/other-revoked.txt" run unrevoked-text; [[ -e $t/unrevoked-text/state/active ]]
# sshd refuses every key when a text list has a line that is not a bare key,
# so such a list proves no login either.
printf 'this-is-not-a-key\n' >"$t/malformed-revoked.txt"; printf 'restrict %s\n' "$(<"$t/rsa.pub")" >"$t/options-revoked.txt"
printf 'ssh-ed25519 AAAA\n' >"$t/baddata-revoked.txt"
# CRLF endings are valid for sshd; the listed key is still revoked.
read -r key_type key_data _ <<<"$key"; printf '%s %s\r\n' "$key_type" "$key_data" >"$t/crlf-listed.txt"
prepare crlf-revoked; touch "$t/crlf-revoked/state/"{active,enabled}; REVOKED_KEYS="$t/crlf-listed.txt" run crlf-revoked
[[ ! -e $t/crlf-revoked/state/active ]] || { echo "a CRLF revocation list did not revoke its key" >&2; exit 1; }
for list in malformed options baddata; do
  prepare "$list-revoked"; touch "$t/$list-revoked/state/"{active,enabled}; REVOKED_KEYS="$t/$list-revoked.txt" run "$list-revoked"
  [[ ! -e $t/$list-revoked/state/active ]] || { echo "a $list revocation list was treated as revoking nothing" >&2; exit 1; }
done
# A certificate listed for some other key is a valid entry and revokes only it.
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$t/ca"; /usr/bin/ssh-keygen -q -s "$t/ca" -I other -n other "$t/rsa.pub"
cp "$t/rsa-cert.pub" "$t/cert-revoked.txt"
prepare cert-revoked; touch "$t/cert-revoked/state/"{active,enabled}; REVOKED_KEYS="$t/cert-revoked.txt" run cert-revoked
[[ -e $t/cert-revoked/state/active ]] || { echo "a valid certificate entry was treated as a malformed revocation list" >&2; exit 1; }
# An account sshd refuses outright, or forces into a command, proves no login.
prepare refused; touch "$t/refused/state/"{active,enabled}; REFUSE_CONNECTION=yes run refused; [[ ! -e $t/refused/state/active ]]
prepare forced; touch "$t/forced/state/"{active,enabled}; FORCE_COMMAND=/usr/bin/false run forced; [[ ! -e $t/forced/state/active ]]
# Entries that are not login accounts must not decide the machine's SSH state,
# whatever their names or homes look like.
prepare system-entries; printf 'svc.name:x:2:2:Service:/var/empty:/usr/bin/nologin\nOdd Name:x:3:3::relative:/usr/bin/false\n\n' >>"$t/system-entries/root/etc/passwd"; touch "$t/system-entries/state/"{active,enabled}; run system-entries; [[ -e $t/system-entries/state/active ]]
prepare malformed-uid; echo 'broken:x:notanumber:1::/home/broken:/usr/bin/bash' >>"$t/malformed-uid/root/etc/passwd"; touch "$t/malformed-uid/state/"{active,enabled}; run malformed-uid; [[ ! -e $t/malformed-uid/state/active ]]
# openssh removed: a missing unit is not enabled, so there is nothing to disable
# and the migration completes instead of staying pending forever.
prepare unit-missing; rm "$t/unit-missing/root/home/keyed/.ssh/authorized_keys"; UNIT_MISSING=1 run unit-missing; ! grep -q 'systemctl disable' "$t/unit-missing/events"
if /usr/bin/bash "$mapped/bin/omarchy-migrate-sshd-key-only" -p >/dev/null 2>&1; then exit 1; fi
NAMESPACE
pass "machine SSH migration preserves shared access, validates all users, serializes, and fails closed"
grep -qF '/usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only' "$ROOT/migrations/1788163637.sh" || fail "migration lacks fixed machine dispatch"
! grep -Eq 'authorized_keys|getent passwd|/usr/bin/id -u' "$ROOT/migrations/1788163637.sh" || fail "migration still uses invoking-user state"
pass "per-user migration delegates one fixed cold root machine phase"

# After the first account converted the machine, a later account without sudo
# rights must still complete: no prompt, no privileged call.
m=$(mktemp -d); trap 'rm -rf -- "$t" "$m"' EXIT
printf '#!/bin/bash\necho "sudo $*" >>"%s/calls"\n[[ $1 == -k ]]\n' "$m" >"$m/sudo"; chmod +x "$m/sudo"
mkdir -p "$m/etc" "$m/var"
sed -e "s#^legacy_config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf\$#legacy_config=$m/etc/10-omarchy-hardening.conf#" \
  -e "s#^key_only_config=/etc/ssh/sshd_config.d/00-omarchy-key-only.conf\$#key_only_config=$m/etc/00-omarchy-key-only.conf#" \
  -e "s#^completion_marker=/var/lib/omarchy/migrations/1788163637\$#completion_marker=$m/var/1788163637#" \
  -e "s#/usr/bin/omarchy-migrate-sshd-key-only#$m/helper#g" \
  -e "s#/usr/bin/sudo#$m/sudo#g" "$ROOT/migrations/1788163637.sh" >"$m/migration"
grep -q "^legacy_config=$m/" "$m/migration" && grep -q "^key_only_config=$m/" "$m/migration" && grep -q "^completion_marker=$m/" "$m/migration" ||
  fail "test could not redirect the migration's machine paths"
# A key-only file that was never certified, such as one an interrupted setup
# left behind, must reach the root phase; once certified, it must not. Run as
# namespace root so the marker can be root-owned.
printf '#!/bin/bash\necho helper >>"%s/calls"\n' "$m" >"$m/helper"; chmod +x "$m/helper"
: >"$m/etc/00-omarchy-key-only.conf"
unshare --user --map-root-user bash -euo pipefail "$m/migration" >/dev/null || fail "an uncertified key-only file failed its migration"
grep -qx helper "$m/calls" || fail "an uncertified key-only file skipped validation" "$(cat "$m/calls" 2>/dev/null)"
: >"$m/calls"; unshare --user --map-root-user touch "$m/var/1788163637"
unshare --user --map-root-user bash -euo pipefail "$m/migration" >/dev/null || fail "a certified conversion failed its migration"
[[ ! -s $m/calls ]] || fail "a certified conversion re-entered the root phase" "$(cat "$m/calls")"
rm -f "$m/etc/00-omarchy-key-only.conf" "$m/var/1788163637" "$m/calls"
pass "an uncertified key-only file is validated and a certified conversion is not"
bash -euo pipefail "$m/migration" >/dev/null || fail "a converted machine blocks a later account without sudo"
[[ ! -e $m/calls ]] || fail "a converted machine still prompts a later account" "$(cat "$m/calls")"
: >"$m/calls"
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >"$m/etc/10-omarchy-hardening.conf"
if bash -euo pipefail "$m/migration" >/dev/null 2>&1; then fail "a pending legacy repair completed without its machine phase"; fi
grep -qF "sudo -N -- $m/helper" "$m/calls" || fail "a pending legacy repair did not run its machine phase" "$(cat "$m/calls" 2>/dev/null)"
pass "later accounts complete without privileges once the legacy file is gone, and stay pending while it remains"

# A failed entry revocation must still revoke again on the way out.
: >"$m/calls"; rm -f "$m/revoked-once"
printf '#!/bin/bash\necho "sudo $*" >>"%s/calls"\nif [[ $1 == -k && ! -e %s/revoked-once ]]; then touch %s/revoked-once; exit 1; fi\n[[ $1 == -k ]]\n' "$m" "$m" "$m" >"$m/sudo"
if bash -euo pipefail "$m/migration" >/dev/null 2>&1; then fail "a failed entry revocation was ignored"; fi
[[ $(grep -c '^sudo -k$' "$m/calls") == 2 ]] || fail "a failed entry revocation did not revoke again on exit" "$(cat "$m/calls")"
pass "a failed entry revocation still revokes on exit"

# A TERM sent only to the migration while its exit revocation hangs reaches
# that sudo, so the migration still ends.
: >"$m/calls"; rm -f "$m/revoked-once" "$m/migration.pid"
printf '#!/bin/bash\necho "sudo $*" >>"%s/calls"\nif [[ $1 == -k && -e %s/revoked-once ]]; then echo "$PPID" >%s/migration.pid; sleep 30 & wait $!; fi\n[[ $1 == -k ]] && touch %s/revoked-once\n[[ $1 == -k ]]\n' "$m" "$m" "$m" "$m" >"$m/sudo"
printf 'PasswordAuthentication no\n' >"$m/etc/10-omarchy-hardening.conf"
bash -euo pipefail "$m/migration" >/dev/null 2>&1 & runner=$!
for (( i = 0; i < 200; i++ )); do [[ -s $m/migration.pid ]] && break; sleep 0.05; done
[[ -s $m/migration.pid ]] || fail "the migration never reached its exit revocation"
kill -TERM "$(<"$m/migration.pid")" 2>/dev/null || true
for (( i = 0; i < 100; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$runner" 2>/dev/null; then pkill -KILL -f "sleep 30" 2>/dev/null; wait "$runner" 2>/dev/null || true; fail "a TERM to the migration did not reach its hung exit revocation"; fi
wait "$runner" 2>/dev/null || true
rm -f "$m/etc/10-omarchy-hardening.conf"
pass "a TERM during the exit revocation reaches the revoking command"
