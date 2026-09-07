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
is-active) [[ -e $STATE/active ]] && exit 0 || exit 1;; is-enabled) [[ -e $STATE/enabled ]] && exit 0 || exit 1;;
reload) if [[ ${SLOW_RELOAD:-0} == 1 ]]; then mkdir "$STATE/held" 2>/dev/null || touch "$STATE/overlap"; sleep .15; rmdir "$STATE/held" 2>/dev/null || true; fi; [[ ${RELOAD_FAIL:-0} != 1 ]];;
disable) rm -f "$STATE/active" "$STATE/enabled";; esac
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
SH
chmod 0755 "$b"/*; cp "$repo/bin/omarchy-security-functions" "$mapped/bin/"
sed -e "s#legacy_config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf#legacy_config=\$TEST_ROOT/etc/ssh/sshd_config.d/10-omarchy-hardening.conf#" \
 -e "s#key_only_config=/etc/ssh/sshd_config.d/00-omarchy-key-only.conf#key_only_config=\$TEST_ROOT/etc/ssh/sshd_config.d/00-omarchy-key-only.conf#" \
 -e "s#main_config=/etc/ssh/sshd_config#main_config=\$TEST_ROOT/etc/ssh/sshd_config#" -e "s#dropin_dir=/etc/ssh/sshd_config.d#dropin_dir=\$TEST_ROOT/etc/ssh/sshd_config.d#" \
 -e "s#passwd_file=/etc/passwd#passwd_file=\$TEST_ROOT/etc/passwd#" -e "s#login_defs=/etc/login.defs#login_defs=\$TEST_ROOT/etc/login.defs#" \
 -e "s#machine_lock=/run/omarchy-sshd-key-only-migration.lock#machine_lock=$t/run/lock#" \
 -e "s#-- /run#-- $t/run#g" -e "s#-L /run#-L $t/run#g" -e "s#== /run#== $t/run#g" \
 -e "s#/usr/bin/systemctl#$b/systemctl#g" -e "s#/usr/bin/ssh-keygen#$b/ssh-keygen#g" -e "s#/usr/bin/sshd#$b/sshd#g" \
 "$repo/bin/omarchy-migrate-sshd-key-only" >"$mapped/bin/omarchy-migrate-sshd-key-only"; chmod 0755 "$mapped/bin/"*
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$t/key"; key=$(<"$t/key.pub")
prepare() { local d="$t/$1"; mkdir -p "$d/root/etc/ssh/sshd_config.d" "$d/root/home/keyed/.ssh" "$d/root/home/later" "$d/state"; chmod 700 "$d/root/home/"{keyed,keyed/.ssh,later}; printf '%s\n' "$key" >"$d/root/home/keyed/.ssh/authorized_keys"; chmod 600 "$d/root/home/keyed/.ssh/authorized_keys"; cat >"$d/root/etc/passwd" <<EOF
root:x:0:0:root:/root:/usr/bin/nologin
keyed:x:1000:1000:Keyed:$d/root/home/keyed:/usr/bin/bash
later:x:1001:1001:Later:$d/root/home/later:/usr/bin/bash
daemon:x:2:2:Daemon:/sbin:/usr/bin/nologin
EOF
 echo 'UID_MIN 1000' >"$d/root/etc/login.defs"; echo 'Include /etc/ssh/sshd_config.d/*.conf' >"$d/root/etc/ssh/sshd_config"; printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >"$d/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"; : >"$d/events"; }
run() { TEST_ROOT="$t/$1/root" STATE="$t/$1/state" EVENTS="$t/$1/events" MATCH_BAD_USER="${MATCH_BAD_USER:-}" SLOW_RELOAD="${SLOW_RELOAD:-0}" RELOAD_FAIL="${RELOAD_FAIL:-0}" HOSTKEY_FAIL="${HOSTKEY_FAIL:-0}" T_FAIL="${T_FAIL:-0}" "$mapped/bin/omarchy-migrate-sshd-key-only"; }
prepare shared; touch "$t/shared/state/"{active,enabled}; run shared; run shared; [[ -e $t/shared/state/active ]]; ! grep -q 'systemctl disable' "$t/shared/events"
prepare no-key; rm "$t/no-key/root/home/keyed/.ssh/authorized_keys"; touch "$t/no-key/state/"{active,enabled}; run no-key; [[ ! -e $t/no-key/state/active ]]
prepare matched; touch "$t/matched/state/"{active,enabled}; MATCH_BAD_USER=later run matched; [[ ! -e $t/matched/state/active ]]
prepare symlink-key; mv "$t/symlink-key/root/home/keyed/.ssh/authorized_keys" "$t/symlink-key/root/home/key"; ln -s ../key "$t/symlink-key/root/home/keyed/.ssh/authorized_keys"; touch "$t/symlink-key/state/"{active,enabled}; run symlink-key; [[ ! -e $t/symlink-key/state/active ]]
prepare stopped; touch "$t/stopped/state/enabled"; run stopped; [[ -e $t/stopped/state/enabled ]]; ! grep -q 'systemctl reload' "$t/stopped/events"
prepare reload-fail; touch "$t/reload-fail/state/"{active,enabled}; RELOAD_FAIL=1 run reload-fail; [[ ! -e $t/reload-fail/state/active && ! -e $t/reload-fail/state/enabled && -e $t/reload-fail/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf ]]
prepare syntax-fail; touch "$t/syntax-fail/state/"{active,enabled}; T_FAIL=1 run syntax-fail; [[ ! -e $t/syntax-fail/state/active && ! -e $t/syntax-fail/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf ]]
prepare concurrent; touch "$t/concurrent/state/"{active,enabled}; SLOW_RELOAD=1 run concurrent & a=$!; SLOW_RELOAD=1 run concurrent & c=$!; wait "$a"; wait "$c"; [[ ! -e $t/concurrent/state/overlap ]]
prepare admin; echo 'PasswordAuthentication yes' >"$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"; touch "$t/admin/state/"{active,enabled}; before=$(sha256sum "$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"); run admin; after=$(sha256sum "$t/admin/root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"); [[ $before == "$after" && -e $t/admin/state/active && ! -s $t/admin/events ]]
if /usr/bin/bash "$mapped/bin/omarchy-migrate-sshd-key-only" -p >/dev/null 2>&1; then exit 1; fi
NAMESPACE
pass "machine SSH migration preserves shared access, validates all users, serializes, and fails closed"
grep -qF '/usr/bin/sudo -N -- /usr/bin/omarchy-migrate-sshd-key-only' "$ROOT/migrations/1788163637.sh" || fail "migration lacks fixed machine dispatch"
! grep -Eq 'authorized_keys|getent passwd|/usr/bin/id -u' "$ROOT/migrations/1788163637.sh" || fail "migration still uses invoking-user state"
pass "per-user migration delegates one fixed cold root machine phase"
