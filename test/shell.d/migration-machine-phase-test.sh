#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
tmp=$(mktemp -d)
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
body_copy() { sed '/^if (( $# == 0 )); then/,$d' "$ROOT/migrations/$1.sh" >"$2"; }

fido_dir="$tmp/fido2"; fido_file="$fido_dir/fido2"; fido_marker="$tmp/fido.marker"
mkdir "$fido_dir"; printf 'credential\n' >"$fido_file"; chmod 700 "$fido_dir"
fido_body="$tmp/fido-body.sh"; body_copy 1787494718 "$fido_body"
sed -i -e "s|/etc/fido2/fido2|$fido_file|g" -e "s|/var/lib/omarchy/migrations/1787494718|$fido_marker|g" -e 's/-o root -g root //' "$fido_body"
source "$fido_body"; repair_machine
[[ $(stat -c %a "$fido_dir") == 755 ]] || fail "FIDO2 repair leaves a hidden credential directory"
[[ $(stat -c %a "$fido_file") == 644 ]] || fail "FIDO2 repair does not restore the credential mode"
pass "FIDO2 machine body repairs a hidden directory and credential mode"

bt_bin="$tmp/bt-bin"; mkdir "$bt_bin"
cat >"$bt_bin/timeout" <<'SH'
#!/bin/bash
shift
exec "$@"
SH
cat >"$bt_bin/bluetoothctl" <<'SH'
#!/bin/bash
[[ ${BT_QUERY_FAIL:-0} == 0 ]] || exit 124
if [[ $1 == list ]]; then echo 'Controller AA:BB test'; else echo "Powered: ${BT_POWER:-no}"; fi
SH
cat >"$bt_bin/power" <<'SH'
#!/bin/bash
echo "$1" >>"$BT_LOG"
SH
chmod +x "$bt_bin"/*
bt_body="$tmp/bt-body.sh"; bt_marker="$tmp/bt.marker"; bt_conf="$tmp/main.conf"; printf 'AutoEnable=true\n' >"$bt_conf"
body_copy 1786380259 "$bt_body"
sed -i -e "s|/usr/bin/timeout|$bt_bin/timeout|g" -e "s|/usr/bin/bluetoothctl|$bt_bin/bluetoothctl|g" -e "s|/usr/bin/omarchy-bluetooth-power|$bt_bin/power|g" -e "s|/var/lib/omarchy/migrations/1786380259|$bt_marker|g" -e "s|/etc/bluetooth/main.conf|$bt_conf|g" "$bt_body"
source "$bt_body"; BT_LOG="$tmp/bt.log" BT_POWER=yes repair_machine
[[ $(cat "$tmp/bt.log") == on && -e $bt_marker ]] || fail "Bluetooth machine body loses powered-on state"
rm -f "$bt_marker"; : >"$tmp/bt.log"
if BT_LOG="$tmp/bt.log" BT_QUERY_FAIL=1 repair_machine; then fail "Bluetooth discovery failure is treated as powered off"; fi
[[ ! -e $bt_marker && ! -s $tmp/bt.log ]] || fail "Bluetooth query error publishes or changes policy"
pass "Bluetooth machine body distinguishes powered-off state from discovery failure"

t2_bin="$tmp/t2-bin"; mkdir "$t2_bin"
printf '#!/bin/bash\nexit "${T2_QUERY_STATUS:-0}"\n' >"$t2_bin/lspci"
printf '#!/bin/bash\n[[ $1 == -Qq ]] && exit "${PKG_QUERY_STATUS:-0}"\n' >"$t2_bin/pacman"
chmod +x "$t2_bin"/*
t2_body="$tmp/t2-body.sh"; body_copy 1785944594 "$t2_body"
sed -i -e "s|/usr/bin/lspci|$t2_bin/lspci|g" -e "s|/usr/bin/pacman|$t2_bin/pacman|g" -e "s|/var/lib/omarchy/migrations/1785944594|$tmp/t2.marker|g" -e "s|/etc/limine-entry-tool.d/t2-mac.conf|$tmp/t2.conf|g" -e "s|/etc/t2fand.conf|$tmp/fan.conf|g" -e "s|/proc/cmdline|$tmp/cmdline|g" "$t2_body"
source "$t2_body"
if T2_QUERY_STATUS=7 repair_machine; then fail "T2 discovery error is treated as inapplicable"; fi
[[ ! -e $tmp/t2.marker ]] || fail "T2 discovery error publishes completion"
pass "T2 machine body preserves discovery errors for retry"

cups_bin="$tmp/cups-bin"; mkdir "$cups_bin"; printf '#!/bin/bash\nexit 9\n' >"$cups_bin/pacman"; chmod +x "$cups_bin/pacman"
cups_body="$tmp/cups-body.sh"; body_copy 1787815267 "$cups_body"
sed -i -e "s|/usr/bin/pacman|$cups_bin/pacman|g" -e "s|/var/lib/omarchy/migrations/1787815267|$tmp/cups.marker|g" "$cups_body"
source "$cups_body"
if repair_machine; then fail "CUPS package discovery error is treated as absence"; fi
[[ ! -e $tmp/cups.marker ]] || fail "CUPS discovery error publishes completion"
pass "CUPS machine body preserves package discovery errors for retry"

for id in 1785944594 1786380259 1787494718 1787815267; do
  source_file="$ROOT/migrations/$id.sh"
  grep -Fq '/usr/bin/env -i PATH=/usr/bin:/bin' "$source_file" || fail "$id inherits caller environment"
  grep -Fq "/usr/share/omarchy/migrations/$id.sh --machine" "$source_file" || fail "$id lacks a fixed packaged target"
  ! grep -Eq 'OMARCHY_[A-Z_]+:-?/' "$source_file" || fail "$id gives caller path authority"
done
pass "machine phases retain fixed paths and a clean privileged environment"
