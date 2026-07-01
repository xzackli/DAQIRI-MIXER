# RFSoC `feng4el` GPU RX

Date: 2026-07-01

## Purpose

Receive the real four-element CASPER `feng4el` stream directly with DAQIRI on
`digilab-transmit`, assemble element-tagged packets on the GPU, form per-channel
4x4 covariance, and publish the existing ULA beam image to `/corr_ula`.

This is separate from the older synthetic 8256-byte ULA path.

## Wire Contract

The RFSoC sends to `digilab-transmit:ens5f0np0`.

- NIC PCI address: `0000:17:00.0`
- NIC MAC: `b8:ce:f6:e5:6b:5a`
- UDP destination port: `60000`
- UDP payload length: `640` bytes
- CASPER header: first `64` bytes of UDP payload
- `seq`: big-endian `uint32` at UDP payload byte `48`
- `elem`: `uint8` at UDP payload byte `52`
- Active spectrum: first `512` bytes after the 64-byte CASPER header
- DAQIRI raw pointer includes Ethernet + IPv4 + UDP, so receiver offsets are:
  - `seq` at frame byte `90`
  - `elem` at frame byte `94`
  - active spectrum at frame byte `106`

The hardware capture showed tags cycling `0,1,2,3` and `seq % 4 == elem`.

## Files

- `src/config_feng4el.h`
- `src/rx_feng4el_corr.cu`
- `rx_feng4el_host.yaml`
- `scripts/run_rx_feng4el.sh`

Build only this target:

```sh
docker run --rm -v "$PWD":/work -w /work --entrypoint bash daqiri:local -lc \
'DQ="-I/opt/daqiri/include -L/opt/daqiri/lib -ldaqiri -lcuda -L/usr/local/cuda/lib64/stubs -Xlinker -rpath -Xlinker /opt/daqiri/lib -lcudart -lrt -lpthread"; nvcc -O3 -std=c++17 -arch=sm_86 src/rx_feng4el_corr.cu $DQ -lcufft -o rx_feng4el_corr_sm86'
```

Run on `digilab-transmit`:

```sh
cd ~/DAQIRI-MIXER
./scripts/run_rx_feng4el.sh --seconds 4 --fps 2 --device 0
```

## Live Test

With the RFSoC left streaming `feng4el_2026-06-30_1943.fpg` to `10.0.0.2:60000`,
the GPU receiver ran successfully on `digilab-transmit`:

- DAQIRI flow: `udp_dst=60000`
- RX packets: `2,839,552`
- CQE errors: `0`
- App-ring full drops: `0`
- GPU snapshots integrated: `446,151`
- `imissed=0`

Representative output:

```text
[ula] frame 0 snaps=48195 angle=-38.7deg ch=128 vmax=8.9e+07 imissed=0
[ula] frame 2 snaps=161415 angle=+43.4deg ch=128 vmax=9.7e+07 imissed=0
[ula] frame 4 snaps=276165 angle=-3.6deg ch=128 vmax=2.1e+08 imissed=0
[ula] frame 6 snaps=391275 angle=-9.0deg ch=128 vmax=5.8e+07 imissed=0
[ula] stop after 7 frames; snaps=446151 imissed=0
```

`rx_meta_buffers: 65536` is required for this small-packet 3.56 Mpps stream; the
default metadata pool produces `metadata pool exhausted` log spam.

## Caveat

This proves live RFSoC packet ingest into GPU covariance/beamforming. The displayed
angle is not yet a calibrated antenna result. The hardware capture showed live RFDC
tags `elem0` and `elem2`; do a one-cable-at-a-time physical mapping and then add
per-element phase calibration before treating the beam angle as a science value.
