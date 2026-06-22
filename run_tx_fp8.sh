#!/usr/bin/env bash
# Run the TX signal generator on digilab-transmit, inside the daqiri:local container.
# The A6000 is GPU index 1 there (a GeForce sits at 0), so target it by UUID and
# mask the CUDA compat layer (the GeForce trips forward-compat init otherwise).
# Args pass through to bf_tx (e.g. --seconds 60 --astar 2 --rho 0.35 --torbit 3).
# Default --rate keeps the TX just under one A6000's beamform ceiling (~8k snaps/s)
# so the receiver stays lossless; override with TX_RATE=0 (firehose) or any value.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
