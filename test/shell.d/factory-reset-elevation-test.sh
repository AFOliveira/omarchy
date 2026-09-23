#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

if (( EUID == 0 )); then
  skip "factory-reset self-elevation requires an unprivileged caller"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/checkout with spaces"

# Exercise the real startup, but never include the destructive reset body.
awk '
  /^export PATH=/ { found = 1; print "exit 99"; exit }
  { print }
  END { if (!found) exit 1 }
' "$ROOT/bin/omarchy-system-factory-reset" >"$tmp/checkout with spaces/reset"
chmod +x "$tmp/checkout with spaces/reset"
ln -s "$tmp/checkout with spaces/reset" "$tmp/reset-link"

cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >"$CALL_LOG"
exit "${SUDO_STATUS:-0}"
SH
chmod +x "$tmp/bin/sudo"

args=('argument with spaces' '' '--flag' '$(touch should-not-run)' $'two\nlines')
expected=(env 'GUM_INPUT_PROMPT=Reset this computer? ' /usr/bin/omarchy-system-factory-reset "${args[@]}")
for invocation in "$tmp/checkout with spaces/reset" './checkout with spaces/reset' "$tmp/reset-link"; do
  for status in 0 1 127; do
    actual_status=0
    (cd "$tmp" && env -i HOME="$tmp" PATH="$tmp/bin:/usr/bin:/bin" \
      OMARCHY_PATH="$tmp/checkout with spaces" PACKAGED_PATH="$tmp/wrong-target" \
      GUM_INPUT_PROMPT='Reset this computer? ' CALL_LOG="$tmp/call" SUDO_STATUS="$status" \
      "$invocation" "${args[@]}") || actual_status=$?
    (( actual_status == status )) || fail "elevation status is preserved for $invocation"
    mapfile -d '' -t actual <"$tmp/call"
    (( ${#actual[@]} == ${#expected[@]} )) || fail "elevation argument count is preserved"
    for i in "${!expected[@]}"; do
      [[ ${actual[i]} == "${expected[i]}" ]] || fail "elevation argument $i is preserved for $invocation"
    done
    [[ ! -e $tmp/should-not-run ]] || fail "caller arguments were executed"
  done
  pass "factory reset pins $invocation to the packaged command and preserves arguments, styling and status"
done
