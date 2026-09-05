FROM debian:trixie-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bc bison build-essential ca-certificates cpio device-tree-compiler file flex \
    gcc-riscv64-linux-gnu libc6-dev-riscv64-cross libelf-dev libncurses-dev libssl-dev \
    kmod python3 qemu-user rsync u-boot-tools xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
