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

## 16 GB allocation (2026-09-16)

SpacemiT recommended moving to a 16 GB K3 for serial and recovery access and issued a one-time access code for it. The allocation `omarchy-k3-16gb` (expiring 2026-12-15) lists `web_uart` among its supported channels; the 32 GB instance listed only SSH, SFTP and VNC.

| Capability | Result on the 16 GB board |
| --- | --- |
| Remote serial console | **Available.** The workbench's Serial Debug tab is a bidirectional `ttyS0` console carried over SockJS/STOMP. A marker written to `/dev/ttyS0` over SSH appeared in it. During resets it showed U-Boot SPL, U-Boot, `Starting kernel ...` and Linux early boot, and later the Arch login prompt. The tab reverts to Terminal after the board reconnects, so capture must re-select it. |
| Portal power restart | **Passed on hardware.** `POST /api/device/power-reset` returned `code 20000`; the boot ID changed and serial showed a cold firmware start. |
| Root access and boot files | Stock Bianbu 4.0 with default credentials, which were replaced after key installation. The stock `/boot/env_k3.txt` digest matches the 32 GB board. |
| Arch physical host | Passed, including a normal reboot; see [host-boot.md](host-boot.md#second-allocation-16-gb-k3). |

This satisfies requirement 1 below for the 16 GB allocation. Custom-kernel experiments can now be observed on serial and recovered with the portal's power reset. None has been run on this board yet.

### Recovering a board that stops in U-Boot

*Since 2026-09-17 there is a better answer than anything below: U-Boot's
`bootstopkey` environment variable makes the firmware interruptible over the
serial console, so a boot that does not start is fixed at the `=>` prompt. See
[uboot/README.md](uboot/README.md). The rest of this section describes the
day that led there.*


On 2026-09-17 the board stopped booting at firmware level, and recovering it
took three things in order. The first two are easy to get wrong.

**The portal's power reset needs a session the portal considers current.** The
control in the workbench's Control menu issues `POST /api/device/power-reset`
with the `applyId` of the current session. If the browser session has expired,
or the workbench tab was opened before it expired, the dialog still appears and
the confirmation still closes it, but no request is sent. The serial console
goes quiet at the same time, because that too is brokered per session, so the
board looks dead rather than merely unreachable. Sign in again, open the
instance from **我的实例 / My instances** with **开始远程**, and use Control →
Power Reboot from *that* tab. A request logged as

```
POST /api/device/power-reset {"applyId":"…"}  ->  {"code":20000,"message":"操作成功"}
```

is the only confirmation that the board was really power-cycled. Calling the
endpoint by hand with the same `applyId` is rejected (`未识别到ApplyId`).

**A power reset does not recover a boot loader that fails every time.** Once the
session was restored, two confirmed resets changed nothing, because the fault
was reached again on each boot: U-Boot crashed, reset itself, and crashed again
about four seconds later. The serial console showed the whole cycle. Nothing can
be typed into it at that point: `bootdelay` is 0 and U-Boot calls
`disable_ctrlc(1)` around the boot script, so neither a keypress nor Ctrl-C
interrupts it. The portal's serial console does deliver input — the websocket
carries each keystroke as `SEND /api/ws/remoteCmd {"cmd":"\u0003"}` — it is
U-Boot that ignores it.

**The flash panel is the way back.** 刷机 → 打开刷机面板 lists the images the
node has; for this K3 com260 the right one is `Bianbu-LXQt-K3`, whose 2026-04-28
date matches the board's own U-Boot (built 2026-04-30) and restores Bianbu 4.0
with the same `6.18.3-generic` kernel the port targets. `Bianbu-lite-v1`, which
the device record names as its `flashImage`, is an August 2025 build with kernel
6.6.36 and is not a K3 image. The flash is

```
POST /api/device/post-flash {"flashImageTag":"Bianbu-LXQt-K3","deviceId":"…"}
  -> {"code":20000,"data":{"jobId":"…"}}
GET  /api/device/fetch-flash-job?deviceId=…   -> status: flashing
```

and took about nine minutes. It erases the disk: partition table, both
filesystems, passwords and keys. Afterwards the stock `/boot/env_k3.txt` digest
matched the value this port already pins, so the baseline is exactly the stock
image again.

The lesson for boot work on this board is in
[arch-kernel/README.md](arch-kernel/README.md#handing-the-boot-over-to-limine):
never let U-Boot reach a state it cannot fall out of. Keep a serial session open
before arming anything, since a session can only be established while the vendor
system is running, and prefer boot changes that fall back on their own.

## Remaining requirements and completed host work

1. **Reliable recovery independent of Linux.** *(Available on the 16 GB allocation; see above.)* Request working power reset plus a bidirectional UART console that covers reset, U-Boot, and early kernel startup. SpacemiT may be able to enable these on this allocation or move the allocation to a serial-equipped K3. Preserve the existing allocation and data until a replacement is confirmed. A provider-assisted reflash route is another recovery option; the prior factory recovery erased staged data.
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
