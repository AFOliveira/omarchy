# Boot loader: history

This file used to argue that Limine could not work on this board. It can, and
does — see [../limine/README.md](../limine/README.md) for how the board boots
now and [../uboot/README.md](../uboot/README.md) for the firmware change that
made it possible.

What was true, and still is: the stock U-Boot faults when it enters EFI, so on
unpatched firmware an EFI application at `EFI/BOOT/BOOTRISCV64.EFI` sends the
board into a reset loop that nothing can interrupt, and only the portal's
reflash clears. That happened twice on 2026-09-17.

What was wrong: the cause. It is not the empty SD slot and not the block-device
enumeration; it is EFI's network-protocol registration walking an
uninitialised MDIO registry. Two other things changed the picture entirely:
the firmware's `bootstopkey` environment variable, which makes U-Boot
interruptible over the serial console, and the vendor's public U-Boot source,
which builds natively on the board and reproduces the flashed firmware to the
string.
