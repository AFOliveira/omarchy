#!/bin/bash
set -euo pipefail
for (( attempt = 0; attempt < 90; attempt++ )); do
  [[ ! -S /run/user/1000/wayland-0 ]] || exit 0
  sleep 1
done
echo "The Bianbu parent Wayland session did not become ready." >&2
exit 1
