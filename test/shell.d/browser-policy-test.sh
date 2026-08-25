#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

helper="$ROOT/bin/omarchy-browser-policy"
migration="$ROOT/migrations/1787679796.sh"

# Fresh installs and the Quattro transition must never recreate the vulnerable
# mode, and theme changes must go through the one fixed packaged helper.
for file in "$ROOT/bin/omarchy-install-browser" "$ROOT/install/config/theme-system.sh" "$ROOT/bin/omarchy-upgrade-to-quattro"; do
  ! grep -Eq 'chmod[[:space:]]+a\+rw.*(polic|distribution)|-m[[:space:]]+0777.*polic' "$file" ||
    fail "browser policy setup never grants group/other write access: ${file#$ROOT/}"
done
grep -Fq 'install -d -o root -g root -m 0755 "$1"' "$ROOT/bin/omarchy-install-browser" ||
  fail "browser installer creates policy directories root-owned mode 0755"
grep -Fq 'sudo /usr/bin/omarchy-browser-policy firefox "$browser"' "$ROOT/bin/omarchy-install-browser" ||
  fail "Firefox-family installs atomically replace policy through the fixed helper"
grep -Fq '%wheel ALL=(root) NOPASSWD: /usr/bin/omarchy-browser-policy color *' \
  "$ROOT/etc/sudoers.d/omarchy-browser-policy" ||
  fail "passwordless browser policy grant is scoped to the color action"
pass "browser policy directories are root-owned and the passwordless grant is narrow"

# The user-facing theme command accepts only three decimal bytes and hands one
# normalized color to the packaged helper. Invalid theme data falls back to the
# neutral color instead of becoming JSON or an extra privileged argument.
theme_home="$test_tmp/theme-home"
theme_bin="$test_tmp/theme-bin"
sudo_log="$test_tmp/theme-sudo.log"
mkdir -p "$theme_home/.local/state/omarchy/current/theme" "$theme_bin"

