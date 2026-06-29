#!/usr/bin/env bash
# Build the correlator artifacts inside the daqiri:local container. Run on each host:
#   receiver (RTX 5070): rx_host_corr (the correlator) + peek32 (image viewer)
#   transmitter (A6000): tx_host (host-memory sky at line rate, ~380 G)
# Every binary builds on either host (cross-arch builds are harmless); each box runs its own.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; IMG="${DAQIRI_IMG:-daqiri:local}"  # repo root (src/ + binaries here)
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib -lcudart -lrt -lpthread"
docker run --rm -v "$DIR":/work -w /work --entrypoint bash "$IMG" -lc "
  set -e
  echo '[build] rx_host_corr  (RX,  sm_120a / RTX 5070)' ; nvcc -O3 -std=c++17 -arch=sm_120a src/rx_host_corr.cu $DQ -lcufft -o rx_host_corr
  echo '[build] tx_host   (TX,  sm_86   / A6000; host-mem, line rate)' ; nvcc -O3 -std=c++17 -arch=sm_86 src/tx_host.cu $DQ -o tx_host
  echo '[build] rx_ula_corr   (ULA X-engine, real FPGA wire layout, sm_120a)' ; nvcc -O3 -std=c++17 -arch=sm_120a src/rx_ula_corr.cu $DQ -lcufft -o rx_ula_corr
  echo '[build] tx_ula        (ULA synth source, real FPGA wire layout, sm_86)' ; nvcc -O3 -std=c++17 -arch=sm_86 src/tx_ula.cu $DQ -o tx_ula
  echo '[build] ula_selftest  (faithful layout + angle self-test, sm_120a)' ; nvcc -O3 -std=c++17 -arch=sm_120a src/ula_selftest.cu -lcufft -o ula_selftest
  echo '[build] peek32        (viewer)'                  ; g++ -O2 src/peek32.cpp -o peek32 -lrt
  echo built"
