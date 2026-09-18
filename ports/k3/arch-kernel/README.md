# Running an upstream Arch Linux kernel on the K3

## Now: Arch's kernel is the default, with the GPU, 2026-09-18

Arch's `linux` package boots the board by default (`default_entry:
Omarchy/linux`), and the desktop renders on the GPU. SpacemiT's kernel stays
installed as the second entry, `Omarchy/linux-spacemit-k3`, the way a second
kernel sits next to `linux` on any Omarchy machine. What Arch's kernel needs
from this port is packaged:

| Piece | What it is |
| --- | --- |
| `ufs-spacemit-dkms` | SpacemiT's UFS host driver, adapted to the 7.x callbacks, rebuilt by DKMS for every mainline kernel |
| `spacemit-k3-com260-devicetree` | the mainline device tree of this board (`k3-com260-cloud.dts`, with the UFS and GPU nodes), handed to mainline kernels as a systemd-stub addon in `/boot/loader/addons/` whose `.uname` matches only that kernel; SpacemiT's kernel keeps the vendor tree U-Boot passes |
| `pvrsrvkm-k3-dkms` | SpacemiT's GPU kernel driver (Imagination's DDK 24.2@6603887, the release their kernel carries), built for mainline kernels by DKMS |
| `/opt/spacemit` | the matching GPU user space (OpenGL ES 3.2, EGL), staged from SpacemiT's image by `stage-vendor-graphics.sh` as for SpacemiT's kernel; the session sources `/opt/spacemit/env` when `pvrsrvkm` drives the GPU |
| `omarchy-k3-vkms.service` | a virtual KMS device: Arch's kernel has no driver for the K3 display controller, and Hyprland's DRM backend needs a KMS device to start |
| `/etc/mkinitcpio.conf.d/omarchy_k3_mainline.conf` | the UFS, clock and reset modules, optional (`?`) so SpacemiT's kernel is unaffected |
| `reboot=warm` | this firmware's OpenSBI only does a warm reset; SpacemiT's kernel restarts through its watchdog driver, a mainline kernel through SBI |
| U-Boot patches 41-44 | SpacemiT's commits that switch the GPU power domain on at boot (`../uboot/README.md`); without them the first GPU register read hangs the SoC |

Verified after unattended reboots: `7.2.6-arch2-1` boots the LUKS root, gets the
mainline tree, the assigned address and the full desktop with no failed units,
in about 22 s from firmware to desktop (kernel 3.6 s). Hyprland starts through
`start-hyprland` and renders on the GPU: `CDRMRenderer(drm): Using device
/dev/dri/card1` (`pvrsrvkm`), with vkms as its output and the cloud viewer on
Hyprland's headless `K3-CLOUD` output.

glmark2 (`glmark2-es2-wayland`, 1280x720, the same eight scenes):

| Kernel and GPU driver | Renderer | Score |
| --- | --- | --- |
| SpacemiT's kernel, its DDK driver | PowerVR B-Series BXM-4-64, OpenGL ES 3.2 | 491 |
| Arch's kernel, `pvrsrvkm-k3-dkms` | PowerVR B-Series BXM-4-64, OpenGL ES 3.2 build 24.2@6603887 | 399 |
| Arch's kernel, mainline `powervr` + Mesa | Zink on PowerVR Vulkan, OpenGL ES 2.0 | crashes |
| Arch's kernel, no GPU driver | llvmpipe | 0 (about one frame a second) |

The gap between the first two rows is the clock. On Arch's kernel the GPU runs
at a fixed 819.2 MHz: the mainline tree describes no operating points and no GPU
supply, so the DDK's frequency scaling is built out. SpacemiT's kernel scales it
through an operating-point table that tops out at 1.228 GHz, with the PMIC
raising the voltage.

### Two GPU drivers, and why the DDK one is the default

The GPU is a PowerVR BXM-4-64 at **revision (BVNC) 36.56.104.183**. Its power
domain is off at boot with the stock firmware, and a driver's first register read
then hangs the SoC; U-Boot patches 41-44 switch it on (the sequence is
`0xd42828dc` = `0xffffffff`, then bits 0 and 4 of `0xd42828d0`; status bit 8 of
`0xd42828f0` comes up). Both drivers were then brought up on Arch's kernel.

**Mainline `powervr` (`powervr-k3-dkms`, installed but blacklisted).** Mainline
knows three revisions and linux-firmware has firmware for those three only; this
one has neither. Mesa's device tables describe 36.56.104.183 with exactly the
features, quirks and enhancements of 36.52.104.182 (the TH1520's), so the driver
runs it as that revision (`powervr.gpuid=36.52.104.182 exp_hw_support=1`, with
`rogue_36.52.104.182_v1.fw`). The package is 7.2.6's own driver plus the one
change in review upstream for the K3 (probe without a power domain). The kernel
side works: the firmware loads, and Mesa's PowerVR Vulkan driver enumerates
*PowerVR B-Series BXM-4-64 MC1*, Vulkan 1.2, with no GPU faults. User space is
where it stops. The Vulkan driver is marked non-conformant
(`PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`), Mesa's device-select layer crashes
enumerating it (`NODEVICE_SELECT=1`), and OpenGL through Zink on it reaches only
OpenGL ES 2.0, with Mesa 26.2.2 and with Mesa main (26.3.0-devel,
git-825523d2ea) alike. Hyprland needs OpenGL ES 3.

**SpacemiT's DDK (`pvrsrvkm-k3-dkms`, the default).** The driver in SpacemiT's
kernel tree builds unchanged against Linux 7.2, since the DDK carries its own
compatibility layer. It needed its Makefile paths pointed at the module directory
and one patch to release the GPU from reset, which SpacemiT's kernel does outside
the driver. The package's `modprobe.d` file blacklists `powervr`, so the node,
which lists both drivers' compatibles, goes to `pvrsrvkm`.

Going back to the mainline driver is removing `pvrsrvkm-k3-dkms` and installing
`vulkan-powervr`; the session then renders on vkms in software, because Zink
cannot give Hyprland OpenGL ES 3. The Mesa main build used for the test is kept
as `../../build/k3-16gb-port/opt-mesa-git-26.3.0-devel.tar.zst` (it was
`/opt/mesa-git`).

## What upstream already provides for this board

Linux 7.2 carries the K3 SoC support SpacemiT upstreamed: `CONFIG_ARCH_SPACEMIT`,
the K3 clock controller and reset controller, pinctrl, the AIA interrupt
controllers, the `spacemit,k3-dwmac` Ethernet glue, and device trees for three
K3 boards including the CoM260 module (`k3-com260.dtsi`). Arch enables all of it.
The Ethernet, serial console, SMP bring-up and timers needed no work.

## What the board still needed

| Gap | What was done |
| --- | --- |
| **No UFS host driver upstream.** The root disk is a Kingston UFS device behind SpacemiT's `ufshc` controller; `drivers/ufs/host/` upstream has no SpacemiT driver, and the mainline K3 device tree has no UFS node. | The vendor driver `ufs-spacemit.c`, built out of tree (`ufs-spacemit-dkms`). Two changes were needed for the 7.x API: `pwr_change_notify` lost its negotiation arguments, which moved to the separate `negotiate_pwr_mode` callback, and a vendor-only quirk constant does not exist upstream. See `ufs-spacemit-linux-7.2.patch`. |
| **No UFS or GPU node in the device tree.** | `k3-com260-cloud.dts` includes the mainline CoM260 module description and adds the UFS controller (mainline `CLK_APMU_UFS_ACLK` clock and `RESET_APMU_UFS_ACLK` reset) and the GPU (`CLK_APMU_GPU`, `RESET_APMU_GPU`, interrupt 75, compatibles for both drivers). Upstream 7.2 has no UFS reference-clock ID, so only the AXI clock is described and the reference clock keeps the setting the boot loader left; boot with `clk_ignore_unused`. |
| **MAC address.** The boot loader rewrites the MAC of whatever node an `ethernet` alias points at, using its own first address, which is not the address this instance is assigned. | The board file omits the ethernet alias and sets `local-mac-address` directly. The Omarchy network profile matches any Ethernet interface instead of a fixed MAC, because the interface is `eth0` under the upstream kernel and `end1` under the vendor kernel. |
| **No display controller driver upstream.** | vkms gives Hyprland a KMS device, and the desktop is shown through the cloud viewer, as on SpacemiT's kernel. |

The first bring-up, on 2026-09-06, booted this kernel through U-Boot's
`env_k3.txt` into an Omarchy root that was then a subdirectory of the vendor
partition. `BOOT-LOADER.md`, `build-arch-kernel.sh`, `mkinitcpio/` and
`mkinitcpio-k3.conf` describe that path. The Limine entry replaced it, and they
are kept as the record of how the kernel side was first proven.

## Reproducing

Build the packages in `../pkgbuilds/` (`ufs-spacemit-dkms`,
`spacemit-k3-com260-devicetree`, `pvrsrvkm-k3-dkms`; `powervr-k3-dkms` is
optional), install them with Arch's `linux` and `linux-headers`, and run
`../limine/install-limine.sh`. DKMS builds both modules for the new kernel, the
device-tree hook writes the addon, and upstream's Limine hook builds the UKI and
the menu entry. The firmware must carry U-Boot patches 41-44 before the GPU node
is probed.

## Evidence

Under the ignored `build/k3-16gb-port/` directory:
`desktop-arch-kernel-gpu.png` (the desktop rendered by `pvrsrvkm` on
`7.2.6-arch2-1`), `glmark2-arch-kernel-ddk.txt`,
`glmark2-vendor-kernel-powervr.txt`, `glmark2-arch-kernel-llvmpipe.txt`,
`glmark2-arch-kernel-powervr-zink.txt`, `gpu-arch-kernel-vkcube-zink.txt`,
`vkcube-arch-kernel-powervr.png`, `mesa-main-powervr-zink.txt`,
`u-boot-ee6c094b-gpu-power.itb`, and from the first bring-up
`arch-kernel-running.txt` and `serial-arch-kernel-boot.txt`.

## Open points

- The UFS and GPU kernel drivers are out-of-tree modules carried by this port.
  They taint the kernel, and DKMS rebuilds them for each kernel update; a kernel
  whose API they do not build against leaves the board without its root disk
  (UFS) or without GPU rendering (DDK).
- The GPU user space is SpacemiT's binary release, staged from their image, and
  must stay the same DDK release as `pvrsrvkm-k3-dkms`.
- The GPU runs at a fixed 819.2 MHz on this kernel. Scaling needs the operating
  points and a PMIC supply in the mainline device tree.
- The mainline `powervr` route waits on Mesa's PowerVR driver reaching OpenGL ES
  3 through Zink, or a native OpenGL driver.
- The UFS reference clock is not described; the driver relies on the boot
  loader's setting plus `clk_ignore_unused`.
