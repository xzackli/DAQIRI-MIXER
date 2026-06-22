# DAQIRI-MIXER

![star + orbiting planet, imaged from V=X·Xᴴ](demo.gif)

A real-time int8 tensor-core covariance correlator on one RTX 5070, fed by a 400 GbE F-engine stream at ~98% of line rate: it computes per-channel visibilities `V = X·Xᴴ` and images them as a 128-channel 32×32 cube. The 16×16 array is filled and Nyquist-sampled, so one batched cuFFT of `V` forms *every* beam in the field of view at once (above: a star at field center plus an orbiting planet, one channel of the cube). The analytic-sky transmitter `bf_tx_fp8.cu` is a test signal source, not part of the correlator.

## Run

Build on both hosts, then run the correlator on the receiver (RTX 5070) and the signal source on the transmitter (A6000):

```bash
bash build.sh        # bf_rx_host_corr + bf_peek32 (sm_120a) and bf_tx_fp8 (sm_86)
bash run_rx.sh       # receiver:    correlator -> /dev/shm/bf_corr32
bash run_tx.sh       # transmitter: analytic sky (star + orbiting planet)
./bf_peek32 120      # view a channel of the image cube (120 = high freq, bright planet)
```

For full line rate, pin the receiver GPU clocks first — the 5070 idles its PCIe link to Gen1 otherwise.
