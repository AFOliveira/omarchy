# Physical Arch/Omarchy boot on the K3

On 2026-09-05, the allocated K3 booted Arch as the physical host and then passed a second normal reboot with automatic desktop startup. Arch systemd is PID 1 in the initial PID namespace, virtualization detection reports none, and `SoftRebootsCount=0`. The kernel is the unchanged Bianbu `6.18.3-generic`; this result does not establish that the separately compiled kernel boots on this hardware.

## Second allocation: 16 GB K3

On 2026-09-16 the port moved to a new BianbuCloud allocation, `omarchy-k3-16gb` (K3 Com260, 16 GB RAM, 128 GB SSD, stock Bianbu 4.0 and `6.18.3-generic`). Unlike the 32 GB board, it provides the portal's **Serial Debug** console on `ttyS0` and a working **Power Reboot**. Its stock `/boot/env_k3.txt` has the same digest as the first board. Only the partition IDs and network assignment differed:

| Item | 32 GB allocation | 16 GB allocation |
| --- | --- | --- |
| Boot partition (`/dev/sda2`) | `dea91215-8a70-4045-82b5-33296f8be0ac` | `c7bfb4b6-41a3-4508-b77f-1629e37cf53b` |
| Bianbu root (`/dev/sda3`) | `7d6ad53b-30a7-4a45-a65b-b9340c0567e5` | `01e3a021-c161-4b85-b093-85d5e1b8979b` |
| Address | static, assigned by the provider | static, assigned by the provider |

`stage-host.sh` now writes these IDs to `/etc/omarchy-k3-boot-layout` inside the Arch root. `trial-physical.sh` checks the file against the running Bianbu mounts and compiles `host-init` with that boot partition, and `confirm-host-boot.sh` reads it. `host-init.c` no longer builds without an explicit `BOOT_DEVICE`, so an old board's partition cannot be used silently.

The new board did not repeat the container staging and package builds. `stage-host.sh --from-host` copied the booted physical Arch host from the 32 GB board over SSH (13.3 GB, about 52 MB/s between the two boards). It excluded caches, journals, boot records and demo/benchmark scratch data, then regenerated the machine ID, network file, Bianbu SSH host keys, root keys and boot layout. It also refreshed the installed boot-confirmation scripts and units. All 14 staged PowerVR/Mesa libraries and `powervr.ini` were byte-identical to the new board's Bianbu copies (`img-gpu-powervr 24.2-6603887bb22`, Mesa `24.01bb5`).

| Check on the 16 GB board | Result |
| --- | --- |
| Portal Power Reboot on stock Bianbu | `POST /api/device/power-reset` returned `code 20000`; boot ID `cfb49d13…` → `a852b4ea…`. The serial log shows U-Boot SPL (DDR init), U-Boot 2022.10, `Starting kernel ...` and Linux early boot. |
| Recovery timer prerequisite | A 180-second timer survived a Bianbu `soft-reboot` (`SoftRebootsCount=1`) and then physically reset the board: boot `f90a9553…`, `SoftRebootsCount=0`, `expired pid=2467 mode=reboot`. |
| First physical Arch boot | Serial shows the kernel command line with `init=/usr/local/lib/omarchy-k3/host-init omarchy.host_trial=1` and `systemd 261.2-1-arch`. Boot `20a3ef32…`: Arch PID 1, no virtualization, `SoftRebootsCount=0`. The wrapper log records the stock-boot restore and the 600-second timer; the health service confirmed the desktop and cancelled the timer. |
| Normal reboot from Arch | Boot `b357f173…` returned to Arch automatically and was confirmed again. No failed system or user units; no timer left running. |
| Desktop and tools | Hyprland 0.55.4 renders on `PowerVR B-Series BXM-4-64` with the 1920×1080 `K3-CLOUD` output, Waybar and WayVNC. A Foot terminal opened in the session. Native RV64GC compile/run, LuaJIT equality regression (JIT on/off), LazyVim's 52 plugins and Chromium 148 passed. |

### Kernel lab mode

