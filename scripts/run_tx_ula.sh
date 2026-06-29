#!/usr/bin/env bash
# Run the 4-element ULA synthetic source (tx_ula) on the transmitter (A6000), inside the daqiri:local
# container. Emits channelized int8 (a star @ +10deg + a "planet" swept in angle) over the 400G CX-7
# loopback to the receiver's rx_ula_corr -- this stands in for the FPGA F-engine. Reuses tx_host.yaml
# (identical wire). OFF the FPGA board. Args pass through (e.g. --seconds 30 --amp 100 --sweep 40 --tsweep 5).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${DAQIRI_IMG:-daqiri:local}"
A6000="${A6000_UUID:-GPU-738db291-5695-f1de-730a-775913dc555b}"
exec docker run --rm --privileged --network host \
  --gpus "\"device=${A6000}\"" \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/tx_ula "$IMG" tx_host.yaml "$@"
