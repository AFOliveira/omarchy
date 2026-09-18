# Limine on the K3

The board boots the way upstream Omarchy does, with upstream's own packages:
U-Boot starts Limine as an EFI application, `limine-entry-tool` builds the
unified kernel image from pacman hooks and writes the menu, and
`limine-snapper-sync` keeps one entry per Snapper snapshot. Arch's `linux` is
the default entry and SpacemiT's kernel is a second, ordinary kernel package,
so `pacman -Syu` maintains the boot the way it does on x86. What is board-specific lives in drop-ins rather than in scripts of our
own: `/etc/limine-entry-tool.d/omarchy-k3.conf` for the kernel arguments, and a
`Recovery` entry for the vendor system.

This needs the patched U-Boot described in [../uboot/README.md](../uboot/README.md).
The stock firmware faults when it enters EFI.

## What is where

| | |
| --- | --- |
| `/boot` | the ESP (`sda5`, FAT, 2 GiB), mounted where upstream mounts it |
| `/boot/limine.conf` | the menu: upstream's `default/limine/limine.conf` plus the tool's entries |
| `/boot/EFI/BOOT/BOOTRISCV64.EFI`, `/boot/EFI/limine/limine_riscv64.efi` | Limine, deployed by `limine-install` |
| `/boot/EFI/Linux/omarchy_linux.efi`, `omarchy_linux-spacemit-k3.efi` | the UKIs of Arch's kernel (the default) and SpacemiT's, built by `limine-mkinitcpio-install` through `mkinitcpio --uki` |
| `/boot/loader/addons/` | the mainline device tree as a systemd-stub addon, matched to Arch's kernel by `.uname` (see `../arch-kernel/README.md`) |
| `/boot/<machine-id>/limine_history/` | the kernel files snapshot entries boot, deduplicated by hash |
| `/boot/vendor/` | the vendor kernel and initramfs the `Recovery` entry boots |
| `/boot/ubootefi.var` | the firmware's UEFI variables — `BootOrder`, `Boot0000` "Limine", … (see `../uboot/README.md`) |
| `/usr/local/bin/omarchy-k3-efivars-sync` | writes variables changed from Linux back to that file, from a pacman hook and at shutdown |
| `/etc/default/limine` | upstream's `default/limine/default.conf` with this root's command line |
| `/etc/limine-entry-tool.d/omarchy-k3.conf` | the board's own kernel arguments, appended to that command line |
| `/usr/lib/modules/6.18.3-generic/` | the vendor kernel from `linux-spacemit-k3`, in Arch's layout |
| `/usr/lib/modules/6.18.3-generic/extramodules/` | `dm-crypt` and friends from `linux-spacemit-k3-dm-crypt` |
| `/mnt/bootfs` | the vendor's ext4 boot partition (`sda2`), `noauto`: U-Boot's device tree and `env_k3.txt` |
| `/crypto_keyfile.bin` | the LUKS key, also inside the UKI's initramfs (see the port README) |

```bash
ports/k3/build-packages.sh linux-spacemit-k3 linux-spacemit-k3-headers \
    linux-spacemit-k3-dm-crypt limine-mkinitcpio-hook limine-snapper-sync
ports/k3/limine/install-limine.sh        # ESP at /boot, config, packages, first UKI and menu
reboot
```

After that the port has no boot scripts of its own: a kernel or mkinitcpio
update runs `limine-update` from the pacman hook, and creating or deleting a
snapshot runs `limine-snapper-sync` from the Snapper plugin.

## The packages

The three upstream Omarchy installs from the AUR are GraalVM native images
(`limine-entry-tool`, `limine-snapper-sync`, `limine-mkinitcpio-hook`), and
GraalVM has no RISC-V build. The recipes in `../pkgbuilds/` are the AUR ones
with the native image replaced by the same program on the system JRE — same
sources, same version, same files, a launcher in place of the binary. The
kernel packages exist because SpacemiT ships Debian packages, not Arch ones:

| Package | What it is |
| --- | --- |
| `linux-spacemit-k3` | the vendor `linux-image` deb in Arch's kernel layout, with `pkgbase`; its `.install` copies the device tree to the vendor boot partition, where U-Boot reads it |
| `linux-spacemit-k3-headers` | the vendor `linux-headers` deb at `/usr/lib/modules/<release>/build` |
| `linux-spacemit-k3-dm-crypt` | `dm-crypt`, `dm-integrity`, `dm-bufio`, `async_tx`, `async_xor` built out of tree from the stable kernel sources at the vendor's version, because the vendor kernel has no `CONFIG_DM_CRYPT` and so no `encrypt` hook, and so no LUKS root |
| `limine-mkinitcpio-hook` | upstream's, JVM build |
| `limine-snapper-sync` | upstream's, JVM build |

