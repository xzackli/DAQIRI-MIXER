#!/usr/bin/env bash
# line-rate-setup.sh {on|off|check}  — pin the conditions needed for 0-drop line rate.
#
# WHY: the 5070 idles its PCIe link down to Gen1 (power saving), which throttles the H2D
# corner-turn; the RX then back-pressures the TX via NIC pause frames -> capped ~370G.
# Locking the GPU clocks holds the link at Gen5; pause-off removes the back-pressure path.
# Our 459/393 numbers came from the GPU auto-clocking under sustained load -- this makes it
# deterministic so a run with gaps (or a cold GPU) can't silently regress.
#
#   on    lock the 5070 (dev $LR_DEV) GPU+mem clocks to ITS OWN max (-> holds Gen5) + verify
#   off   release the clock lock (link returns to idle Gen1)
#   check verify only (clocks / PCIe gen / NIC pause), no changes
#
# Clock lock goes through a privileged daqiri:local container (no passwordless sudo here).
# NOTE: this is the 5070/receiver. daqiri-power.sh (at ~/daqiri/run/, NOT run/rxtest/) locks
# BOTH boxes but to the A6000's 2100 clock, which underclocks the 5070 -- use this for the RX.
set -uo pipefail
IMG="${DAQIRI_IMG:-daqiri:local}"
DEV="${LR_DEV:-1}"            # 5070 = device 1 on the receiver
NIC="${LR_NIC:-ens7np0}"
MODE="${1:-check}"
SMI(){ docker run --rm --privileged --gpus all --entrypoint nvidia-smi "$IMG" "$@" >/dev/null 2>&1; }

read -r SM MM < <(nvidia-smi -i "$DEV" --query-gpu=clocks.max.sm,clocks.max.mem \
                    --format=csv,noheader,nounits 2>/dev/null | tr -d ',')
case "$MODE" in
  on)  SMI -i "$DEV" -pm 1; SMI -i "$DEV" -lgc "$SM"; SMI -i "$DEV" -lmc "$MM" ;;
  off) SMI -i "$DEV" -rgc; SMI -i "$DEV" -rmc; SMI -i "$DEV" -pm 0 ;;
  check) ;;
  *) echo "usage: $0 {on|off|check}"; exit 1 ;;
esac

echo "=== line-rate-setup: $MODE  (dev $DEV target ${SM}/${MM} MHz, nic $NIC) ==="
G=$(nvidia-smi -i "$DEV" --query-gpu=name,clocks.sm,clocks.mem,pcie.link.gen.current,pcie.link.gen.max,persistence_mode --format=csv,noheader 2>/dev/null)
echo "  GPU : $G"
P=$(ethtool -a "$NIC" 2>/dev/null | awk '/RX:|TX:/{printf "%s=%s ",$1,$2}')
echo "  NIC : pause $P"
# verdicts
GEN=$(echo "$G" | awk -F', ' '{print $4}')
[ "$MODE" = on ] && { echo "$P" | grep -qiE "RX:.*on|TX:.*on" && echo "  WARN: NIC pause is ON -> run: sudo ethtool -A $NIC rx off tx off (or in a privileged container)"; }
[ "$MODE" = on ] && { [ "$GEN" = "5" ] && echo "  OK  : PCIe at Gen5" || echo "  NOTE: PCIe link shows Gen$GEN (idle may read low; it pins to Gen5 once traffic flows with the lock held)"; }

exit 0
