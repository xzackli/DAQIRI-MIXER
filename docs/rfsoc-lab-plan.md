# RFSoC 4x2 → MIXER: lab plan (next session)

Goal: close the loop — **board ADC → 100 GbE → ConnectX-7 → GPU correlator** — with the 4-input int8 half-band design we built & verified.

## Facts / assets
- **Board:** `192.168.2.101` (`rfsoc`, control = 1 GbE), SSH `casper@192.168.2.101` (interactive pw).
- **casperfpga:** `~/miniconda3/envs/casper/bin/python` on **acme2** (v0.4.4.dev).
- **Bitstream:** `acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/rfsoc4x2_stream4_i8_hb/outputs/rfsoc4x2_stream4_i8_hb_2026-06-23_1858.fpg` (built, timing-clean, register map verified). FPGA currently **deprogrammed/idle**.
- **Data sink:** digilab `ens7np0` (ConnectX-7, 400G, MTU 9082, MAC `a0:88:c2:0d:5e:28` = the design's configured dest; dest IP `10.0.0.2:4096`).
- **On-wire format:** 8298 B jumbo; seq = uint64-LE @ byte 42; payload @ 106; per 256-bit unit = `[ADC0][ADC1][ADC2][ADC3]`, each `[I Q I Q I Q I Q]` int8 high-byte, decimated. NOTE: current sample order is **7,5,3,1 newest-first** (not 0,2,4,6) — fine for a zero-lag correlator; rebuild with munge `order=[14 30 10 26 6 22 2 18]` if a clean oldest-first layout is wanted.

## Steps
1. **Power/program.** Power on board if off. Program:
   `cd ~/src/tutorials_devel/rfsoc/tut_onehundred_gbe && ~/miniconda3/envs/casper/bin/python` →
   `fpga=casperfpga.CasperFpga('192.168.2.101'); fpga.upload_to_ram_and_program('rfsoc4x2_stream4_i8_hb/outputs/...1858.fpg'); fpga.get_system_information(...)`.
   Confirm `sys_clkcounter` ticks + `onehundred_gbe_gmac_reg_tx_packet_count` climbs.
2. **Cable** board QSFP100 → ConnectX-7 `ens7np0` (or a free CX-7 port).
3. **Link up.** Confirm board `onehundred_gbe_gmac_reg_phy_status_*` ≠ 0 and `ens7np0` RX counters climb. (RS-FEC default on; MTU 9000 on the NIC.)
4. **ARP.** Set the board's dest MAC for `10.0.0.2 → a0:88:c2:0d:5e:28` via `onehundred_gbe_gmac_arp_cache_*` registers (see Agent-2 runbook).
5. **Capture + sanity.** Raw-socket capture on the digilab side (adapt `tut_100g_catcher.py`). Check: packet size 8298 B, seq continuity, and the **int8 histogram** per ADC.
   - **Gain-staging (top risk):** if the histogram is a near-zero spike, bump RFDC digital gain (QMC/coarse) so signal RMS ≈ 10–30 int8 counts in the *top byte* (see Agent-2 runbook). If railing at ±127, reduce gain.
6. **Into MIXER.** Point the RX at the new format (a CASPER `config.h` variant: 4 antennas, int8, seq@42 LE, payload@106) + GPU PFB/correlate. Start with autocorrelations / a tone to confirm signal before correlating.

## Concrete commands (from config review)

Preamble (from acme2): `fpga=casperfpga.CasperFpga("192.168.2.101"); fpga.get_system_information()`;
`rfdc=fpga.adcs["rfdc"]`; `eth=fpga.gbes["onehundred_gbe"]`. First print `list(fpga.adcs)`, `list(fpga.gbes)`, `fpga.listdev()` to confirm keys/prefix.

**Gain-staging** (no on-board snapshot — `get_adc_snapshot` is NotImplemented; histogram the *captured* int8 instead):
- Primary = DSA (analog atten, 0–27 dB/1 dB, *lower = more gain*): `rfdc.set_dsa(tile,blk,6)` for tile in (0,2)=224/226, blk in (0,1); decrease dB to raise RMS.
- Fine = QMC: `rfdc.set_qmc_settings(t,b,rfdc.ADC_TILE,0,0.0,1,gain,0,rfdc.EVNT_SRC_TILE); rfdc.update_event(t,b,rfdc.ADC_TILE,rfdc.EVENT_QMC)`.
- Do NOT use `set_mixer_scale` for gain (it's the fine-mixer overflow guard; leave AUTO). Target int8 RMS ≈ 10–30, peaks < ~100.

**MTS sync** (tiles 224+226; re-run after EVERY program): `rfdc.run_mts(tile_mask=0b0101); rfdc.get_mts_report()`. Needed for valid inter-input correlation phase; optional if only power spectra.

**ARP** (pass plain MAC int — it byte-swaps internally): `eth.set_single_arp_entry("10.0.0.2", 0xa088c20d5e28); print(eth.get_arp_details(N=8))`.

**Link check** (no helper — raw regs): `fpga.read_uint(P+"gmac_reg_phy_status_h"/"_l")` → stable nonzero = aligned (allow a few s for RS-FEC). Watch `gmac_reg_tx_packet_count` climb.

**NIC (run ON digilab):** `sudo ip link set ens7np0 mtu 9000; sudo ethtool --set-fec ens7np0 encoding rs; sudo ip addr add 10.0.0.2/24 dev ens7np0; sudo ip link set ens7np0 up`.

**Capture (root on digilab, raw AF_PACKET):** recv 8298 B; filter dst IP @ `p[30:34]`==10.0.0.2; **seq = `struct.unpack("<Q", p[42:50])`** (uint64 LE); **payload = `np.frombuffer(p[106:8298], np.int8)`** (int8, NOT int16!); check `np.diff(seq)!=1` for drops and `data.std()`/`abs.max()` for gain.

**Top gotchas:** re-run MTS after each program; RS-FEC mismatch = silent no-link (force `rs` on NIC); MTU must be ≥9000 (jumbo) or OS drops before socket; parse int8 not int16; don't re-upload the fpg if already programmed+synced (resets MTS/ARP).

## Next artifact to build (recommended)
A **`tx_casper_host.cu`** — adapt `src/tx_host.cu` (~70% reusable: the whole DAQIRI burst/pre-fill engine) to emit the new 4-input int8 / seq@42-LE / payload@106 / 8298 B format with a **simple synthetic payload (CW tone or ramp, NOT a sky)**. Validates the MIXER RX's new packet parse + reorder for the CASPER format with **zero hardware**. (4 inputs can't image a sky — keep `tx_host.cu` as-is for the 256-antenna imaging science; don't fake antennas.) A fabric DDS loopback (CW tone, verifiable vs `bf_spectest` slope==c/127) is the later hardware-in-the-loop check.

## Known caveats (verified by agent review)
- Sample order 7,5,3,1 newest-first (above) — RX must match, or rebuild clean.
- Naked decimation **aliases** (demo-OK; halfband FIR or RFDC built-in halfband for spectral science).
- int8 high-byte truncation → −0.5 LSB DC bias on autocorr (mean-subtract, or round).
- 4 ADCs must be SYSREF-synced (tiles 224/226) for valid inter-input phase (see Agent-2 runbook).
