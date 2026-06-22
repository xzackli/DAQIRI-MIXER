#!/usr/bin/env bash
# Run the analytic-sky TX (bf_tx_fp8) on the transmitter (A6000), inside the daqiri:local container.
# The A6000 is GPU index 1 there (a GeForce sits at 0), so target it by UUID and mask the CUDA
# compat layer (the GeForce trips forward-compat init otherwise). Args pass through to bf_tx_fp8
# (e.g. --seconds 60 --astar 2 --rho 0.35 --torbit 3). TX_RATE caps snaps/s so the receiver stays
# lossless (a real F-engine streams at a fixed ADC rate); TX_RATE=0 = firehose.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (sources, configs, binaries live here)
IMG="${DAQIRI_IMG:-daqiri:local}"
A6000="${A6000_UUID:-GPU-738db291-5695-f1de-730a-775913dc555b}"
TX_RATE="${TX_RATE:-7000}"

exec docker run --rm --privileged --network host \
  --gpus "\"device=${A6000}\"" \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/bf_tx_fp8 "$IMG" tx_beamform.yaml --rate "$TX_RATE" "$@"
