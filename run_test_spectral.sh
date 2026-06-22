#!/bin/bash
# Extra tests for the SPECTRAL cube correlator: longer run (stability/imissed), same-frame spectral
# validation (bf_spectest: per-channel star+planet, slope vs c/127, sum-of-channels == broadband).
set -uo pipefail
DIR=/home/zackli/daqiri-beamformer; cd "$DIR"
source ~/.ssh/agent.env >/dev/null 2>&1
bash "$DIR/line-rate-setup.sh" on >/dev/null 2>&1; sleep 2
IMG=daqiri:local
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib"
echo "[test] build RX + bf_spectest (int8 wmma bf_cgemm, no ccglib)..."
docker run --rm -v "$DIR":/work -w /work --entrypoint bash $IMG -lc "
  nvcc -O3 -std=c++17 -arch=sm_120a bf_rx_host_corr.cu $DQ -lcufft -lcudart -lrt -lpthread -o bf_rx_host_corr &&
  g++ -O2 bf_spectest.cpp -o bf_spectest -lrt && echo built" 2>&1 | tail -2
docker rm -f bf_rxspec >/dev/null 2>&1 || true
docker run -d --rm --name bf_rxspec --privileged --network host --gpus all -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat --ipc=host -v /dev/hugepages:/dev/hugepages \
  --ulimit memlock=-1 -v "$DIR":/work -w /work --entrypoint /work/bf_rx_host_corr $IMG \
  rx_beamform_host.yaml --device 1 --seconds 70 >/dev/null 2>&1
sleep 4
ssh digilab-transmit "TX_RATE=12000 ~/daqiri-beamformer/run_tx_fp8.sh --seconds 48" >/tmp/txspec.log 2>&1 &
TXPID=$!
sleep 22
echo "===== bf_spectest @ frame A ====="
docker run --rm --ipc=host -v "$DIR":/work -w /work --entrypoint /work/bf_spectest $IMG 2>&1
sleep 12
echo "===== bf_spectest @ frame B (different orbital instant) ====="
docker run --rm --ipc=host -v "$DIR":/work -w /work --entrypoint /work/bf_spectest $IMG 2>&1
echo "===== RX log (imissed must stay 0 every frame) -- grabbed while RX still alive ====="
docker logs bf_rxspec 2>&1 | grep -E "\[corr\] frame" | tail -14
wait $TXPID 2>/dev/null || true
docker stop bf_rxspec >/dev/null 2>&1 || true
bash "$DIR/line-rate-setup.sh" off >/dev/null 2>&1
echo "DONE"