`arch-kernel/select-arch-kernel.sh lab` replaces the boot file with one that
reads a one-shot selector from the FAT partition, so normal boots start stock
Bianbu while a single test kernel can be armed with `once`. `production`
restores this document's normal boot: vendor kernel, startup wrapper, recovery
timer and desktop confirmation. Both the locally built vendor-source kernel and
the Arch Linux RISC-V kernel package were booted this way; see
[arch-kernel/README.md](arch-kernel/README.md).

A workbench serial session can only be **established** while Bianbu's
`cloud_agent` service is running. An already-open session keeps streaming across
the switch to Arch and across resets, so open the serial console before starting
a kernel experiment.

The portal's web **Terminal** logs into Bianbu with the default `bianbu` password. It fails on this board because the default root and `bianbu` passwords were replaced; use SSH. The serial console remains available under Arch and shows the `omarchy-k3-host login:` prompt.

Evidence is under the ignored `build/k3-16gb-port/` directory: `power-reset-test.json`, `serial-power-reset-boot.txt`, `recovery-timer-test.txt`, `serial-first-arch-boot.txt`, `serial-second-arch-boot.txt`, `bianbu-records/` (wrapper log, trial log, copy logs), `functional-smoke.txt`, `first-physical-boot-desktop.png` and `new-board-terminal.png`.

## Boot layout and recovery

The SSD retains the Bianbu filesystem on `/dev/sda3` and the boot partition on `/dev/sda2`. Arch's root is a bind mount of the independently copied `/var/lib/omarchy-k3-baremetal/rootfs` tree. Arch controls the host's services, networking, devices, and display session. No container manager starts it.

The vendor kernel, DTB, and initramfs are unchanged. The `commonargs` line in `/boot/env_k3.txt` selects `/usr/local/lib/omarchy-k3/host-init` as init. That static RV64GC program:

1. Restores and synchronizes the original Bianbu boot file before attempting the Arch transition.
2. Checks and consumes a one-shot marker in the Bianbu filesystem.
3. Starts the static recovery timer with a 600-second deadline.
4. Uses the installed util-linux `switch_root` to move `/dev`, `/proc`, `/sys`, and `/run` and execute Arch's systemd as PID 1. The existing SSD files are retained.

`omarchy-k3-confirm-host-boot.service` checks the host identity, SSH and network services, default route, user desktop services, the 1920×1080 `K3-CLOUD` output, VNC's protocol header, and the kernel/initramfs hashes. Only after those checks pass does it arm the next Arch boot, synchronize the boot selection, and cancel the recovery timer. It records the confirmed physical boot ID under `/var/lib/omarchy-k3-boot-trials/`.

If startup reaches the timer but the desktop never becomes healthy, the timer resets the board and the restored boot selection returns it to Bianbu. If startup prerequisites are missing, the wrapper executes Bianbu's normal init instead. A Bianbu service also restores the boot file if the vendor initramfs falls back to its normal init.

This mechanism covers userspace startup failures after the wrapper starts. It does **not** provide power control or recovery from a kernel, firmware, or storage hang before then. On the original 32 GB allocation the provider's power reset failed and remote UART was unavailable. On the 16 GB allocation both work: its serial console shows U-Boot and early kernel output, and the portal's power reset restarts the board independently of Linux. That makes kernel experiments observable and recoverable there, but they have not been attempted yet.

