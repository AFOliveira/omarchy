#!/bin/bash
set -euo pipefail
port_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$port_dir/../.." && pwd)
mkdir -p "$repo_dir/build/rv64gc"
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$port_dir:/src:ro" -v "$repo_dir/build/rv64gc:/out" \
  "${K3_BUILD_IMAGE:-omarchy-k3-builder:trixie}" bash -euo pipefail -c '
    riscv64-linux-gnu-gcc -O2 -static -march=rv64gc -mabi=lp64d -Wall -Wextra -Werror /src/rv64gc-smoke.c -o /out/rv64gc-smoke
    riscv64-linux-gnu-readelf -h -A /out/rv64gc-smoke
    qemu-riscv64 -cpu sifive-u54 /out/rv64gc-smoke
  ' 2>&1 | tee "$repo_dir/build/rv64gc/smoke.log"
