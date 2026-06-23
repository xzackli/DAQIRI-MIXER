# DAQIRI-MIXER

![star + orbiting planet, imaged from V=X·Xᴴ](demo.gif)

A 400-GbE-capable real-time int8 tensor-core covariance correlator on a single GPU. It computes per-channel visibilities `V = X·Xᴴ` at ingress with a tensor-core GEMM, then runs a small batched cuFFT at 20 Hz to image the integrated visibilities at spatial Nyquist — a 128-freq-channel 32×32 cube. The 16×16 array is filled and Nyquist-sampled, so that image is the full grid of beams in the field of view (above: toy packet generator input). The analytic-sky transmitter `src/tx_fp8.cu` is a test signal source from a connected host with a GPU, but this could in principle be an FPGA. This code takes in a 400 GbE F-engine stream at ~98% of line rate. 

The NIC capture/transmit runs on [NVIDIA DAQIRI](https://github.com/NVIDIA/daqiri), which moves raw Ethernet packets between the ConnectX-7 and the GPU (ibverbs/DPDK engines, GPUDirect, flow steering). Everything here links `libdaqiri` and runs inside the `daqiri:local` container.

## Hardware

You need a CUDA GPU + ConnectX 6 or later NIC, change the `-arch` in `scripts/build.sh`, the `--device` / GPU UUID in the run scripts, and the NIC address + `cpu_core`s in the YAMLs.

This was developed and tested with two hosts connected with a pair of 400 GbE NVIDIA ConnectX-7.

- **Receiver** — RTX 5070 (Blackwell); runs the correlator. GeForce can't GPUDirect, so we use host DRAM.
- **Transmitter** — RTX A6000 (Ampere); runs the analytic-sky TX over GPUDirect.


## Run

Build on both hosts, then run the correlator on the receiver and the signal source on the transmitter:

```bash
bash scripts/build.sh    # rx_host_corr + peek32, tx_fp8 (GPUDirect) + tx_fp8_host (line rate)
bash scripts/run_rx.sh   # receiver:    correlator -> /dev/shm/corr32
bash scripts/run_tx.sh   # transmitter: analytic sky (star + orbiting planet)
./peek32 120             # view a channel of the image cube (120 = high freq, bright planet)
```

For full line rate, some GPUs need to prevent idling with `bash scripts/pin-clocks.sh on` (and `off` after).

**Three TX modes** (the receiver always runs the same `run_rx.sh`):

- **`run_tx.sh`** — analytic sky over **GPUDirect** from one A6000. Correct image, capped ~145 GbE (the A6000's P2P read ceiling).
- **`run_tx_host.sh`** — analytic sky from **host memory at line rate (~380 GbE)**. The headline: a correct star + orbiting planet imaged end-to-end at the link rate, `imissed=0`. Bypasses the GPUDirect cap by streaming from host hugepages; paced at 380 G via `pacing_mbps` in `tx_host.yaml`.
- **`run_thru.sh`** — DAQIRI's `reorder_seq` host firehose, **~389 GbE of sequence data** (not the sky — the image is meaningless). Pure datapath/throughput check (NIC rate + `imissed`); measured ~389 Gbps received, 0 overflow, ~2–3% shed with full compute.

A single GPU can't *generate* sky packets per-packet at 400 GbE, so `tx_fp8_host` exploits that the sky changes slowly (orbit ~seconds) vs the line rate: it **pre-fills** each host TX buffer once (header + seq + the antenna's fp8 sky), then re-sends them with no per-packet work. When the planet moves, only the stale payloads are rewritten, and those rewrites are **staggered** across the update period so they never stall the send (`--refresh-hz`, default 8 Hz, rides right at the 380 G cap; rewrite cost = `num_bufs × payload × refresh-hz` of CPU memcpy competing with the NIC). The **RX needs none of this** — its buffer is a NIC *receive* buffer the hardware refills with live packets every snapshot, so it always sees the current sky for free. (The deep pool `num_bufs=16384` is required: at 380 G the NIC has more packets in flight than a shallow pool holds, so reusing a buffer the NIC hasn't sent yet tears packets.)

The live image is just a monitor. The science product is the integrated visibility cube `V` — a real deployment writes that to disk (`bash scripts/run_rx.sh --dump /data/v.f32`) and images offline. `--flush N` trades live-view smoothness (low, default 4) against peak throughput (raise it).

## Configuration

The two YAMLs are [DAQIRI](https://github.com/NVIDIA/daqiri) stream configs (the `daqiri.cfg` block).

- **`tx_beamform.yaml`** — GPUDirect transmit (tested on an A6000). The memory region is `kind: "device"`, so `tx_fp8`'s CUDA kernel writes the eth/ip/udp header + seq + int4 payload straight into the NIC's device buffers (no host copy). One TX queue, `batch_size: 256` = one 256-antenna snapshot per burst; `offloads: ["tx_eth_src"]` lets the NIC fill the source MAC.
- **`rx_beamform_host.yaml`** — host-bounce capture on the receiver. Consumer GeForce GPUs can't GPUDirect, so in this example we bounce off host with `kind: "huge"` (host hugepages), with `engine: "ibverbs"` (MPRQ DevX), a single RX queue, and a flow rule steering `udp_dst: 4096` to it.
- **`tx_host.yaml`** — the line-rate host TX (`run_tx_host.sh`): `kind: "huge"` (host hugepages, not GPUDirect), `num_bufs: 16384` (multiple of 256, deep enough for the in-flight TX window), `pacing_mbps: 380000` to cap at 380 G. (`tx_firehose.yaml` is the same idea for the `reorder_seq` throughput bench.)

Adjust these for your hardware: the NIC PCIe address (`0000:c7:00.0`), the `cpu_core`/`master_core` assignments, and `num_bufs`/`buf_size` (sized here for the 8256 B jumbo heap).

The wire format itself (packet/heap sizes, the `seq` field offset, packets-per-batch) lives in **two** places: the YAMLs above, which configure DAQIRI's transport, and `src/config.h`, the compile-time `#define`s the `tx`/`rx` kernels build against. There's no shared source of truth — if you change the wire format, update both to match.
