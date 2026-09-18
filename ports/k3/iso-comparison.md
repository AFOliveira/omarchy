# Official Omarchy ISO versus the running K3

Audit date: **2026-09-06**. The K3 is a working bare-metal port of the **v3.8.4 desktop baseline**, with board-specific boot and graphics integration. It does **not** match the current **v4.0.2 / Quattro** installation.

This audit compared upstream source manifests and installer code with a fresh `pacman -Q` inventory, the running kernel, root mount, desktop processes, and Omarchy checkout on the board. It did not download, extract, or install the released ISO, so it is not a byte-for-byte inventory of that image's offline mirror.

## Versions and evidence

| Component | Audited revision |
| --- | --- |
| Current official release | [v4.0.2](https://github.com/omacom/omarchy/releases/tag/v4.0.2), released 2026-08-31; source `346e69e1cec6c4e8924531874af6ba010a1bc99e` |
| Official ISO source inspected | [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso/tree/2673c613d9a71e23920e43fbb951238145e0f1e8), current source at `2673c613d9a71e23920e43fbb951238145e0f1e8`; not asserted to be the exact release build revision |
| Omarchy checkout actually running on K3 | `8fcc9d6048af4cb0e3af8512c78049857a3b53dd`, upstream v3.8.4, plus local port files and changes |
| K3 Arch userspace | Arch Linux RISC-V, rolling release; initially extracted from the 2026-08-27 rootfs, subsequently updated and supplemented with locally built packages |
| K3 running kernel | `6.18.3-generic riscv64`, supplied by SpacemiT |
| K3 compositor | Hyprland `0.55.4-2.3`, built with the port's patches |

The upstream v3.8.4 tag contains `3.8.3` in its version file. The commit identifies our baseline more reliably than that displayed string. The published Omarchy fork has its own integration commit; the live user's checkout remains the upstream baseline with applied local changes.

The earlier README statement describing Quattro as only an alpha when this port began was incorrect: v4.0.2 had already been released. Selecting v3.8.4 reduced the initial desktop integration scope, but it did not select the then-current official release.

## What the official ISO supplies

The [ISO project](https://github.com/omacom/omarchy-iso/tree/2673c613d9a71e23920e43fbb951238145e0f1e8) supplies a bootable x86_64 live environment, the configurator/installer, and an offline package mirror. It installs Arch, the Omarchy runtime/settings/Neovim packages, and configures the system and user. The source recipe also includes hardware-dependent packages in the mirror; their presence on installation media does not mean every installed machine uses them.

The inspected recipe boots its live environment with `linux-t2`, while its target Arch package list includes `linux`, firmware, Limine, Snapper, and the normal base tools. Target setup is hardware-dependent. That live/target distinction matters when comparing kernels: the live ISO kernel is not necessarily the kernel selected for an installed PC.

Quattro's main desktop change is a single Quickshell-based `omarchy-shell` with built-in plugins for the bar, menus, notifications, clipboard, emoji picker, control panels, lock screen and other services. It also introduces visual theme/background selectors and a plugin manager. The older separate Waybar/Walker desktop is no longer the current architecture. See the [Quattro release notes](https://github.com/omacom/omarchy/releases/tag/v4.0.0) and [v4.0.2 plugin source](https://github.com/omacom/omarchy/tree/346e69e1cec6c4e8924531874af6ba010a1bc99e/shell/plugins).

## Practical differences

| Area | Official current installation | This K3 installation |
| --- | --- | --- |
| Architecture and delivery | x86_64 ISO and offline installer | riscv64 rootfs plus board-specific staging/boot scripts; no general K3 installation image |
| Boot | PC boot/install stack, Arch kernel packages and hardware selection | SpacemiT firmware, kernel, DTB, modules and initramfs; a startup wrapper hands PID 1 to Arch |
| Root and recovery | Btrfs/Snapper/Limine integration; encryption supported by the installer | ext4 root at `/var/lib/omarchy-k3-baremetal/rootfs`; Bianbu retained for recovery; no Omarchy snapshot/boot-menu or encryption setup |
| Desktop shell | Quickshell with the Quattro shell/plugin framework | v3.8.4 configs, Waybar, Walker/Elephant, Mako, Hyprlock, Hypridle and other separate services |
| Graphics | Upstream desktop stack with PC-specific driver setup | Ported Hyprland/Aquamarine/portal plus SpacemiT PowerVR userspace; GPU compositor with a virtual 1080p cloud output |
| Apps and tools | Current default manifest includes Omawrite, Omacut, Omacalc, Moonlight, Tensaku, and new utilities | Foot, Neovim/LazyVim, btop, Lazygit, Chromium, Nautilus, mpv and many other packages; several current defaults are absent |
| Networking and access | Current source uses NetworkManager and normal installer configuration | Static cloud network via systemd-networkd; SSH and a loopback WayVNC service, reached through a tunnel |
| Updates | Packaged Omarchy runtime/settings and release migrations | Git-based v3.8.4 runtime; K3 update wrapper holds the source baseline and compositor ABI dependencies for coordinated rebuilds |
| Release fixes | v4.0.2 includes additional security fixes | Those upstream fixes cannot be assumed to have been backported; this audit did not establish security parity |

The physical boot evidence is in [host-boot.md](host-boot.md). The board's live root is `/dev/sda3[/var/lib/omarchy-k3-baremetal/rootfs]`, mounted as ext4. This is Arch running as the host OS, not an Arch container inside a running Bianbu system.

## Package comparison

The live board has **963 installed packages including dependencies**. Counting exact package names against the two release manifests gives:

| Upstream base manifest | Declared packages | Exact installed names | Names absent |
| --- | ---: | ---: | ---: |
| v3.8.4, our selected baseline | 149 | 137 | 12 |
| v4.0.2, current release | 147 | 116 | 31 |

These are package-presence counts, not a percentage of working Omarchy features. They exclude the additional/optional hardware manifest and do not prove runtime compatibility. Four v4 name differences have older functional counterparts installed: `nvim` → `neovim`, `mise-bin` → `mise`, `ttfx` → `python-terminaltexteffects`, and `ttf-jetbrains-mono-nerd-basic` → `ttf-jetbrains-mono-nerd`. This is not a claim of exact version or pacman dependency equivalence.

The twelve absent v3.8.4 base names are:

```text
1password-beta  1password-cli  aether  asdcontrol  claude-code
dotnet-runtime-9.0  localsend  pinta  signal-desktop  spotify
typora  ufw-docker
```

The absent v4.0.2 base names are:

```text
aether  asdcontrol  bluez-tools  bluez-utils  cups-pk-helper
ddcutil  dotnet-runtime  dua-cli  herdr  inotify-tools
networkmanager  localsend  mise-bin  moonlight-qt  mpv-mpris
nvim  omacalc  omacut  omawrite  pacman-contrib  pinta  ttfx
qemu-user-static-binfmt  qrencode  qt6-imageformats  quickshell
tensaku  ttf-jetbrains-mono-nerd-basic  udiskie  ufw-docker  zbar
```

Some older missing applications are proprietary binaries, some can potentially be built from source, and some are hardware-specific. They should not all be described as impossible on RISC-V. Signal, Spotify and 1Password also stopped being mandatory defaults in Quattro.

Installed does not mean usable with the current graphics driver. Alacritty has rendered invisible glyphs, and the latest `imv` check failed creating an EGL context. The demonstrations use Foot, software rendering for Chromium/Nautilus where needed, and mpv's `wlshm` output. Audio, a connected physical monitor, arbitrary kernel replacement and every optional application have not been validated.

Local raw evidence: `build/k3-installed-20260906.txt`, `build/k3-iso-audit/package-comparison-3.8.4.tsv`, and `build/k3-iso-audit/package-comparison-4.0.2.tsv`. The pinned source checkouts used for this audit are under `build/k3-iso-audit/`.

## Work needed for current-release parity

1. Rebase the integration onto v4.0.2 and review the intervening migrations and security fixes.
2. Build/test Quickshell and its Qt dependencies on the K3 PowerVR stack, then port the shell/plugins and the compatible Hyprland configuration together.
3. Package the runtime, settings and native app dependencies for riscv64; resolve the manifest gaps explicitly.
4. Provide a reproducible K3 installation image and validate its boot, updates and recovery path. Decide which PC-specific storage/boot features should be adapted for the board.
5. Run the upstream desktop acceptance checks adapted for RISC-V, including actual app rendering, shell interactions and reboot persistence.

The accurate current description is **“Omarchy v3.8.4 desktop port running directly on K3, using Arch RISC-V and the SpacemiT BSP.”** Calling it a complete port of the current official ISO would overstate what has been implemented and tested.
