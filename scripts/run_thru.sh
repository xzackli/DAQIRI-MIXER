#!/usr/bin/env bash
# Line-rate THROUGHPUT test: drive the RX correlator with DAQIRI's reorder_seq HOST firehose
# (~98% of 400 GbE of sequence data -- NOT the sky, so the image is garbage here). Measures NIC
# receive rate + RX imissed to show the datapath + correlator sustain line rate. The single-GPU
# GPUDirect TX (tx_fp8) caps ~145 G, which is why throughput uses this host-memory firehose.
# Pass --noflop as arg 4 to measure the pure datapath (no GEMM/FFT). For the correct star+planet
# image, use scripts/run_tx.sh instead.
#   usage: run_thru.sh [label] [target-gbps|0=max] [secs] [rx-extra-flags]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; IMG="${DAQIRI_IMG:-daqiri:local}"
LABEL="${1:-thru}"; RATE="${2:-0}"; SECS="${3:-15}"; RXEXTRA="${4:-}"
NIC="${MIXER_NIC:-ens7np0}"; A6000="${A6000_UUID:-GPU-738db291-5695-f1de-730a-775913dc555b}"
RXLOG=/tmp/mixer_thru_rx_${LABEL}.log; TXLOG=/tmp/mixer_thru_tx_${LABEL}.log
WIRE=8064   # payload_size 8000 + header_size 64
cnt(){ ethtool -S "$NIC" | awk -v k="$1:" '$1==k{print $2}'; }
source ~/.ssh/agent.env >/dev/null 2>&1 || true
bash "$DIR/scripts/pin-clocks.sh" on >/dev/null 2>&1
scp -q "$DIR/tx_firehose.yaml" digilab-transmit:~/daqiri/run/ || { echo "scp tx_firehose.yaml failed"; exit 1; }
docker rm -f mixer_thru_rx >/dev/null 2>&1 || true
echo "[$LABEL] RX (rx_host_corr --flush 16) ..."
docker run --rm --name mixer_thru_rx --privileged --network host --gpus all \
  -e NVIDIA_DISABLE_REQUIRE=1 --mount type=tmpfs,destination=/usr/local/cuda/compat \
  --ipc=host -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 -v "$DIR":/work -w /work \
  --entrypoint /work/rx_host_corr "$IMG" rx_beamform_host.yaml --device 1 --flush 16 --seconds $((SECS+30)) $RXEXTRA \
  >"$RXLOG" 2>&1 &
for i in $(seq 1 60); do grep -q "THIN-DRAIN RX" "$RXLOG" && break; sleep 1; done
grep -q "THIN-DRAIN RX" "$RXLOG" || { echo "RX not ready:"; tail -15 "$RXLOG"; docker stop mixer_thru_rx 2>/dev/null; bash "$DIR/scripts/pin-clocks.sh" off >/dev/null 2>&1; exit 1; }
sleep 3
PHY0=$(cnt rx_packets_phy); DISC0=$(cnt rx_prio0_buf_discard); OOB0=$(cnt rx_out_of_buffer)
echo "[$LABEL] reorder_seq HOST firehose ${SECS}s (target ${RATE} gbps; 0=max) ..."
ssh -o BatchMode=yes digilab-transmit "docker run --rm --privileged --network host \
  --gpus '\"device=$A6000\"' -e NVIDIA_DISABLE_REQUIRE=1 \
  --mount type=tmpfs,destination=/usr/local/cuda/compat \
  -v /dev/hugepages:/dev/hugepages --ulimit memlock=-1 -v ~/daqiri/run:/run/daqiri \
  --entrypoint /opt/daqiri/bin/daqiri_bench_raw_reorder_seq $IMG \
  /run/daqiri/tx_firehose.yaml --seconds $SECS --target-gbps $RATE" >"$TXLOG" 2>&1
sleep 2
PHY1=$(cnt rx_packets_phy); DISC1=$(cnt rx_prio0_buf_discard); OOB1=$(cnt rx_out_of_buffer)
docker stop mixer_thru_rx >/dev/null 2>&1 || true; sleep 1
DPHY=$((PHY1-PHY0)); DDISC=$((DISC1-DISC0)); DOOB=$((OOB1-OOB0))
RXV=$(grep -oE "V-updates=[0-9]+" "$RXLOG" | tail -1 | grep -oE "[0-9]+")
RXIM=$(grep -oE "imissed=[0-9]+" "$RXLOG" | tail -1 | grep -oE "[0-9]+")
echo "================= THROUGHPUT: $LABEL ================="
awk -v p="$DPHY" -v s="$SECS" -v w="$WIRE" 'BEGIN{printf "NIC received   : %d pkts = %.0f Gbps (%dB wire)\n", p, p*w*8.0/s/1e9, w}'
echo "NIC discard    : prio0=$DDISC out_of_buffer=$DOOB"
echo "RX V-updates   : ${RXV:-?}   imissed: ${RXIM:-?}"
echo "TX firehose    : $(grep -iE 'complete|gbps|sent|byte' "$TXLOG" | tail -2 | tr '\n' ' ')"
echo "====================================================="
bash "$DIR/scripts/pin-clocks.sh" off >/dev/null 2>&1
