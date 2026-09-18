# U-Boot on the K3: the patched firmware, and the prompt

The flashed firmware is `U-Boot 2022.10-g267f0eb7`: SpacemiT's commit
`ee6c094b` plus the 47 patches in `patches/`. On top of a serial prompt set in
the environment (section 1), they make its EFI loader work (2), boot through a
UEFI boot manager with variables Linux can write (3), switch the GPU on at boot
(4), and stop asking the serial terminal for its size (5). Together they let the
board boot through Limine the way upstream Omarchy boots a PC.

## 1. A serial prompt (environment only)

U-Boot reads its environment from SPI NOR, `mtd3`. It is live — `CONFIG_ENV_SIZE`
is `0x4000`, and the CRC in its first four bytes matches the following 16 KiB —
so `fw_setenv` can edit it from Linux with

```
# /etc/fw_env.config     device   offset  env size  erase size
/dev/mtd3                0x0000   0x4000    0x1000
```

The build has `CONFIG_AUTOBOOT_KEYED=y`, which is why "press any key" never
worked: it wants the string named by `bootstopkey`. With

```
fw_setenv bootdelay 5
fw_setenv bootstopkey stop
```

typing `stop` repeatedly during `Autoboot in 5 seconds` gives the `=>` prompt.
That is the recovery path for everything else in this port: a boot file or a
menu entry that does not boot is fixed from here instead of by a reflash. The
compiled-in stop string is `s`; the environment variable overrides it. The
stock environment is saved at `../../build/k3-16gb-port/mtd3-env.backup`.

Note that `mtdparts=…` must be on the kernel command line for `/dev/mtd3` to
exist; the Limine entries carry it. Only SpacemiT's kernel has the SPI NOR
driver, so `fw_setenv` and flashing run from that entry (`bootctl set-oneshot
Omarchy.linux-spacemit-k3`, then reboot); Arch's kernel has no `/dev/mtd*`.

## 2. The EFI fault, and the fix that is flashed

Entering EFI faulted on the stock firmware, and the first diagnosis was wrong.
What settled it was a prompt and symbols:

| Test at the prompt | Result |
| --- | --- |
| `mmc dev 0` — probe the empty SD slot, no EFI | fails cleanly (`mmc_init: -123`), returns |
| `efidebug devices` — EFI start-up, no image | faults, `EPC 0x1020b43cc` |
| the same address in a matching build with symbols | `strcmp`, called from `miiphy_get_dev_by_name` (`common/miiphyutil.c:52`) |
| `md.q` of `mii_devs` and `current_mii` at the prompt | all zero |

So the fault is in the network stack, not the block devices. Registering
`EFI_SIMPLE_NETWORK_PROTOCOL` probes the Ethernet device on demand, and that
walks the MDIO registry — which on this board is never initialised, because
`initr_net` does not run at boot. The "MMC: no card present" line that preceded
every crash was only the last thing printed before it.

`patches/` starts with three patches of ours against the vendor tree, written to
be submitted as is:

1. `net: miiphy: initialize the MDIO device list statically` — the fix. With
   it, EFI networking stays enabled and `efidebug devices` simply works.
2. `efi_loader: keep registering block devices after a probe failure` —
   `efi_disks_register()` stopped at the first block device whose probe
   failed (the empty SD slot), so the UFS disk holding the ESP was never
   registered and a loader could not have found its own volume.
