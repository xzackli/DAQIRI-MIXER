#!/usr/bin/env bash
# Build the correlator artifact inside the daqiri:local container. Run it on each host:
#   receiver (RTX 5070): runs bf_rx_host_corr + bf_peek32 + bf_spectest
#   transmitter (A6000): runs bf_tx_fp8
# Every binary is built regardless of host (cross-arch builds are harmless); each box just runs its own.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; IMG="${DAQIRI_IMG:-daqiri:local}"
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib -lcudart -lrt -lpthread"
docker run --rm -v "$DIR":/work -w /work --entrypoint bash "$IMG" -lc "
  set -e
  echo '[build] bf_rx_host_corr  (RX,  sm_120a / RTX 5070)' ; nvcc -O3 -std=c++17 -arch=sm_120a bf_rx_host_corr.cu $DQ -lcufft -o bf_rx_host_corr
  echo '[build] bf_tx_fp8        (TX,  sm_86   / A6000)'    ; nvcc -O3 -std=c++17 -arch=sm_86   bf_tx_fp8.cu      $DQ -o bf_tx_fp8
  echo '[build] bf_peek32        (viewer)'                  ; g++ -O2 bf_peek32.cpp  -o bf_peek32  -lrt
  echo '[build] bf_spectest      (validation)'              ; g++ -O2 bf_spectest.cpp -o bf_spectest -lrt
  echo built"
