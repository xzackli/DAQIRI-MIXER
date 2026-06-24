# DAQIRI-MIXER

*Multi-Input X-Engine in Real-Time (MIXER) with NVIDIA DAQIRI*

![star + orbiting planet, imaged from V=X·Xᴴ](demo.gif)

A 400-GbE-capable real-time int8 tensor-core covariance correlator on a single GPU. It computes per-channel visibilities `V = X·Xᴴ` with a tensor-core GEMM, then runs a small batched cuFFT at 20 Hz to image the integrated visibilities at spatial Nyquist. The NIC capture/transmit runs on [NVIDIA DAQIRI](https://github.com/NVIDIA/daqiri), which moves raw Ethernet packets between the ConnectX-7 and the GPU (ibverbs/DPDK engines, GPUDirect, flow steering); everything here links `libdaqiri` and runs inside the `daqiri:local` container.

We've tested it end-to-end with zero loss at ~380 GbE — ~95% of the 400 GbE line rate. We include a small simulated packet generator (`src/tx_host.cu`) simulating a 16×16-element array observing an analytic sky — a star and an orbiting planet (the image above). It's a test signal source from a connected host, but in principle could be a CPU or an FPGA. The array is filled and Nyquist-sampled, so one cuFFT of the visibilities forms the full grid of beams across the field of view, imaged as a 128-frequency-channel 32×32 cube.

## Hardware

You need a CUDA GPU and a ConnectX 6 or later NIC. Change the `-arch` in `scripts/build.sh`, the `--device` / GPU UUID in the run scripts, and the NIC address + `cpu_core`s in the YAMLs.

This was developed and tested with two hosts connected with a pair of 400 GbE NVIDIA ConnectX-7.

- **Receiver** — RTX 5070 (Blackwell); runs the correlator. GeForce can't GPUDirect, so we use host DRAM.
- **Transmitter** — RTX A6000 (Ampere); streams the analytic-sky TX from host DRAM at line rate.


## Run

Build on both hosts, then run the correlator on the receiver and the signal source on the transmitter:

```bash
bash scripts/build.sh    # rx_host_corr + peek32 + tx_host (host-memory sky, line rate)
bash scripts/run_rx.sh   # receiver:    correlator -> /dev/shm/corr32
bash scripts/run_tx_host.sh  # transmitter: generate synthetic packets (~380 GbE)
./peek32 120             # view a channel of the image cube (120 = high freq, bright planet)
```

You might need to prevent idling on GPUs with `bash scripts/pin-clocks.sh on` (and `off` after).

`run_tx_host.sh` streams the analytic sky from **host memory at line rate (~380 GbE)** into the `run_rx.sh` correlator (`imissed=0`) — a correct star + orbiting planet imaged end-to-end at the link rate (host DRAM on both sides), paced at 380 G via `pacing_mbps` in `tx_host.yaml`.

The live image is just a monitor. The science product is the integrated visibility cube `V` — a real deployment writes that to disk (`bash scripts/run_rx.sh --dump /data/v.f32`) and images offline. `--flush N` trades live-view smoothness (low, default 4) against peak throughput (raise it).

## Configuration

The YAMLs are [DAQIRI](https://github.com/NVIDIA/daqiri) stream configs (the `daqiri.cfg` block).

- **`rx_beamform_host.yaml`** — host-bounce capture on the receiver. Consumer GeForce GPUs can't GPUDirect, so in this example we bounce off host with `kind: "huge"` (host hugepages), with `engine: "ibverbs"` (MPRQ DevX), a single RX queue, and a flow rule steering `udp_dst: 4096` to it.
- **`tx_host.yaml`** — the line-rate host TX (`run_tx_host.sh`): `kind: "huge"` (host hugepages), `num_bufs: 16384` (multiple of 256, deep enough for the in-flight TX window), `pacing_mbps: 380000` to cap at 380 G.

Adjust these for your hardware: the NIC PCIe address (`0000:c7:00.0`), the `cpu_core`/`master_core` assignments, and `num_bufs`/`buf_size` (sized here for the 8256 B jumbo heap).

The wire format itself (packet/heap sizes, the `seq` field offset, packets-per-batch) lives in **two** places: the YAMLs above, which configure DAQIRI's transport, and `src/config.h`, the compile-time `#define`s the `tx`/`rx` kernels build against. If you change the format, you need to update both.
