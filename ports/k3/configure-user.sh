#!/bin/bash
# Apply the Omarchy user configuration inside an already provisioned Arch rootfs.
set -euo pipefail

if (( EUID == 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f /.omarchy-k3-rootfs ]]; then
  echo "Run as the ordinary user inside the staged Arch RISC-V system." >&2
  exit 1
fi

source_dir=${K3_OMARCHY_SOURCE:-/opt/omarchy-source}
state_dir="$HOME/.local/state/omarchy"
export OMARCHY_PATH="$HOME/.local/share/omarchy"
export PATH="$OMARCHY_PATH/bin:$HOME/.local/bin:$PATH"
if [[ ! -d $source_dir/bin ]] || [[ $(cat "$source_dir/version") != "3.8.3" ]]; then
  echo "Expected the Omarchy v3.8.4 source checkout at $source_dir." >&2
  exit 1
fi
# The upstream v3.8.4 tag still contains "3.8.3" in its version file.

mkdir -p "$state_dir" "$HOME/.local/share"
if [[ ! -d $OMARCHY_PATH ]]; then
  cp -a "$source_dir" "$OMARCHY_PATH"
fi
mkdir -p "$HOME/.config/omarchy/branding"
[[ -e $HOME/.config/omarchy/branding/about.txt ]] || cp "$OMARCHY_PATH/icon.txt" "$HOME/.config/omarchy/branding/about.txt"
[[ -e $HOME/.config/omarchy/branding/screensaver.txt ]] || cp "$OMARCHY_PATH/logo.txt" "$HOME/.config/omarchy/branding/screensaver.txt"
if [[ ! -f $state_dir/k3-configured ]]; then
  backup_dir="$state_dir/k3-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  [[ ! -d $HOME/.config ]] || cp -a "$HOME/.config" "$backup_dir/config"
  [[ ! -f $HOME/.bashrc ]] || cp -a "$HOME/.bashrc" "$backup_dir/bashrc"
  mkdir -p "$HOME/.config"
  cp -a "$OMARCHY_PATH/config/." "$HOME/.config/"
  cp "$OMARCHY_PATH/default/bashrc" "$HOME/.bashrc"
  mkdir -p "$state_dir/toggles/hypr" "$HOME/.config/omarchy/themes"
  cp "$OMARCHY_PATH/default/hypr/toggles/flags.conf" "$state_dir/toggles/hypr/"

  # Generate the shipped theme before starting any graphical services.
  next_theme="$HOME/.config/omarchy/current/next-theme"
  mkdir -p "$next_theme"
  cp -a "$OMARCHY_PATH/themes/tokyo-night/." "$next_theme/"
  omarchy-theme-set-templates
  [[ ! -e $HOME/.config/omarchy/current/theme ]] || mv "$HOME/.config/omarchy/current/theme" "$backup_dir/theme"
  mv "$next_theme" "$HOME/.config/omarchy/current/theme"
  printf 'tokyo-night\n' > "$HOME/.config/omarchy/current/theme.name"
  mapfile -d '' -t backgrounds < <(find "$HOME/.config/omarchy/current/theme/backgrounds" -type f -print0 | sort -z)
  if (( ${#backgrounds[@]} > 0 )); then
    ln -snf "${backgrounds[0]}" "$HOME/.config/omarchy/current/background"
  fi
  mkdir -p "$HOME/.config/btop/themes" "$HOME/.config/mako"
  ln -snf "$HOME/.config/omarchy/current/theme/btop.theme" "$HOME/.config/btop/themes/current.theme"
  ln -snf "$HOME/.config/omarchy/current/theme/mako.ini" "$HOME/.config/mako/config"

  # The cloud desktop is 1080p; the upstream default uses 2x UI scaling.
  cat > "$HOME/.config/hypr/monitors.conf" <<'EOF'
env = GDK_SCALE,1
monitor = ,preferred,auto,1
EOF
  mkdir -p "$HOME/.local/share/fonts"
  cp "$OMARCHY_PATH/config/omarchy.ttf" "$HOME/.local/share/fonts/"
  fc-cache -f
  bash "$OMARCHY_PATH/install/config/user-dirs.sh"
  mkdir -p "$HOME/.config/elephant/menus" "$HOME/.config/autostart"
  for menu in omarchy_themes omarchy_background_selector omarchy_unlocks; do
    ln -snf "$OMARCHY_PATH/default/elephant/$menu.lua" "$HOME/.config/elephant/menus/$menu.lua"
  done
  cp "$OMARCHY_PATH/default/walker/walker.desktop" "$HOME/.config/autostart/"
  touch "$state_dir/k3-configured"
fi

if ! grep -Fq '# Omarchy K3 command path' "$HOME/.bashrc"; then
  cp -a "$HOME/.bashrc" "$state_dir/bashrc-before-k3-path"
  bashrc_tmp=$(mktemp "$HOME/.bashrc.k3.XXXXXX")
  cat > "$bashrc_tmp" <<'EOF'
# Omarchy K3 command path (also used by noninteractive SSH commands).
export OMARCHY_PATH="$HOME/.local/share/omarchy"
export PATH="$OMARCHY_PATH/bin:$HOME/.local/bin:$PATH"
export EDITOR="${EDITOR:-nvim}"

EOF
  cat "$HOME/.bashrc" >> "$bashrc_tmp"
  chmod --reference="$HOME/.bashrc" "$bashrc_tmp"
  mv "$bashrc_tmp" "$HOME/.bashrc"
fi

mkdir -p "$HOME/.config/uwsm/env.d"
cat > "$HOME/.config/uwsm/env.d/k3.sh" <<'EOF'
# Import the vendor graphics environment before UWSM starts applications.
. /opt/spacemit/env
EOF

# Foot renders text correctly with the vendor GPU stack and is a supported
# Omarchy terminal. Preserve subsequent user choices after this initial setup.
if [[ ! -f $state_dir/k3-terminal-configured ]]; then
  [[ ! -f $HOME/.config/xdg-terminals.list ]] || cp -a "$HOME/.config/xdg-terminals.list" "$state_dir/xdg-terminals-before-k3.list"
  mkdir -p "$HOME/.local/share/applications"
  cp "$OMARCHY_PATH/default/foot/foot.desktop" "$HOME/.local/share/applications/"
  printf 'foot.desktop\n' > "$HOME/.config/xdg-terminals.list"
  touch "$state_dir/k3-terminal-configured"
fi

if command -v omarchy-nvim-setup >/dev/null; then
  omarchy-nvim-setup
fi
omarchy-version
omarchy --help
printf '\nOmarchy configuration is staged. Desktop startup and runtime checks are separate steps.\n'
