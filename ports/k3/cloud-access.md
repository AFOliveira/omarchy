# K3 cloud access and boot-control audit

Tested on the allocated 32 GB K3 Com260 on 2026-09-05. The board now boots the Arch/Omarchy physical host using Bianbu's unchanged `6.18.3-generic` kernel. See [the physical boot record](host-boot.md) for the completed host transition and subsequent normal reboot.

The instance allows root access and changes to its boot configuration. Physical Arch startup has now been demonstrated: Arch runs PID 1 in the initial host namespace, and its direct DRM desktop starts automatically after a normal reboot. The remaining access limitation is observation and recovery of failed early kernel/firmware startup independently of Linux. The container was an intermediate staging choice.

## Tests and observations

| Capability | Result | Scope of evidence |
| --- | --- | --- |
| Root access | Available | Root SSH works on the physical Bianbu host. |
| Boot partition writes | Passed | Created, read, synchronized, and removed a temporary file in `/boot`; the boot configuration digest was unchanged. |
| Boot configuration takes effect | Passed on hardware | Added a unique, otherwise unused `omarchy.boot_audit` argument to `commonargs` in `/boot/env_k3.txt`; after a normal reboot it appeared in `/proc/cmdline`. The kernel, initramfs, and DTB selections were unchanged. |
| Automatic restoration | Passed | A temporary system service restored the original boot file on startup, with the original SHA-256 digest. The service was then disabled and removed. |
| Portal system restart | Passed on hardware | The portal reported success, the physical boot ID changed, and the container, desktop, and VNC services started automatically. This test was made with Linux healthy. |
| Portal power restart | Failed | The ordinary power-restart control returned HTTP 200 with application result `code: 1`, `message: 操作失败!` (operation failed). The boot ID did not change. |
| Remote serial console | Not available in the inspected UI | Serial settings are disabled; no serial-debug selector appeared. The Linux host has `ttyS0` and a serial getty, but those do not provide a remote connection to the other end of the UART. |
| Portal image flashing | Preset selection only in the inspected UI | The panel displayed `spacemit-lab-test-v1`, `Bianbu-lite-v1`, `Bianbu3.0`, and `Bianbu-LXQt-K3`. No custom-image upload control was visible. No image was flashed during this audit. |
| Recovery watchdog | Not verified | No `/dev/watchdog*` device or populated watchdog class was present. A platform watchdog driver was bound; that alone does not demonstrate an available timed recovery mechanism. |
| Custom-kernel execution | Still unverified on this board | The earlier custom `kexec` attempt left the board unreachable. This audit did not repeat it. The running kernel enables `CONFIG_KEXEC` and `CONFIG_KEXEC_FILE`. |
| Arch as physical host | Passed on hardware | New physical boot IDs, Arch systemd as PID 1, no virtualization, and `SoftRebootsCount=0`; a second normal reboot started SSH, networking, the desktop, and VNC automatically. |
| Userspace recovery timer | Passed | A static timer survived a Bianbu soft reboot and forced a physical return to the stock system. It also returned the Arch userspace-switch trial to Bianbu. The physical boot wrapper restores stock boot before arming its timer; the healthy Arch desktop subsequently confirms future Arch boots. This does not recover an early kernel hang. |

The portal dashboard continues to display a stale “system resetting” state while SSH and the desktop work. A new portal tab also failed to render reliably. Neither observation explains the power-control failure, and neither establishes a hardware restriction.

The [SpacemiT K3 cloud kernel guide](https://forum.spacemit.com/t/topic/1020), dated 2026-03-06, describes custom kernel installation and reports serial/U-Boot access on 16 GB instances but not 32 GB instances. That matches the current UI observation. It is not evidence that every 32 GB board is physically incapable of serial access. The [general cloud guide](https://forum.spacemit.com/t/topic/121) also documents serial and preset-image recovery features.

## Remaining requirements and completed host work

1. **Reliable recovery independent of Linux.** Request working power reset plus a bidirectional UART console that covers reset, U-Boot, and early kernel startup. SpacemiT may be able to enable these on this allocation or move the allocation to a serial-equipped K3. Preserve the existing allocation and data until a replacement is confirmed. A provider-assisted reflash route is another recovery option; the prior factory recovery erased staged data.
2. **Physical Arch root and networking: completed for this allocation.** A separate root tree has matching vendor modules/firmware, its own networkd/resolved, and SSH on the physical interface. The unchanged vendor initramfs launches a static startup wrapper which hands PID 1 to Arch. A dedicated Arch initramfs or flashable disk image is not required for this demonstrated path and has not been produced.
3. **Direct display and remote access: completed for the desktop/SSH path.** Hyprland uses Arch's logind seat and the board's DRM/PowerVR devices directly. Native WayVNC provides the remote desktop, and the provider's display port is preserved by a proxy. Bianbu-specific provider agents and ADB are not running under Arch; use direct SSH for administration. UART and independent power reset are still needed to improve custom-kernel recovery.

Serial access is not a logical prerequisite for every successful OS boot, as the physical Arch result now demonstrates. It makes failures diagnosable, and independent power control makes repeated kernel experiments recoverable. The tests do not establish compatibility of the separately rebuilt kernel or a general-purpose custom disk image.

## Local evidence

The workspace's ignored `build/` directory contains:

- `k3-cloud-access-menus.json` and `k3-cloud-flash-panel.txt`: inspected portal controls.
- `k3-cloud-power-result.json`: failed power-restart response.
- `k3-cloud-system-restart-result.json` and `k3-cloud-system-restart-verified.txt`: successful system restart and hardware boot verification.
- `k3-stage-boot-marker.py`, `k3-boot-marker-staging.log`, and `k3-boot-marker-verified.txt`: boot-marker test and restoration result.
- `k3-boot-control-evidence/`: copied original boot file, marker, observed command line, old/new boot IDs, and restoration script.
- `k3-after-boot-access-test.png`: visually inspected Omarchy desktop after the final test boot.

The earlier system-restart test produced boot ID `790c1dee-9609-4dbb-9626-ea99187af457`; the boot-marker test produced `5ae55529-7698-477f-b932-8350083627f3`. Both used `6.18.3-generic`. The original `/boot/env_k3.txt` SHA-256 is `9936c59b50f2e552fca32879e12208eb87532fda40cf053aa78e3c3f67b0b90a`. The old audit marker is no longer active. The current boot file selects the verified Arch startup wrapper, with the original file retained for recovery. The new physical Arch boot IDs and screenshots are recorded in [host-boot.md](host-boot.md).
