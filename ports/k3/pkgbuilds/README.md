# Source package recipes

## Boot and kernel packages

These recipes exist so the board's boot, and Arch's own kernel on it, are
maintained by packages and pacman hooks, the way upstream Omarchy's are, rather
than by scripts in this port:

| Package | Upstream | What changed for RISC-V |
| --- | --- | --- |
| `limine-mkinitcpio-hook` | AUR 1.39.0-1 (`limine-entry-tool` sources) | the GraalVM native image is replaced by the same program on the system JRE; GraalVM publishes no RISC-V build |
| `limine-snapper-sync` | AUR 1.31.0-1 | the same substitution |
| `linux-spacemit-k3` | none | SpacemiT's `linux-image-6.18.3-generic` deb repackaged into Arch's kernel layout (`/usr/lib/modules/<release>/{vmlinuz,pkgbase}`), the `Image` unwrapped from the gzip Bianbu ships; the `.install` copies the device tree to the vendor boot partition, where U-Boot reads it |
| `linux-spacemit-k3-headers` | none | the matching `linux-headers` deb at `/usr/lib/modules/<release>/build` |
| `ufs-spacemit-dkms` | none | SpacemiT's UFS host driver adapted to Linux 7.x, rebuilt by DKMS for mainline kernels |
| `spacemit-k3-com260-devicetree` | none | the mainline device tree of this board, given to mainline kernels as a systemd-stub addon whose `.uname` matches only that kernel |
| `pvrsrvkm-k3-dkms` | SpacemiT's kernel tree at `4158237f`, `drivers/gpu/drm/img-rogue` (Imagination DDK 24.2@6603887) | the GPU driver the desktop renders with on Arch's kernel, built by DKMS for 7.x kernels: Makefile paths pointed at the module directory, DVFS left out, one patch releasing the GPU from reset; `prepare()` fetches only that directory and checks its git tree hash; blacklists `powervr` (see `../arch-kernel/README.md`) |
| `powervr-k3-dkms` | Linux 7.2.6 `drivers/gpu/drm/imagination` | plus the upstream-in-review patch to probe without a power domain; runs the GPU as revision 36.52.104.182. Installed but blacklisted while `pvrsrvkm-k3-dkms` is: its Mesa user space reaches only OpenGL ES 2.0 through Zink |
| `linux-spacemit-k3-dm-crypt` | none | `dm-crypt`, `dm-integrity`, `dm-bufio`, `async_tx` and `async_xor` built out of tree from the stable kernel sources at the vendor's version, because the vendor kernel is built without `CONFIG_DM_CRYPT` |

The two Limine recipes build with `gradle installDist` instead of
`nativeCompile` and install the jars under `/usr/share/java/<name>/` with a
launcher at the path the package's own scripts call
(`/usr/lib/limine/<name>`). Everything else — the hooks, the systemd units, the
Snapper plugin, the configuration files — is the upstream package's.

`linux-spacemit-k3-dm-crypt` is what makes upstream's `encrypt` hook, and so a
LUKS root, possible here. The modules load on the vendor kernel
(`vermagic: 6.18.3-generic SMP preempt mod_unload riscv`) and a LUKS2 mapping
over them passed a write-and-read-back check before anything was encrypted.


The Omarchy application recipes originate from the official [package repository](https://github.com/omacom/omarchy-pkgs), inspected at `99234a4fbb61b46225b2e9e560e114fbfebe8a95`. The Neovim recipe uses the stable configuration from `2eb15bc7265c5293985f7e5f483e39df7be9c548`, version 2026.7.17. Source checksums remain enabled. Declaring `riscv64` identifies the build target and does not establish runtime compatibility.

The compositor recipes are built from pinned upstream sources:

| Package | Source commit | Port changes |
| --- | --- | --- |
| Hyprland 0.55.4 | `a0136d8c04687bb36eb8a28eb9d1ff92aea99704` | Explicit pointer conversions, corrected target comparisons, animation ownership handling for Hyprutils 0.14, and EGL import validation for PowerVR |
| Aquamarine 0.14.0 | `a79fb21b2e2a82dd061a6d071802bcf38bd5c383` | Acknowledge the parent XDG surface configuration before committing its first buffer |
| Hyprland portal 1.4.1 | `cc8e5ef8fb2acef3db488b9a33b0c48c2a4ee204` | Rebuild against the current RISC-V shared libraries |

The installed repository compositor and portal packages initially required older Aquamarine/Hyprutils SONAMEs. These recipes rebuild the binaries with dependency tracking for the installed ABI. Hyprland embeds the pinned Glaze 7.2.0 source because the repository provides a newer incompatible major version.

`build-packages.sh` compiles as the ordinary Arch user and installs through pacman. Its native helper accepts a list of recipe names, serializes use of the shared build cache, and retains successful artifacts. Compiler processes remain in the invoking systemd service. A cached build is reused only when the recipe fingerprint and artifact paths match.

All included recipes have built natively on the K3. Walker 2.17.0 with Elephant 2.22.0, the 2026.7.17 editor package, and the preview share picker have passed desktop runtime checks. `validate-plugins.lua` checks that all 52 plugin directories exist and that no error has been reported at that point; it does not exercise asynchronous file-opening callbacks. The Ristretto theme uses the maintained `loctvl842/monokai-pro.nvim` source at a pinned commit.

LuaJIT is pinned to [PLCT's RISC-V release](https://github.com/plctlab/LuaJIT/tree/2c509ee67e20772bce3a11ce8f53b6b14b4980bb), version `2.1.1786451769-1.1`. The repository's older `2.1.1702376626-1` incorrectly invokes a table's equality metamethod when comparing it with a nil variable, causing Snacks/LazyVim errors when opening Markdown. Disabling JIT does not fix the old interpreter. The updated package passes `luajit/equality.lua` with JIT enabled and disabled, including inside Neovim. A fresh graphical editor opened the boot guide and moved through it with JIT enabled, empty `v:errmsg`, and no error messages. This fixes the runtime without changing cached plugin sources. The K3 updater holds this tested runtime.

On the physical Arch host, `sudo ports/k3/build-packages.sh luajit` builds directly as the ordinary user and installs through pacman. The same entry point retains the container staging path when run from Bianbu.

The PowerVR patch skips only the driver's unsupported PRIME-to-GEM preflight check when the DRM driver name is `pvr`; plane/dimension checks and actual EGL texture import validation remain active. Other drivers retain the original path.

The share picker builds with stable Rust on RISC-V. `tzupdate` carries a locked TLS dependency update because its old `ring` dependency did not support RISC-V. The Yaru recipe builds GTK color data to generate accent variants but packages only icons and cursors. A successful package build alone is not a claim that every feature or optional hardware path has been tested.

NeatVNC 1.0.1 uses the Nettle 4 backports from Arch's package recipe at `4537131d951c92feadf3e5ad1a02872884df85ab`. H.264 is disabled for this board profile because browser viewers retained stale frames; standard Tight/ZRLE image encodings update the desktop correctly. TLS, authentication, JPEG, and GBM support remain enabled. All three upstream test groups pass natively.
