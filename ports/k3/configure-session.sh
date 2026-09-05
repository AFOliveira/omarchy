#!/bin/bash
# Finish user setup with a running desktop session and D-Bus.
set -euo pipefail

if (( EUID == 0 )) || [[ ! -f /etc/omarchy-k3 ]]; then
  echo "Run as the ordinary user in the Omarchy K3 desktop session." >&2
  exit 1
fi

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export PATH="$OMARCHY_PATH/bin:$PATH"
state_dir="$HOME/.local/state/omarchy"
mkdir -p "$state_dir" "$HOME/.config/systemd/user/app-walker@autostart.service.d"
cp "$OMARCHY_PATH/default/walker/restart.conf" "$HOME/.config/systemd/user/app-walker@autostart.service.d/restart.conf"
elephant service enable
systemctl --user daemon-reload
systemctl --user enable --now elephant.service swayosd-server.service

if [[ ! -f $state_dir/k3-session-configured ]]; then
  bash "$OMARCHY_PATH/install/config/mimetypes.sh"
  omarchy-theme-set-gnome
  gsettings set org.gnome.desktop.interface gtk-enable-primary-paste true
  touch "$state_dir/k3-session-configured"
fi
