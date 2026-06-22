#!/usr/bin/env bash
# Firehose throughput test of the SPLIT-K full-beam correlator: reorder_seq HOST TX (~392 G) ->
# bf_rx_host_corr (5070). Measures NIC rate + RX imissed (image is irrelevant here -- sequence data).
# usage: run_thru_corr.sh <label> <target-gbps|0=max> <secs>
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; IMG=daqiri:local
LABEL="${1:-corr}"; RATE="${2:-0}"; SECS="${3:-15}"
NIC=ens7np0; A6000=GPU-738db291-5695-f1de-730a-775913dc555b
RXLOG=/tmp/ht_rxcorr_${LABEL}.log; TXLOG=/tmp/ht_txcorr_${LABEL}.log
cnt(){ ethtool -S "$NIC" | awk -v k="$1:" '$1==k{print $2}'; }
source ~/.ssh/agent.env >/dev/null 2>&1
bash "$DIR/line-rate-setup.sh" on >/dev/null 2>&1
# build correlator (int8 wmma bf_cgemm, NCUBE=128 channels, K=1024 -- no ccglib)
DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib"
docker run --rm -v "$DIR":/work -w /work --entrypoint bash $IMG -lc \
  "nvcc -O3 -std=c++17 -arch=sm_120a bf_rx_host_corr.cu $DQ -lcufft -lcudart -lrt -lpthread -o bf_rx_host_corr && echo built" 2>&1 | tail -1
scp -q /home/zackli/daqiri/run/tx_huge.yaml digilab-transmit:~/daqiri/run/ || { echo "scp failed"; exit 1; }
docker rm -f bf_rxcorr_ht >/dev/null 2>&1 || true
echo "[$LABEL] RX (bf_rx_host_corr split-K, 5070)..."
docker run --rm --name bf_rxcorr_ht --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 -v "$DIR":/work -w /work \
  --entrypoint /work/bf_rx_host_corr "$IMG" rx_beamform_host.yaml --device 1 --seconds $((SECS+30)) \
  >"$RXLOG" 2>&1 &
for i in $(seq 1 60); do grep -q "THIN-DRAIN RX" "$RXLOG" && break; sleep 1; done
grep -q "THIN-DRAIN RX" "$RXLOG" || { echo "RX not ready:"; tail -15 "$RXLOG"; docker stop bf_rxcorr_ht 2>/dev/null; exit 1; }
sleep 3
PHY0=$(cnt rx_packets_phy); DISC0=$(cnt rx_prio0_buf_discard); OOB0=$(cnt rx_out_of_buffer)
echo "[$LABEL] reorder_seq HOST TX firehose for ${SECS}s..."
ssh -o BatchMode=yes digilab-transmit "docker run --rm --privileged --network host \
  --gpus '\"device=$A6000\"' -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 -v ~/daqiri/run:/run/daqiri \
  --entrypoint /opt/daqiri/bin/daqiri_bench_raw_reorder_seq $IMG \
  /run/daqiri/tx_huge.yaml --seconds $SECS --target-gbps $RATE" >"$TXLOG" 2>&1
sleep 2
PHY1=$(cnt rx_packets_phy); DISC1=$(cnt rx_prio0_buf_discard); OOB1=$(cnt rx_out_of_buffer)
docker stop bf_rxcorr_ht >/dev/null 2>&1 || true; sleep 1
DPHY=$((PHY1-PHY0)); DDISC=$((DISC1-DISC0)); DOOB=$((OOB1-OOB0))
RXBF=$(grep -oE "V-updates=[0-9]+" "$RXLOG" | tail -1 | grep -oE "[0-9]+")
RXIM=$(grep -oE "imissed=[0-9]+" "$RXLOG" | tail -1 | grep -oE "[0-9]+")
echo "================= HOSTTX THRU (split-K corr): $LABEL ================="
awk -v p=$DPHY -v s=$SECS 'BEGIN{printf "NIC received   : %d pkts = %.0f Gbps (8088B wire)\n", p, p*8088.0*8/s/1e9}'
echo "NIC discard    : prio0=$DDISC out_of_buffer=$DOOB"
echo "RX V-updates   : ${RXBF:-?}   imissed: ${RXIM:-?}"
echo "TX(reorder_seq): $(grep -iE "complete|gbps|sent|byte" "$TXLOG" | tail -2 | tr '\n' ' ')"
echo "==================================================================="
bash "$DIR/line-rate-setup.sh" off >/dev/null 2>&1
