# txcache — static-buffer 400GbE TX flood benchmark (digilab-transmit)

DPDK app that pre-fills a small ring of jumbo UDP packets ONCE and transmits
the same mbufs forever (refcount bump before each enqueue, so the PMD
completion "free" only decrements). No per-send generation or copying, so
DRAM carries only the NIC single read stream (~45.6 GB/s), which the two
DIMMs sustain.

**Defaults = best measured config** (2 queues x 256 pkts x 8972 B payload):
**364-366 Gbps L2 sustained** (~365-367 wire), receiver-phy confirmed, 0 CRC
errors, flow control off both ends. This is the box's read-path ceiling
(PCIe Gen5 x16 completion / 2-DIMM efficiency), established 2026-08-20.

## Run

    scripts/run_tx_cache.sh [secs]      # privileged docker chroot (no sudo needed)

Rebuild (repo root): `gcc -O3 -march=native src/tx_cache.c -o tx_cache $(pkg-config --cflags --libs libdpdk)`

`src/dram_bw.c` = IMC CAS-counter DRAM bandwidth sampler (SPR raw events, needs
root); run alongside to verify the no-extra-DRAM-traffic property.

## Findings baked into the flags (do not re-chase)

- CX-7 DMA reads on this box are NEVER served from CPU caches (measured:
  DRAM read == TX rate for any working-set size, NoSnoop on or off, payload
  demand-resident in L2). `--prefetch`/`--touch` only hurt; default 0.
- `--repeat` (resend same packet back-to-back) serializes the memory
  controller: 338 G. Worse.
- `--pace-gbps` (mlx5 SEND_ON_TIMESTAMP hw pacing) is implemented but the
  NIC firmware has REAL_TIME_CLOCK_ENABLE / ACCURATE_TX_SCHEDULER = False,
  so it exits with an error until those are flipped (mlxconfig + mlxfwreset).
- Hybrid host+GPUDirect queues and 3-6 queue fan-outs all measured worse.
