# Physical Arch/Omarchy boot on the K3

On 2026-09-05, the allocated K3 booted Arch as the physical host and then passed a second normal reboot with automatic desktop startup. Arch systemd is PID 1 in the initial PID namespace, virtualization detection reports none, and `SoftRebootsCount=0`. The kernel is the unchanged Bianbu `6.18.3-generic`; this result does not establish that the separately compiled kernel boots on this hardware.

## Boot layout and recovery

The SSD retains the Bianbu filesystem on `/dev/sda3` and the boot partition on `/dev/sda2`. Arch's root is a bind mount of the independently copied `/var/lib/omarchy-k3-baremetal/rootfs` tree. Arch controls the host's services, networking, devices, and display session. No container manager starts it.

The vendor kernel, DTB, and initramfs are unchanged. The `commonargs` line in `/boot/env_k3.txt` selects `/usr/local/lib/omarchy-k3/host-init` as init. That static RV64GC program:

1. Restores and synchronizes the original Bianbu boot file before attempting the Arch transition.
2. Checks and consumes a one-shot marker in the Bianbu filesystem.
3. Starts the static recovery timer with a 600-second deadline.
4. Uses the installed util-linux `switch_root` to move `/dev`, `/proc`, `/sys`, and `/run` and execute Arch's systemd as PID 1. The existing SSD files are retained.

`omarchy-k3-confirm-host-boot.service` checks the host identity, SSH and network services, default route, user desktop services, the 1920×1080 `K3-CLOUD` output, VNC's protocol header, and the kernel/initramfs hashes. Only after those checks pass does it arm the next Arch boot, synchronize the boot selection, and cancel the recovery timer. It records the confirmed physical boot ID under `/var/lib/omarchy-k3-boot-trials/`.

If startup reaches the timer but the desktop never becomes healthy, the timer resets the board and the restored boot selection returns it to Bianbu. If startup prerequisites are missing, the wrapper executes Bianbu's normal init instead. A Bianbu service also restores the boot file if the vendor initramfs falls back to its normal init.

This mechanism covers userspace startup failures after the wrapper starts. It does **not** provide power control or recovery from a kernel, firmware, or storage hang before then. The provider's power-reset control still failed during the audit, and remote UART remained unavailable. Changing the kernel therefore remains a different and less recoverable experiment.

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

These tools are specific to the allocated board's partition IDs, user UID, network configuration, and exact vendor boot files. They do not partition or flash a new board.

- `stage-host.sh` copies the working Arch container into a separate host root, copies matching modules/firmware and SSH keys, and enables the host network and SSH services. It initially disables the desktop.
- Before attempting a root transition, the recovery timer was compiled and installed on Bianbu with `systemd/omarchy-k3-boot-guard.service`. A Bianbu-to-Bianbu `systemctl soft-reboot` proved that the timer survived the userspace restart and physically reset the board back into the stock system. Its persistent log is a prerequisite of the trial scripts.
- `trial-host.sh` performs the optional Arch userspace-switch trial with a five-minute return to Bianbu. It does not change the next physical boot selection.
- `tests/host-init-qemu.sh` tests the physical startup wrapper and actual vendor `switch_root` binary on isolated ext4 images. It verifies a successful root transition followed by timed reset, and a missing-root fallback. Both must restore the exact original boot-file hash. Copy the board's `switch_root`, `libc.so.6`, and `ld-linux-riscv64-lp64d.so.1` into `build/host-init-test/` before running it. Bianbu's runtime needs vector, Zcb, Zicond, and Zfa support in the emulated CPU; the wrapper and timer themselves are built for RV64GC.
- `trial-physical.sh`, run on Bianbu, compiles and installs the startup wrapper, prepares the fallback, and reboots once into the staged Arch root with a ten-minute recovery timer. It keeps the vendor kernel/initramfs/DTB selections.
- Copy this port directory to the physical Arch host and run `enable-host-desktop.sh` as root. It installs the direct display session, cloud proxy, and boot confirmation service. A successful confirmation makes future healthy boots continue using Arch.

Keep a root SSH session available during the first ten-minute physical trial. If more time is needed after confirming SSH and the restored boot file, the known timer PID in `/run/omarchy-k3-boot-guard.pid` can be cancelled with SIGTERM. This was done during the first interactive display test; subsequent boots cancel it automatically through the health service.

## Selecting Bianbu for the next restart

From root SSH on the healthy Arch host:

```bash
set -euo pipefail
systemctl disable --now omarchy-k3-confirm-host-boot.service
mkdir -p /mnt/bianbu
mount /dev/disk/by-partuuid/7d6ad53b-30a7-4a45-a65b-b9340c0567e5 /mnt/bianbu
mount /dev/disk/by-partuuid/dea91215-8a70-4045-82b5-33296f8be0ac /boot
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

The stock digest is `9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a`. After returning to Bianbu, connect with the saved SSH configuration or `-l bianbu`. Arch's filesystem remains on disk.

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
