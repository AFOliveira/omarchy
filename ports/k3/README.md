# SpacemiT K3 bring-up

Experimental work based on Omarchy **v3.8.4**, commit `8fcc9d6048af4cb0e3af8512c78049857a3b53dd`, on branch `riscv/k3-bringup`. The upstream default branch was `quattro` / `4.0.0.alpha` when inspected on 2026-09-04; stable v3.8.4 was selected for this first port.

Omarchy now boots as the physical K3's Arch RISC-V operating system, using the vendor `6.18.3-generic` kernel, initramfs, DTB, modules, and GPU libraries. Arch runs PID 1 in the initial host namespace; Hyprland uses DRM and the PowerVR GPU directly. A normal physical restart returns to Arch and starts the desktop and remote access automatically. The original Bianbu installation and earlier container remain on disk as recovery and staging environments.

This is a board-specific installation, not a general flashable Arch image. The upstream installer still assumes x86_64, Omarchy's package repositories, Limine, and a Btrfs root. The separately built custom kernel has not successfully booted on the physical board.

## Source checkout

This branch pins its package recipes through the `ports/k3/packages` submodule. Run `git submodule update --init --recursive` before building. The package profile is documented in [packages/ports/k3/README.md](packages/ports/k3/README.md).

## Baselines

| Component | Selected baseline |
| --- | --- |
| Board | Allocated SpacemiT K3 Com260; 32 GB RAM, 128 GB SSD, 16 online CPUs |
| Working host | Arch Linux RISC-V, vendor kernel `6.18.3-generic`; Bianbu 4.0 retained for recovery |
| Kernel | [SpacemiT Linux 6.18](https://github.com/spacemit-com/linux-6.18), pinned in `kernel.env`, `k3_bianbu_defconfig` |
| Kernel configuration changes | Unique `-omarchy-k3` release suffix; DWARF/BTF debugging disabled to reduce build storage |
| Cross compiler | Debian trixie `riscv64-linux-gnu-gcc` 14.2.0 in a Docker container |
| Userspace ISA | `-march=rv64gc -mabi=lp64d`; QEMU's RV64GC `sifive-u54` CPU used for initial checks |
| Arch userspace | [Arch Linux RISC-V](https://archriscv.felixc.at/), rootfs dated 2026-08-27 |

The vendor kernel retains its runtime feature detection and vector context support. The RV64GC restriction applies to the initial userspace test program; this does not claim that every instruction in the vendor kernel is RV64GC.

## Recorded results

- **Physical Arch boot and a subsequent normal reboot passed on 2026-09-05.** Arch systemd `261.2-1-arch` runs as host PID 1, `Virtualization` is empty, and `SoftRebootsCount=0`. SSH, networkd, resolved, the direct Hyprland session, and boot confirmation start automatically. Both system and user managers report no failed units.
- Hyprland opens `/dev/dri/card1` through logind on `seat0`/`tty1` and renders through `/dev/dri/renderD128`; its renderer reports `PowerVR B-Series BXM-4-64`. The disconnected physical DP connector does not prevent the 1920×1080 headless cloud output from working. There is no parent Bianbu Wayland session.
- The physical host passed native RV64GC compilation/execution, Neovim's 52-plugin check, remote keyboard input in Foot, and password lock/unlock. Screenshots and boot evidence are listed in [host-boot.md](host-boot.md).
- Display power-off skips the virtual `K3-CLOUD` output on this port so the remote lock screen remains available. Physical outputs retain their normal power control. Compressed VNC capture and a fresh headless-browser viewer were checked after the change.
- LuaJIT `2.1.1786451769-1.1` replaces the old repository runtime, which raised invalid equality callbacks in LazyVim. The regression passes with JIT enabled and disabled; the graphical editor opens Markdown and moves through the file without errors. Its pinned recipe and regression are under `packages/ports/k3/pkgbuilds/luajit/`.
- The custom `6.18.3-omarchy-k3` Image, 17 device trees, and modules compiled successfully.
- The RV64GC atomic/floating-point test passed under QEMU's `sifive-u54` CPU and natively on the physical K3.
- The custom kernel booted the minimal RV64GC initramfs under QEMU and reached power-down.
- The Arch rootfs ran Bash and pacman under QEMU. A separate generic-virt kernel also booted the complete Arch system to a healthy systemd state under the RV64GC CPU model.
- Native Arch on K3 installed the headless profile and 688 desktop/dependency packages. The ordinary user passed the command metadata check (282 commands), theme listing, and a native GCC-built RV64GC smoke test.
- The earlier Arch container reached a healthy systemd state with no failed units. Its separate SSH listener used keys only at `127.0.0.1:2223`; it is retained in the recovery installation.
- The vendor PowerVR userspace in `/opt/spacemit` initialized GBM, EGL 1.5, and OpenGL ES 3.2 on the BXM-4-64. Initial container testing required DRM access through the container device policy; the physical host uses its own logind seat.
- Hyprland `0.55.4-2.3`, Aquamarine `0.14.0-2.1`, and the Hyprland portal `1.4.1-1.1` compiled natively and run with the Omarchy desktop configuration. The port fixes Wayland configure ordering, animation ownership with Hyprutils 0.14, and the PowerVR driver's unsupported PRIME-to-GEM import check.
- The 1920×1080 `K3-CLOUD` output displays the wallpaper, Waybar, Walker launcher, Foot terminal, LazyVim editor, and Chromium. Browser page rendering and password lock/unlock were checked visually. The editor's 52-plugin validation passes.
- Native WayVNC streams Omarchy through the workstation's SSH-tunneled browser viewer. The host proxy also preserves the provider's original port 5901 and forwards to WayVNC bound only to `127.0.0.1:5900`. The provider portal viewer worked during container staging; it has not been independently revalidated after the physical Arch transition.
- The native NeatVNC `1.0.1-2.1` package disables H.264 after browser viewers retained stale desktop frames. Tight/ZRLE rendering passed browser keyboard and terminal-output checks. The three upstream test groups, including RFB authentication handshakes, pass.
- Earlier container and Bianbu reboot tests brought up the staged desktop automatically. The document portal had access to `/dev/fuse`; both managers reported no failed services. Those earlier results were superseded by the physical Arch boot above.
- Chromium screen sharing successfully opened Omarchy's native preview picker and displayed a live 1920×1080 PipeWire stream in a local test page. No screen data was sent to an external service.
- **The physical K3 did not reconnect after the custom kernel was entered with `kexec`.** Loading the image had succeeded, but loading does not prove a working boot. Serial output was unavailable for this instance, so the failure location is unknown.
- During the failed custom-kernel attempt, BianbuCloud's power and system restart controls returned failures. Its stock-system recovery job succeeded after about eleven minutes; SSH returned with the vendor kernel. The factory recovery erased the first staged userspace. Arch was subsequently rebuilt, tested in a container, and promoted to the physical host.

The stock boot selection was unchanged before the failed `kexec` attempt. Further kernel transitions need a verified recovery path; userspace bring-up is continuing with the working vendor kernel. `build-qemu-kernel.sh` builds a separate generic-virt kernel for local userspace testing and must not be confused with the K3 kernel artifact.

A subsequent [cloud access audit](cloud-access.md) on 2026-09-05 verified boot-partition writes and a custom kernel command-line argument through a physical reboot, with automatic restoration of the original boot file. The portal's system restart worked while Linux was healthy; power restart returned an error, and serial settings were disabled. These results establish control over boot configuration while leaving independent early-boot recovery unresolved.

## Physical host boot

See [host-boot.md](host-boot.md) for the tested installation, boot health check, recovery procedure, and exact evidence. The host root is an independent Arch tree at `/var/lib/omarchy-k3-baremetal/rootfs` on the existing SSD. A temporary startup program restores the Bianbu boot selection, arms a recovery timer, and hands host PID 1 to Arch. After SSH, networking, Hyprland, the portal, and VNC are healthy, Arch selects itself for the next boot and cancels the timer.

SSH now reaches the ordinary Arch user directly:

```bash
ssh -F "$HOME/.local/state/omarchy-riscv/ssh_config" omarchy-k3
ports/k3/start-local-viewer.sh
```

The private SSH configuration's `omarchy-k3` user is `afonso`. Use `-l root` for administration. The old `omarchy-k3-arch` container alias is unnecessary on the physical Arch host. The workstation's direct viewer is [http://127.0.0.1:6083/vnc.html?autoconnect=true&reconnect=true&resize=scale](http://127.0.0.1:6083/vnc.html?autoconnect=true&reconnect=true&resize=scale).

## Initial container staging

The initial staging target was `/var/lib/machines/omarchy-k3`, alongside Bianbu. The following scripts prepare that intermediate environment; they are not the startup path of the current physical Arch host. In the container, Hyprland uses the stock Wayland session for its GPU allocator and creates an independent headless output for cloud rendering.

```bash
# On the board as root, with the verified rootfs archive in the downloads directory:
ports/k3/stage-arch.sh
ports/k3/install-desktop-packages.sh
ports/k3/build-packages.sh
```

The initial audit found 126 base packages in the RISC-V repositories. The desktop manifest adds runtime/build tools and excludes the repository Hyprland and portal binaries because their shared-library dependencies do not match the current repository libraries. Source recipes cover core packages absent from those repositories. Package installation and GUI runtime validation are separate milestones. `configure-user.sh` applies the Omarchy defaults as the ordinary Arch user; its source directory defaults to `/opt/omarchy-source`. The upstream v3.8.4 tag contains `3.8.3` in its version file, which is also what `omarchy-version` reports.

`enable-container.sh --cli-only` starts the persistent Arch system before the desktop packages are all ready. `build-packages.sh` can then run selected recipes inside that running machine, for example `build-packages.sh walker omarchy-walker`. Builds use an ordinary user's credentials without creating an independent PAM session, so stopping the managed build service also stops its compilers. The default desktop startup is enabled by `enable-container.sh` after its required packages are installed.

The K3 update command holds the patched compositor and its ABI dependencies until they can be rebuilt together. Pacman dependency checks remain active. A repository upgrade that requires newer versions of those libraries must be resolved by rebuilding the port, rather than forcing the transaction.

`enable-container.sh` installs the host container service, a PAM-backed UWSM desktop session inside Arch, the native user WayVNC service, and the host cloud proxy. `configure-session.sh` enables Elephant and SwayOSD and applies the user application associations and GTK theme. The cloud display helper tolerates the compositor's IPC socket appearing after the wrapper starts. Its output rules also survive theme/configuration reloads.

When running the retained Bianbu recovery environment, `omarchy-shell` opens the staged container's Arch user shell. Its key-only SSH listener uses host loopback port 2223. On the current physical Arch installation, use the direct SSH command above.

The workstation also has a direct browser viewer through its SSH tunnel. Run `ports/k3/start-local-viewer.sh`, then open the printed localhost URL. Its services listen only on loopback; the board connection travels through SSH. Stop the workstation helpers with `systemctl --user stop omarchy-k3-web-viewer.service omarchy-k3-vnc-tunnel.service` when finished. This does not stop the board's desktop.

The viewer dependencies are already prepared in this workspace. To prepare another workstation with its own authorized K3 SSH configuration:

```bash
git clone https://github.com/novnc/noVNC.git build/noVNC
git -C build/noVNC checkout --detach bef170ebf149cffa0d1c61eb0e4a77a737391f35
python3 -m venv build/vnc-tools
build/vnc-tools/bin/pip install websockify==0.13.0
ports/k3/start-local-viewer.sh
```

The [noVNC project](https://github.com/novnc/noVNC) documents the browser client and its WebSocket proxy. `K3_SSH_CONFIG`, `K3_NOVNC_DIR`, and `K3_WEBSOCKIFY` override the launcher's default paths.

## Current limitations

- The physical board uses `6.18.3-generic`. The custom BSP kernel has **not** booted successfully on the physical board. A QEMU boot is not a substitute for that result.
- Foot is the supported default terminal for this port. Alacritty creates a window with the vendor driver but its glyphs render invisibly, including with the alternate GLES renderer.
- PipeWire and WirePlumber run, but the physical host reports no ALSA sound cards. Audio forwarding through the cloud viewer and camera support have not been implemented.
- Optional applications supplied only as x86_64/proprietary binaries are not made compatible by this port. Source-built replacements cover the desktop core; availability of launcher shortcuts does not establish that every upstream optional app is installed or usable.
- The SSD uses ext4. Omarchy's Btrfs snapshots and Limine installation are not provided by this boot design. Physical suspend, board firmware updates, and arbitrary kernel replacement remain unvalidated. The K3 updater keeps the ported Omarchy source baseline and compositor ABI dependencies pinned.
- The network configuration preserves this allocation's assigned static address and MAC. DHCP and installation on a different board need separate validation. The startup tools deliberately check this board's partition IDs and vendor boot-file digest.
- The user's keyring is encrypted. After automatic login, Chromium can ask for the Arch account password to unlock it. Account credentials and SSH configuration are kept outside this repository.

## Build and inspect

Run from the repository root. Docker access is required; the tools do not install anything into the host operating system.

```bash
# Build an isolated cross toolchain.
docker build -t omarchy-k3-builder:trixie ports/k3

# Compile a static RV64GC program and run it with vector support disabled.
ports/k3/smoke-rv64gc.sh

# Download/check an Arch RISC-V rootfs and run its Bash and pacman under QEMU.
ports/k3/smoke-arch.sh

# Clone the pinned BSP and build its Image, device trees, and modules.
ports/k3/build-kernel.sh

# With the existing workspace's sibling kernel checkout:
K3_KERNEL_DIR=/home/afonso/omarchy-riscv-kernel ports/k3/build-kernel.sh

# Attempt a generic QEMU virt boot with the BSP and a tiny RV64GC PID 1.
ports/k3/boot-smoke.sh

# Audit the base and optional package manifests against RISC-V metadata.
python3 ports/k3/audit-packages.py
```

`K3_JOBS` defaults to 8. `K3_OUTPUT_DIR` changes the kernel build output directory. The kernel builder requires a clean checkout at the recorded commit. It stages files under `build/k3-kernel/stage` and creates `omarchy-k3-kernel.tar.gz`; it does not deploy them or change a bootloader. This is an experimental staging archive, not an Arch package or a flashable disk image. Kernel headers and GPU userspace libraries are not packaged here.

`build/rv64gc/smoke.log` records the ELF architecture attributes and atomic/floating-point test result. The boot check records `build/rv64gc/boot.log`. QEMU `virt` is a generic RISC-V machine; it does not emulate K3 storage, networking, GPU, or board firmware. A passing QEMU check cannot establish board compatibility. If the BSP reaches power-down without a suitable QEMU reset driver, the harness stops the emulator after 30 seconds and requires both success and power-down markers with no kernel panic.

The downloaded Arch rootfs SHA-256 is `a2045c8b62232db2f60d8e4db610dbb5d9e12856dab0ba08634ad3d7cb7ad498`. This is the digest observed after an HTTPS download, not an independently verified publisher signature. Package signature verification remains enabled in the supplied pacman configuration.

## Package audit, 2026-09-04

The initial metadata audit found **126 of 149 base packages available**, **22 missing**, and **one provider requiring review** (`dotnet-runtime-9.0` versus `dotnet-runtime`). Of 60 additional/optional packages, 29 were available and 31 were missing. Many of the optional gaps describe x86 hardware and need exclusion from a board-specific profile.

Hyprland 0.55.4, Alacritty 0.17.0, Waybar 0.15.0, Chromium 148, Neovim 0.12.5, and the Hyprland portal are present in the RISC-V repository. Their availability does not establish compatibility with Omarchy's pinned configuration or with the K3 graphics stack.

The missing base package names are `1password-beta`, `1password-cli`, `aether`, `asdcontrol`, `claude-code`, `cliamp`, `hyprland-preview-share-picker`, `localsend`, `omarchy-nvim`, `omarchy-walker`, `pinta`, `python-terminaltexteffects`, `signal-desktop`, `spotify`, `tobi-try`, `ttf-ia-writer`, `typora`, `tzupdate`, `ufw-docker`, `xdg-terminal-exec`, `yaru-icon-theme`, and `yay`. Missing means absent from the inspected core/extra databases, not impossible to build. Source packages, proprietary binaries, and board-inapplicable packages need separate decisions.

The generated `build/package-audit/packages.md` and `packages.json` contain the complete inventory, repository URLs, retrieval time, and database hashes. Providers are never silently substituted.

## Board iteration order

1. BianbuCloud account creation and K3 allocation are complete. Login credentials are stored outside this Git checkout. The application code must not be committed.
2. Run `bash ports/k3/probe.sh > k3-inventory.txt` on the allocated instance. It reads the model, kernel, CPU ISA, mounts, kernel configuration, graphics devices, and available tools. Treat the inventory as private until reviewed; boot arguments can contain environment-specific information.
3. Establish serial/recovery access, identify the existing boot entries, and retain the vendor kernel, DTB, modules, and boot configuration. Start with the working vendor kernel.
4. Run the static RV64GC smoke binary on the board, then stage an Arch RISC-V rootfs in a separate directory or container. Verify DNS, TLS, package signatures, native compilation, and an ordinary user's shell. The stock Bianbu root filesystem remains available for recovery.
5. Build a headless Omarchy package profile and port the shell/editor configuration. Resolve missing core dependencies before enabling desktop setup. Preserve the board boot chain and avoid x86 hardware packages.
6. Validate DRM render nodes and EGL/GBM with the board's actual GPU driver and userspace. Then test a minimal Hyprland session, followed by Omarchy's desktop configuration, portals, audio, and input.
7. Test the staged kernel as a separate recoverable boot entry only after confirming the board's exact DTB, root device, firmware, and console settings. Image construction and durable installation follow a successful board boot.

SpacemiT references: [cloud user guide](https://forum.spacemit.com/t/topic/121), [custom K3 kernel walkthrough](https://forum.spacemit.com/t/topic/1020), and [K3 Debian image project](https://github.com/jing-liu-spacemit/debian-builder/tree/k3-main).
