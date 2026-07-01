#!/usr/bin/env bash
# Run the RFSoC feng4el 4-element GPU X-engine on digilab-transmit.
# The board's 100G QSFP is cabled to ens5f0np0 and sends UDP dst port 60000.
# Args pass through, e.g. --seconds 10 --fps 5 --device 0.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${DAQIRI_IMG:-daqiri:local}"
exec docker run --rm --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/rx_feng4el_corr_sm86 "$IMG" rx_feng4el_host.yaml --device 0 "$@"
