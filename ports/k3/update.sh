#!/bin/bash
# Keep the K3 profile on its ported source baseline while updating Arch packages.
set -euo pipefail
if [[ $(uname -m) != "riscv64" ]] || [[ ! -f /etc/omarchy-k3 ]]; then
  echo "This updater requires the installed Omarchy K3 profile." >&2
  exit 1
fi
if [[ ${1:-} != "-y" ]]; then
  gum confirm "Update the Arch RISC-V packages? Omarchy stays on the ported source baseline." || exit 0
fi
# The patched compositor and its ABI dependencies must be rebuilt together.
# Keep the tested LuaJIT port until a newer runtime passes its regression check.
# Pacman still enforces dependencies and will reject incompatible upgrades.
held_packages=aquamarine,hyprland,xdg-desktop-portal-hyprland,hyprutils,hyprgraphics,hyprcursor,hyprlang,hyprwire,neatvnc,luajit
sudo pacman -Syu --ignore "$held_packages"
echo "Arch RISC-V package update complete. The compositor libraries and LuaJIT remain pinned pending validation."
