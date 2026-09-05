#!/bin/bash
# Open the board through the workstation's pinned SSH connection.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ssh_config=${K3_SSH_CONFIG:-$HOME/.local/state/omarchy-riscv/ssh_config}
viewer_dir=${K3_NOVNC_DIR:-$repo_dir/build/noVNC}
websockify=${K3_WEBSOCKIFY:-$repo_dir/build/vnc-tools/bin/websockify}
if (( EUID == 0 )) || [[ ! -f $ssh_config || ! -f $viewer_dir/vnc.html || ! -x $websockify ]]; then
  echo "Run as the workstation user with its K3 SSH configuration, noVNC, and websockify prepared; see ports/k3/README.md." >&2
  exit 1
fi

if ! systemctl --user is-active --quiet omarchy-k3-vnc-tunnel.service; then
  systemd-run --user --collect --unit=omarchy-k3-vnc-tunnel \
    --property=Restart=on-failure --property=RestartSec=5 \
    /usr/bin/ssh -N -o ExitOnForwardFailure=yes -F "$ssh_config" \
    -L 127.0.0.1:15900:127.0.0.1:5900 omarchy-k3
fi
if ! systemctl --user is-active --quiet omarchy-k3-web-viewer.service; then
  systemd-run --user --collect --unit=omarchy-k3-web-viewer \
    --property=Restart=on-failure --property=RestartSec=5 \
    "$websockify" --web="$viewer_dir" 127.0.0.1:6083 127.0.0.1:15900
fi
echo 'Desktop: http://127.0.0.1:6083/vnc.html?autoconnect=true&reconnect=true&resize=scale&quality=6&compression=6'
