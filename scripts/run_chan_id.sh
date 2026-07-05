#!/usr/bin/env bash
# Run the RFSoC feng4el raw wire channel-ID helper on digilab-transmit.
# Optional args: [--yaml file] [bursts]. Bursts defaults to chan_id's built-in default.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${DAQIRI_IMG:-daqiri:local}"
BIN="$DIR/chan_id"
if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN; build it with scripts/build.sh" >&2
  exit 1
fi
yaml=rx_feng4el_host.yaml
bursts=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yaml)
      if [[ $# -lt 2 ]]; then
        echo "--yaml requires a file" >&2
        exit 1
      fi
      yaml="$2"
      shift 2
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$bursts" ]]; then
        echo "unexpected extra argument: $1" >&2
        exit 1
      fi
      bursts="$1"
      shift
      ;;
  esac
done
args=("$yaml")
if [[ -n "$bursts" ]]; then
  args+=("$bursts")
fi
# GPU/CUDA-compat flags match run_rx_feng4el.sh: chan_id links libcudart, and the
# proven hardware-validation runs used exactly this flag set.
exec docker run --rm --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 \
  -v "$DIR":/work -w /work \
  --entrypoint /work/chan_id "$IMG" "${args[@]}"
