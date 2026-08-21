#!/usr/bin/env bash
# Static-buffer 400GbE TX flood benchmark, digilab-transmit CX-7 (c7:00.0 / ens7np0).
# Defaults = best measured config (2q x 256 x 8972B): ~364-366 Gbps L2 sustained,
# receiver-phy confirmed -- this box's read-path ceiling (docs/txcache-bench.md).
# Needs root for hugepages + mlx5 DevX: runs via privileged docker chroot
# (no passwordless sudo on the digilab boxes; zackli is in the docker group).
# Build first (from repo root, on the transmitter):
#   gcc -O3 -march=native src/tx_cache.c -o tx_cache $(pkg-config --cflags --libs libdpdk)
#   gcc -O2 src/dram_bw.c -o dram_bw
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
SECS=${1:-30}
docker run --rm --privileged --network host --pid host -v /:/host daqiri:local \
  chroot /host /bin/bash -c "cd $DIR && ./tx_cache -l 7,8,9 -a c7:00.0 -- --secs $SECS"
# DRAM bandwidth check (IMC CAS counters), run alongside:
#   docker run --rm --privileged --pid host -v /:/host daqiri:local chroot /host $DIR/dram_bw 30
# Receiver-side ground truth (no root, on digilab-receiver):
#   ethtool -S ens7np0 | grep rx_bytes_phy   # delta over time