cat >"$theme_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_SUDO_LOG"
SH
cat >"$theme_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$theme_bin"/*

printf '29,30,31\n' >"$theme_home/.local/state/omarchy/current/theme/chromium.theme"
HOME="$theme_home" PATH="$theme_bin:$ROOT/bin:$PATH" TEST_SUDO_LOG="$sudo_log" \
  bash "$ROOT/bin/omarchy-theme-set-browser"
[[ $(tail -n1 "$sudo_log") == '/usr/bin/omarchy-browser-policy color #1d1e1f' ]] ||
  fail "theme setter passes one normalized color to the packaged helper" "$(cat "$sudo_log")"

printf '1,2,3\"},\"ExtensionInstallForcelist\":[\"bad\"]\n' >"$theme_home/.local/state/omarchy/current/theme/chromium.theme"
HOME="$theme_home" PATH="$theme_bin:$ROOT/bin:$PATH" TEST_SUDO_LOG="$sudo_log" \
  bash "$ROOT/bin/omarchy-theme-set-browser"
[[ $(tail -n1 "$sudo_log") == '/usr/bin/omarchy-browser-policy color #1c2027' ]] ||
  fail "invalid theme data falls back without reaching the policy schema" "$(cat "$sudo_log")"
pass "theme colors cross the privileged boundary as one validated value"

# The shipped helper uses fixed system paths and must run as real root. Retarget
# a scratch copy and replace only its root identity with this test uid; this
# keeps the production helper free of path/environment test hooks.
fixture_root="$test_tmp/root"
helper_copy="$test_tmp/omarchy-browser-policy"
test_uid=$(id -u)
test_gid=$(id -g)

sed \
  -e 's/if ((EUID != 0)); then/if false; then/' \
  -e 's/$owner == 0/$owner == '"$test_uid"'/g' \
  -e 's/$source_owner == 0/$source_owner == '"$test_uid"'/g' \
  -e 's/chown root:root /chown '"$test_uid:$test_gid"' /g' \
  -e "s|/etc/chromium/policies/managed|$fixture_root/etc/chromium/policies/managed|g" \
  -e "s|/etc/opt/chrome/policies/managed|$fixture_root/etc/opt/chrome/policies/managed|g" \
  -e "s|/etc/opt/edge/policies/managed|$fixture_root/etc/opt/edge/policies/managed|g" \
  -e "s|/etc/brave/policies/managed|$fixture_root/etc/brave/policies/managed|g" \
  -e "s|/usr/lib/firefox/distribution|$fixture_root/usr/lib/firefox/distribution|g" \
  -e "s|/opt/zen-browser/distribution|$fixture_root/opt/zen-browser/distribution|g" \
  -e "s|/usr/share/omarchy/default/firefox/policies.json|$fixture_root/usr/share/omarchy/default/firefox/policies.json|g" \
  "$helper" >"$helper_copy"
chmod +x "$helper_copy"

chromium_dirs=(
  "$fixture_root/etc/chromium/policies/managed"
  "$fixture_root/etc/opt/chrome/policies/managed"
  "$fixture_root/etc/opt/edge/policies/managed"
  "$fixture_root/etc/brave/policies/managed"
)
firefox_dirs=(
  "$fixture_root/usr/lib/firefox/distribution"
  "$fixture_root/opt/zen-browser/distribution"
)
policy_dirs=("${chromium_dirs[@]}" "${firefox_dirs[@]}")

for directory in "${policy_dirs[@]}"; do
  install -d -m 0755 "$(dirname -- "$directory")"
  install -d -m 0777 "$directory"
  printf '{"ExtensionInstallForcelist":["attacker"]}\n' >"$directory/99-injected.json"
  mkdir "$directory/nested-policy"
  printf 'still hostile\n' >"$directory/nested-policy/policy.json"
  chmod 0666 "$directory/99-injected.json"
  chmod 0777 "$directory/nested-policy"
done
install -d -m 0755 "$(dirname -- "$fixture_root/usr/share/omarchy/default/firefox/policies.json")"
cp "$ROOT/default/firefox/policies.json" "$fixture_root/usr/share/omarchy/default/firefox/policies.json"
chmod 0644 "$fixture_root/usr/share/omarchy/default/firefox/policies.json"

printf 'SIMULATED SECRET\n' >"$test_tmp/secret"
for directory in "${chromium_dirs[@]}"; do
  ln -s "$test_tmp/secret" "$directory/color.json"
done
for directory in "${firefox_dirs[@]}"; do
  printf '{"policies":{"ExtensionSettings":{"*":{"installation_mode":"force_installed"}}}}\n' >"$directory/policies.json"
  printf 'package-owned companion file\n' >"$directory/vendor.cfg"
  chmod 0644 "$directory/vendor.cfg"
done

if "$helper_copy" color '#112233' >"$test_tmp/unsafe-color.out" 2>&1; then
  fail "color helper refuses policy directories that are still writable"
fi

repair_output=$("$helper_copy" repair)
[[ $repair_output == *'Quarantined untrusted browser policies'* ]] ||
  fail "repair reports that existing policy contents were untrusted" "$repair_output"

for directory in "${policy_dirs[@]}"; do
  [[ $(stat -c %a "$directory") == 755 ]] || fail "repair makes $directory mode 0755"
  quarantine=$(find "$directory" -mindepth 1 -maxdepth 1 -type d -name '.omarchy-policy-quarantine.*' -print -quit)
  [[ -n $quarantine && $(stat -c %a "$quarantine") == 700 ]] || fail "repair creates a root-only quarantine in $directory"
  [[ -e $quarantine/99-injected.json && -e $quarantine/nested-policy ]] ||
    fail "repair quarantines every unknown entry from $directory"
  [[ ! -e $directory/99-injected.json && ! -e $directory/nested-policy ]] ||
    fail "unknown policy entries remain active in $directory"
done

for directory in "${chromium_dirs[@]}"; do
  jq -e '. == {BrowserThemeColor:"#1c2027", BrowserColorScheme:"device"}' "$directory/color.json" >/dev/null ||
    fail "repair replaces Chromium policy with the fixed neutral schema"
  [[ ! -L $directory/color.json && $(stat -c %a "$directory/color.json") == 644 ]] ||
    fail "repaired Chromium color policy is a regular mode-0644 file"
done
for directory in "${firefox_dirs[@]}"; do
  cmp -s "$ROOT/default/firefox/policies.json" "$directory/policies.json" ||
    fail "repair restores only Omarchy's packaged Firefox policy"
  grep -Fq 'package-owned companion file' "$directory/vendor.cfg" ||
    fail "repair preserves trusted non-policy Firefox distribution files"
  [[ ! -L $directory/policies.json && $(stat -c %a "$directory/policies.json") == 644 ]] ||
    fail "repaired Firefox policy is a regular mode-0644 file"
done
pass "repair disables all content from the formerly writable policy directories"

quarantine_count=$(find "$fixture_root" -type d -name '.omarchy-policy-quarantine.*' | wc -l)
second_output=$("$helper_copy" repair)
[[ -z $second_output ]] || fail "an idempotent repair does not quarantine its own trusted files" "$second_output"
[[ $(find "$fixture_root" -type d -name '.omarchy-policy-quarantine.*' | wc -l) == "$quarantine_count" ]] ||
  fail "an idempotent repair does not create nested quarantines"

"$helper_copy" color '#aBcDeF'
for directory in "${chromium_dirs[@]}"; do
  jq -e '. == {BrowserThemeColor:"#aBcDeF", BrowserColorScheme:"device"}' "$directory/color.json" >/dev/null ||
    fail "color helper writes only its fixed schema"
done
if "$helper_copy" color '#000000"},"ProxyMode":"fixed_servers' >/dev/null 2>&1; then
  fail "color helper rejects JSON/policy injection"
fi
rm -f "${firefox_dirs[0]}/policies.json"
printf 'destination must not overwrite this\n' >"$test_tmp/firefox-symlink-target"
ln -s "$test_tmp/firefox-symlink-target" "${firefox_dirs[0]}/policies.json"
"$helper_copy" firefox firefox
cmp -s "$ROOT/default/firefox/policies.json" "${firefox_dirs[0]}/policies.json" ||
  fail "Firefox install action atomically replaces a stale policy entry"
grep -Fq 'destination must not overwrite this' "$test_tmp/firefox-symlink-target" ||
  fail "Firefox install action followed a stale policies.json symlink"
if "$helper_copy" firefox '../../../tmp' >/dev/null 2>&1; then
  fail "Firefox install action rejects arbitrary browser/path arguments"
fi
pass "root helper is idempotent and accepts only fixed policy actions"

# A symlinked fixed policy path is rejected before any other directory changes.
symlink_dir=${chromium_dirs[0]}
real_dir="$symlink_dir.real"
mv -T "$symlink_dir" "$real_dir"
ln -s "$test_tmp/secret" "$symlink_dir"
before_hash=$(sha256sum "${chromium_dirs[1]}/color.json")
if "$helper_copy" repair >/dev/null 2>&1; then
  fail "repair refuses a symlinked policy path"
fi
[[ $(sha256sum "${chromium_dirs[1]}/color.json") == "$before_hash" ]] ||
  fail "repair preflights every path before modifying any browser"
rm -f "$symlink_dir"
mv -T "$real_dir" "$symlink_dir"
pass "repair rejects unsafe policy paths before making changes"

# Finally, drive the migration through a strict sudo shim. It must call the
# packaged repair action, surface quarantine to the desktop owner, and restore
# the current theme only after the repair succeeds.
migration_copy="$test_tmp/migration.sh"
migration_bin="$test_tmp/migration-bin"
migration_log="$test_tmp/migration.log"
notification_log="$test_tmp/notifications.log"
sed "s|/usr/bin/omarchy-browser-policy|$helper_copy|g" "$migration" >"$migration_copy"
mkdir -p "$migration_bin"

cat >"$migration_bin/sudo" <<'SH'
#!/bin/bash
[[ $# == 2 && $1 == "$TEST_POLICY_HELPER" && $2 == repair ]] || exit 97
printf 'sudo:%s\n' "$*" >>"$TEST_MIGRATION_LOG"
exec "$@"
SH
cat >"$migration_bin/omarchy-theme-set-browser" <<'SH'
#!/bin/bash
printf 'theme\n' >>"$TEST_MIGRATION_LOG"
SH
cat >"$migration_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_NOTIFICATION_LOG"
SH
chmod +x "$migration_bin"/*

printf '{"ExtensionInstallForcelist":["late-attacker"]}\n' >"${chromium_dirs[0]}/late-injected.json"
PATH="$migration_bin:$PATH" TEST_POLICY_HELPER="$helper_copy" TEST_MIGRATION_LOG="$migration_log" \
  TEST_NOTIFICATION_LOG="$notification_log" bash -euo pipefail "$migration_copy" >"$test_tmp/migration.out"

grep -Fq "sudo:$helper_copy repair" "$migration_log" || fail "migration invokes the fixed repair helper"
grep -Fxq 'theme' "$migration_log" || fail "migration restores the current theme after repair"
grep -Fq 'Browser policies quarantined' "$notification_log" || fail "migration alerts the owner about unknown policy files"
[[ ! -e ${chromium_dirs[0]}/late-injected.json ]] || fail "migration leaves a late injected policy active"
pass "migration repairs existing systems and alerts on quarantined policy files"
