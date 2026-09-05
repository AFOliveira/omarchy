#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command unshare
require_command setpriv
require_command cc

if [[ ${OMARCHY_DEBUG_SUDO_SECURITY_NS:-0} != 1 ]]; then
  outer_uid=$(id -u)
  outer_gid=$(id -g)
  subuid=$(awk -F: -v user="$(id -un)" '$1 == user { print $2; exit }' /etc/subuid)
  subgid=$(awk -F: -v user="$(id -un)" '$1 == user { print $2; exit }' /etc/subgid)
  if [[ -z $subuid || -z $subgid ]]; then
    pass "no subordinate uid/gid range; skipping debug sudo proof"
    exit 0
  fi
  exec unshare --user --mount \
    --map-users "0:$outer_uid:1" --map-users "1:$subuid:65536" \
    --map-groups "0:$outer_gid:1" --map-groups "1:$subgid:65536" \
    env OMARCHY_DEBUG_SUDO_SECURITY_NS=1 bash "$0"
fi

[[ $(id -u) == 0 ]] || fail "debug proof did not enter its root namespace"

test_tmp=$(mktemp -d)
mount -t tmpfs -o mode=0755,suid tmpfs "$test_tmp"
stub_bin="$test_tmp/bin"
script_dir="$test_tmp/scripts"
test_home="$test_tmp/home"
root_dir="$test_tmp/root"
event_log="$test_tmp/events"
token="$test_tmp/sudo-token"
victim="$root_dir/published"
armed="$test_tmp/waiter-armed"
staging_marker="$test_home/staging-command-ran"
mkdir -p "$stub_bin" "$script_dir" "$test_home/runtime" "$root_dir"
touch "$event_log"
chown -R 1000:1000 "$test_home" "$event_log"
chmod 0700 "$test_home" "$test_home/runtime"
chmod 0755 "$test_tmp" "$stub_bin" "$script_dir" "$root_dir"
chmod 0600 "$event_log"

