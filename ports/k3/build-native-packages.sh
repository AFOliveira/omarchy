#!/bin/bash
# Build selected recipes inside the staged native Arch system.
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
recipe_dir="$port_dir/packages/ports/k3/pkgbuilds"

if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f /.omarchy-k3-rootfs ]]; then
  echo "Run as root inside the staged Arch RISC-V userspace." >&2
  exit 1
fi
if [[ ! -d $recipe_dir ]]; then
  echo "Initialize the pinned package sources: git submodule update --init --recursive" >&2
  exit 1
fi

recipes=(aquamarine hyprland xdg-desktop-portal-hyprland yay luajit omarchy-nvim ttf-ia-writer xdg-terminal-exec python-terminaltexteffects tobi-try elephant
  elephant-bluetooth elephant-calc elephant-clipboard elephant-desktopapplications
  elephant-files elephant-menus elephant-providerlist elephant-runner
  elephant-symbols elephant-todo elephant-unicode elephant-websearch walker omarchy-walker
  yaru-icon-theme cliamp tzupdate hyprland-preview-share-picker neatvnc)
if (( $# > 0 )); then
  recipes=("$@")
fi
for recipe in "${recipes[@]}"; do
  if [[ ! $recipe =~ ^[a-z][a-z0-9-]*$ ]] || [[ ! -f $recipe_dir/$recipe/PKGBUILD ]]; then
    printf 'Unknown source recipe: %s\n' "$recipe" >&2
    exit 1
  fi
done

build_dir=/home/afonso/.cache/omarchy-k3/packages
install -d -o afonso -g afonso /home/afonso/.cache /home/afonso/.cache/omarchy-k3 \
  "$build_dir" "$build_dir/sources" "$build_dir/artifacts"
# Builds share their configuration, source cache, and package database.
exec {build_lock}> "$build_dir/.build.lock"
if ! flock --nonblock "$build_lock"; then
  echo "Another native package builder is using this directory." >&2
  exit 1
fi
cp /etc/makepkg.conf "$build_dir/makepkg.conf"
cat >> "$build_dir/makepkg.conf" <<CONFIG
MAKEFLAGS="-j8"
OPTIONS+=(!debug !lto)
SRCDEST="$build_dir/sources"
PKGDEST="$build_dir/artifacts"
CONFIG

for recipe in "${recipes[@]}"; do
  install -d -o afonso -g afonso "$build_dir/$recipe"
  cp -a "$recipe_dir/$recipe/." "$build_dir/$recipe/"
  chown -R afonso:afonso "$build_dir/$recipe"
  (
    cd "$build_dir/$recipe"
    fingerprint=$(find "$recipe_dir/$recipe" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
    # Process substitution would hide a failed makepkg invocation.
    package_list=$(setpriv --reuid=afonso --regid=afonso --init-groups --reset-env -- makepkg --config "$build_dir/makepkg.conf" --packagelist)
    [[ -n $package_list ]]
    mapfile -t archives <<< "$package_list"
    cached=true
    [[ -f .last-build && $(cat .last-build) == "$fingerprint" ]] || cached=false
    for archive in "${archives[@]}"; do
      [[ -s $archive ]] || cached=false
    done
    if [[ $cached != "true" ]]; then
      setpriv --reuid=afonso --regid=afonso --init-groups --reset-env -- env GOMAXPROCS=8 CARGO_BUILD_JOBS=8 \
        makepkg --config "$build_dir/makepkg.conf" --noconfirm --force
      package_list=$(setpriv --reuid=afonso --regid=afonso --init-groups --reset-env -- makepkg --config "$build_dir/makepkg.conf" --packagelist)
      [[ -n $package_list ]]
      mapfile -t archives <<< "$package_list"
    fi
    for archive in "${archives[@]}"; do
      [[ -s $archive ]]
    done
    printf '%s\n' "$fingerprint" > .last-build
    pacman -U --needed --noconfirm "${archives[@]}"
  )
done
printf 'Requested native package builds completed.\n'
