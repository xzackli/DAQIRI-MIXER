# Full-field correlator (single RTX 5070, ~98% of 400 GbE)

A real-time int8 tensor-core covariance correlator on one RTX 5070, fed by a 400 GbE F-engine stream: it computes per-channel visibilities `V = X·Xᴴ` and images them as a 128-channel 32×32 cube. The 16×16 array is filled and Nyquist-sampled, so one batched cuFFT of `V` forms *every* beam in the field of view at once. The analytic-sky transmitter is `bf_tx_fp8.cu` (a test signal source, not part of the correlator).

## Run

```bash
bash build.sh                    # RX + readers (sm_120a, RTX 5070) and TX (sm_86, A6000)
bash line-rate-setup.sh on       # pin the 5070 clocks before a throughput run (off after)
bash run_verify_corr.sh          # live sky: star + orbiting planet, 128-channel cube
bash run_thru_corr.sh fire 0 25  # firehose throughput (NIC rate + imissed)
bash run_test_spectral.sh        # bf_spectest: per-channel slope == c/127, sum-of-channels == broadband
```
