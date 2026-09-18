#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir "$stub"
test_uid=$(id -u)

cat >"$stub/id" <<'SH'
#!/bin/bash
case ${1:-} in
-u) printf '%s\n' "$TEST_UID" ;;
-Gn) [[ ${2:-} == -- && ${3:-} == "${TEST_ACCOUNT:-audit}" ]] || exit 2; printf '%s\n' "${TEST_GROUPS:-audit sshers}" ;;
*) exit 2 ;;
esac
SH
cat >"$stub/getent" <<'SH'
#!/bin/bash
[[ ${1:-} == passwd && ${2:-} == "$TEST_UID" ]] || exit 2
printf '%s:x:%s:100:Audit Test:%s:/bin/bash\n' "${TEST_ACCOUNT:-audit}" "$TEST_UID" "$HOME"
SH
cat >"$stub/passwd" <<'SH'
#!/bin/bash
[[ ${1:-} == -S && ${2:-} == -- && ${3:-} == "${TEST_ACCOUNT:-audit}" ]] || exit 2
printf '%s %s 2026-01-01 -1 -1 -1 -1\n' "${TEST_ACCOUNT:-audit}" "${ACCOUNT_STATUS:-P}"
SH

cat >"$stub/omarchy-pkg-add" <<'SH'
#!/bin/bash
echo "package $*" >>"$EVENTS"
[[ ${PACKAGE_FAIL:-0} != 1 ]] || exit 1
rm -f "$STATE/no-unit"
SH
cat >"$stub/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ ${UFW_MISSING:-0} == 1 ]]
SH
cat >"$stub/curl" <<'SH'
#!/bin/bash
echo github-fetch >>"$EVENTS"
[[ ${GH_FAIL:-0} != 1 ]] || exit 1
printf %s "${GH_KEYS:-}"
SH
cat >"$stub/gum" <<'SH'
#!/bin/bash
case $1 in choose) printf '%s\n' "${GUM_CHOICE:-}" ;; input) [[ ${GUM_CANCEL:-0} != 1 ]] && printf '%s\n' "${GUM_INPUT:-}" ;; esac
SH
cat >"$stub/mv" <<'SH'
#!/bin/bash
if [[ ${*: -1} == */authorized_keys ]]; then
  echo authorized-key >>"$EVENTS"
  # The second move onto authorized_keys is rollback restoring the original.
  if [[ ${KEYS_HANG:-0} == 1 && -e $STATE/keys-moved ]]; then echo "$PPID" >"$STATE/setup.pid"; sleep 30 & wait $! || true; exit 1; fi
  touch "$STATE/keys-moved"
fi
exec /usr/bin/mv "$@"
SH

cat >"$stub/sudo" <<'SH'
#!/bin/bash
set -euo pipefail
echo "sudo $*" >>"$EVENTS"
if [[ ${1:-} == -k ]]; then
  # The first revocation is setup's entry, a later one cleanup's final one.
  # Each records its parent, which sudo keys timestamps by under ppid.
  if [[ -e $STATE/k-seen ]]; then
    echo "$PPID" >"$STATE/setup.pid"; echo "$PPID" >>"$STATE/final-k.ppid"
    if [[ ${REVOKE_SLOW:-0} == 1 ]]; then touch "$STATE/revoking"; sleep 1; echo revoked >>"$EVENTS"; fi
    if [[ ${REVOKE_ORPHAN:-0} == 1 ]]; then sleep 30 & exit 0; fi
    if [[ ${REVOKE_HANG:-0} == 1 ]]; then [[ ${REVOKE_IGNORE_TERM:-0} != 1 ]] || trap '' TERM; sleep 30 >/dev/null & wait $!; fi
  else
    echo "$PPID" >"$STATE/k-seen"
  fi
  exit 0