Arch's own `linux` needs three more (`ufs-spacemit-dkms`,
`spacemit-k3-com260-devicetree`, `pvrsrvkm-k3-dkms`); see
`../arch-kernel/README.md`.

## The hand-off from U-Boot

With the firmware patched (`../uboot/`), U-Boot's own `boot_grub` does the
hand-off. It loads the device tree from the boot partition and runs `bootefi
bootmgr`, which starts the option `limine-install` registered, `Boot0000`
"Limine" (`\EFI\limine\limine_riscv64.efi`). Only if no boot option starts does
it load the removable-media path `EFI/BOOT/BOOTRISCV64.EFI` and call `bootefi`
on it, **without a size**. The size matters: `load`
remembers the device and path the image came from, and `bootefi <addr>` passes
that on, while `bootefi <addr>:<size>` deliberately forgets it and hands the
loader a memory-mapped device path. An earlier version of the port did the
latter, and every boot showed Limine's "Could not meaningfully match the boot
device handle with a volume … Press any key to continue" before the menu. There
is no `env_k3.txt` override any more; the NOR environment holds the compiled
default. On the serial console that is:

```
[   7.238] 142055 bytes read in 1 ms          (device tree)
[   7.247] UEFI boot manager
[   7.282] Booting: Limine
```

and on the kernel side:

```
efi: EFI v2.9 by Das U-Boot
efi: RTPROP=0x3fbd79040 INITRD=0x3fbd52040 MEMRESERVE=0x3fbd51040
LoaderDevicePartUUID = 420cdefc-41f1-4cc6-a5b8-62d7d836ff74   (the ESP)
```

`systemd-analyze` reports firmware and loader time, and `bootctl status` shows
`Limine 12.9.0`, `Partition: /dev/disk/by-partuuid/420cdefc-…` (the ESP, now
that the loader knows its volume), `Loader: /EFI/Linux/omarchy_linux.efi`,
`Current Entry: Omarchy.linux` and `Current Stub: systemd-stub 261.3-1-arch`. Booted through the UKI, the kernel's initrd
comes from the stub (`efi: … INITRD=0x3fbd52040`).

## The kernel, the initramfs and the UKI

Arch's `linux` needs nothing here beyond its package. The vendor `Image` is a
RISCV64 PE with an EFI stub, so its kernel package puts it where Arch puts its
own (`/usr/lib/modules/<release>/vmlinuz`, with
`pkgbase`) after unwrapping the gzip Bianbu ships it in. From there the whole
kernel side is upstream's: `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` is
upstream's hook list, `limine-mkinitcpio-install` runs `mkinitcpio --uki`
through `ukify` on every kernel or mkinitcpio update, and the splash is the
Omarchy plymouth theme installed as `install/login/plymouth.sh` does.

Two of upstream's entries in that file needed a decision. `microcode` only
warns on RISC-V and is kept. `thunderbolt` in `thunderbolt_module.conf` does
not exist here and makes the build fail, so it is not installed — and a failed
mkinitcpio means the tool installs no UKI at all, which is how one run left the
board at an empty menu. `encrypt` is upstream's and is kept, which is what
`linux-spacemit-k3-dm-crypt` is for.

`lsinitcpio -a` on the built image lists the hook run order
(`udev plymouth keymap encrypt`, late `plymouth btrfs-overlayfs`).

## Two things the entries must carry

**No `dtb_path`.** U-Boot fixes the device tree up at boot — display clocks,
the splash framebuffer reservation, MAC addresses — and passes the result to
the EFI application as the firmware device tree. An entry that names a DTB file
replaces that with the raw file, and the kernel then logs `read bitclk failed
from dts` and shows a corrupt display. Limine passes the firmware tree through
when no override is given.

**The vendor's kernel arguments.** U-Boot's script adds `mtdparts=…`,
`boot_mode=nor`, `earlycon=sbi`, `random.trust_bootloader=1` and the
unaligned-access hints on its own path; Limine's entries have to spell them
out. `mtdparts` is what makes the SPI NOR partitions — and so the U-Boot
environment, `/dev/mtd3` — visible from Linux.

The drop-in adds three of the board's own, each commented where it is written:

* `reboot=warm`: this OpenSBI only does a warm reset. SpacemiT's kernel restarts
  through its watchdog driver, but a mainline kernel asks SBI for a cold reset
  by default and hangs.
* `plymouth.ignore-serial-consoles`, so plymouth leaves the serial console
  alone. SpacemiT's arguments also carry `plymouth.prefer-fbcon`; it is left
  out, because upstream does not set it and with it Omarchy's script theme
  crashes in plymouth 26.134.222 (a NULL console viewer in
  `ply_console_viewer_hide`, fixed upstream by `88c8dd8` after that release).
  With it the reboot splash failed on every shutdown.