3. `board: spacemit: k3: fall back to the kernel when the EFI loader fails` —
   `boot_grub` ended right after `bootefi`, so a loader that fails to load or
   returns left the board at the prompt; now `boot_kernel` runs afterwards. The
   loads stay as the vendor wrote them, and `bootefi` keeps being called without
   a size: `do_bootefi_image()` forgets the device the image was loaded from
   when a size is given and hands the loader a memory-mapped device path, so
   Limine could not find its own volume ("Could not meaningfully match the boot
   device handle with a volume", then a key press to continue). An earlier
   version of this patch did exactly that; it was replaced once the message
   showed up on the console of every boot.

The first one is also a candidate for mainline U-Boot, where the same
declaration exists. `efi-k3.patch` is the earlier diagnostic version (it
gated EFI networking behind an `efi_net` variable) and is kept for the record.

### Which source

The vendor banner says `U-Boot 2022.10 (Apr 30 2026 - 11:07:27 +0800)` and
`gcc (Bianbu 15.2.0-16ubuntu1bb2)`. Building `spacemit-com/uboot-2022.10`,
branch `k3-br-v1.0.y`, at commit `ee6c094b` with `k3_defconfig`, the board's own
compiler, `BUILD_TAG=jenkins-BSP-build-bsp-deb-361` and the banner's
`SOURCE_DATE_EPOCH`, produces a U-Boot blob whose string set differs from the
flashed vendor blob by exactly one string, a packaging JSON. The remaining byte
differences are the address shift that string causes. The commit after it,
`7b72d722`, removes a string the vendor blob still has, which is how the commit
was pinned. The branch tip is a hundred commits further on, touching DDR, UFS,
SPL and device trees; none of that is on the board.

The flashed image is therefore `ee6c094b` + `k3_defconfig` + the series
(patches 1–3 above, 4–47 below), with an honest banner:

```
U-Boot 2022.10-g267f0eb7
```

The NOR environment's `boot_grub` was then set to the compiled default taken
from the flashed image itself (`fw_setenv boot_grub "$(strings -n 20 /dev/mtd6ro |
grep -m1 '^boot_grub=' | cut -d= -f2-)"`), so the board's environment matches the
source and `env_k3.txt` no longer needs an override.

## 3. A UEFI boot manager and writable variables

With patches 1–3 the board booted like a PC booting from a USB stick: U-Boot
loaded the removable-media path `EFI/BOOT/BOOTRISCV64.EFI`, and nothing from
Linux could change that, because U-Boot 2022.10 keeps UEFI variables in memory
only and refuses `SetVariable` once the OS runs (`efivarfs` was read-only). A
PC boots the option `limine-install` registered with `efibootmgr`. Patches
4–40 make this board do the same.

**4–39: 36 commits from mainline U-Boot, cherry-picked in order**, each carrying
its `(cherry picked from commit …)` line. They are the variable-store history
between v2022.10 and v2024.10 plus the series that added runtime variables —
`efi_loader: conditionally enable SetvariableRT` (`c28d32f946`),
`Add OS notifications for SetVariable at runtime` (`bc3dd2493e`) and
`add an EFI variable with the file contents` (`00da8d65a3`) — together with the
fixes the series depends on (attribute checks, buffer overruns in
`efi_var_mem_compare()` and `efi_var_restore()`, no string-literal comparisons
from runtime code) and `avoid superfluous variable store writes on unchanged
data` (`94c5c0835b`), which matters here because Limine sets a non-volatile
`LimineLastBootedEntry` on every boot. The chain was replayed on a branch of
mainline v2022.10 carrying this tree's EFI files, so every conflict was a real
3-way one. Three commits were left out as tree-wide or cosmetic (`3f8d13044b`,
`bc4fe5666d`, `e9c34fab18`) and two header conflicts were resolved by hand
(`bc3dd2493e`, `94c5c0835b`: kept the new declarations, dropped a GUID for a
feature this tree lacks). Every file the series touches outside
`lib/efi_loader` and `include/efi*` is byte-identical to v2022.10 here.

**40: `board: spacemit: k3: boot through the UEFI boot manager`**:

* `CONFIG_EFI_VARIABLE_FILE_STORE=y` — variables live in `ubootefi.var` on the
  EFI system partition (the only partition with the ESP type; the old one was
  retyped to Linux data so U-Boot does not pick it).
* `CONFIG_EFI_RT_VOLATILE_STORE=y` — Linux may change variables at runtime;
  `efivarfs` mounts read-write and `efibootmgr` works.
* `boot_grub` runs `bootefi bootmgr` first (`BootNext`, then `BootOrder`), then
  the removable-media path, then the kernel on the boot partition — the order a
  PC's firmware follows.

The OS side of runtime variables is U-Boot's documented contract: changes are
kept in memory and published as the `VarToFile` variable, and the OS writes that
to the file named by `RTStorageVolatile`. `../limine/omarchy-k3-efivars-sync`
does it from a pacman hook (after Limine's own deploy hook registers the boot
option) and at shutdown.

Verified on the board:

```
$ limine-install                      # upstream's, EFI_REGISTER=yes
EFI boot entry 'Limine' for '\EFI\limine\limine_riscv64.efi' added successfully.
$ efibootmgr                          # after a reboot
BootCurrent: 0000
BootOrder: 0000
Boot0000* Limine  HD(5,GPT,420cdefc-…)/\EFI\limine\limine_riscv64.efi
```

With `BootOrder` deleted by hand the board boots the removable-media path and
`efibootmgr` says what it says on a PC, "No BootOrder is set; firmware will
attempt recovery". `bootctl set-oneshot <entry>` boots that entry once and the
next boot is the default again, so snapshots and the vendor system no longer
need the serial menu.

## 4. The GPU powered at boot

SpacemiT's firmware from July and August 2026 switches the GPU's power domain on
before Linux starts; the `ee6c094b` build does not, and a GPU driver's first
register read then hangs the SoC. **41–44** are those four commits from the
vendor branch, cherry-picked with their `(cherry picked from commit …)` lines:
`6990f5a9ba` (open the GPU, LCD0 and LCD1 power switches), `775d425c89` (mark
them `spacemit,default-on` in `k3.dtsi`), `9c7e7dd321` (use the hardware mode
for the GPU switch) and `9c8de7d560` (fix that mode). With them the GPU driver on
Arch's kernel probes and renders (`../arch-kernel/README.md`), and SpacemiT's
kernel is unaffected.

## 5. No terminal size query on the serial console

When an EFI application starts, `efi_console` asks the terminal for its size
(cursor to 999;999, then `ESC [6n`) and waits 100 ms for the answer. This
board's only console is the provider's web terminal, whose round trip is longer
than that. The answer then arrives after U-Boot has stopped waiting, Limine reads
it as a key press and stops its countdown, and the board sits at the menu
whenever the console is open.

Mainline U-Boot has an option for exactly this since March 2026. **45–46** are
its two commits: `4cb7243640` (`efi_console_set_ansi()`, which skips the query)
and `0c3eb097d9` (`CONFIG_EFI_CONSOLE_DISABLE_ANSI`). Each needed a small hand
resolution for 2022.10: the header context, the Kconfig neighbours, and
`CONFIG_DM_VIDEO` where mainline now says `CONFIG_VIDEO`. **47** turns the option
on for the K3. The query never answered in time here, so the console stays
80x25 as before. Verified with the console attached: Limine counts down from 5
to 1 and boots the default entry on its own.

## How it was written

```bash
git clone --depth 1 -b k3-br-v1.0.y https://github.com/spacemit-com/uboot-2022.10.git
git fetch --shallow-since=2026-04-27 origin k3-br-v1.0.y && git checkout ee6c094b
git am patches/*.patch
make k3_defconfig && make -j8                # natively on the board
flashcp u-boot.itb /dev/mtd6                 # then read back and compare
```

`mtd6` holds a plain FIT at offset 0 (13 configurations, one per board variant
including `k3_com260`, CRC32 hashes, no signatures). The SPL in `mtd2` is
untouched. Before writing, the whole partition was saved to
`../../build/k3-16gb-port/mtd6-uboot.backup`; `flashcp` of that file restores
the vendor firmware.

Chainloading a U-Boot from the running one (`load` + `go`) does not work — the
new image relocates onto the running one — so the write could not be tested
first. The portal's own description of its reflash, "one-click firmware
flashing to debug U-Boot and Linux drivers", was the fallback it was done
against.

## Evidence

Under `../../build/k3-16gb-port/`: `uboot-flash-2026-09-17.txt`,
`u-boot-ee6c094b-noansi.itb` (what is flashed, patches 1–47),
`u-boot-ee6c094b-gpu-power.itb` (patches 1–44),
`u-boot-ee6c094b-uefi-bootmgr.itb` (patches 1–40),
`u-boot-ee6c094b-efifix4.itb` (patches 1–3; `efifix3` is the build before with
the explicit-size `bootefi`), `mtd6-uboot.backup`,
`mtd3-env.backup`, `limine-boot-serial.txt`, `limine-boot-serial-efifix4.txt` (Limine reporting
`Booting /EFI\BOOT\BOOTRISCV64.EFI` and systemd-stub `LoaderDevicePartUUID`
equal to the ESP), `uboot-bootefi-crash.txt` (the
fault on the stock firmware) and `limine-under-uboot-qemu.txt` (Limine under a
working U-Boot EFI, which showed the loader itself was fine).

The vendor system keeps a rollback kit in `/root/omarchy-k3-rollback/` on its own
partition: the images for patches 1–3, 1–40, 1–44 and 1–47 and a tar of the
ESP, next to its own `flashcp`, so it can put an earlier firmware back without
the encrypted Omarchy root.
