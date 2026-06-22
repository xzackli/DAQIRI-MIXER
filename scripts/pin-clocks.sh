#!/usr/bin/env bash
# pin-clocks.sh {on|off|check}  — pin the receiver GPU clocks for 0-drop line rate.
#
# WHY: the 5070 idles its PCIe link down to Gen1 (power saving), which throttles the H2D
# corner-turn; the RX then back-pressures the TX via NIC pause frames -> capped well below
# line rate. Locking the GPU clocks holds the link at Gen5, so a run with gaps (or a cold
# GPU) can't silently regress.
#
#   on    lock the GPU (dev $LR_DEV) core+mem clocks to ITS OWN max (-> holds Gen5) + verify
#   off   release the lock (link returns to idle Gen1)
#   check verify only (clocks / PCIe gen / NIC pause), no changes
#
# Clock lock goes through a privileged daqiri:local container (no passwordless sudo needed).
set -uo pipefail
IMG="${DAQIRI_IMG:-daqiri:local}"
DEV="${LR_DEV:-1}"            # receiver compute GPU (e.g. the 5070 = device 1)
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

echo "=== pin-clocks: $MODE  (dev $DEV target ${SM:-?}/${MM:-?} MHz, nic $NIC) ==="
G=$(nvidia-smi -i "$DEV" --query-gpu=name,clocks.sm,clocks.mem,pcie.link.gen.current,pcie.link.gen.max,persistence_mode --format=csv,noheader 2>/dev/null)
echo "  GPU : ${G:-<no host nvidia-smi for dev $DEV>}"
P=$(ethtool -a "$NIC" 2>/dev/null | awk '/RX:|TX:/{printf "%s=%s ",$1,$2}')
echo "  NIC : pause ${P:-<unknown>}"

if [ "$MODE" = on ]; then
  # verify the locks actually took: read the live clocks back and compare to target (not all
  # GPUs/drivers support -lgc/-lmc; on those nvidia-smi no-ops and the clock stays unpinned).
  read -r CSM CMM < <(nvidia-smi -i "$DEV" --query-gpu=clocks.sm,clocks.mem \
                        --format=csv,noheader,nounits 2>/dev/null | tr -d ',')
  verdict(){ # label  current  target  (held if within 30 MHz of target)
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "  WARN: $1 — could not read clocks (host nvidia-smi missing for dev $DEV?)"; return; fi
    local d=$(( $2 - $3 )); d=${d#-}
    if [ "$d" -le 30 ]; then echo "  OK  : $1 locked at $2 MHz (target $3)"
    else echo "  WARN: $1 did NOT lock — reads $2 MHz vs target $3; this GPU/driver may not support it"; fi
  }
  verdict "core clock (-lgc)" "${CSM:-}" "${SM:-}"
  verdict "mem  clock (-lmc)" "${CMM:-}" "${MM:-}"
  GEN=$(echo "$G" | awk -F', ' '{print $4}')
  [ "$GEN" = "5" ] && echo "  OK  : PCIe at Gen5" \
                    || echo "  NOTE: PCIe shows Gen${GEN:-?} (idle may read low; pins to Gen5 once traffic flows with the lock held)"
  echo "${P:-}" | grep -qiE "RX:.*on|TX:.*on" && echo "  WARN: NIC pause is ON -> sudo ethtool -A $NIC rx off tx off (or in a privileged container)"
fi
exit 0