* `systemd.tty.term.*`, `systemd.tty.rows.*` and `systemd.tty.columns.*` for
  `console` and `ttyS0` (vt220, 24x80). Without them systemd asks the serial
  terminal for its type and size at boot and when the getty starts. The web
  terminal answers after systemd has stopped waiting, and the answers land in
  the login prompt, which garbled every serial login. The values are what
  systemd and programs fall back to when nothing answers.

## Snapshots

`limine-snapper-sync` writes a `Snapshots` directory into `limine.conf`, newest
first, capped at 5 by upstream's `MAX_SNAPSHOT_ENTRIES`, and keeps the kernel
files each one needs under `/boot/<machine-id>/limine_history/`, deduplicated
by hash. The Snapper plugin runs it when a snapshot is created or deleted, and
`limine-snapper-sync.service` watches `/.snapshots` — that watcher needs
`inotify-tools`, or it logs `inotifywait is not installed` and exits, leaving
only the plugin path.

Booting one from the menu mounts the read-only snapshot and, through the
`btrfs-overlayfs` hook, puts a tmpfs overlay on it, so the boot is writable and
nothing written survives, as upstream:

```
LoaderEntrySelected = Omarchy.Snapshots.2026-09-18-04-12-56.linux-spacemit-k3
rootflags=subvol=/@snapshots/3/snapshot
overlay / overlay rw,lowerdir=…,upperdir=…/upper,workdir=…/work
```

The desktop came up in that boot too. Its one failed unit is
`systemd-remount-fs.service` — fstab's `/` line cannot be re-applied to an
overlay (`overlay: No changes allowed in reconfigure`); the hook is upstream's
verbatim and touches neither fstab nor that unit, so this is left as is.

The next start is the live root again.

## `default_entry` has to be a path here

Upstream's `limine.conf` says `default_entry: 2`. The tool nests the kernel
under an OS directory and adds `Snapshots`, the EFI fallback and the board's
`Recovery` entry, so on this board that number selects something else and the
menu waits instead of booting. Limine also accepts an entry path, which says
what is meant:

```
default_entry: Omarchy/linux
```

`install-limine.sh` writes that, and `luks-root.sh` keeps whatever is there when
it rebuilds the menu.

To boot something else once, use the Boot Loader Interface as on a PC:

```
bootctl set-oneshot 'Recovery--vendor-Bianbu-system'     # or a snapshot's id
reboot                                                    # the next boot is the default again
```

The ids are the ones in `LoaderEntries` (`bootctl list` shows them).
`systemctl reboot --boot-loader-entry=` refuses them — logind only accepts
entries it finds as files on the ESP, which Limine's are not, on any machine.

## Differences from upstream that remain

* **The Limine tools are JVM builds, not GraalVM native images**, and so need
  a Java runtime (`java-runtime-headless`). They behave the same and are the
  same version.
* **UEFI variables persist through a file, not flash.** The firmware keeps them
  in `/boot/ubootefi.var` and lets Linux change them in memory; changes reach
  the file through `omarchy-k3-efivars-sync` (pacman hook and shutdown), which
  is U-Boot's documented contract for runtime variables. `efibootmgr`,
  `limine-install`'s registration and `bootctl set-oneshot` all work; a change
  made by hand is lost only if the board loses power before a clean shutdown.
* **The `Recovery` entry reads its kernel from the ESP**, not from the vendor's
  ext4 partition: Limine faults inside `linux_load` when the kernel comes from
  ext4 through `guid(…)`, so `install-limine.sh` stages the vendor kernel and
  initramfs into `/boot/vendor/`.
* **No `dtb_path` in any entry**, and the board's kernel arguments have to be
  spelled out — see the section above.
* **U-Boot's 5-second countdown precedes Limine's**, so the desktop is about
  ten seconds further from power-on than it was; the countdown is what makes
  the U-Boot prompt reachable when something needs fixing by hand.
* **The firmware no longer asks the terminal for its size.** U-Boot's EFI
  console did, the provider's web terminal answered too late, and Limine took
  the late answer for a key press and stopped its countdown whenever the
  console was open. U-Boot patches 45–47 turn the query off
  (`../uboot/README.md`, section 5). A key typed into the console during the
  countdown still stops it, as on any machine.
* **Choosing a menu entry over that console is timing-sensitive.** The stream
  arrives with a second or more of latency, so a script has to send its keys
  relative to U-Boot's countdown line, not Limine's menu.
  `~/.local/state/omarchy-riscv/portal/limine-select.py` does that, and
  `type-text.py` can type a whole entry into Limine's `B` blank-entry editor,
  which is the way back in when no entry in the menu boots.
