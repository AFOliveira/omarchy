#!/bin/bash
# Preserve the installed K3 graphics ABI in a separate prefix inside Arch.
set -euo pipefail
rootfs=${K3_ROOTFS_DIR:-/var/lib/machines/omarchy-k3}
if (( EUID != 0 )) || [[ $(uname -m) != "riscv64" ]] || [[ ! -f $rootfs/.omarchy-k3-rootfs ]]; then
  echo "Run as root on the Bianbu K3 after staging Arch." >&2
  exit 1
fi
dpkg-query -W img-gpu-powervr libegl-mesa0 libgbm1

prefix="$rootfs/opt/spacemit"
install -d "$prefix/lib/dri" "$prefix/share/glvnd/egl_vendor.d" "$prefix/share/doc"
for lib in libEGL_mesa.so.0 libGLX_mesa.so.0 libglapi.so.0 libgbm.so.1; do
  cp -L "/usr/lib/riscv64-linux-gnu/$lib" "$prefix/lib/$lib"
done
for driver in pvr swrast kms_swrast; do
  if [[ -f /usr/lib/riscv64-linux-gnu/dri/${driver}_dri.so ]]; then
    cp -L "/usr/lib/riscv64-linux-gnu/dri/${driver}_dri.so" "$prefix/lib/dri/"
  fi
done
for lib in libGLESv1_CM_PVR_MESA libGLESv2_PVR_MESA libpvr_dri_support libsrv_um \
  libsutu_display libglslcompiler libufwriter libusc libPVRScopeServices; do
  cp -L "/usr/lib/$lib.so" "$prefix/lib/"
done
cp /etc/powervr.ini "$rootfs/etc/powervr.ini"
cat > "$prefix/share/glvnd/egl_vendor.d/50_spacemit.json" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": { "library_path": "/opt/spacemit/lib/libEGL_mesa.so.0" }
}
EOF
cat > "$prefix/env" <<'EOF'
# Source this only in the K3 graphics session.
export LD_LIBRARY_PATH="/opt/spacemit/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH=/opt/spacemit/lib/dri
export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/spacemit/share/glvnd/egl_vendor.d/50_spacemit.json
EOF
dpkg-query -W img-gpu-powervr libegl-mesa0 libglapi-mesa libgbm1 > "$prefix/share/doc/installed-vendor-packages.txt"
for package in img-gpu-powervr libegl-mesa0 libgbm1; do
  if [[ -d /usr/share/doc/$package ]]; then
    cp -a "/usr/share/doc/$package" "$prefix/share/doc/"
  fi
done
find "$prefix/lib" -type f -exec sha256sum {} + > "$prefix/share/doc/library-sha256sums.txt"
echo "Vendor libraries staged at /opt/spacemit inside Arch. Runtime validation is still required."
