#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/sudo"
cat >"$stub" <<'SH'
#!/bin/bash
printf 'authorization\n' >>"$AUTH_LOG"
exit "${AUTH_STATUS:-0}"
SH
chmod +x "$stub"

check_phase() {
  local id=$1 source="$ROOT/migrations/$1.sh" mapped="$tmp/$1.sh" marker="$tmp/$1.marker" authfile="$tmp/$1.auth"
  cp "$source" "$mapped"
  sed -i \
    -e "s|/usr/bin/sudo|$stub|g" \
    -e "s|/var/lib/omarchy/migrations/$id|$marker|g" \
    -e "s|/etc/fido2/fido2|$authfile|g" \
    -e "s|/etc/limine-entry-tool.d/t2-mac.conf|$tmp/t2.conf|g" \
    -e "s|/etc/t2fand.conf|$tmp/fan.conf|g" \
    -e "s|/proc/cmdline|$tmp/cmdline|g" \
    -e "s|/usr/bin/lspci|$tmp/lspci|g" \
    -e "s|/usr/bin/pacman|$tmp/pacman|g" \
    "$mapped"

  : >"$tmp/auth.log"
  case $id in
  1785944594)
    printf '#!/bin/bash\necho "Apple [106b:1801]"\n' >"$tmp/lspci"
    printf '#!/bin/bash\nexit 1\n' >"$tmp/pacman"
    chmod +x "$tmp/lspci" "$tmp/pacman"
    printf 'pcie_ports=compat\n' >"$tmp/t2.conf"
    printf '[Fan1]\n' >"$tmp/fan.conf"
    : >"$tmp/cmdline"
    ;;
  1787494718) printf credential >"$authfile" ;;
  esac

  AUTH_LOG="$tmp/auth.log" AUTH_STATUS=0 bash -euo pipefail "$mapped"
  [[ $(wc -l <"$tmp/auth.log") == 1 ]] || fail "$id does not use exactly one authorization"
  pass "$id dispatches one fixed machine authorization when applicable"

  : >"$tmp/auth.log"
  touch "$marker"
  if [[ $id == 1787494718 ]]; then chmod 644 "$authfile"; fi
  AUTH_LOG="$tmp/auth.log" AUTH_STATUS=0 bash -euo pipefail "$mapped" || true
  if [[ $id != 1787494718 ]]; then
    [[ ! -s $tmp/auth.log ]] || fail "$id authorizes after its machine marker exists"
    pass "$id performs zero authorizations when complete"
  fi

  rm -f "$marker"
  : >"$tmp/auth.log"
  if AUTH_LOG="$tmp/auth.log" AUTH_STATUS=143 bash -euo pipefail "$mapped"; then
    fail "$id ignores failed or cancelled machine authorization"
  fi
  [[ $(wc -l <"$tmp/auth.log") == 1 && ! -e $marker ]] || fail "$id publishes completion after failed authorization"
  pass "$id leaves machine completion unpublished after cancellation"

  grep -Fq '/usr/bin/env -i PATH=/usr/bin:/bin' "$source" || fail "$id machine phase inherits caller environment"
  grep -Fq "/usr/share/omarchy/migrations/$id.sh --machine" "$source" || fail "$id machine phase is not a fixed packaged target"
  ! grep -Eq 'OMARCHY_[A-Z_]+:-?/' "$source" || fail "$id gives caller environment path authority"
  pass "$id fixes its privileged paths and clears the machine environment"
}

for id in 1785944594 1786380259 1787494718 1787815267; do check_phase "$id"; done