fi
map() { [[ $1 == /etc/* || $1 == /var/* ]] && printf '%s%s' "$FAKE_ROOT" "$1" || printf %s "$1"; }
case $1 in
systemctl)
  a=$2
  case $a in
  is-active) [[ ${ACTIVE_QUERY_ERROR:-0} != 1 ]] || exit 2; [[ ! -e $STATE/no-unit ]] || { echo inactive; exit 4; }; [[ -e $STATE/active ]] && { echo active; exit 0; } || { echo inactive; exit 3; } ;;
  is-enabled) [[ ${ENABLED_QUERY_ERROR:-0} != 1 ]] || exit 2; [[ ! -e $STATE/no-unit ]] || { echo not-found; exit 4; }; [[ -e $STATE/enabled ]] && { echo enabled; exit 0; } || { echo disabled; exit 1; } ;;
  start) [[ ${START_PARTIAL:-0} != 1 ]] || { touch "$STATE/active"; exit 1; }; [[ ${START_FAIL:-0} != 1 ]] || exit 1; touch "$STATE/active" ;;
  enable) [[ ${ENABLE_PARTIAL:-0} != 1 ]] || { touch "$STATE/enabled"; exit 1; }; [[ ${ENABLE_FAIL:-0} != 1 ]] || exit 1; touch "$STATE/enabled" ;;
  stop) [[ ${STOP_FAIL:-0} != 1 ]] || exit 1; rm -f "$STATE/active" ;;
  disable) [[ ${DISABLE_FAIL:-0} != 1 ]] || exit 1; rm -f "$STATE/enabled" ;;
  reload) n=0; [[ ! -e $STATE/reloads ]] || read -r n <"$STATE/reloads"; n=$((n+1)); echo "$n" >"$STATE/reloads"; [[ ${RELOAD_ALWAYS_FAIL:-0} != 1 && (${RELOAD_ONCE:-0} != 1 || $n != 1) ]] ;;
  esac ;;
ufw)
  shift
  if [[ $1 == show ]]; then [[ ${UFW_QUERY_ERROR:-0} != 1 ]] || exit 1; [[ -e $STATE/rule && ${VERIFY_MISS:-0} != 1 ]] && echo "ufw limit 22/tcp comment 'omarchy-sshd'"; exit 0
  elif [[ $1 == limit ]]; then [[ ${LIMIT_PARTIAL:-0} != 1 ]] || { touch "$STATE/rule"; exit 1; }; [[ ${LIMIT_FAIL:-0} != 1 ]] || exit 1; touch "$STATE/rule"; [[ ${LIMIT_SIGNAL:-0} != 1 ]] || kill -TERM "$PPID"
  elif [[ $1 == --force ]]; then [[ ${DELETE_SIGNAL:-0} != 1 ]] || { trap "" TERM; kill -TERM "$PPID"; }; if [[ ${DELETE_HANG:-0} == 1 ]]; then echo "$PPID" >"$STATE/setup.pid"; sleep 30 & wait $! || true; fi; [[ ${DELETE_FAIL:-0} != 1 ]] || exit 1; rm -f "$STATE/rule"
  elif [[ $1 == reload ]]; then n=0; [[ ! -e $STATE/ufw-reloads ]] || read -r n <"$STATE/ufw-reloads"; n=$((n+1)); echo "$n" >"$STATE/ufw-reloads"; [[ ${UFW_RELOAD_ALWAYS_FAIL:-0} != 1 && (${UFW_RELOAD_ONCE:-0} != 1 || $n != 1) ]]
  fi ;;
test) p=$(map "$3"); case $2 in -e) [[ -e $p ]] ;; -L) [[ -L $p ]] ;; -f) [[ -f $p ]] ;; esac ;;
mktemp) p=$(map "$2"); mkdir -p "${p%/*}"; /usr/bin/mktemp "$p" ;;
cp) s=$(map "${*: -2:1}"); d=$(map "${*: -1}"); /usr/bin/cp -a "$s" "$d"; [[ ${BACKUP_SIGNAL:-0} != 1 ]] || kill -TERM "$PPID" ;;
install) s=$(map "${*: -2:1}"); d=$(map "${*: -1}"); mkdir -p "${d%/*}"; /usr/bin/install -m0644 "$s" "$d"; if [[ $d == *.conf ]]; then echo installed-hardening; else echo installed-marker; [[ ${MARKER_SIGNAL:-0} != 1 ]] || kill -TERM "$PPID"; fi >>"$EVENTS" ;;
/usr/bin/awk) x=("$@"); x[-1]=$(map "${x[-1]}"); exec "${x[@]}" ;;
/usr/bin/find) x=("$@"); x[1]=$(map "${x[1]}"); exec "${x[@]}" ;;
ssh-keygen) echo host-keygen >>"$EVENTS"; [[ ${HOSTKEY_FAIL:-0} != 1 ]] || exit 1; touch "$FAKE_ROOT/etc/ssh/ssh_host_key" ;;
sshd)
  if [[ $2 == -t ]]; then echo sshd-t >>"$EVENTS"; [[ ${T_FAIL:-0} != 1 ]]
  else echo sshd-T >>"$EVENTS"; [[ ${DUMP_FAIL:-0} != 1 ]] || exit 1; if [[ " $* " == *' -C '* ]]; then echo "PasswordAuthentication ${MATCH_PASS_AUTH:-${PASS_AUTH:-no}}"; echo "KbdInteractiveAuthentication ${MATCH_KBD_AUTH:-${KBD_AUTH:-no}}"; echo "AuthenticationMethods ${MATCH_AUTH_METHODS:-${AUTH_METHODS:-publickey}}"; echo "PubkeyAuthentication ${MATCH_PUBKEY_AUTH:-${PUBKEY_AUTH:-yes}}"; echo "AuthorizedKeysFile ${MATCH_KEYS_SETTING:-${AUTHORIZED_KEYS_SETTING:-.ssh/authorized_keys}}"; echo "PubkeyAcceptedAlgorithms ${ACCEPTED_ALGORITHMS:-ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256}"; echo "RequiredRSASize 1024"; echo "RefuseConnection ${MATCH_REFUSE:-no}"; echo "ForceCommand ${MATCH_FORCE:-none}"; [[ -z ${ALLOW_USERS:-} ]] || echo "AllowUsers $ALLOW_USERS"; [[ -z ${DENY_USERS:-} ]] || echo "DenyUsers $DENY_USERS"; [[ -z ${ALLOW_GROUPS:-} ]] || echo "AllowGroups $ALLOW_GROUPS"; [[ -z ${DENY_GROUPS:-} ]] || echo "DenyGroups $DENY_GROUPS"; else echo "PasswordAuthentication ${PASS_AUTH:-no}"; echo "KbdInteractiveAuthentication ${KBD_AUTH:-no}"; echo "AuthenticationMethods ${AUTH_METHODS:-publickey}"; echo "PubkeyAuthentication ${PUBKEY_AUTH:-yes}"; echo "AuthorizedKeysFile ${AUTHORIZED_KEYS_SETTING:-.ssh/authorized_keys}"; fi; fi ;;
mv) s=$(map "${*: -2:1}"); d=$(map "${*: -1}"); /usr/bin/mv -fT "$s" "$d" ;;
rm) [[ ${CONFIG_RM_FAIL:-0} != 1 ]] || exit 1; /usr/bin/rm -f "$(map "${*: -1}")" ;;
*) exec "$@" ;;
esac
SH
chmod +x "$stub"/*

mapped_root="$tmp/omarchy"
mkdir -p "$mapped_root/bin"
sed "s#/usr/bin/sudo#$stub/sudo#g" "$ROOT/bin/omarchy-security-functions" >"$mapped_root/bin/omarchy-security-functions"
cp "$ROOT/bin/omarchy-sshd-functions" "$mapped_root/bin/omarchy-sshd-functions"
mapped_sshd="$mapped_root/bin/omarchy-setup-security-sshd"
sed \
  -e "s#/usr/bin/getent#$stub/getent#g" \
  -e "s#/usr/bin/id#$stub/id#g" \
  -e "s#/usr/bin/passwd#$stub/passwd#g" \
  -e "s#/usr/bin/sudo#$stub/sudo#g" \
  -e "s#/usr/bin/omarchy-pkg-add#$stub/omarchy-pkg-add#g" \
  -e "s#/usr/bin/omarchy-cmd-missing#$stub/omarchy-cmd-missing#g" \
  -e "s#/usr/bin/curl#$stub/curl#g" \
  -e "s#/usr/bin/gum#$stub/gum#g" \
  -e "s#/usr/bin/mv#$stub/mv#g" \
  "$ROOT/bin/omarchy-setup-security-sshd" >"$mapped_sshd"
# A copy whose cleanup jobs give up quickly, to test those bounds.
sed -e 's#^CLEANUP_COMMAND_BOUND=120$#CLEANUP_COMMAND_BOUND=1#' -e 's#^CLEANUP_REVOKE_BOUND=30$#CLEANUP_REVOKE_BOUND=1#' "$mapped_sshd" >"$mapped_root/bin/omarchy-setup-security-sshd-fast"
grep -qx 'CLEANUP_COMMAND_BOUND=1' "$mapped_root/bin/omarchy-setup-security-sshd-fast" && grep -qx 'CLEANUP_REVOKE_BOUND=1' "$mapped_root/bin/omarchy-setup-security-sshd-fast" ||
  fail "test could not shorten the cleanup bounds"
# A copy whose keeper cannot identify its job, as without /proc.
sed 's#</proc/self/stat#</proc/self/omarchy-missing#' "$mapped_sshd" >"$mapped_root/bin/omarchy-setup-security-sshd-nojob"
grep -qF '</proc/self/omarchy-missing' "$mapped_root/bin/omarchy-setup-security-sshd-nojob" || fail "test could not break the cleanup keeper"
chmod 0755 "$mapped_root/bin/"*

ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
key=$(<"$tmp/key.pub")

run() {
  local name=$1; shift; local d="$tmp/$name"
  mkdir -p "$d/home" "$d/root/etc/ssh/sshd_config.d" "$d/state"
  [[ -e $d/root/etc/ssh/sshd_config ]] || echo 'Include /etc/ssh/sshd_config.d/*.conf' >"$d/root/etc/ssh/sshd_config"
  : >"$d/events"
  [[ ${PRE_ACTIVE:-0} != 1 ]] || touch "$d/state/active"
  [[ ${PRE_ENABLED:-0} != 1 ]] || touch "$d/state/enabled"
  [[ ${PRE_RULE:-0} != 1 ]] || touch "$d/state/rule"
  [[ ${UNIT_MISSING:-0} != 1 ]] || touch "$d/state/no-unit"
  ${RUN_WRAPPER:-} env HOME="$d/home" PATH="$stub:/usr/bin" OMARCHY_PATH="$mapped_root" FAKE_ROOT="$d/root" STATE="$d/state" EVENTS="$d/events" USER=audit TEST_UID="$test_uid" \
    TEST_ACCOUNT="${TEST_ACCOUNT:-audit}" TEST_GROUPS="${TEST_GROUPS:-audit sshers}" ACCOUNT_STATUS="${ACCOUNT_STATUS:-P}" ACTIVE_QUERY_ERROR="${ACTIVE_QUERY_ERROR:-0}" ENABLED_QUERY_ERROR="${ENABLED_QUERY_ERROR:-0}" \
    PACKAGE_FAIL="${PACKAGE_FAIL:-0}" GH_FAIL="${GH_FAIL:-0}" GH_KEYS="${GH_KEYS:-}" GUM_CHOICE="${GUM_CHOICE:-}" GUM_INPUT="${GUM_INPUT:-}" GUM_CANCEL="${GUM_CANCEL:-0}" \
    START_FAIL="${START_FAIL:-0}" START_PARTIAL="${START_PARTIAL:-0}" ENABLE_FAIL="${ENABLE_FAIL:-0}" ENABLE_PARTIAL="${ENABLE_PARTIAL:-0}" RELOAD_ONCE="${RELOAD_ONCE:-0}" RELOAD_ALWAYS_FAIL="${RELOAD_ALWAYS_FAIL:-0}" \
    HOSTKEY_FAIL="${HOSTKEY_FAIL:-0}" T_FAIL="${T_FAIL:-0}" DUMP_FAIL="${DUMP_FAIL:-0}" PASS_AUTH="${PASS_AUTH:-no}" KBD_AUTH="${KBD_AUTH:-no}" AUTH_METHODS="${AUTH_METHODS:-publickey}" PUBKEY_AUTH="${PUBKEY_AUTH:-yes}" AUTHORIZED_KEYS_SETTING="${AUTHORIZED_KEYS_SETTING:-.ssh/authorized_keys}" \
    MATCH_PASS_AUTH="${MATCH_PASS_AUTH:-}" MATCH_KBD_AUTH="${MATCH_KBD_AUTH:-}" MATCH_AUTH_METHODS="${MATCH_AUTH_METHODS:-}" MATCH_PUBKEY_AUTH="${MATCH_PUBKEY_AUTH:-}" MATCH_KEYS_SETTING="${MATCH_KEYS_SETTING:-}" \
    ALLOW_USERS="${ALLOW_USERS:-}" DENY_USERS="${DENY_USERS:-}" ALLOW_GROUPS="${ALLOW_GROUPS:-}" DENY_GROUPS="${DENY_GROUPS:-}" \
    ACCEPTED_ALGORITHMS="${ACCEPTED_ALGORITHMS:-}" UFW_QUERY_ERROR="${UFW_QUERY_ERROR:-0}" LIMIT_SIGNAL="${LIMIT_SIGNAL:-0}" BACKUP_SIGNAL="${BACKUP_SIGNAL:-0}" \
    MATCH_REFUSE="${MATCH_REFUSE:-}" MATCH_FORCE="${MATCH_FORCE:-}" DELETE_SIGNAL="${DELETE_SIGNAL:-0}" MARKER_SIGNAL="${MARKER_SIGNAL:-0}" DELETE_HANG="${DELETE_HANG:-0}" KEYS_HANG="${KEYS_HANG:-0}" REVOKE_SLOW="${REVOKE_SLOW:-0}" REVOKE_HANG="${REVOKE_HANG:-0}" REVOKE_IGNORE_TERM="${REVOKE_IGNORE_TERM:-0}" REVOKE_ORPHAN="${REVOKE_ORPHAN:-0}" \
    LIMIT_FAIL="${LIMIT_FAIL:-0}" LIMIT_PARTIAL="${LIMIT_PARTIAL:-0}" VERIFY_MISS="${VERIFY_MISS:-0}" UFW_RELOAD_ONCE="${UFW_RELOAD_ONCE:-0}" UFW_RELOAD_ALWAYS_FAIL="${UFW_RELOAD_ALWAYS_FAIL:-0}" DELETE_FAIL="${DELETE_FAIL:-0}" CONFIG_RM_FAIL="${CONFIG_RM_FAIL:-0}" \
    "${SETUP_BIN:-$mapped_sshd}" "$@"
}
no_publish() { ! grep -Eq 'sudo systemctl (start|enable|reload)|sudo ufw limit' "$tmp/$1/events" || fail "$1 published SSH" "$(cat "$tmp/$1/events")"; }
rolled_back() { [[ ! -e $tmp/$1/state/active && ! -e $tmp/$1/state/enabled && ! -e $tmp/$1/state/rule && ! -e $tmp/$1/home/.ssh/authorized_keys ]] || fail "$1 did not roll back"; }

for c in help unknown gh both; do case $c in help) a=(--help); want=0;; unknown) a=(--bad); want=2;; gh) a=(--gh-keys); want=2;; both) a=("--key=$key" --gh-keys x); want=2;; esac; if run "arg-$c" "${a[@]}" >/dev/null 2>&1; then s=0; else s=$?; fi; [[ $s == $want && ! -s $tmp/arg-$c/events ]] || fail "argument $c mutated"; done
pass "SSH arguments and help are mutation-free"

for c in package gh-fail gh-empty gh-invalid prompt-cancel prompt-invalid home-symlink home-writable auth-symlink auth-dir; do
  a=("--key=$key")
  case $c in package) PACKAGE_FAIL=1;; gh-fail) GH_FAIL=1; a=(--gh-keys x);; gh-empty) GH_KEYS=''; a=(--gh-keys x);; gh-invalid) GH_KEYS=bad; a=(--gh-keys x);; prompt-cancel) GUM_CHOICE='Paste key manually'; GUM_CANCEL=1; a=();; prompt-invalid) GUM_CHOICE='Paste key manually'; GUM_INPUT=bad; a=();; home-symlink) mkdir -p "$tmp/$c/real-home"; ln -s "$tmp/$c/real-home" "$tmp/$c/home";; home-writable) mkdir -p "$tmp/$c/home"; chmod 0777 "$tmp/$c/home";; auth-symlink) mkdir -p "$tmp/$c/home/.ssh"; ln -s "$tmp/victim" "$tmp/$c/home/.ssh/authorized_keys";; auth-dir) mkdir -p "$tmp/$c/home/.ssh/authorized_keys";; esac
  if run "$c" "${a[@]}" >/dev/null 2>&1; then fail "$c succeeds"; fi; no_publish "$c"; unset PACKAGE_FAIL GH_FAIL GH_KEYS GUM_CHOICE GUM_CANCEL GUM_INPUT
done
GH_KEYS="bad
$key"; run gh-mixed --gh-keys x >/dev/null; grep -qxF "$key" "$tmp/gh-mixed/home/.ssh/authorized_keys"; unset GH_KEYS
pass "key acquisition and authorization fail before publication"

run fresh "--key=$key" >/dev/null
[[ $(head -n1 "$tmp/fresh/events") == 'sudo -k' && $(tail -n1 "$tmp/fresh/events") == 'sudo -k' ]] ||
  fail "SSH setup does not begin and end with credential invalidation" "$(cat "$tmp/fresh/events")"
prev=0
for e in authorized-key installed-hardening host-keygen sshd-t sshd-T 'sudo systemctl start' 'sudo systemctl enable' 'sudo ufw limit'; do n=$(grep -nF "$e" "$tmp/fresh/events"|head -1|cut -d: -f1); [[ -n $n && $prev -lt $n ]] || fail "unsafe fresh order at $e"; prev=$n; done
grep -qxF 'AuthenticationMethods publickey' "$tmp/fresh/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf"
[[ -f $tmp/fresh/root/var/lib/omarchy/migrations/1788163637 ]] || fail "a published setup did not certify its conversion"
n=$(grep -n 'installed-marker' "$tmp/fresh/events" | head -1 | cut -d: -f1); r=$(grep -n 'sudo ufw limit' "$tmp/fresh/events" | head -1 | cut -d: -f1)
[[ -n $n && -n $r ]] && (( r < n )) || fail "the conversion was certified before it was published" "$(cat "$tmp/fresh/events")"
pass "fresh SSH is key-authorized and validated before publication, and certified only after it"

# Without the package the unit does not exist, so its state cannot be recorded
# until openssh is installed; installing it first lets setup proceed.
UNIT_MISSING=1 run unit-missing "--key=$key" >/dev/null || fail "setup fails when openssh is not installed yet" "$(cat "$tmp/unit-missing/events")"
p=$(grep -nF 'package openssh' "$tmp/unit-missing/events" | head -1 | cut -d: -f1); q=$(grep -nF 'sudo systemctl is-' "$tmp/unit-missing/events" | head -1 | cut -d: -f1)
[[ -n $p && -n $q ]] && (( p < q )) || fail "openssh is not installed before the service state is recorded" "$(cat "$tmp/unit-missing/events")"
pass "setup installs openssh before recording the service state"

# ssh-keygen -lf accepts restricted lines; none of them proves a usable login.
n=0
for opt in 'cert-authority' 'command="false"' 'from="!*,*"' 'expiry-time="20200101"' 'restrict' 'no-pty'; do
  n=$((n+1))
  if run "restricted-$n" "--key=$opt $key" >/dev/null 2>&1; then fail "restricted key accepted: $opt"; fi
  no_publish "restricted-$n"; [[ ! -e $tmp/restricted-$n/home/.ssh/authorized_keys ]] || fail "restricted key was authorized: $opt"
done
run flags "--key=no-agent-forwarding,no-port-forwarding $key" >/dev/null || fail "flag-only options that keep the login usable were refused"
pass "restricted key options are refused before any authorization or publication"

# The key must also be one sshd would accept for this account.
ACCEPTED_ALGORITHMS=ecdsa-sha2-nistp256,rsa-sha2-512
if run algorithm "--key=$key" >/dev/null 2>&1; then fail "a key whose algorithm sshd refuses was published"; fi
no_publish algorithm; rolled_back algorithm; unset ACCEPTED_ALGORITHMS
[[ ! -e $tmp/algorithm/root/var/lib/omarchy/migrations/1788163637 ]] || fail "a failed setup certified a conversion"
for c in refuse force; do
  if [[ $c == refuse ]]; then MATCH_REFUSE=yes; else MATCH_FORCE=/usr/bin/false; fi
  if run "login-$c" "--key=$key" >/dev/null 2>&1; then fail "setup published for an account sshd would $c"; fi
  no_publish "login-$c"; rolled_back "login-$c"; unset MATCH_REFUSE MATCH_FORCE
done
pass "setup refuses a key the account's effective policy would not accept, refuse, or force"

# An unanswered UFW query must not read as "no rule": rollback would then
# delete the administrator's existing rule.
PRE_RULE=1 UFW_QUERY_ERROR=1
if run ufw-query "--key=$key" >/dev/null 2>&1; then fail "setup continued without knowing the UFW rules"; fi
[[ -e $tmp/ufw-query/state/rule ]] || fail "an unanswered UFW query deleted the existing rule"
no_publish ufw-query; unset PRE_RULE UFW_QUERY_ERROR
# A signal right after the rule is added still removes it.
LIMIT_SIGNAL=1
if run limit-signal "--key=$key" >/dev/null 2>&1; then fail "an interrupted setup reported success"; fi
rolled_back limit-signal; unset LIMIT_SIGNAL
# A signal right after the config backup still removes the backup.
name=backup-signal; cfg="$tmp/$name/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf"; mkdir -p "${cfg%/*}"; echo ADMIN >"$cfg"
BACKUP_SIGNAL=1
if run "$name" "--key=$key" >/dev/null 2>&1; then fail "setup interrupted after its backup reported success"; fi
! compgen -G "$tmp/$name/root/etc/ssh/sshd_config.d/.00-omarchy-key-only.backup.*" >/dev/null || fail "an interrupted setup left its config backup behind"
[[ $(<"$cfg") == ADMIN ]] || fail "an interrupted setup changed the existing config"
unset BACKUP_SIGNAL
# A second signal arriving while rollback runs is held; it does not abort it.
UFW_RELOAD_ONCE=1 DELETE_SIGNAL=1
if run rollback-signal "--key=$key" >/dev/null 2>&1; then fail "a failed setup reported success"; fi
rolled_back rollback-signal
[[ $(tail -n1 "$tmp/rollback-signal/events") == 'sudo -k' ]] || fail "a signal during rollback skipped the final revocation" "$(tail -n3 "$tmp/rollback-signal/events")"
unset UFW_RELOAD_ONCE DELETE_SIGNAL
# A command that hangs during rollback is bounded: a TERM sent only to setup,
# as `kill $pid` or timeout --foreground send, is held, the hung command is
# killed at its deadline, and rollback goes on with its remaining steps.
# Nothing here kills recorded PIDs; every stand-in that hangs is a bounded
# sleep inside a job the cleanup bounds.
UFW_RELOAD_ONCE=1 DELETE_HANG=1 SETUP_BIN="$mapped_root/bin/omarchy-setup-security-sshd-fast"
run rollback-hang "--key=$key" >"$tmp/rollback-hang.out" 2>&1 & runner=$!
for (( i = 0; i < 200; i++ )); do [[ -s $tmp/rollback-hang/state/setup.pid ]] && break; sleep 0.05; done
[[ -s $tmp/rollback-hang/state/setup.pid ]] || fail "the rollback never reached the hanging firewall command"
kill -TERM "$(<"$tmp/rollback-hang/state/setup.pid")" 2>/dev/null || true
for (( i = 0; i < 300; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
kill -0 "$runner" 2>/dev/null && fail "a hung rollback command held setup forever"
wait "$runner" 2>/dev/null || true
# The killed delete did not remove the rule, so rollback must say so, and
# still restore everything else and revoke.
[[ ! -e $tmp/rollback-hang/state/active && ! -e $tmp/rollback-hang/state/enabled && ! -e $tmp/rollback-hang/home/.ssh/authorized_keys ]] ||
  fail "rollback did not restore the service and keys after its hung command was killed"
grep -q 'CRITICAL: SSH setup rollback was incomplete' "$tmp/rollback-hang.out" || fail "an interrupted rollback step was not reported" "$(cat "$tmp/rollback-hang.out")"
[[ $(tail -n1 "$tmp/rollback-hang/events") == 'sudo -k' ]] || fail "rollback did not finish after its hung command was killed"
unset UFW_RELOAD_ONCE DELETE_HANG SETUP_BIN
# The same holds for restoring authorized_keys, which runs without sudo.
name=keys-hang; mkdir -p "$tmp/$name/home/.ssh"; chmod 0700 "$tmp/$name/home/.ssh"; echo "$key" >"$tmp/$name/home/.ssh/authorized_keys"; chmod 0600 "$tmp/$name/home/.ssh/authorized_keys"
LIMIT_FAIL=1 KEYS_HANG=1 SETUP_BIN="$mapped_root/bin/omarchy-setup-security-sshd-fast"
run "$name" "--key=$key" >"$tmp/$name.out" 2>&1 & runner=$!
for (( i = 0; i < 200; i++ )); do [[ -s $tmp/$name/state/setup.pid ]] && break; sleep 0.05; done
[[ -s $tmp/$name/state/setup.pid ]] || fail "the rollback never reached the hanging key restoration"
kill -TERM "$(<"$tmp/$name/state/setup.pid")" 2>/dev/null || true
for (( i = 0; i < 300; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
kill -0 "$runner" 2>/dev/null && fail "a hung key restoration held setup forever"
wait "$runner" 2>/dev/null || true
grep -q 'CRITICAL: SSH setup rollback was incomplete' "$tmp/$name.out" || fail "an interrupted key restoration was not reported" "$(cat "$tmp/$name.out")"
[[ $(tail -n1 "$tmp/$name/events") == 'sudo -k' ]] || fail "rollback did not revoke after its hung key restoration was killed"
unset LIMIT_FAIL KEYS_HANG SETUP_BIN
# The final revocation is not something a signal stops: a TERM sent to setup
# while it runs is held, and the revocation completes.
LIMIT_FAIL=1 REVOKE_SLOW=1
run revoke-signal "--key=$key" >"$tmp/revoke-signal.out" 2>&1 & runner=$!
for (( i = 0; i < 200; i++ )); do [[ -e $tmp/revoke-signal/state/revoking ]] && break; sleep 0.05; done
[[ -e $tmp/revoke-signal/state/revoking && -s $tmp/revoke-signal/state/setup.pid ]] || fail "the rollback never reached its final revocation"
kill -TERM "$(<"$tmp/revoke-signal/state/setup.pid")" 2>/dev/null || true
wait "$runner" 2>/dev/null || true
grep -qx revoked "$tmp/revoke-signal/events" || fail "a TERM to setup interrupted its final revocation" "$(tail -n3 "$tmp/revoke-signal/events")"
! grep -q 'could not invalidate' "$tmp/revoke-signal.out" || fail "a completed final revocation was reported as failed"
[[ $(<"$tmp/revoke-signal/state/final-k.ppid") == "$(<"$tmp/revoke-signal/state/k-seen")" ]] ||
  fail "the final revocation ran under a different parent than setup's own sudo calls"
unset LIMIT_FAIL REVOKE_SLOW
# A final revocation that hangs is bounded and reported, not waited on forever.
LIMIT_FAIL=1 REVOKE_HANG=1 SETUP_BIN="$mapped_root/bin/omarchy-setup-security-sshd-fast"
run revoke-hang "--key=$key" >"$tmp/revoke-hang.out" 2>&1 & runner=$!
for (( i = 0; i < 300; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
kill -0 "$runner" 2>/dev/null && fail "a hung final revocation held setup forever"
wait "$runner" 2>/dev/null && fail "setup succeeded although its final revocation never completed" || true
grep -q 'could not invalidate cached sudo authorization' "$tmp/revoke-hang.out" || fail "a hung final revocation was not reported" "$(cat "$tmp/revoke-hang.out")"
! grep -q 'Killed' "$tmp/revoke-hang.out" || fail "a killed revocation leaked a job report" "$(cat "$tmp/revoke-hang.out")"
[[ $(grep -c '^sudo -k$' "$tmp/revoke-hang/events") == 4 ]] || fail "a hung final revocation was not retried" "$(cat "$tmp/revoke-hang/events")"
unset LIMIT_FAIL REVOKE_HANG SETUP_BIN
# Nor does a signal to setup's whole process group unbound it, even when the
# hung revocation ignores that signal. Setup leads its own group here.
LIMIT_FAIL=1 REVOKE_HANG=1 REVOKE_IGNORE_TERM=1 RUN_WRAPPER=setsid SETUP_BIN="$mapped_root/bin/omarchy-setup-security-sshd-fast"
run revoke-group "--key=$key" >"$tmp/revoke-group.out" 2>&1 & runner=$!
for (( i = 0; i < 200; i++ )); do [[ -s $tmp/revoke-group/state/setup.pid ]] && break; sleep 0.05; done
[[ -s $tmp/revoke-group/state/setup.pid ]] || fail "the rollback never reached its final revocation"
kill -TERM -- "-$(<"$tmp/revoke-group/state/setup.pid")" 2>/dev/null || true
for (( i = 0; i < 300; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
kill -0 "$runner" 2>/dev/null && fail "a group signal left a hung final revocation unbounded"
wait "$runner" 2>/dev/null && fail "setup succeeded although its final revocation never completed" || true
grep -q 'could not invalidate cached sudo authorization' "$tmp/revoke-group.out" || fail "a hung final revocation after a group signal was not reported" "$(cat "$tmp/revoke-group.out")"
unset LIMIT_FAIL REVOKE_HANG REVOKE_IGNORE_TERM RUN_WRAPPER SETUP_BIN
# A revoker that exits but leaves something running has still revoked: its
# exit, not its leftover, ends the job. With the full 30-second bound,
# finishing within 15 seconds proves that. The leftover is a 30-second sleep.
LIMIT_FAIL=1 REVOKE_ORPHAN=1
run revoke-orphan "--key=$key" >"$tmp/revoke-orphan.out" 2>&1 & runner=$!
for (( i = 0; i < 300; i++ )); do kill -0 "$runner" 2>/dev/null || break; sleep 0.05; done
kill -0 "$runner" 2>/dev/null && fail "a revoker's leftover process held setup forever"
wait "$runner" 2>/dev/null || true
! grep -q 'could not invalidate' "$tmp/revoke-orphan.out" || fail "a revocation that succeeded was reported as failed"
[[ $(grep -c '^sudo -k$' "$tmp/revoke-orphan/events") == 2 ]] || fail "a revocation that succeeded was retried" "$(cat "$tmp/revoke-orphan/events")"
unset LIMIT_FAIL REVOKE_ORPHAN
# Cleanup never signals a PID it recorded: the only signals in setup are the
# keeper's, on the group it belongs to and the PID that group reserves.
kills=$(grep -nE '(^|[^[:alnum:]_])kill ' "$ROOT/bin/omarchy-setup-security-sshd" | grep -vE 'kill -0 "\$group"|kill -KILL -- "-\$group"' || true)
[[ -z $kills ]] || fail "setup signals a process outside its keeper" "$kills"
# Where bounded cleanup jobs cannot work, setup refuses before anything
# privileged rather than run a cleanup it could not bound.
SETUP_BIN="$mapped_root/bin/omarchy-setup-security-sshd-nojob"
if run nojob "--key=$key" >"$tmp/nojob.out" 2>&1; then fail "setup without bounded cleanup jobs succeeded"; fi
[[ ! -s $tmp/nojob/events ]] || fail "setup without bounded cleanup jobs ran sudo" "$(cat "$tmp/nojob/events")"
grep -q 'Could not start a bounded cleanup job' "$tmp/nojob.out" || fail "setup without bounded cleanup jobs did not say why" "$(cat "$tmp/nojob.out")"
unset SETUP_BIN
# A signal can arrive as a non-signal failure enters cleanup; the EXIT trap's
# first command both records the status and marks cleanup active.
grep -qxF "trap 'CLEANUP_EXIT_STATUS=\$? CLEANUP_ACTIVE=true; rollback_setup' EXIT" "$ROOT/bin/omarchy-setup-security-sshd" ||
  fail "setup's EXIT trap does not mark cleanup active in its first command"
# The completion certificate never outlives an incomplete setup: an earlier
# one is invalidated, and a signal right after writing it removes it again.
name=marker-signal; mkdir -p "$tmp/$name/root/var/lib/omarchy/migrations"; : >"$tmp/$name/root/var/lib/omarchy/migrations/1788163637"
MARKER_SIGNAL=1
if run "$name" "--key=$key" >/dev/null 2>&1; then fail "setup interrupted after certifying reported success"; fi
[[ ! -e $tmp/$name/root/var/lib/omarchy/migrations/1788163637 ]] || fail "an interrupted setup left its completion certificate"
rolled_back "$name"; unset MARKER_SIGNAL
name=stale-marker; mkdir -p "$tmp/$name/root/var/lib/omarchy/migrations"; : >"$tmp/$name/root/var/lib/omarchy/migrations/1788163637"
T_FAIL=1
if run "$name" "--key=$key" >/dev/null 2>&1; then fail "a failed setup reported success"; fi
[[ ! -e $tmp/$name/root/var/lib/omarchy/migrations/1788163637 ]] || fail "a failed setup left an earlier completion certificate in place"
unset T_FAIL
pass "firewall query errors and signals during firewall, backup, certification or rollback changes roll back cleanly"

for c in hostkey syntax dump pass kbd methods pubkey keysfile matched; do case $c in hostkey) HOSTKEY_FAIL=1;; syntax) T_FAIL=1;; dump) DUMP_FAIL=1;; pass) PASS_AUTH=yes;; kbd) KBD_AUTH=yes;; methods) AUTH_METHODS=any;; pubkey) PUBKEY_AUTH=no;; keysfile) AUTHORIZED_KEYS_SETTING=/etc/ssh/admin_keys;; matched) MATCH_PASS_AUTH=yes;; esac; if run "$c" "--key=$key" >/dev/null 2>&1; then fail "$c succeeds"; fi; no_publish "$c"; rolled_back "$c"; unset HOSTKEY_FAIL T_FAIL DUMP_FAIL PASS_AUTH KBD_AUTH AUTH_METHODS PUBKEY_AUTH AUTHORIZED_KEYS_SETTING MATCH_PASS_AUTH; done
pass "host-key, syntax, and effective-policy failures are pre-publication"

for c in allow-user deny-user allow-group deny-group locked complex-rule; do
  case $c in
    allow-user) ALLOW_USERS=someone;; deny-user) DENY_USERS=audit;; allow-group) ALLOW_GROUPS=admins;; deny-group) DENY_GROUPS=sshers;; locked) ACCOUNT_STATUS=L;; complex-rule) ALLOW_USERS='aud*';;
  esac
  if run "admission-$c" "--key=$key" >/dev/null 2>&1; then fail "$c admission restriction succeeds"; fi
  no_publish "admission-$c"; rolled_back "admission-$c"
  unset ALLOW_USERS DENY_USERS ALLOW_GROUPS DENY_GROUPS ACCOUNT_STATUS
done
ALLOW_USERS=audit DENY_USERS=someone ALLOW_GROUPS=sshers DENY_GROUPS=admins run admission-ok "--key=$key" >/dev/null
TEST_ACCOUNT='machine$' TEST_GROUPS='machine$ sshers' ALLOW_USERS='machine$' run dollar-account "--key=$key" >/dev/null
unset ALLOW_USERS DENY_USERS ALLOW_GROUPS DENY_GROUPS TEST_ACCOUNT TEST_GROUPS
pass "account admission controls and status are tied to the newly keyed account"

for query in active enabled; do
  PRE_ACTIVE=1 PRE_ENABLED=1
  if [[ $query == active ]]; then ACTIVE_QUERY_ERROR=1; else ENABLED_QUERY_ERROR=1; fi
  if run "query-$query" "--key=$key" >/dev/null 2>&1; then fail "$query query error succeeds"; fi
  [[ -e $tmp/query-$query/state/active && -e $tmp/query-$query/state/enabled && ! -e $tmp/query-$query/home/.ssh/authorized_keys ]] ||
    fail "$query query error changed pre-existing service state or retained the new key"
  no_publish "query-$query"
  unset PRE_ACTIVE PRE_ENABLED ACTIVE_QUERY_ERROR ENABLED_QUERY_ERROR
done
pass "service state query errors abort and roll back without changing existing state"

mkdir -p "$tmp/precedence/root/etc/ssh/sshd_config.d"
printf 'PasswordAuthentication yes\nInclude /etc/ssh/sshd_config.d/*.conf\n' >"$tmp/precedence/root/etc/ssh/sshd_config"
if run precedence "--key=$key" >/dev/null 2>&1; then fail "auth before drop-in include succeeds"; fi
no_publish precedence
mkdir -p "$tmp/earlier/root/etc/ssh/sshd_config.d"; echo '# admin' >"$tmp/earlier/root/etc/ssh/sshd_config.d/-admin.conf"
if run earlier "--key=$key" >/dev/null 2>&1; then fail "earlier expanded drop-in succeeds"; fi
no_publish earlier
for kind in symlink directory; do p="$tmp/hard-$kind/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf"; mkdir -p "${p%/*}"; if [[ $kind == symlink ]]; then ln -s "$tmp/victim" "$p"; else mkdir "$p"; fi; if run "hard-$kind" "--key=$key" >/dev/null 2>&1; then fail "$kind hardening path succeeds"; fi; [[ $kind != symlink || -L $p ]] && [[ $kind != directory || -d $p ]] || fail "$kind hardening path changed"; no_publish "hard-$kind"; done
pass "ambiguous include precedence and nonregular hardening paths fail closed"

for c in start start-partial enable enable-partial limit limit-partial verify reload; do case $c in start) START_FAIL=1;; start-partial) START_PARTIAL=1;; enable) ENABLE_FAIL=1;; enable-partial) ENABLE_PARTIAL=1;; limit) LIMIT_FAIL=1;; limit-partial) LIMIT_PARTIAL=1;; verify) VERIFY_MISS=1;; reload) UFW_RELOAD_ONCE=1;; esac; if run "$c" "--key=$key" >/dev/null 2>&1; then fail "$c succeeds"; fi; rolled_back "$c"; unset START_FAIL START_PARTIAL ENABLE_FAIL ENABLE_PARTIAL LIMIT_FAIL LIMIT_PARTIAL VERIFY_MISS UFW_RELOAD_ONCE; done
pass "partial service/firewall publication rolls back fresh state"

name=active-fail; cfg="$tmp/$name/root/etc/ssh/sshd_config.d/00-omarchy-key-only.conf"; auth="$tmp/$name/home/.ssh/authorized_keys"; mkdir -p "${cfg%/*}" "${auth%/*}"; echo ADMIN >"$cfg"; chmod 0600 "$cfg"; printf '# existing\n%s\n' "$key" >"$auth"; chmod 0640 "$auth"; before=$(stat -c '%u:%g:%a' "$cfg"):$(sha256sum "$cfg"); auth_before=$(stat -c '%u:%g:%a' "$auth"):$(sha256sum "$auth"); PRE_ACTIVE=1 RELOAD_ONCE=1; if run "$name" "--key=$key" >/dev/null 2>&1; then fail "active reload failure succeeds"; fi; after=$(stat -c '%u:%g:%a' "$cfg"):$(sha256sum "$cfg"); auth_after=$(stat -c '%u:%g:%a' "$auth"):$(sha256sum "$auth"); [[ $before == "$after" && $auth_before == "$auth_after" && $(grep -c 'systemctl reload' "$tmp/$name/events") == 2 ]] || fail "active config/authorized_keys was not exactly restored/reloaded"; unset PRE_ACTIVE RELOAD_ONCE
name=matched-restore; auth="$tmp/$name/home/.ssh/authorized_keys"; mkdir -p "${auth%/*}"; printf '# preserve\n%s\n' "$key" >"$auth"; chmod 0640 "$auth"; auth_before=$(stat -c '%u:%g:%a' "$auth"):$(sha256sum "$auth"); MATCH_PASS_AUTH=yes; if run "$name" "--key=$key" >/dev/null 2>&1; then fail "unsafe matched dump succeeds"; fi; auth_after=$(stat -c '%u:%g:%a' "$auth"):$(sha256sum "$auth"); [[ $auth_before == "$auth_after" ]] || fail "matched-policy failure did not restore authorized_keys exactly"; no_publish "$name"; unset MATCH_PASS_AUTH
PRE_ACTIVE=1 PRE_ENABLED=1 PRE_RULE=1; run existing "--key=$key" >/dev/null; [[ -e $tmp/existing/state/active && -e $tmp/existing/state/enabled && -e $tmp/existing/state/rule ]]; ! grep -Eq 'systemctl (start|enable)|ufw limit' "$tmp/existing/events"; unset PRE_ACTIVE PRE_ENABLED PRE_RULE
pass "pre-existing service/firewall/config state is preserved"

LIMIT_PARTIAL=1 DELETE_FAIL=1 UFW_RELOAD_ALWAYS_FAIL=1; if run rollback-fail "--key=$key" >"$tmp/rollback.out" 2>&1; then fail "incomplete rollback succeeds"; fi; grep -q 'CRITICAL: SSH setup rollback was incomplete' "$tmp/rollback.out" || fail "rollback failure is silent"; unset LIMIT_PARTIAL DELETE_FAIL UFW_RELOAD_ALWAYS_FAIL
pass "rollback failures are loud"

if command -v sshd >/dev/null; then cat >"$tmp/real.conf" <<EOF
HostKey $tmp/key
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
Match all
 PasswordAuthentication no
 KbdInteractiveAuthentication no
 AuthenticationMethods publickey
 PubkeyAuthentication yes
 AuthorizedKeysFile .ssh/authorized_keys
Match User nobody
 PasswordAuthentication yes
 KbdInteractiveAuthentication yes
 AuthenticationMethods any
 PubkeyAuthentication no
 AuthorizedKeysFile /etc/ssh/admin_keys
EOF
dump=$(sshd -T -f "$tmp/real.conf" -C user=nobody,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22); grep -qixF 'passwordauthentication no' <<<"$dump"; grep -qixF 'kbdinteractiveauthentication no' <<<"$dump"; grep -qixF 'authenticationmethods publickey' <<<"$dump"; grep -qixF 'pubkeyauthentication yes' <<<"$dump"; grep -qixF 'authorizedkeysfile .ssh/authorized_keys' <<<"$dump"; pass "real sshd Match cannot bypass first Match-all usable-key policy"; fi