cleanup() {
  local status=$?
  trap - EXIT
  rm -f "$armed"
  [[ ! -s $test_home/waiter.pid ]] || kill "$(<"$test_home/waiter.pid")" 2>/dev/null || true
  rm -rf "$test_tmp"/* 2>/dev/null || true
  umount -l "$test_tmp" 2>/dev/null || true
  rmdir "$test_tmp" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

cat >"$test_tmp/sudo.c" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *need(const char *name) {
  const char *value = getenv(name);
  if (!value || !*value) exit(125);
  return value;
}

static void event(const char *message) {
  int fd = open(need("TEST_EVENT_LOG"), O_WRONLY | O_APPEND);
  if (fd < 0 || dprintf(fd, "%s\n", message) < 0) exit(125);
  close(fd);
}

int main(int argc, char **argv) {
  const char *token = need("TEST_SUDO_TOKEN");
  int index = 1, no_update = 0, noninteractive = 0, fd;
  if (argc == 2 && !strcmp(argv[1], "-h")) {
    if (getenv("TEST_SUDO_NO_N")) puts("usage: sudo [-ABbEHknPS] command");
    else puts("usage: sudo [-ABbEHkNnPS] command");
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "-k")) {
    event("invalidate");
    const char *delay_marker = getenv("TEST_DELAY_INVALIDATE_MARKER");
    if (delay_marker && *delay_marker) {
      fd = open(delay_marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
      if (fd < 0) return 120;
      close(fd);
      usleep(500000);
    }
    if (unlink(token) && errno != ENOENT) return 121;
    fd = open(need("TEST_WAITER_ARMED"), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 122;
    close(fd);
    return 0;
  }
  if (index < argc && !strcmp(argv[index], "-N")) { no_update = 1; index++; }
  if (index < argc && !strcmp(argv[index], "-n")) { noninteractive = 1; index++; }
  if (index < argc && !strcmp(argv[index], "--")) index++;
  if (noninteractive && access(token, F_OK)) return 1;
  if (no_update) {
    event("grant-no-update");
  } else if (!noninteractive) {
    event("publish-token");
    fd = open(token, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 123;
    close(fd);
    usleep(200000);
  }
  if (index >= argc || setgid(0) || setuid(0)) return 124;
  if (!strcmp(argv[index], "/usr/bin/dmesg")) {
    puts("modeled kernel log");
    return 0;
  }
  execv(argv[index], &argv[index]);
  return 126;
}
C
cc -O2 -Wall -Wextra -o "$stub_bin/sudo" "$test_tmp/sudo.c"
chown 0:0 "$stub_bin/sudo"
chmod 4755 "$stub_bin/sudo"

cat >"$stub_bin/inxi" <<'STUB'
#!/bin/bash
: >"$TEST_COLLECTOR_RAN"
printf 'collector\n' >>"$TEST_EVENT_LOG"
printf 'harmless inxi output\n'
STUB
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
case "$*" in
  '-Q omarchy-dev') printf 'omarchy-dev audit\n' ;;
  '-Qqe'|'-Sql') : ;;
  *) exit 1 ;;
esac
STUB
for command in journalctl expac; do
  printf '#!/bin/bash\nexit 0\n' >"$stub_bin/$command"
done
for command in mkdir install; do
  cat >"$stub_bin/$command" <<'STUB'
#!/bin/bash
: >"$TEST_STAGING_MARKER"
"$TEST_REAL_SUDO" -n -- /usr/bin/install -o 0 -g 0 -m 0600 "$TEST_PAYLOAD" "$TEST_VICTIM" 2>/dev/null || :
exit 99
STUB
done
chmod 0755 "$stub_bin/inxi" "$stub_bin/pacman" "$stub_bin/journalctl" "$stub_bin/expac" \
  "$stub_bin/mkdir" "$stub_bin/install"

sed "s#/usr/bin/sudo#$stub_bin/sudo#g" \
  "$ROOT/bin/omarchy-security-functions" >"$script_dir/omarchy-security-functions"
sed "s#/usr/bin/sudo#$stub_bin/sudo#g" \
  "$ROOT/bin/omarchy-debug" >"$script_dir/omarchy-debug"
chmod 0755 "$script_dir/omarchy-security-functions" "$script_dir/omarchy-debug"

printf 'debug-payload\n' >"$test_home/payload"
chown 1000:1000 "$test_home/payload"
chmod 0600 "$test_home/payload"

start_waiter() {
  rm -f "$victim" "$test_home/reused" "$test_home/waiter.pid"
  setpriv --reuid=1000 --regid=1000 --clear-groups \
    env -i HOME="$test_home" TEST_SUDO="$stub_bin/sudo" \
      TEST_SUDO_TOKEN="$token" TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
      TEST_PAYLOAD="$test_home/payload" TEST_VICTIM="$victim" \
      bash -c '
        echo $$ >"$HOME/waiter.pid"
        while [[ ! -e $TEST_WAITER_ARMED ]]; do /usr/bin/sleep 0.005; done
        while [[ -e $TEST_WAITER_ARMED ]]; do
          if "$TEST_SUDO" -n -- /usr/bin/install -o 0 -g 0 -m 0600 "$TEST_PAYLOAD" "$TEST_VICTIM" 2>/dev/null; then
            : >"$HOME/reused"
            exit 0
          fi
          /usr/bin/sleep 0.005
        done
      ' &
}

run_debug() {
  local command=$1
  shift
  setpriv --reuid=1000 --regid=1000 --clear-groups \
    env -i HOME="$test_home" XDG_RUNTIME_DIR="$test_home/runtime" \
      PATH="$stub_bin:/usr/bin:/bin" VIRTUAL_ENV="$test_home/venv" TEST_SUDO_TOKEN="$token" \
      TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
      TEST_COLLECTOR_RAN="$test_home/collector" TEST_STAGING_MARKER="$staging_marker" \
      TEST_REAL_SUDO="$stub_bin/sudo" TEST_PAYLOAD="$test_home/payload" TEST_VICTIM="$victim" \
      "$@" "$command" --print >/dev/null
}

: >"$event_log"
: >"$token"
chown 1000:1000 "$token"
rm -f "$armed" "$test_home/collector" "$staging_marker"
start_waiter
run_debug "$script_dir/omarchy-debug"
rm -f "$armed"
wait "$(<"$test_home/waiter.pid")" 2>/dev/null || true
[[ -e $test_home/collector && ! -e $victim && ! -e $test_home/reused && ! -e $token ]] ||
  fail "debug collector reused or retained sudo authorization"
[[ ! -e $staging_marker ]] || fail "debug resolved a staging command through hostile PATH"
[[ $(head -n 1 "$event_log") == invalidate ]] || fail "debug ran a collector before cold invalidation"
grep -qxF grant-no-update "$event_log" || fail "debug dmesg did not use sudo --no-update"
[[ $(grep -c '^invalidate$' "$event_log") -ge 3 ]] || fail "debug did not invalidate at entry, after dmesg, and cleanup"
pass "debug pins staging, starts cold, and keeps collectors outside command-scoped dmesg authorization"

: >"$event_log"
rm -f "$token" "$armed" "$test_home/collector"
mutant="$script_dir/omarchy-debug-mutant"
sed "s#$stub_bin/sudo -N --#$stub_bin/sudo --#" "$script_dir/omarchy-debug" >"$mutant"
chmod 0755 "$mutant"
start_waiter
run_debug "$mutant"
rm -f "$armed"
wait "$(<"$test_home/waiter.pid")" 2>/dev/null || true
[[ -e $test_home/reused && -e $victim ]] || fail "removing -N did not restore the modeled credential race"
pass "sudo --no-update is mutation-tested as the load-bearing race guard"

: >"$event_log"
rm -f "$token" "$armed" "$test_home/collector" "$victim"
if run_debug "$script_dir/omarchy-debug" TEST_SUDO_NO_N=1; then
  fail "debug accepted sudo without --no-update support"
fi
[[ ! -e $test_home/collector && ! -e $token && ! -e $victim ]] ||
  fail "unsupported sudo reached user-resolved collectors"
pass "unsupported sudo fails before user-resolved collection"

: >"$event_log"
: >"$token"
chown 1000:1000 "$token"
rm -f "$armed" "$test_home/collector" "$victim"
no_sudo_output=$(setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" XDG_RUNTIME_DIR="$test_home/runtime" \
    PATH="$stub_bin:/usr/bin:/bin" TEST_SUDO_TOKEN="$token" \
    TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_COLLECTOR_RAN="$test_home/collector" TEST_STAGING_MARKER="$staging_marker" \
    TEST_REAL_SUDO="$stub_bin/sudo" TEST_PAYLOAD="$test_home/payload" TEST_VICTIM="$victim" \
    "$script_dir/omarchy-debug" --no-sudo --print)
[[ $no_sudo_output == *"(skipped - --no-sudo flag used)"* && -e $test_home/collector && ! -e $token ]] ||
  fail "--no-sudo no longer skips dmesg while collecting the user report"
! grep -q '^grant-no-update$' "$event_log" || fail "--no-sudo invoked privileged dmesg"
[[ $(grep -c '^invalidate$' "$event_log") -ge 2 ]] || fail "--no-sudo did not protect collectors from a cached token"
[[ $(stat -c '%a' "$test_home/runtime/omarchy-debug.log") == 600 ]] || fail "debug log is not private"
pass "--no-sudo skips dmesg, revokes cached credentials, and writes a private report"

bash_env="$test_home/bash-env"
startup_marker="$test_home/bash-env-ran"
cat >"$bash_env" <<'BASH_ENV'
: >"$TEST_STARTUP_MARKER"
set -o privileged
shift
function /usr/bin/env { return 0; }
function /usr/bin/readlink { printf '/usr/bin/bash\n'; }
function /usr/bin/sudo {
  local -a forwarded=()
  local argument
  for argument in "$@"; do
    [[ $argument == -N ]] || forwarded+=("$argument")
  done
  "$TEST_REAL_SUDO" "${forwarded[@]}"
}
trap 'unset BASH_ENV; set -o privileged' DEBUG
BASH_ENV
: >"$event_log"
: >"$token"
chown 1000:1000 "$token"
rm -f "$startup_marker" "$victim" "$test_home/collector"
startup_padding=$(printf '%65536s' '')
if setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" BASH_ENV="$bash_env" \
    TEST_STARTUP_MARKER="$startup_marker" TEST_SUDO_TOKEN="$token" \
    TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_REAL_SUDO="$stub_bin/sudo" TEST_COLLECTOR_RAN="$test_home/collector" \
    TEST_STARTUP_PADDING="$startup_padding" \
    /usr/bin/bash "$script_dir/omarchy-debug" -p --print >/dev/null 2>&1; then
  fail "debug accepted an ordinary Bash launch with a decoy -p"
fi
[[ -e $startup_marker && -e $token && ! -s $event_log && ! -e $victim && ! -e $test_home/collector ]] ||
  fail "unsafe Bash startup reached the privileged debug workflow"
pass "immutable startup guard rejects oversized shift, trap, and slash-function injection before the workflow"

: >"$event_log"
rm -f "$test_home/collector"
if setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" MY_BASH_ENV=/dev/null \
    TEST_SUDO_TOKEN="$token" TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_COLLECTOR_RAN="$test_home/collector" "$script_dir/omarchy-debug" --print \
    >/dev/null 2>&1; then
  fail "debug accepted an ambiguous BASH_ENV substring"
fi
[[ ! -s $event_log && ! -e $test_home/collector ]] ||
  fail "ambiguous BASH_ENV state reached the debug workflow"
pass "ambiguous BASH_ENV-like names fail closed without rejecting VIRTUAL_ENV"

: >"$event_log"
: >"$token"
chown 1000:1000 "$token"
rm -f "$test_home/collector" "$victim"
if setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" TARGET="$script_dir/omarchy-debug" \
    TEST_SUDO_TOKEN="$token" TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_REAL_SUDO="$stub_bin/sudo" TEST_COLLECTOR_RAN="$test_home/collector" \
    /usr/bin/bash -c '
      set -o privileged
      function /usr/bin/env { return 0; }
      function /usr/bin/readlink { printf "/usr/bin/bash\n"; }
      function /usr/bin/sudo {
        local -a forwarded=()
        local argument
        for argument in "$@"; do
          [[ $argument == -N ]] || forwarded+=("$argument")
        done
        "$TEST_REAL_SUDO" "${forwarded[@]}"
      }
      BASH_ARGV0=$TARGET
      source "$TARGET" --print
    ' "$script_dir/omarchy-debug" >/dev/null 2>&1; then
  fail "debug accepted a forged -c source launch"
fi
[[ -e $token && ! -s $event_log && ! -e $victim && ! -e $test_home/collector ]] ||
  fail "forged same-shell startup reached the privileged debug workflow"
pass "debug rejects pre-executed same-shell code even when it forges script identity"

interactive_continued="$test_home/interactive-continued"
: >"$event_log"
: >"$token"
chown 1000:1000 "$token"
rm -f "$interactive_continued" "$test_home/collector" "$victim"
setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" TARGET="$script_dir/omarchy-debug" \
    TEST_SUDO_TOKEN="$token" TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_REAL_SUDO="$stub_bin/sudo" TEST_COLLECTOR_RAN="$test_home/collector" \
    TEST_INTERACTIVE_CONTINUED="$interactive_continued" \
    /usr/bin/bash --noprofile --norc -i >/dev/null 2>&1 <<'INTERACTIVE'
set -o privileged
function /usr/bin/env { return 0; }
function /usr/bin/sudo { "$TEST_REAL_SUDO" "$@"; }
BASH_ARGV0=$TARGET
source "$TARGET" --print
: >"$TEST_INTERACTIVE_CONTINUED"
exit
INTERACTIVE
[[ -e $interactive_continued && -e $token && ! -s $event_log && ! -e $victim && ! -e $test_home/collector ]] ||
  fail "interactive source continued into the privileged debug workflow"
pass "unsafe interactive source returns to its shell without entering the workflow"

unreadable_environment="$root_dir/unreadable-environ"
unreadable_script="$script_dir/omarchy-debug-unreadable-proc"
: >"$unreadable_environment"
chmod 000 "$unreadable_environment"
sed 's#/proc/\$\$/environ#${TEST_PROC_ENVIRONMENT}#g' \
  "$script_dir/omarchy-debug" >"$unreadable_script"
chmod 0755 "$unreadable_script"
: >"$event_log"
rm -f "$test_home/collector"
if setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" \
    TEST_PROC_ENVIRONMENT="$unreadable_environment" TEST_SUDO_TOKEN="$token" \
    TEST_EVENT_LOG="$event_log" TEST_WAITER_ARMED="$armed" \
    TEST_COLLECTOR_RAN="$test_home/collector" "$unreadable_script" --print \
    >/dev/null 2>&1; then
  fail "debug accepted an unreadable initial environment boundary"
fi
[[ ! -s $event_log && ! -e $test_home/collector ]] ||
  fail "unreadable initial environment reached the debug workflow"
pass "unreadable initial environment state fails closed"

signal_script="$script_dir/signal-cleanup"
cat >"$signal_script" <<'SIGNAL_TEST'
#!/bin/bash -p
source "${BASH_SOURCE[0]%/*}/omarchy-security-functions"
cleanup_signal_test() {
  local status=$?
  omarchy_security_exit_with_revoked_sudo "$status"
}
trap cleanup_signal_test EXIT
omarchy_security_install_signal_exit_traps
: >"$TEST_SIGNAL_READY"
while :; do :; done
SIGNAL_TEST
chmod 0755 "$signal_script"

revoke_armed="$test_home/revoke-armed"
signal_ready="$test_home/signal-ready"
: >"$token"
chown 1000:1000 "$token"
rm -f "$revoke_armed" "$signal_ready"
setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i HOME="$test_home" TEST_SUDO_TOKEN="$token" TEST_EVENT_LOG="$event_log" \
    TEST_WAITER_ARMED="$armed" TEST_DELAY_INVALIDATE_MARKER="$revoke_armed" \
    TEST_SIGNAL_READY="$signal_ready" \
    "$signal_script" &
signal_pid=$!
for attempt in {1..200}; do
  [[ ! -e $signal_ready ]] || break
  sleep 0.005
done
[[ -e $signal_ready ]] || fail "signal cleanup process did not become ready"
kill -TERM "$signal_pid"
for attempt in {1..200}; do
  [[ ! -e $revoke_armed ]] || break
  sleep 0.005
done
[[ -e $revoke_armed ]] || fail "signal cleanup did not begin its blocking invalidation"
kill -TERM "$signal_pid"
set +e
wait "$signal_pid"
signal_status=$?
set -e
[[ $signal_status == 143 && ! -e $token ]] ||
  fail "a second TERM interrupted sudo revocation" "status=$signal_status token=$([[ -e $token ]] && echo present || echo absent)"
pass "cleanup ignores a second TERM until cached sudo authorization is revoked"
