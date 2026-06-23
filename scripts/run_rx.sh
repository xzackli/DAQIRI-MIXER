#!/usr/bin/env bash
# Run the correlator RX (rx_host_corr) on the receiver (RTX 5070 = device 1),
# inside the daqiri:local container. Publishes the 128-channel image cube to the
# shared-memory segment /dev/shm/corr32; view a channel with: ./peek32 120
# Args pass through to rx_host_corr (e.g. --seconds 45 --fps 20 --device 1).
# For full line rate, pin the receiver GPU clocks first (the 5070 idles PCIe to Gen1).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (sources, configs, binaries live here)
IMG="${DAQIRI_IMG:-daqiri:local}"
exec docker run --rm --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/rx_host_corr "$IMG" rx_beamform_host.yaml --device 1 "$@"