The root switch uses [util-linux switch_root](https://github.com/util-linux/util-linux/blob/master/sys-utils/switch_root.c). Earlier staging also tested [systemd soft reboot](https://github.com/systemd/systemd/blob/main/man/systemd-soft-reboot.service.xml), which changes userspace without restarting the kernel. The final physical boot evidence below is independent of that earlier soft-reboot test.

## Installed desktop and access

`omarchy-k3-host-desktop.service` starts the `afonso` user's UWSM session on `seat0`, VT 1. `omarchy-k3-host-session` selects `/dev/dri/card1` and clears inherited parent-display variables. Aquamarine opens the separate PowerVR render node `/dev/dri/renderD128`; Hyprland reports `PowerVR B-Series BXM-4-64`. The physical DP connector is disconnected, so the cloud desktop uses the GPU-backed headless `K3-CLOUD` output.

WayVNC runs as the ordinary user on loopback port 5900. The workstation's pinned SSH tunnel and local noVNC viewer connect to that port. `omarchy-k3-cloud-vnc.service` also preserves the provider's previous display proxy on port 5901. The provider's Bianbu-specific administration agents are not running under Arch; use direct SSH for administration.

The port's display-power helper leaves the virtual `K3-CLOUD` output active while locking the desktop. It still powers off physical outputs. Compressed ZRLE captures and the noVNC browser viewer passed; uncompressed full-frame captures timed out during later remote tests and should not be used as the sole display-health check.

```bash
ssh -F "$HOME/.local/state/omarchy-riscv/ssh_config" omarchy-k3
ssh -F "$HOME/.local/state/omarchy-riscv/ssh_config" -l root omarchy-k3
ports/k3/start-local-viewer.sh
```

The private SSH alias uses `afonso` directly. The original Bianbu configuration was saved alongside it as `ssh_config.before-physical-arch`. Account credentials remain outside the repository.

## Reproducing this staged installation

These tools assume the stock Bianbu 4.0 layout (`/boot` on its own partition, Bianbu root on another), the `afonso` UID 1000 user, and the exact vendor boot files; partition IDs and the network assignment are read from the running board. They do not partition or flash a new board.

- `stage-host.sh` copies the working Arch container into a separate host root, copies matching modules/firmware and SSH keys, and enables the host network and SSH services. It initially disables the desktop. It records the board's partitions in `/etc/omarchy-k3-boot-layout`.
- `stage-host.sh --from-host DEST` instead copies a booted physical Arch K3 host over SSH (`K3_SSH_CONFIG` and `K3_RSYNC_EXCLUDE_FROM` are optional). It keeps the enabled desktop, regenerates board identity, and refreshes the installed boot-confirmation files. This is how the 16 GB board was staged.
- Before attempting a root transition, the recovery timer was compiled and installed on Bianbu with `systemd/omarchy-k3-boot-guard.service`. A Bianbu-to-Bianbu `systemctl soft-reboot` proved that the timer survived the userspace restart and physically reset the board back into the stock system. Its persistent log is a prerequisite of the trial scripts.
- `trial-host.sh` performs the optional Arch userspace-switch trial with a five-minute return to Bianbu. It does not change the next physical boot selection.
- `tests/host-init-qemu.sh` tests the physical startup wrapper and actual vendor `switch_root` binary on isolated ext4 images. It verifies a successful root transition followed by timed reset, and a missing-root fallback. Both must restore the exact original boot-file hash. Copy the board's `switch_root`, `libc.so.6`, and `ld-linux-riscv64-lp64d.so.1` into `build/host-init-test/` before running it. Bianbu's runtime needs vector, Zcb, Zicond, and Zfa support in the emulated CPU; the wrapper and timer themselves are built for RV64GC.
- `trial-physical.sh`, run on Bianbu, compiles and installs the startup wrapper for the recorded boot partition, prepares the fallback, and reboots once into the staged Arch root with a ten-minute recovery timer. It keeps the vendor kernel/initramfs/DTB selections. With a desktop-enabled root, as after `--from-host`, a healthy first boot is confirmed directly and `enable-host-desktop.sh` is unnecessary.
- Copy this port directory to the physical Arch host and run `enable-host-desktop.sh` as root. It installs the direct display session, cloud proxy, and boot confirmation service. A successful confirmation makes future healthy boots continue using Arch.

Keep a root SSH session available during the first ten-minute physical trial. If more time is needed after confirming SSH and the restored boot file, the known timer PID in `/run/omarchy-k3-boot-guard.pid` can be cancelled with SIGTERM. This was done during the first interactive display test; subsequent boots cancel it automatically through the health service.

## Selecting Bianbu for the next restart

From root SSH on the healthy Arch host:

```bash
set -euo pipefail
boot_partuuid=$(sed -n 's/^BOOT_PARTUUID=//p' /etc/omarchy-k3-boot-layout)
bianbu_partuuid=$(sed -n 's/^BIANBU_PARTUUID=//p' /etc/omarchy-k3-boot-layout)
[[ -n $boot_partuuid && -n $bianbu_partuuid ]]
systemctl disable --now omarchy-k3-confirm-host-boot.service
mkdir -p /mnt/bianbu
mount "/dev/disk/by-partuuid/$bianbu_partuuid" /mnt/bianbu
mount "/dev/disk/by-partuuid/$boot_partuuid" /boot
saved_hash=$(sha256sum /mnt/bianbu/var/lib/omarchy-k3-boot-trials/env-before-physical-trial)
[[ ${saved_hash%% *} == "9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a" ]]
cp /mnt/bianbu/var/lib/omarchy-k3-boot-trials/env-before-physical-trial /boot/.omarchy-recovery
sync /boot/.omarchy-recovery
mv /boot/.omarchy-recovery /boot/env_k3.txt
rm -f /mnt/bianbu/var/lib/omarchy-k3-baremetal/armed
sync
umount /boot /mnt/bianbu
systemctl reboot
```

The stock digest is `9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a` on both allocations. The 32 GB host predates the layout file; use its IDs from the table above there. After returning to Bianbu, connect with the saved SSH configuration or `-l bianbu`. Arch's filesystem remains on disk. On the 16 GB board, the portal's Power Reboot plus the serial console can also recover a host that no longer answers SSH.

## Evidence

| Observation | Result |
| --- | --- |
| Original Bianbu recovery-timer test | Physical reset returned Bianbu with boot ID `853e1d6d-daf4-4760-8532-2e48d50ea2b7`. |
| Arch userspace-switch trial | Arch PID 1, no virtualization, `SoftRebootsCount=1`; automatic reset returned Bianbu as `5def81a8-b8fc-4fd5-9329-c4217466c1ca`. |
| First physical Arch boot | Boot ID `1fe4e393-ac09-477e-8dcb-7d77271444b4`, Arch PID 1, `SoftRebootsCount=0`. |
| Subsequent normal physical reboot | Boot ID `6b3ea786-67a5-4e18-8c49-1a19f77b707a`; host desktop, VNC proxy, and boot confirmation started automatically. |
| Host services | No failed system or user units; direct SSH, networkd, and resolved active. |
| Native build/editor | Static RV64GC arithmetic/atomics smoke passed; Neovim reported `LAZY_PLUGIN_CACHE_OK 52`. |
| Editor runtime | LuaJIT `2.1.1786451769-1.1` passes mixed-type equality regression with JIT on/off; graphical Markdown editing reports no errors after cursor movement. The old repository runtime failed this check. |
| Display and input | Native screenshot inspected; browser keyboard opened Foot and ran shell commands; password lock/unlock passed. |

The ignored `build/` directory contains `k3-arch-host-trial.json`, `k3-physical-arch-trial.json`, `k3-physical-arch-cli-verified.txt`, `k3-physical-arch-reboot.json`, `k3-physical-arch-reboot-services.txt`, `k3-physical-arch-app-checks.txt`, `k3-host-gpu-evidence.txt`, `k3-host-editor-validation.json`, `k3-host-luajit-tests.txt`, `k3-host-native-luajit-build.log`, `k3-host-final-health.txt`, `k3-host-final-boot-confirmation.txt`, and `host-init-test/`. Screenshots include `k3-physical-arch-desktop.png`, `k3-physical-arch-input.png`, `k3-physical-arch-unlocked.png`, `k3-host-chromium-loaded.png`, and `k3-host-native-editor.png`.

This installation has the core Omarchy desktop and CLI. Optional proprietary/x86 applications, audio forwarding, physical audio/camera, Btrfs snapshots, Limine installation, and the separately rebuilt kernel remain outside the demonstrated result.
