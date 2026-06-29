# DAQIRI-MIXER — RFSoC 4x2 → GPU ULA pipeline: outstanding items
_As of 2026-06-25. What's PROVEN: F-engine channelizes on silicon (fe256), GPU X-engine +
transport + byte contract validated end-to-end (loopback), MTS root-caused, gain-staging measured._

## 1. FPGA streaming graft — DIAGNOSIS CRACKED (ordinary wiring bug); clean rebuild underway (agent a1269998)
Real ADC → F-engine → int8 → corner-turn → packetizer → 100GbE. Build failed at
`onehundred_gbe/tx_dest_ip` "Inheriting a sample time is not supported."
- **NOT a 100G/FFT incompatibility** (confirmed by CASPER expert Wei Liu + the CASPER mailing list: the IDENTICAL
  error appears in stock `snap_tut_corr`; per CASPER dev Kocz the erroring block is the VICTIM — the cause is an
  UPSTREAM signal stuck at `-1`/inherited). **Stock `stream4` builds clean and its OWN framing already runs at
  `[1000000]`** → the FFT subrate is FINE. (Six efforts mis-blamed the subrate, ata_snap, the gbe block, etc.)
- **Real bug:** swapping stream4's always-valid raw-ADC front-end for the F-engine left the packetizer framing
  (`tx_valid`/`tx_eof`/enable + some `From`/`Goto` tags) without a properly-rated driver → `-1`. The corner-turn
  is proven clean. The contaminated `strm1a-d` lineage is too sim-gateway-dense to patch.
- **Fix (clean rebuild from stock stream4, minimal diff):** start from provably-clean stock `stream4`, keep ALL its
  framing untouched, insert the data path (corner-turn → requant → F-engine) in stages, **compiling after each** to
  localize any `-1`. Drive the corner-turn read from stream4's existing system-rate cadence. Then build `.fpg` (1-input).

## 2. 4-input coherence (needed only for a real ANGLE demo, not noise-plumbing)
- [ ] Enable `t224_enable_mts` + `t226_enable_mts` in the graft's rfdc yellow block
      (builds PL+Analog SYSREF, marker/DTC). Currently OFF → `run_mts` fails 0x200.
- [ ] After programming: `run_mts(tile_mask=0b0101)` to sync tiles 224+226.

## 3. Physical signal source (currently the inputs are quiet/terminated)
- [ ] Feed the 4 SMAs a **coherent analog signal** — a split tone with progressive phase delay =
      a source at a known angle. Without this there is nothing for the ULA to image
      (measured: raw int8 ≈ 0, signal ~0.4% of ADC full-scale).

## 4. Gain-staging confirmation (the #1 measured risk)
- [ ] Verify the graft's post-FFT `sw_reg` requant gain (`Fix_18_12`, up to ~64×) recovers the
      weak signal that stream4's crude high-byte munge cannot (needs ~48 dB; DSA+QMC only ~29 dB).

## 5. End-to-end hardware demo (all downstream pieces already proven)
- [ ] Program graft → board channelizes+requants int8 → 100GbE → CX-5 (digilab-transmit) →
      `rx_ula_corr` (deployed, sm_86) → freq×angle image via `peek_ula`.
      Transport, GPU X-engine, and the 8256-B wire contract are all validated; this is the payoff step.

## Notes / already handled
- fe256 `sync_gen` mask bug (2048 vs 256) — harmless to the spectrometer, already FIXED in strm1.
- Buildable artifacts in hand: `rfsoc4x2_fe256_*.fpg` (F-engine, timing MET, HW-confirmed),
  `rfsoc4x2_stream4_i8_hb_*.fpg` (raw 4-input int8 100GbE, timing MET).
- Full graft diagnosis: `scratchpad/GRAFT_ASSEMBLY_NOTES.md`; HW findings: memory `daqiri-rfsoc-hw-validation`.

## Separate track — digilab transport box (not the RFSoC; see memory `daqiri-followups`)
- [ ] Reboot persistence (`ens7np0` admin-down, hugepages reset, CPU governors, GPU clock lock).
- These are the 400G GPUDirect/beamformer-demo boxes, independent of the RFSoC ingest above.
