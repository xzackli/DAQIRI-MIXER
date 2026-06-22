#!/bin/bash
# Live end-to-end verify of the fp8 CORRELATOR full-beam path: build + start the correlator RX,
# send the analytic sky from digilab-transmit, peek the 32x32 alias-free image (star center + planet).
set -uo pipefail
DIR=/home/zackli/daqiri-beamformer; cd "$DIR"
source ~/.ssh/agent.env >/dev/null 2>&1
bash "$DIR/line-rate-setup.sh" on >/dev/null 2>&1; sleep 2
IMG=daqiri:local
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib"
echo "[corr] build bf_rx_host_corr + bf_peek32 (int8 wmma bf_cgemm, no ccglib)..."
docker run --rm -v "$DIR":/work -w /work --entrypoint bash $IMG -lc "
  nvcc -O3 -std=c++17 -arch=sm_120a bf_rx_host_corr.cu $DQ -lcufft -lcudart -lrt -lpthread -o bf_rx_host_corr &&
  g++ -O2 bf_peek32.cpp -o bf_peek32 -lrt && echo built" 2>&1 | tail -3
docker rm -f bf_rxcorr >/dev/null 2>&1 || true
docker run -d --rm --name bf_rxcorr --privileged --network host --gpus all -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat --ipc=host -v /dev/hugepages:/dev/hugepages \
  --ulimit memlock=-1 -v "$DIR":/work -w /work --entrypoint /work/bf_rx_host_corr $IMG \
  rx_beamform_host.yaml --device 1 --seconds 45 >/dev/null 2>&1
sleep 4
ssh digilab-transmit "TX_RATE=${TX_RATE:-12000} ~/daqiri-beamformer/run_tx_fp8.sh --seconds 38" >/tmp/txcorr.log 2>&1 &
TXPID=$!
sleep 20
echo "===== bf_peek32 channel 120 (high freq -> bright planet) ====="
docker run --rm --ipc=host -v "$DIR":/work -w /work --entrypoint /work/bf_peek32 $IMG 120 2>&1
sleep 5
echo "===== bf_peek32 channel 16 (low freq -> faint planet; same star) ====="
docker run --rm --ipc=host -v "$DIR":/work -w /work --entrypoint /work/bf_peek32 $IMG 16 2>&1
echo "===== correlator RX log ====="
docker logs bf_rxcorr 2>&1 | tail -10
echo "===== TX log ====="; tail -4 /tmp/txcorr.log 2>/dev/null
wait $TXPID 2>/dev/null || true
docker stop bf_rxcorr >/dev/null 2>&1 || true
bash "$DIR/line-rate-setup.sh" off >/dev/null 2>&1
echo "DONE"
