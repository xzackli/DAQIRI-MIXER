#!/usr/bin/env bash
# Run the LINE-RATE analytic-sky TX (tx_host) on the transmitter, inside the daqiri:local container.
# Streams the star + orbiting-planet sky from HOST memory at ~380 GbE -- bypassing the ~145 G single-GPU
# GPUDirect cap -- by pre-filling the host TX buffers with the sky once, then re-sending them.
# Only stale payloads are rewritten as the planet moves, staggered so the send never stalls. Paced at 380
# via pacing_mbps in tx_host.yaml. Args pass through to tx_host (e.g. --rho 0.35 --torbit 3 --refresh-hz 8).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (sources, configs, binaries live here)
IMG="${DAQIRI_IMG:-daqiri:local}"
A6000="${A6000_UUID:-GPU-738db291-5695-f1de-730a-775913dc555b}"

exec docker run --rm --privileged --network host \
  --gpus "\"device=${A6000}\"" \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/tx_host "$IMG" tx_host.yaml "$@"
