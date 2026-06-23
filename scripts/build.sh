#!/usr/bin/env bash
# Build the correlator artifacts inside the daqiri:local container. Run on each host:
#   receiver (RTX 5070): rx_host_corr (the correlator) + peek32 (image viewer)
#   transmitter (A6000): tx_fp8 (analytic-sky test signal source)
# Every binary builds on either host (cross-arch builds are harmless); each box runs its own.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; IMG="${DAQIRI_IMG:-daqiri:local}"  # repo root (src/ + binaries here)
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib -lcudart -lrt -lpthread"
docker run --rm -v "$DIR":/work -w /work --entrypoint bash "$IMG" -lc "
  set -e
  echo '[build] rx_host_corr  (RX,  sm_120a / RTX 5070)' ; nvcc -O3 -std=c++17 -arch=sm_120a src/rx_host_corr.cu $DQ -lcufft -o rx_host_corr
  echo '[build] tx_fp8        (TX,  sm_86   / A6000)'    ; nvcc -O3 -std=c++17 -arch=sm_86   src/tx_fp8.cu      $DQ -o tx_fp8
  echo '[build] peek32        (viewer)'                  ; g++ -O2 src/peek32.cpp -o peek32 -lrt
  echo built"
