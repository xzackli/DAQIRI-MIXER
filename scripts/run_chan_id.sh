#!/usr/bin/env bash
# Run the RFSoC feng4el raw wire channel-ID helper on digilab-transmit.
# Optional arg: bursts count, default is chan_id's built-in default.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${DAQIRI_IMG:-daqiri:local}"
BIN="$DIR/chan_id"
if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN; build it with scripts/build.sh" >&2
  exit 1
fi
args=(rx_feng4el_host.yaml)
if [[ $# -gt 0 ]]; then
  args+=("$1")
fi
# GPU/CUDA-compat flags match run_rx_feng4el.sh: chan_id links libcudart, and the
# proven hardware-validation runs used exactly this flag set.
exec docker run --rm --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/chan_id "$IMG" "${args[@]}"
