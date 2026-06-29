#!/usr/bin/env bash
# Run the 4-element ULA X-engine (rx_ula_corr) on the receiver (RTX 5070 = device 1), inside the
# daqiri:local container. Per channel: 4x4 covariance V=X*X^H, then 1-D beamform -> publishes a
# (NCHAN x NBEAM) frequency-vs-angle image to /dev/shm/corr_ula. Reuses the proven MIXER transport
# (identical 8256 B wire) -> same rx_beamform_host.yaml. OFF the FPGA board (400G CX-7 loopback).
# Args pass through (e.g. --seconds 30 --fps 20 --device 1).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${DAQIRI_IMG:-daqiri:local}"
exec docker run --rm --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/rx_ula_corr "$IMG" rx_beamform_host.yaml --device 1 "$@"
