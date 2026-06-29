# PFB + 100 GbE F-engine — clean-rebuild design (2026-06-25)

## COVERAGE PLAN (2026-06-26 night): all-channels first, SUB-BAND select as fallback
manas100g4 streams clean 8256B jumbo packets but SPARSE (128 of 2048 words = manas's downselect trigger
cns_mux_en1/3 vs Counter3). Goal = full per-spectrum coverage (manas100g5). IF full coverage hits issues
(tx overflow / corner-turn read pattern won't stream all words cleanly / framing alignment), FALLBACK =
**SUB-BAND CHANNEL SELECT**: a channel-select stage streaming a contiguous window of N channels of interest
(not the full 32768) before the packetizer. STANDARD CASPER pattern (ata_snap/ALPACA chan_reorder+select;
tut_spec channel-select readout) — lower data rate, scientifically focused. Per-packet still = one coherent
[selected-ch x time] int8 heap + seq. (User directive 2026-06-26.)

## ✅✅✅ PACKET-FRAMING FIXED + HW-VERIFIED (2026-06-26 night) — manas100g4 emits clean 8256 B jumbo frames
DELIVERABLE: **acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas100g4/outputs/manas100g4_2026-06-26_2153.fpg**
(+.dtbo). JASPER_DONE_OK; TIMING MET (WNS=+0.182ns, TNS=0, WHS=+0.010ns, THS=0, no violations).
HW-VERIFIED on board rfsoc 192.168.2.101 + CX-5 ens5f0np0 (digilab-transmit):
- Board programs + streams: tx_packet_count climbs steadily ~135k pps.
- **CX-5 RX size-bucket delta (the proof): over 6 s, `rx_8192_to_10239_bytes_phy` += 722,173 pkts (the JUMBO
  8256 B bucket) while `rx_65_to_127_bytes_phy` += 0 (the OLD broken-tiny-packet bucket is now FLAT) and
  `rx_discards_phy` += 0 (no drops; MTU 9086 ≥ 8256).** seq = Counter1 (64b free-running) → 1 inc/packet,
  monotonic by construction (unchanged from manas100g3). Bring-up = ~/stream_manas4.py; seq/tx check = ~/seqchk.py.
manas100g3.slx + its fpg untouched (proven baseline fallback). Bounded goal DONE: clean fixed-size 8256 B
jumbo packets + monotonic seq. (Deferred: full per-channel coverage = more packets; planar re/im content layout.)

## 🩹 PACKET-FRAMING FIX (2026-06-26 night) — manas100g4 = manas100g3 with 8192 B-payload jumbo frames
THE BUG (manas100g3 emitted 1-word/tiny packets, not 8 KB frames): the packetizer is the manas
sync-anchored corner-turn read-out. The per-packet length is set by TWO `pulse_ext` blocks at the
top level:
- **`pulse_ext4.pulse_len`** = DPRAM-read window = DATA words per packet.
- **`pulse_ext3.pulse_len`** = tx_valid window = data + 1 seq-header word.
tx_valid = pulse_ext3 output (gated by enable_tx via Mux4→data_delay2→Goto"tx_valid"); tx_end_of_frame
= `edge_detect` (Falling) on that same tx_valid → ONE eof per valid-window. seq = Counter1 (64-bit free-
running, period 1) → Concat1(64b) → Mux3 word-0. The 64b corner-turn word is widened to 512b for the gbe
by `txd512` = Concat(c_pad448[448b 0] ++ Delay4[64b]) → onehundred_gbe.tx_data. So each gbe wire word =
64 BYTES (8 B real corner-turn data in the LSB + 56 B zero pad).
ROOT CAUSE: the manas retarget kept manas's 64-bit/10G framing math — **pulse_ext3=1025, pulse_ext4=1024**
(= 1024 data words × 8 B = 8192 B payload AT 64-BIT WORDS). But the 100G word is 512-bit/64-byte, so 1024
words = 65536 B → a 65 KB frame, far over the 9 KB MTU → the CMAC mis-framed → tiny/broken packets on the wire.
THE FIX (manas100g4.slx, saved from manas100g3): rescale word-count 64b→512b: **pulse_ext4 1024→128**
(128 × 64 B = 8192 B payload), **pulse_ext3 1025→129** (128 data + 1 seq header → 129 × 64 B = 8256 B frame).
TWO scalar edits, nothing else. COMPILES CLEAN (no -1; tx path Mux3/txd512/pulse_ext3/4/Counter3/5 all
[1000000 0]). The trigger constants (cns_mux_en1=4095-256, cns_mux_en3=2047-256 vs Counter3) are UNCHANGED
→ packets are now sparse (128 of every 2048 words) but CLEAN/fixed-size/monotonic-seq — exactly the bounded
goal. Full per-channel coverage (more packets) + planar re/im content layout = the deferred follow-up.
CX-5 (digilab-transmit ens5f0np0) MTU already 9086 (≥9000) → jumbo 8256 B frames will NOT be dropped.
Bring-up = ~/stream_manas4.py (auto-finds newest manas100g4 fpg). Verify = ~/cx5_buckets.sh delta on
digilab-transmit: a clean fix moves the rx-size delta into `rx_8192_to_10239_bytes_phy` (was `rx_65_to_127`).

## ✅✅✅ SOLVED — DELIVERABLE .fpg BUILT + TIMING-CLOSED (2026-06-26)
**acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas100g3/outputs/manas100g3_2026-06-26_1452.fpg**
(+.dtbo). Model: manas100g3.slx. PFB+FFT → 100GbE F-engine on RFSoC 4x2, SINGLE-core (onehundred_gbe only).
- JASPER_DONE_OK; TIMING MET (WNS=+0.433ns, WHS=+0.010ns, TNS/THS=0, no violations).
- Regmap: rfdc(0xa0000000) + onehundred_gbe(0xa00a0000, full gmac set + ARP) + F-engine ctrl regs
  (fft_shift, acc_len, acc_cnt, cnt_rst, sync/sync_cnt, dest_ip/dest_port, eth_en/eth_rst/eth_first_sync,
  snapshot_ctrl, test_mode, adc_snapshot_ss, sys). NO ten_gbe regs (true single-core).
- **THE FINAL ANCHOR FIX (the [Inf]→[1000000] imposer that replaced the ten_gbe hack):** set
  **`explicit_period = on, period = 1` on the corner-turn `Dual Port RAM1` block itself.** ONE native CASPER
  setting, no extra blocks. Root cause: DPRAM had explicit_period=off (inheriting→[Inf]) while its read-addr
  Counter5 was explicit_period=on/1; pinning the DPRAM's own period makes its read output [1000000 0], which
  propagates through Delay4→txd512→onehundred_gbe. (A snapshot did NOT pull — a BRAM data input inherits, it
  doesn't impose; onehundred_gbe's tx_data Gateway genuinely can't back-propagate a rate, unlike ten_gbe.)
- THE COMPLETE RECIPE (PFB+FFT→100GbE on rfsoc4x2): (1) build WHOLE-native at the F-engine rate, never graft
  onto a raw-ADC design; (2) bridge [Inf] FFT data→eth with a sync-anchored DPRAM corner-turn (addr/we from
  counters edge-triggered off the FFT sync); (3) set explicit_period=1 on the corner-turn DPRAM so its read
  output imposes [1000000] (onehundred_gbe can't pull it). manas_fpga (Kocz) was the template.
- REMAINING FOLLOW-UPS (refinements, NOT blockers): (a) half ADC bandwidth (128→64 slice; n_inputs=3 = full
  BW); (b) FFT size = 65536-pt (manas default; original target 256 — reconfigure FFTSize if needed); (c)
  program on board (192.168.2.101 via casperfpga) + verify channelized data over 100GbE → CX-5 → GPU.



User chose: **clean rebuild on ata_snap topology** (not debug-the-graft, not GPU hedge).
This doc is the durable plan; survives context compaction. Build on acme2.

## 🎉 CLEAN COMPILE ACHIEVED (2026-06-26) — manas100g2.slx = PFB+FFT→100GbE on rfsoc4x2, NO -1
acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/**manas100g2.slx** (manas_b4.slx = steps a+b checkpt).
Retargeted manas ZCU111/10G → rfsoc4x2/100G, COMPILES CLEAN. onehundred_gbe: tx_data=UFix_512_0 [1000000 0],
tx_dest_ip=UFix_32_0 [1000000 0], all tx ports [1000000 0]; rfdc out=[1 0]; fft+DPRAM corner-turn=[1000000 0].
Steps: (a) swap ZCU111 platform→RFSoC4x2 (delete xsg config+token, add from fengv_clean); strip manas's sim-only
debug taps (o1..o13/Gateway Out23/4 Scopes) on the [Inf] FFT data + terminate fft overflow. (b) delete part-pinned
ZCU111 rfdc, add rfsoc4x2 rfdc; ADC reconcile = SLICE rfsoc4x2 128b/8-samp [63:0]→manas's 64b/4-samp munge (keeps
PFB/FFT n_inputs=2; HALF bandwidth — n_inputs=3 full-BW is a follow-up); DRIVE rfdc AXI inputs 7-10 with period-1
anchor Constants (unconnected rfdc inputs = [Inf] poison). (c) ten_gbe→onehundred_gbe; corner-turn tx_data 64→512b
via Concat(64b CT-data LSB + 448b zero pad MSB); dest_port Slice 32→16; tx_byte_enable=64b ones; map 6 framing sigs.

### ⚠️ KEY NEW FINDING — onehundred_gbe does NOT pull the rate; ten_gbe DOES (the real 10G-vs-100G asymmetry)
The FFT/corner-turn region is intrinsically [Inf] until an assigned-ST sink PULLS it to [1000000].
**ten_gbe's tx_data port PULLS (imposes) the rate; onehundred_gbe's tx_data REQUIRES its input PRE-RESOLVED
and does NOT pull.** (This vindicates the long-dismissed Stage-A "onehundred_gbe-specific" intuition — there IS
a real asymmetry.) Ruled out as re-raters (all still -1 at tx_data): Convert 64→512, Concat-pad, Assert(rate=on,
period=1), Register reclock, software_register. THE WORKING ANCHOR in manas100g2 = a CO-RESIDENT ten_gbe kept
purely as the [1000000] rate imposer (its tx_data fed by the corner-turn); with it present, onehundred_gbe
inherits cleanly. Deleting ten_gbe → -1 returns at eth_first_sync/sim_out_reg_gw (confirms ten_gbe is the unique
imposer; the vacc/snapshot BRAMs do NOT pull).
=> CAVEAT for the .fpg: the design has BOTH ten_gbe (anchor) + onehundred_gbe (output) cores. For a clean
single-core build, replace the ten_gbe anchor with a SYNTHESIZABLE [1000000]-pulling sink — a snap_tut_corr-style
bitfield_snapshot on the FFT data whose we/addr is driven from the [1000000] sync (manas's existing snapshots
don't pull; one wired directly on the FFT data with sync-driven we should). OR test whether the co-resident
ten_gbe builds benign (risk: rfsoc4x2 transceiver-site conflict with the 100G QSFP). TODO before/at .fpg build.
TODO follow-ups: (1) single-core anchor (snapshot vs ten_gbe-benign), (2) n_inputs=3 full ADC bandwidth,
(3) the 256-pt-vs-65536-pt FFT size (manas is FFTSize=16=65536pt; our target was 256 — reconfigure if needed).

## 🏁 PATH A RESULT + FINAL SYNTHESIS (2026-06-26) — the complete "what was hard" answer
PATH A retargeted manas WHOLE. Result: manas's design is FULLY PORTABLE — pfb_fir_real, fft_wideband_real,
the sync-anchored DPRAM corner-turn, ten_gbe, ALL CASPER/xps libs resolve in our mlib_devel unmodified.
manas COMPILES CLEAN on ZCU111 under our toolchain (after 2 version fixes) → **the corner-turn bridges
FFT→eth with NO -1 in a whole-native-rate design** (the opposite of Path B's graft). Friction was ONLY at:
  (1) Toolchain skew: manas is R2022a — won't load in R2021a. Fix = zip-patch the slx version stamps
      (coreProperties/configSet R2022a→R2021a) + retarget 9195 top-level blocks hdlBasic/X → xbsIndex_r4/X
      (the 2022 basic-blockset lib name 'hdlBasic' doesn't exist in 2021.1; CASPER masked-subsystem internals
      already used xbsIndex_r4 and were fine).
  (2) Platform + rfdc are HARD-PINNED to the source part: xsg core config hw_sys is a locked dropdown
      (ZCU111:xczu28dr only) → can't set rfsoc4x2 in place, must delete+add fresh. rfdc mask callback
      update_rfdc_clocking rejects xczu48dr ("Not a valid Xilinx RFSoC part") → rfdc must be REPLACED.
  (3) ADC geometry mismatch: manas rfdc=2 muxed lanes→64b/4-samp PFB feed; rfsoc4x2 rfdc=10 outs/128b/8-samp.
      Front-end (munge/bus_expand/PFB n_inputs) must absorb 128b/8-samp → manas's 64b/4-samp, or rebuild PFB.
  manasport.slx left in clean-compiling ZCU111 state; rfsoc4x2 swap blocked at the part-bound rfdc.

### THE COMPLETE "WHAT WAS HARD" ANSWER (PATH A vs PATH B):
1. **NOT hard = the FFT→100G rate bridge.** The sync-anchored DPRAM corner-turn solves the [Inf]→rated
   problem cleanly — proven BOTH in isolation (Path B ct_iso) AND in a whole design (Path A manas on ZCU111).
2. **Hard #1 (fundamental) = you can't GRAFT a PFB+FFT into a pre-built design.** The [Inf] FFT region
   globally poisons the HOST's pre-existing assigned-ST sim sinks (debug snapshots / sim-swreg gateways /
   gbe sim-status). Proven by Path B: corner-turn works in isolation but the vdif graft still aborts, and the
   -1 hops to an unrelated VDIF sim-swreg when the gbe is deleted. => MUST build/retarget WHOLE-native-rate.
3. **Hard #2 (the real remaining engineering) = building/retargeting the whole native design:** platform +
   rfdc yellow blocks are part-pinned (delete-replace, not reconfigure); ADC port-geometry/sample-width
   reconciliation; gbe ten→onehundred + corner-turn/tx_data 64→512b; + foreign-toolchain version skew.

### → CONCRETE PATH TO THE .fpg (most reliable): FINISH PATH A.
manasport.slx is clean-compiling (ZCU111). Remaining BOUNDED steps (no more mystery -1):
  (a) delete manas's xsg core config + rfdc; add rfsoc4x2 RFSoC4x2 xsg core config + rfdc (from fengv_clean).
  (b) reconcile ADC: rfsoc4x2 rfdc 128b/8-samp → slice/feed manas's PFB (or set manas PFB n_inputs=3/8-samp).
  (c) ten_gbe→onehundred_gbe; re-dimension the DPRAM corner-turn data port + tx_data Mux/Concat 64→512b
      (sync-anchored counter→DPRAM→tx_valid topology transfers directly; only widths/depths change); map
      manas's 6 framing sigs onto onehundred_gbe's 10 inputs (+byte_enable).
  (d) compile clean → casper_build.sh → .fpg + timing.
ALT (if manas front-end surgery is messy): build a FRESH minimal rfsoc4x2 model native at the F-engine rate
= rfsoc4x2 platform+rfdc + pfb_fir + fft_wideband_real + manas's DPRAM corner-turn cluster + onehundred_gbe,
NO debug snapshots / stray sim-swregs (nothing for [Inf] to poison). Route ALL fft outputs (data→corner-turn,
sync→counters, ovf→term).

## 🎯🎯 DEFINITIVE "WHAT WAS HARD" ANSWER (2026-06-26, PATH B result)
PATH B grafted manas's sync-anchored DPRAM corner-turn into the vdif fengv2 base. Two crisp facts:
1. **The DPRAM corner-turn bridge WORKS — proven in ISOLATION** (ct_iso.slx COMPILES CLEAN; CT_dpram
   CompiledSampleTime = [1000000 0], the wr/rd-addr counters + edge-detect all [1000000 0], DPRAM-read
   output resolves [1 0]). So the [Inf]→rated FFT-to-Ethernet bridge is REAL, reproducible, NOT the hard part.
2. **But grafting it into the vdif base STILL aborts** — and DECISIVELY: deleting onehundred_gbe entirely,
   the -1 HOPS to `pps_count_sec/sim_out_reg_gw` (a sim sw-reg gateway in the VDIF base, UNRELATED to the
   corner-turn or gbe). With the CT-read fully detached from the gbe: still aborts.
=> **THE HARD THING IS NOT THE FFT→100G BRIDGE. It is that you CANNOT GRAFT a PFB+FFT into a pre-built CASPER
   design.** The [Inf] FFT-data region globally poisons the HOST design's pre-existing assigned-sample-time
   SIM sinks (debug snapshots, sim sw-reg gateways like sim_out_reg_gw, the gbe sim-status ports) — the GLOBAL
   Simulink rate graph becomes unresolvable. A local data-path bridge (corner-turn) re-rates the data but does
   NOT quarantine those host sinks. manas/snap_tut_corr/ata_snap compile ONLY because their ENTIRE model is
   built native at the F-engine rate — they contain NO [1 0]-rooted sim-swreg/snapshot island for the [Inf]
   region to poison. THIS is why every graft (stream_rfdc_100g, strm2a2, vdif) failed across ~13 attempts, and
   why the bridge-in-isolation works but the graft doesn't.
=> THE ONLY CLEAN ROUTE: build/retarget the WHOLE design native at the F-engine rate (PATH A = retarget manas
   whole; or build from scratch). NOT a graft. R2022a gotcha: manas_spec_244b.slx is R2022a — won't open in
   acme2 R2021a; cluster reverse-engineered from .slx XML. Counter explicit_period enum = on/off (NOT 'Explicit').
   Artifacts: ct_iso.slx (bridge works), rfsoc4x2_fengv2.slx (graft, aborts), fengv2_ctbak.slx.

## 🏆🏆 THE PROVEN MECHANISM — jkocz/manas_fpga (cloned acme2:/tmp/manas_fpga) — 2026-06-26
Kocz's COMPLETE CASPER PFB+FFT→Ethernet F-engine (manas_spec_244b.slx + .fpg, runs). ZCU111/**10GbE**
(NOT rfsoc4x2/100G) so not a drop-in — but it reveals THE EXACT FFT→eth bridge that solves our [Inf]→sink -1:
**A Dual-Port-RAM corner-turn whose read/write ADDRESS + WRITE-ENABLE are generated by counters
EDGE-TRIGGERED off the delay-aligned FFT `sync` output (the [1000000] anchor).** The [Inf] FFT data ONLY
enters via the DPRAM read port (whose addressing lives in the sync-anchored [1000000] domain) → the gbe
NEVER sees naked [Inf]. tx_valid/eof/seq all from the SAME sync-anchored counters. NO Assert ring at the
eth iface — the corner-turn IS the rate anchor.
=> CRUCIAL: earlier corner-turn attempts (strm2a2 ct_bram, the reorder double-buffer) "failed" because their
addressing used FREE-RUNNING counters, NOT FFT-SYNC-ANCHORED ones. The sync-anchoring is THE missing
ingredient. (My fengv2 register-with-en anchor is likely INSUFFICIENT — a Register gates but doesn't re-rate
[Inf]; a DPRAM read at a counter-driven rate DOES. If fengv2 fails, this is why.)
COPYABLE CLUSTER (manas system_root.xml): fft_wideband_real→Delay6→Delay9→Goto5(`fft_sync`); From(fft_sync)
→edge_detect2→Counter3/Counter5 → Dual Port RAM1 (addr+we) ; fft data Goto6/7→From14/12→complex_convert→
bus_create→DPRAM data-in ; DPRAM out→data_delay1→Goto_tx_data9→Mux3→tx_data ; tx_valid from Mux4←pulse_ext3
(Logical2) gated by enable_tx. seq = uint64-BE @ byte0 (Counter1→Concat1→Mux3); payload 8192B @ byte8; 8 pkts/
spectrum; dest_ip/dest_port = sw_regs. Config: pfb_fir_real pfbsize=16/4tap/n_inputs=2/16→18; fft_wideband_real
fftsize=16(65536pt)/n_inputs=2; PL 122.88MHz; ADC 3932.16 MSPS. Packet decoder: decode_packet.py.
THE BUILD PLAN (definitive): take manas's PFB+FFT+**sync-anchored-DPRAM-corner-turn** (proven to bridge
[Inf]→rated), retarget ZCU111→rfsoc4x2, re-dimension the DPRAM corner-turn + gbe for 512b/100G (use vdif's
proven onehundred_gbe + inp1 512b FIFO as the eth tail, OR swap manas's ten_gbe→onehundred_gbe). The
sync-anchored-counter→DPRAM→tx_valid topology transfers DIRECTLY. Render system_root.xml's eth cluster on
acme2 first to confirm the counter→eof wiring before porting.

## ✅✅ CONFIRMED EMPIRICALLY (2026-06-26 AM, fengv2 attempt): the Register/Assert rate-anchor is INSUFFICIENT — manas's prediction holds
Ran the prompt-prescribed "rate-anchor the quant 128b to [1000000] before the sink" experiment on acme2 to a
DECISIVE negative. Three downstream anchor mechanisms TESTED, ALL still abort with the canonical -1
(SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED, "Inheriting a sample time not supported"):
- **Xilinx Register, en = FFT sync (FE_fft Out1, [1000000]), data = FE_cat128 ([Inf]) → Gateway Out: ABORTS.**
  A Register gates WHEN it loads but does NOT re-rate [Inf]→[1000000]; the GW still sees inherited/[Inf].
- **Xilinx Assert(assert_rate=on, rate_source=Explicit, period=1) on FE_cat128 → Gateway Out: ABORTS.** The
  Assert creates a SECOND distinct rate, not a unification; the [Inf] data is unchanged.
- **Wiring the FFT sync (Out1, the [1000000] anchor) into a grounded Gateway Out (so the sync rate domain is
  resolvable, not floating) → gbe rx_overrun_ack STILL ABORTS.** Grounding the sync does not help.
DECISIVE ISOLATIONS on the fengv base (rfsoc4x2_fengv2.slx = fengv with the 4 debug bitfield_snapshots DELETED;
they tapped raw rfdc raw1/raw1a/raw2/raw2a — debug-only, safe to delete, and deleting them MOVED the -1 off the
snapshots):
- After deleting debug snapshots, fengv2 aborts at **onehundred_gbe/..._rx_overrun_ack** (gbe rx-side assigned-ST
  sink) — the -1 hopped from the snapshot BRAM to the gbe.
- **Feeding inp1.data_in from the RAW ADC (offset_binary, [1000000]) instead of FE_cat128 — i.e. F-engine data
  ENTIRELY OFF the data path — STILL aborts at the SAME gbe rx_overrun_ack.** => the abort is NOT the F-engine
  data routing into inp1; it is the mere PRESENCE of fft_wideband_real in the model.
- **Deleting fft_wideband_real + all quant consumers (keeping FE_busexp + FE_pfb, raw ADC into inp1) → COMPILES
  CLEAN (isofft.slx).** => pins the -1 EXACTLY to fft_wideband_real's [Inf] data outputs vs the gbe's [1000000]
  assigned-ST sinks. Matches the prior "fft_wideband_real ALONE aborts; pfb EXONERATED" isolation.
CONCLUSION: the fengv2 rate-anchor approach is DEAD (proven). [Inf]→sink cannot be fixed by any downstream
Register/Assert/sync-grounding. **The ONLY proven bridge is the manas_fpga sync-anchored Dual-Port-RAM corner-turn
(see top section).** fengv2.slx / isofft.slx left on acme2 as evidence. NEXT = build the manas DPRAM corner-turn
(retarget ZCU111→rfsoc4x2/100G), NOT another anchor on fengv. fengv_clean.slx remains the clean stubbed base.

## ✅ VERDICT (2026-06-26): the -1 is NOT pfb_fir — it's a [Inf]-rate fft/pfb DATA path hitting an ASSIGNED-ST sink
DECISIVE isolation harnesses on acme2 (rooted [1 0] sources → Gateway Outs, each compiled, CompiledSampleTime read):
- **pfb_fir_real ALONE (n_inputs=3,PFBSize=8,4tap,16→18) → Gateway Outs: COMPILES CLEAN.** All 9 outs [1000000 0].
- **pfb_fir_generic ALONE (n_streams=1,n_inputs=3,PFBSize=8) → Gateway Outs: COMPILES CLEAN.** All 9 outs [1000000 0].
  => **pfb_fir_real is EXONERATED. Both PFB blocks resolve clean in isolation.** The real-vs-generic lead was a RED HERRING
  (the only reason the first "real" harness aborted was the fft hung on it; the first "generic" harness was clean only
  because it had NO fft).
- **fft_wideband_real ALONE → Gateway Outs: ABORTS** with the canonical SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED "-1" at the
  LAST Gateway Out (gw6 for the 6-out FFTSize=8/n_inputs=3 config). Swept FFTSize=8/n_in=3, 8/2, 11/2 (snap's exact config)
  — **ALL abort identically.** Driving with clocked Counters instead of Constants: STILL aborts. Removing the load on the
  last port: the -1 HOPS to the next port (gw5). => global rate-resolution failure of the fft DATA outputs, not one port.
- **GROUND TRUTH — compiled snap_tut_corr (the WORKING model):** pfb_fir_generic / a0p0_1st_shift / fft_wideband_real
  **DATA outputs are ALL [Inf 0]; ONLY the sync output (OUT1) is [1000000 0].** snap compiles CLEAN with [Inf]-rate fft data
  outputs because those ports drive ordinary Xilinx blocks (bus_create / Goto), which ACCEPT [Inf]. A **Gateway Out** (and
  the gbe tx_dest_ip / bitfield_snapshot BRAM sinks) carry SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED → they REFUSE [Inf]/inherited
  → THAT is the -1.
- **ROOT CAUSE (final):** the fft_wideband_real (and pfb) DATA path is genuinely constant-rate **[Inf]** until clocked by
  downstream rate-defining logic. The -1 fires whenever an [Inf] fft data signal reaches an assigned-sample-time SINK
  (Gateway Out in the harness; gbe tx ports / snapshot BRAMs in feng2/3/4/v) WITHOUT a rate anchor in between. It is NOT
  pfb_fir_real, NOT a missing a0p0_1st_shift (that block's outputs are also [Inf]), NOT the fft config — it is the
  **[Inf] fft-data → assigned-ST sink junction**.
- **THE FIX (what snap does, what feng must do):** do NOT wire fft/quant data straight into an assigned-ST sink. Route the
  fft DATA outputs through the bus_create / reorder / Goto chain into a sink whose WRITE side supplies the rate — i.e. a
  snapshot BRAM whose we/addr is driven from the [1000000] sync/valid domain (snap's pattern), OR pin the gbe tx signals
  with Kocz's Assert(assert_rate=on,period=1) ring so the assigned ST is satisfied locally. Equivalently: the sync/valid
  ([1000000]) path must reach the sink alongside the [Inf] data so the data inherits a real rate at the write boundary.
  This is the SAME class as the Assert-ring fix already documented for tx_dest_ip — generalized: ANY assigned-ST sink fed
  by fft [Inf] data needs an explicit rate pin or a clocked write-enable.

## 🔬 KEY UNTESTED LEAD (2026-06-26): pfb_fir_REAL vs pfb_fir_GENERIC  [RESOLVED ABOVE — verdict: red herring]
The fengv isolation test proved the F-engine subgraph has an INTERNAL -1 (severed + Gateway Out still
aborts) — NOT vdif/inp1/sync. BUT the agent's "[1000000] presence poisons everything" is AGAIN the
oscillation trap: snap_tut_corr has pfb_fir_GENERIC + fft_wideband_real + bitfield snapshots at [1000000]
and COMPILES CLEAN. EVERY failed attempt (feng2/3/4/v) used **pfb_fir_REAL**; snap_tut_corr uses
**pfb_fir_generic** (+ a0p0_1st_shift FFT-shift block). UNTESTED hypothesis: pfb_fir_real (or its config/
drive) produces the internal unresolved rate; pfb_fir_generic does not. TEST: isolate pfb_fir_real-based
vs pfb_fir_generic-based F-engine (rooted [1 0] sources → Gateway Out), see which resolves clean. If
generic resolves → rebuild the F-engine with snap_tut_corr's exact blocks (pfb_fir_generic + a0p0_1st_shift
+ fft_wideband_real), then re-insert into fengv_clean (vdif_misc base, which compiles + whose inp1.data_in
natively wants [1000000]). fengv_clean.slx = the ready base. snap_tut_corr = the working F-engine source.

## ⛔ fengv (vdif_misc base) RESULT — 2026-06-26 — SAME WALL, NOW ON KOCZ'S BASE
Hypothesis: vdif_misc (rfsoc_vdif_v0_4) already mixes [1 0] data + [1000000] PPS-framing + 512b
onehundred_gbe and COMPILES, so inserting the [1000000] F-engine at inp1.data_in should be absorbed by
inp1's FIFO/gearbox. **DISPROVEN.** Built rfsoc4x2_fengv on acme2 (= rfsoc4x2_fengv_base, a pristine
vdif_misc copy). Findings:
- STEP 1 (pps stub) COMPILES CLEAN. Replaced the unresolved `rfsoc_pps` library link (xps_library/IO/
  rfsoc_pps, absent from mlib_devel; 1-in/1-out, output → edge_detect1, PPS-only not data) with a Xilinx
  Constant (Bool 0, explicit_period=on, period=1) wired to edge_detect1.in1. Clean compile, all rates
  resolved. Saved as **fengv_clean.slx** (the clean stubbed baseline — keep as fallback).
- ORIGINAL data path measured (in fengv_clean, compiled): rfdc.out0(Fix_128_0) → munge → offset_binary
  → Goto17(tag adc1) → From2 → inp1.data_in. CRUCIAL: **munge OUT = [1000000 0]; inp1 block ST carries
  [1 0],[1000000 0],[Inf 0]; inp1.data_in is fed at [1000000 0] natively** (the munge already collapses
  [1 0]→[1000000] before inp1). So inp1.data_in DOES want [1000000] — matches the F-engine output rate.
- BUILT the F-engine (block-copied FE_busexp/FE_pfb/FE_fft masks from feng2: bus_expand 128b→8×16b;
  pfb_fir_real n_inputs=3,PFBSize=8,4tap,16→18b; fft_wideband_real FFTSize=8,n_inputs=3,in_bw=18,
  bin_pt=17, shift=Const 255; quant 4 cplx UFix_36_0 → Slice re[35:18]/im[17:0] → Reinterpret Fix_18_17
  → Convert Fix_8_7 → Concat 8×int8=64b + 64b zero pad = UFix_128_0). Sync DATA-ANCHORED (the prescribed
  fix): Slice 1 bit off bus_expand lane0 (→Bool[1 0]) → Counter rst → Counter mod-32 → Relational ==0
  → pfb sync. Rerouted FE_cat128(128b) → Goto17 (replacing offset_binary).
- COMPILE: ABORTS at `bitfield_snapshot4/ss/bram/sim_mem/sim_data` — "Inheriting a sample time is not
  supported when specifying SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED" (the canonical -1, hopped to a snapshot
  BRAM victim sink, NOT tx_dest_ip this time but same class).
- DECISIVE ISOLATION TEST: undid the Goto17 reroute (restored offset_binary→inp1, original intact) AND
  severed the F-engine from rfdc (fed bus_expand from a rooted synthetic Counter @ explicit [1 0]) AND
  sent FE_cat128 only to a Gateway Out. **STILL aborts at bitfield_snapshot4 with the IDENTICAL -1.**
  Also tried rooting the sync-path constants (FE_zero, FE_synccnt) to explicit_period=on,period=1 → no
  change. => The poisoning is NOT the rfdc-lane sharing, NOT the inp1 junction, NOT the sync anchoring.
  It is the **mere PRESENCE of the pfb_fir_real+fft_wideband_real [1000000] subgraph in the model**: it
  makes a pre-existing assigned-sample-time snapshot BRAM (bitfield_snapshot4, fine in the clean base)
  unable to resolve. This REPRODUCES the documented wall (10+ prior attempts) now on Kocz's OWN working
  vdif_misc base — so the wall is NOT specific to stream_rfdc_100g's [1 0] framing.
- CONCLUSION: grafting a CASPER PFB+FFT into an EXISTING rfsoc4x2 100G design (stream_rfdc_100g OR
  vdif_misc) intrinsically introduces a [1000000] region that the global Simulink rate-resolver cannot
  reconcile with that design's assigned-ST sinks (snapshot BRAMs / gbe tx_dest_ip). The ONLY proven-clean
  PFB→FFT→quant designs (snap_tut_corr, ata_snap) are built WHOLE at the F-engine rate from scratch — they
  do NOT contain a [1 0]-rooted snapshot/framing island that the F-engine then poisons.
- NEXT (unchanged recommendation): either (a) build the ENTIRE design natively at the F-engine rate using
  ata_snap's framing (no reuse of an existing [1 0] design's snapshot/gbe machinery), or (b) ship the
  GPU-PFB hedge (stream4_i8_hb.fpg: raw int8 over 100GbE today → PFB on GPU; line-rate already works), or
  (c) get a real RFSoC PFB+FFT+100GbE reference from a CASPER dev. Artifacts on acme2: fengv_clean.slx
  (clean stubbed vdif_misc baseline, COMPILES), rfsoc4x2_fengv.slx (F-engine inserted, does NOT compile).

## 🎯 SPECIFIC ROOT CAUSE FOUND (2026-06-26) — feng4's sync is a free-floating rate island
The Assert ring is ALREADY in feng4's onehundred_gbe (auto-carried by the gbe mask; assert_rate=on,
period=1 on all tx ports — tx_data n_bits=512). So Assert wasn't missing. The REAL -1: **FE_syncgen**
(a standalone CASPER sync_gen, 0 inputs, Counter3+sync_period_const explicit_period=off) generates the
PFB sync with NO anchor to the rfdc data rate. rfdc emits only data ports (no sync/valid out). So the
F-engine merges a ROOTLESS sync with rfdc-clocked data → global rate graph unresolvable → every
assigned-ST sink (gbe, sim swregs) inherits -1. Pinning the sync counter to explicit period=1 makes it
a SECOND distinct rate (still 2-rate) → still aborts. THE FIX: derive the PFB sync from the rfdc DATA
domain so it INHERITS the data rate (snap_tut_corr's pattern: sync from a data-domain counter via From71,
NOT a free-standing sync_gen). This is THE specific, narrow, correct root cause — not "[1000000] is
fundamental". feng4.cp1bak.slx = clean CP1 fallback. snap_tut_corr (/tmp/alpaca_td/snap/tut_corr) = the
working sync-derivation reference to copy.

## CP3 RESULT (2026-06-26) — real F-engine reintroduces -1; agent over-concluded "fundamental" (WRONG)
feng4 + real rfdc→pfb_fir_real→fft_wideband_real→quant → packetizer → gbe: ABORTS (-1, hops across sim
gateways). Agent concluded "[1000000] F-engine intrinsically breaks the rate graph." THIS IS WRONG /
the oscillation trap: snap_tut_corr (pfb_fir_generic→fft_wideband_real→quant at [1000000]) COMPILES CLEAN;
ata_snap + stock stream4 framing also [1000000] + build. So [1000000] is NOT the blocker — feng4 has a
SPECIFIC unresolved signal. NEXT (evidence-based, breaks the oscillation): apply vdif_misc's
**Assert(assert_rate=on, period=1)** ring on the gbe tx ports (+ any floating sim swreg gateway) — Kocz's
documented fix for THIS exact error. feng4 (full F-engine+packetizer wired) + Assert ring → compile.
If still -1, diff feng4's F-engine vs snap_tut_corr's WORKING one (pfb_fir_generic + a0p0_1st_shift FFT-
shift block — which feng4 LACKS) to find the specific -1. feng4.cp1bak.slx = clean CP1 baseline to fall
back to. DO NOT re-conclude "[1000000] is fundamental".

## 🏆 GOLD REFERENCE: jkocz/vdif_misc — WORKING rfsoc4x2→100GbE packetizer (cloned acme2:/tmp/vdif_misc)
Kocz's own design (rfsoc_vdif_v0_4.slx + rfsoc_vdif_pps.fpg, runs on hardware). RAW-ADC VDIF
packetizer over onehundred_gbe — EXACTLY our target shape minus the F-engine. Two reusable mechanisms:
1. **THE CLEAN tx_dest_ip FIX = Xilinx `Assert` block with `assert_rate=on, period=1` on EVERY gbe tx
   port** (assert_tx_valid/tx_dest_ip[n_bits32]/tx_dest_port[n_bits16]/tx_data/tx_end_of_frame/
   tx_byte_enable). Pinning an explicit rate on those signals nails the sample time so tx_dest_ip
   resolves — costs nothing in HW. This is THE canonical resolution of our error, by the dev who
   diagnosed it, in working gateware (system_446.xml). CLEANER than ata_snap's BRAM approach.
   => FALLBACK for CP3/CP4: if any gbe tx signal won't resolve, wrap it in Assert(rate=on,period=1).
2. dest_ip/dest_port = sw_regs (inp1_ip/inp1_port via init_fpga.py write_int) read IN-PIPELINE, wired
   to gbe via Goto/From (tags ip/port/valid/eof). VDIF: 8032B frame (32B hdr+8000B), header built in
   bus_header from per-field sw_regs (ref_ep/sec_from_ep/th_id/st_id/num_ch...), PPS-synced (arm/first_sync).
ALTERNATIVE BASE (if feng4/ata_snap port stalls): use vdif_misc's NATIVE rfsoc4x2/100G packetizer +
bolt our PFB+FFT in front of its `inp1` packetizer data_in (replace rfdc raw samples). It's already
100G/512b native (no gearbox-from-64b needed — check its internal tx_data width) + has the Assert ring.
init_fpga.py = the bring-up recipe (mac/ip/arp/header/arm). Local extract of system XMLs in this
session's scratchpad/slx_extract/.

## 🎉 CP1 PASSED (2026-06-25 night) — the tx_dest_ip WALL IS BROKEN
Model: acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/rfsoc4x2_feng4.slx. COMPILES CLEAN.
- Cloned strm2a2 -> feng4. Copied ata_snap's `packetizer` subsystem WHOLE (add_block CopyOption copy) —
  instantiated cleanly on the rfsoc4x2 platform, NO library/platform mismatch. Carries its own ips/ants/
  chans BRAMs + ant_tracker + counters.
- Synthetic F-engine-rate source (64b Counter->data_in; 20b Counter+Relational==0 ->sync_in frame pulse;
  Bool0->mrst_in; UFix8->version). Built 64b->512b gearbox (7-stage Register delay + 8-in Concat=512b;
  mod-8 phase counter + Relational==7 AND valid -> once-per-8 tx_valid). Wired packetizer-> onehundred_gbe.
- ⛳ THE CRUX RESOLVED: GBE IN4 tx_dest_ip ST=**[1000000 0]** (from ips BRAM, packet-counter addressed),
  tx_eof=[1000000 0], rst=[1000000 0] — REAL resolved rates, NOT -1. The Constant-on-[1 0] grafts could
  never clear this; the in-pipeline BRAM dest_ip + native-F-engine-rate framing + gearbox->onehundred_gbe
  DOES. tx_data/tx_valid read [Inf 0] (constant, not -1) only because the synthetic source has no clock
  anchor — resolves once the real rfdc front-end is attached (CP3).
REMAINING: CP3 = replace synthetic source with real rfdc->bus_expand->pfb_fir->fft_wideband_real->quant
(int8, 64b) -> packetizer.data_in; compile clean. CP4 = casper_build.sh -> .fpg + timing. (CP2 gearbox
cadence/framing tightening folds into CP3/correctness.)

## ✅ COMPLETE PORT PLAN (2026-06-25 night, after snap_tut_corr characterization)
CORRECTION: snap_tut_corr has NO ethernet block (it's a spectrometer w/ BRAM/CPU readout). It DOES
compile clean (proves CASPER PFB→FFT→quant at [1000000] resolves), but the real PFB→eth packetizer
template is **ata_snap snap_adc5g_feng** (already characterized). The plan = PORT ata_snap's back-end to
rfsoc4x2/100G. This is the user's original "clean rebuild on ata_snap topology" — now fully understood:
WHY prior grafts failed: they reused stream_rfdc_100g's [1 0] always-valid framing + a CONSTANT
tx_dest_ip. The [1000000] F-engine region + [1 0] framing = unresolvable global rate graph (proven, 9+
configs). ata_snap resolves because its ENTIRE data+framing+dest_ip is native to the F-engine rate AND
dest_ip is generated IN-PIPELINE from a shared-BRAM (`ips`, addressed by a packet counter), NOT a Constant.

THE BUILD (port ata_snap back-end → rfsoc4x2/100G):
- Front-end (ours): rfdc → bus_expand → pfb_fir → **fft_wideband_real** (rate-preserving streaming FFT,
  n_inputs=3, FFTSize=8=256pt) → quant (int8 re/im, like ata_snap's eq: ×coeff sw_reg → Convert → UFix_8).
- Back-end (PORT from ata_snap, width-independent framing — REUSE AS-IS): eq→chan_reorder(corner-turn)
  →packetizer→eth_mux. The packetizer generates: dest_ip from `ips` shared-BRAM (swreg-writable, packet-
  counter addressed) — THIS is the -1 fix; valid_out + eof from internal counters (time_ctr/packet_count/
  pkt_ctr) + Relational + pulse_ext gated on the FFT/reorder sync. ALL at the F-engine rate.
- TWO width changes only: (1) GEARBOX 64b→512b: accumulate 8× consecutive 64b channel words → one 512b
  word via a mod-8 counter + Register ping-pong + bus_create (EXACTLY strm2a2's Register14/18→bus_create4
  256→512 proven-timed pattern); re-rate packetizer data_in + per-word valid/eof to the 512b cadence
  (eof once per 512b super-word at frame boundary). (2) SWAP ten_gbe → onehundred_gbe (tx_data=UFix_512_0,
  tx_valid, tx_end_of_frame, tx_dest_ip=UFix_32_0; drop unused ports per strm2a2's onehundred_gbe mask).
- ata_snap eth interface measured: tx_data=UFix_64_0, eth block ST=[[1,0],[1000000,0],[None,0]];
  tx iface runs [None,0] continuous + frame signals [1000000,0]. dest_ip updates [1,0]/[None,0].
KEY: keep dest_ip BRAM-in-pipeline (NEVER a Constant) and build the WHOLE path native at the F-engine
rate. Both snap_tut_corr + ata_snap compile clean = proof this resolves.
CHECKPOINTS: CP1 port ata_snap eq→packetizer→ten_gbe into a fresh rfsoc4x2 model fed by our front-end,
compile clean (proves the framing ports). CP2 gearbox + ten_gbe→onehundred_gbe, compile. CP3 full front-
end real rfdc, compile. CP4 casper_build.sh → .fpg + timing.
Reference on disk: /tmp/ata_snap/snap_adc5g_feng.slx; chars /tmp/atasnap_{struct,rates}.json. 512b tail
template: ~/src/.../rfsoc4x2_strm2a2.slx (Register14/18→bus_create4→Concat1→FIFO→onehundred_gbe, BUILDS).

## 🧱 SESSION 2026-06-25 NIGHT (feng3) — ONE-PATH config TRIED & FAILED; -1 ROOT NOW PROVEN
Executed the EXACT refined plan (F-engine REPLACES raw ADC into packetizer + tx_dest_ip on
software_register). Built rfsoc4x2_feng3 fresh from pristine rfsoc4x2_stream_rfdc_100g (baseline
compiles CLEAN). Steps + results (each agent-verified by reading CompiledSampleTime):
- D0: clone pristine -> feng3, baseline compile = CLEAN. ✓
- D1: add FRESH F-engine on unused rfdc.out5 (bus_expand->pfb_fir_real n_inputs=3,PFBSize=8,4tap,16->18b
  ->fft_wideband_real FFTSize=8,n_inputs=3,in_bw=18,bin_pt=17; sync_gen self-contained 0-in/1-out;
  shift=Const 255,n_bits=8,explicit_period=on) + requant (4 cplx UFix_36_0 -> Slice re[35:18]/im[17:0]
  -> Reinterpret Fix_18_17 -> Convert Fix_8_7 -> Concat 64b + 192b zero pad = 256b). ISOLATED tap
  (outputs -> Gateway Outs, NOT into gbe). COMPILE ABORT at onehundred_gbe/tx_dest_ip (-1). So merely
  ADDING the F-engine region on the SHARED rfdc poisons the gbe — confirms A5b.
- D3: replace tx_dest_ip driver (Constant2) with a From-Processor software_register (copied pkt_rst
  swreg, width 32, name dest_ip, sim-in Constant, output -> gbe in7). The "documented fix". COMPILE
  ABORT at tx_dest_ip, IDENTICAL -1. **The swreg fix does NOT clear it.**
- D4: TRUE one-path splice: delete Mux3->Register14/Register18, wire FE_concat(256b)->both Register14
  & Register18 (gbe data now ONLY from F-engine; raw munge path dead). COMPILE ABORT at tx_dest_ip,
  IDENTICAL -1. **The one-path config the doc said was "never cleanly tried" — now tried, FAILS too.**
- D5-D11 DIAGNOSTICS (delete gbe, probe what's at -1): the -1 is NOT tx_dest_ip-specific. With the gbe
  removed, the abort HOPS to the next assigned-sample-time sink: top-level Gateway Out7, then
  fifo_full/sim_out_reg_gw (a To-Processor swreg INSIDE the BASELINE, downstream of FIFO, NOTHING to
  do with the F-engine). i.e. EVERY block needing an assigned ST inherits -1 once the F-engine exists.
  gbe inputs map: IN1=From4(rst) IN2=Mux6(data) IN3=Mux8(valid) IN4=Concat(2 consts) IN5=Const6
  IN6=Register7(eof) IN7=dest_ip IN8-10=Consts. ALL gbe-feeding Constants already have
  explicit_period=on,period=1 (NOT the cause). 
### ⛳ PROVEN ROOT (this session, evidence-backed): the F-engine's [1000000] PFB/FFT subrate region,
sharing the rfdc clock-domain with stream_rfdc_100g's [1 0]-always-valid framing, makes the GLOBAL
Simulink rate graph unresolvable -> every assigned-ST sink (gbe, Gateway Outs, swreg sim gateways)
goes -1. This is INTRINSIC to grafting a [1000000] F-engine onto a [1 0]-built 100G tail, and is
INDEPENDENT of: (a) whether F-engine is isolated-tap vs in-datapath, (b) tx_dest_ip driver
(Constant vs software_register), (c) which corner-turn/bridge. A FRESH pfb_fir_real+fft_wideband_real
fails identically to the imported fe256 biplex — so it is NOT fe256-specific; it is the rate-philosophy
clash. ata_snap compiles ONLY because its ENTIRE datapath+framing+dest_ip is natively built around the
[1000000] F-engine rate (dest_ip generated IN-PIPELINE from shared-BRAM, not a [1 0] Constant).
### ➡️ THE ONLY PATHS LEFT (do NOT re-try grafts onto stream_rfdc_100g — 9+ attempts, all the same -1):
1. Build the WHOLE design natively at the F-engine rate using ata_snap's framing pattern: port
   snap_adc5g_feng's packetizer/dest_ip-from-BRAM/eth_mux to 512b/100G (NOT reuse stream_rfdc_100g's
   [1 0] framing at all). This is the ALPACA "100g spectrometer" pattern; biggest effort but the only
   one consistent with the proven evidence.
2. Get a real RFSoC PFB+FFT+100GbE reference design (ask CASPER dev Mitch) and diff.
3. Ship the GPU-PFB hedge (stream4_i8_hb.fpg: raw int8 over 100GbE today -> PFB on GPU). Per memory,
   line-rate beamforming already works on GPU; this unblocks the science now.
feng3.slx (one-path splice, does NOT compile) on acme2; scratch B*/C*/D* .m/.log in ~/.

## The settled diagnosis (why 8+ prior efforts oscillated)
The "Inheriting a sample time is not supported" abort at `onehundred_gbe/tx_dest_ip` is a
VICTIM. Root cause = an upstream framing signal stuck at `-1` because the gated/rewired
F-engine front-end left stream4's packet framing (`From1/From2` Goto tags, `Mux8`=tx_valid,
`Register7`=tx_eof) without a properly-rated driver. NOT a 100G/FFT incompatibility
(proven: `f6_nogbe` reproduces the error with the gbe REMOVED; stock stream4 framing is
natively `[1000000]` and builds).

## Two proven references (both characterized headlessly 2026-06-25)
### ata_snap `snap_adc5g_feng.slx` (acme2:/tmp/ata_snap) — COMPILES CLEAN, real PFB+FFT+gbe
Dataflow: adc5g(16×UFix_8_0) → pfb(→UFix_288_0) → eq(→**UFix_64_0** int8 requant) →
eqtvg → chan_reorder(corner-turn) → packetizer → eth_mux → eth(ten_gbe).
- **Entire packetizer→eth datapath is 64-bit.** ten_gbe tx = UFix_64_0.
- packetizer: [sync_in,data_in(64),mrst_in,version] → [data_out(64),valid_out,eof,dest_ip(32)].
  Generates dest_ip IN-PIPELINE from `ips` shared-BRAM; eof+dest_ip update at **[1000000,0]**
  (frame rate), data+valid at [None,0]. THIS coexistence is what resolves clean.
- LESSON (not literal reuse): 64-bit ≠ our 512-bit CMAC. Port the *framing principle*,
  not the packetizer block.

### strm2a2 `rfsoc4x2_strm2a2.slx` — BUILDS + timing-closed (our proven 512b/100G tail)
Dataflow: rfdc → bus_create(munge) → **ct_bram corner-turn** → ct_rdreg → Register14/18
ping-pong(256b) → bus_create4(→512b) → Concat1(header) → FIFO(512b) → Mux6 → onehundred_gbe.
Proven-resolved rates (REPRODUCE THESE):
- onehundred_gbe: tx_data=UFix_512_0[None,0]; tx_dest_ip=UFix_32_0[None,0];
  tx_end_of_frame/rst=Bool[1000000,0]. block ST=[[1,0],[None,0]].
- corner-turn: ct_bram = dual-port RAM, addr UFix_9_0 (512 deep), data UFix_256_0.
  **ct_we0/ct_we1 = always-1 Bool constants** → writes EVERY clock (always-valid).
  read addr from free-running ct_cnt(UFix_16_0)→ct_ra slice. ct_rdreg out=[1000000,0].
- framing: Counter1→UFix_64_0 seq; edge_detect[1000000,0]; Register7/10[1000000,0];
  From1/From2[1000000,0]; Mux8(tx_valid)[None,0]; Concat1=448b pad+64b seq.

## WHY strm2a2 builds and the grafts didn't
strm2a2's corner-turn write side is fed by the always-valid raw ADC (we=1 const), read side
free-runs → downstream is ALWAYS-VALID → stock framing (Counter1/Relational/edge_detect/
Mux8/From1/2) stays resolved. Grafts replaced the front-end and broke that always-valid
property + From/Goto bindings → -1.

## THE ARCHITECTURE (decided)
Keep strm2a2's ENTIRE tail UNTOUCHED (corner-turn read + Register14/18 + bus_create4 +
Concat1 + FIFO + Mux6 + ALL framing + onehundred_gbe). Replace ONLY what feeds the
corner-turn WRITE DATA: instead of raw-ADC munge, feed the **F-engine channelized int8**.
Keep ct_we=1 (always-valid write) — the F-engine streams channels continuously at [1 0]
(ata_snap proves pfb/eq output is continuous [1 0], NOT gappy), so always-valid holds.

F-engine front-end (reuse fe256's PROVEN-on-silicon blocks): rfdc → pfb_fir → fft(256-pt) →
requant to int8 (eq: gain sw_reg Fix_18_12 → Convert Fix_8_7). Output = channelized int8
stream, width-matched to the corner-turn 256b write port.

## BUILD ORDER (compile after EVERY step; localize any -1 immediately; never proceed on -1)
0. Clone strm2a2 → new model `rfsoc4x2_feng100`. Confirm it still compiles clean (baseline).
1. Build F-engine front-end as ISOLATED test model first: rfdc→pfb_fir→fft→requant→Terminator.
   Prove COMPILES CLEAN in isolation. Capture output width + rate. (de-risks front-end)
2. In feng100: delete raw-ADC→corner-turn-write path; insert F-engine; wire F-engine int8
   output → corner-turn write data (resize write port to match; keep we=1). Compile.
3. Verify the framing chain still resolves (From1/2, Mux8, Register7 = NOT -1). Compile.
4. casper_build.sh feng100 → JASPER_DONE_OK + timing MET. Deliverable .fpg.

## ANTI-OSCILLATION GUARDS
- If a compile -1 recurs after a fix attempt, STOP and re-read THIS doc + the actual
  CompiledSampleTime of the -1 cluster before trying anything new. Do NOT blame 100G/FFT.
- The corner-turn READ side + framing are PROVEN; if -1 appears there after insertion, the
  bug is in how the F-engine WRITE side perturbs the model, not the tail.
- Keep ct_we=always-1. Do NOT gate the corner-turn write on FFT valid (that's what broke grafts).

## ⚠️ CHECKPOINT A RESULT (2026-06-25 late) — hypothesis PARTLY WRONG: PFB is the rate-reducer
Built rfsoc4x2_feng2 = stream_rfdc_100g + isolated front-end on unused rfdc.out5:
bus_expand(128b->8x16b) -> pfb_fir_real(n_inputs=3,PFBSize=8,4tap) -> fft_wideband_real(n_inputs=3,FFTSize=8).
MEASURED (live [1 0] sync): rfdc.out5=[1 0], bus_expand=[1 0], sync_gen=[1 0], BUT
**pfb_fir_real DATA OUT = [1000000 0]** -> fft inherits [1000000]. fft_wideband_real IS rate-preserving
(in==out) but the PFB already collapsed [1 0]->[1000000] UPSTREAM of it. So "wideband fft keeps it [1 0]"
is WRONG; the [1000000] domain is intrinsic to the CASPER PFB+FFT F-engine (matches every real design).
CAVEAT: fft DATA OUT measured [Inf 0] (degenerate/constant) -> the fft wasn't fully resolving in this
isolated tap (shift/sync framing not fully valid), so the pfb=[1000000] reading needs reconfirmation
with a properly-working fft (non-[Inf] outputs).
KEY POSITIVE FINDING: the isolated front-end (on unused rfdc.out5) COMPILES CLEAN. The tx_dest_ip abort
ONLY reappeared (A5b) when the F-engine sync was sliced off the SAME rfdc lane that also feeds the gbe
-> tx_dest_ip is a victim of the F-engine [1000000] region perturbing the SHARED rfdc->gbe rate graph,
NOT the FFT/100G. => In the REAL integration the F-engine REPLACES the raw ADC (gbe sees ONLY F-engine
output, ONE path, no shared-graph conflict) — that exact config has NOT been cleanly tried.
HARNESS BUG found: `pgrep -u zackli -f glnxa64/MATLAB` self-matches the polling ssh cmd -> false BUSY.
Use `pgrep -u zackli -af "[m]odel_composer .*-nodesktop"` instead.
NEXT EXPERIMENT (refined): full ONE-PATH integration rfdc->F-engine->requant->packetizer->gbe (F-engine
REPLACES raw ADC, not a parallel tap), with tx_dest_ip driven by a software_register (AXI-rooted, per
research) so it resolves independent of the F-engine region. Note stock stream4 framing is natively
[1000000] and BUILDS, so a uniformly-[1000000] data+framing path into the gbe may resolve. First get the
fft producing REAL (non-[Inf]) outputs.
feng2 scratch .m/.log on acme2 (~/A1..A7).

## 🔑 CRUX (2026-06-25 late) — fft_wideband_real is RATE-PRESERVING (but PFB reduces upstream)
Measured in an isolated harness (acme2:~/fftrate.slx, fftrate2.m): fft_wideband_real
(FFTSize=8=256pt, n_inputs=3) → IN rate == OUT rate (both [1000000] in the no-rfdc throwaway,
where [1000000] is just the default base with no clock source). RATE-PRESERVING: in==out.
Contrast fe256's BIPLEX fft: [1 0] in → [1000000] out (rate-REDUCING). THAT was the whole bug.
=> In the real design (rfdc anchors base = [1 0]), fft_wideband_real output = [1 0] continuous.
KEY PARAM FACTS (verified):
- fft_wideband_real: n_inputs is LOG2 of parallel samples. 8 samples/clock → **n_inputs=3** (NOT 8!).
  FFTSize=8 (=256pt). input_bit_width=18, bin_pt_in=17. Ports: 10 in (sync + 8 data + shift),
  6 out (sync + 4 complex channel-pairs + overflow). Block: casper_library_ffts/fft_wideband_real.
- pfb_fir_real: casper_library_pfbs/pfb_fir_real. n_inputs=3 (match), PFBSize=8, TotalTaps=4,
  BitWidthIn=16 (rfdc width), BitWidthOut=18 (match fft input).
- dest_ip: stock tut_onehundred_gbe drives it from a Constant (resolves fine when single-rate).
  Keep single-rate via the rate-preserving fft; if any [1000000] sneaks in, switch tx_dest_ip to a
  software_register (AXI-rooted) per the research (the belt-and-suspenders fix).

## CONCRETE BUILD SPEC (one-design, careful incremental)
Base: clone ~/src/.../rfsoc4x2_stream_rfdc_100g.slx (single-ADC raw streamer, BUILDS) -> rfsoc4x2_feng2.
Front-end insert (between rfdc and the packetizer's data input): rfdc 1 ADC (8 real samp/clk, 16b) ->
bus_expand to 8 lanes -> pfb_fir_real(n_inputs=3) -> fft_wideband_real(n_inputs=3,FFTSize=8) ->
4 complex outputs (re|im) -> int8 requant (Convert Fix_8_7 per re/im) -> pack to the packetizer's
expected width -> existing packetizer/FIFO/100GbE UNCHANGED. Keep everything [1 0] single-rate.
CHECKPOINTS (compile + agent-verify each): (A) front-end compiles + fft OUT rate == [1 0] in-context;
(B) +requant compiles, int8 bit-true; (C) full integration compiles clean (NO tx_dest_ip -1);
(D) casper_build.sh -> JASPER_DONE_OK + timing MET.

## ✅ NEW STRATEGY (2026-06-25 eve) — ONE-DESIGN rate-preserving streaming F-engine
ROOT CAUSE (definitive): rfdc output is [1 0] in BOTH tut_spec(fe256) AND tut_onehundred_gbe
(measured: both 3932.16 MSPS, 8 samp/cyc, 2x dec). The [1000000] is created INSIDE fe256 by its
**biplex FFT** (fft_biplex, spectrometer-style, rate-REDUCING). Grafting that [1000000] region onto
strm2a2's [1 0] design = a 2-rate model → onehundred_gbe/tx_dest_ip can't resolve → the -1.
Working streaming F-engines (ata_snap: fft/eq data = [None,0] CONTINUOUS) use a rate-PRESERVING FFT
and build the WHOLE PFB→FFT→requant→packetizer→gbe in ONE design at ONE rate.

THE PLAN (careful, incremental, agent-verified per the user 2026-06-25):
- Base: start from STOCK rfsoc4x2 tut_onehundred_gbe (rfdc→packetizer→100GbE, builds, ONE rate).
  Candidate: /tmp/alpaca_td/rfsoc/tut_onehundred_gbe/rfsoc4x2_tut_onehundred_gbe.slx OR
  ~/src/.../rfsoc4x2_stream_rfdc_100g.slx. Confirm baseline builds.
- Insert a RATE-PRESERVING streaming F-engine (rfdc→pfb_fir→fft→requant) whose output is continuous
  [1 0] always-valid, so it drops into the raw-ADC packetizer's slot (raw ADC is also [1 0] always-
  valid → packetizer/framing/dest_ip stay single-rate → no -1).
- CRUX SUBSYSTEM (test FIRST, very carefully): the FFT config that yields continuous [1 0] output
  (NOT [1000000]). ata_snap uses fft_wideband (rate-preserving). Determine the exact mask (fft type,
  n_inputs, n_streams) + verify the output rate is [1 0]/[None] in isolation BEFORE integrating.
  NOTE prior notes claimed fft_wideband_real ALSO gave [1000000] — must re-verify; the difference may
  be n_inputs/samples-per-clock matching the 8-samp/clk rfdc so the FFT runs fully-parallel (no serialize).
- Subsystems to build+verify (each agent-tested): (1) streaming FFT rate, (2) pfb_fir+fft chain,
  (3) int8 requant bit-true, (4) packetizer integration keeping dest_ip single-rate, (5) compile+build.
- If continuous-[1 0] FFT proves impossible, fallback = ata_snap's pattern: keep [1000000] but drive
  dest_ip IN-PIPELINE from the packetizer (not a standalone Constant) so it needn't be constant-rate.
Reference on disk: /tmp/alpaca_td (ALPACA tutorials_devel: tut_spec, tut_onehundred_gbe, snap_tut_corr
= working PFB+FFT+10GbE). ata_snap chars: /tmp/atasnap_{struct,rates}.json.

## ⚠️ CORRECTED DIAGNOSIS (2026-06-25, after agent-team comparison vs ata_snap + measurements)
The "divert ct_bram write data, keep ct_bram" plan below is FLAWED and produces the -1. Root cause,
now evidence-backed (2 independent agents on ata_snap's compilable JSON + direct measurement):
- fe256's F-engine data path is uniformly **[1000000 0]** (measured: fft.out1..10 + bus_expand all
  [1000000 0]). strm2a2's corner-turn write (pack4) is **[1 0]**. Different Simulink base rates.
- strm2a2's `ct_bram` is a SINGLE-counter dual-port RAM (ct_cnt drives BOTH ct_wa and ct_ra). It only
  resolves because the raw-ADC write is always-valid [1 0] (write rate == read rate). It CANNOT
  reconcile write-rate ≠ read-rate. Feeding it the [1000000] F-engine output leaves the read side with
  no [1 0]-pinned boundary → downstream framing → onehundred_gbe/tx_dest_ip inherits -1 (victim).
- MEASURED CONFIRMATION: feng100_fe (pack4→ct_bram RESTORED + F-engine→requant→GatewayOut tapped off)
  STILL aborts at tx_dest_ip → merely ADDING the [1000000] F-engine branch poisons the gbe rate graph
  unless properly bridged. (Gateway Out on fft data is itself a -1 trigger — can't read fft-data rate
  that way; terminating fft data = -1 island. So the F-engine MUST connect through a real rate bridge.)
- ata_snap (COMPILES CLEAN) proves the bridge: its chan_reorder contains a `dbl_buffer` with
  **wr_addr/din=[1000000,0], rd_addr=[1,0]** (read pinned to system rate) → dout=[None,0] always-valid.
  That [1,0] read pin is the ONE property ct_bram lacks. ([1000000] coexisting with [1 0]+gbe is FINE —
  both proven models carry [1000000]; the "subrate poisons everything" theory is DISPROVEN.)

### THE FIX (replaces "divert write data" below): dual-rate double-buffer with [1 0] read pin
Replace the single-counter `ct_bram` corner-turn with a proper ping-pong double-buffer:
  - write side: addr/we clocked at the F-engine frame rate, driven from the FFT sync ([1000000]).
  - read side: addr counter PINNED to explicit_period [1 0] (forces always-valid system-rate read).
  - ping-pong two buffers (swap read/write each frame) so read never collides with write.
  - output (always-valid [None,0]) → existing ct_rdreg → Register14/18 → bus_create4 → ...tail unchanged.
Implementation options (in order of preference):
  (1) CASPER `reorder` block (casper_library_reorder/reorder), double_buffer=1, 256b data, identity map
      first (channel order is a science detail; reorder_map.py later). Read side self-clocks [1 0].
  (2) Copy ata_snap `snap_adc5g_feng/chan_reorder/reorder3` (has dbl_buffer0, PROVEN), widen 64b→256b.
  (3) Manual: keep ct_bram dual-port RAM, add a 2nd write counter @ frame rate + pin read counter
      explicit_period [1 0] + ping-pong via addr-MSB toggle. Reuses the proven BRAM primitive.
NOTE prior session tried a reorder (double_buffer, identity) in the CONTAMINATED strm1 lineage and it
failed — but that was confounded by strm1's broken framing. feng100's framing is CLEAN (byte-identical
strm2a2), so the reorder bridge has not been fairly tested. The [1 0] read pin is the key to verify.
SUCCESS CRITERION for the bridge: feng100 compiles clean (no tx_dest_ip abort).

## ⛔ RESULT OF THE CLEAN REBUILD (2026-06-25) — reproduces the documented wall
The clean rebuild was EXECUTED: feng100 = strm2a2 tail + fe256 F-engine (boxed as `Feng`) +
int8 requant. Outcomes:
- ct_bram corner-turn (divert write data): COMPILE ABORT at onehundred_gbe/tx_dest_ip (-1).
- reorder double-buffer bridge (the agent-team-recommended fix, n_bits=256, double_buffer=1,
  sync from Feng, en=const1): COMPILE ABORT at onehundred_gbe/tx_dest_ip (SAME -1). The CASPER
  reorder did NOT resolve it (consistent with the prior session's reorder attempt, lines 196-212).
- Isolation attempt (strip to rfdc+Feng+requant+GatewayOut to measure the true F-engine rate):
  FAILS at platform check "XPS block must be on the same level as the Xilinx SysGen block" — can't
  strip the model without breaking the yellow-block platform. So the F-engine's ACTUAL in-context
  output rate remains UNMEASURED (Gateway-Out-on-fft-data + platform-strip both confound it).
CONCLUSION: the clean rebuild + the canonical double-buffer fix BOTH hit the identical tx_dest_ip
-1 that blocked 8+ prior attempts. This is the documented wall. The agents' diagnosis (raw-ADC
corner-turn wrong) was sound but the reorder replacement did not clear it — suggesting the -1 is
NOT only the corner-turn but something in how fe256's F-engine rate (or its swreg/sync wiring)
interacts with onehundred_gbe, which cannot be measured headlessly with available techniques.
LIKELY ROOT (unproven, can't measure): fe256's F-engine carries a different Simulink base sample
rate than strm2a2's [1 0] tail; importing it whole brings that rate. A FRESH PFB/FFT built in the
100GbE design's native [1 0] framework MIGHT avoid it — but the prior session's "fresh F-engine
rebuild" also aborted identically, lowering confidence.
RECOMMENDATION (per memory daqiri-rfsoc-hw-validation): escalate to a CASPER core dev (Mitch, who
wrote both CASPER + ALPACA) or obtain a concrete RFSoC 100G+FFT reference design to diff against;
OR ship the GPU-PFB hedge (stream4_i8_hb.fpg streams raw int8 over 100GbE TODAY → PFB on GPU).
ARTIFACTS: feng100.slx (F-engine embedded, reorder bridge, does NOT compile). Scratch copies
feng100_{diag,fe,iso}.slx can be deleted.

## EXACT ASSEMBLY SPEC (characterized 2026-06-25 — both models fully probed)

### strm2a2 internals (the base; KEEP everything except the one diverted signal)
- Data path: `rfdc → bus_create×4 → munge1..4 → pack4(256b) → ct_bram.port2(write data)`.
- Corner-turn: `ct_bram` dual-port RAM (addr UFix_9_0 = 512 deep, data UFix_256_0);
  write: port1=ct_wa(addr), port2=pack4(DATA), port3=ct_we1(=Bool const 1); 
  read: port4=ct_ra(addr), port5=ct_bd0(const), port6=ct_we0(=Bool const 1).
  ct_we0/we1 ALWAYS 1 → always-valid. read addr from free-running ct_cnt→ct_ra slice.
- Tail: `ct_rdreg → Register14/18(ping-pong 256b) → bus_create4(→512b) → Concat1(448b pad+
  64b seq) / FIFO(512b) → Mux6 → onehundred_gbe`.
- FRAMING (do NOT touch): Goto"rst"←Register2←Slice8 (a COUNTER slice, independent of data
  path); From/From1/From3 read "rst" (From1→FIFO rst, From2→Counter1 rst, From3→...).
  Goto1"gbe_rst"←Register5; From4/5 read it. tx_eof/edge_detect/Register7/10 at [1000000,0].
- **THE SINGLE SURGICAL CHANGE: ct_bram.port2 source: `pack4` → the F-engine int8 output.**
  Disconnect pack4→ct_bram; leave pack4/munge/bus_create in place (harmless) or delete.
  Slice8/Register2/"rst" + ALL framing + tail STAY BYTE-IDENTICAL. rfdc STAYS.

### fe256 F-engine (the source to copy; preserves its OWN proven sync wiring)
- `sync_gen`(out→Delay23) + `sync_cntr`(in From2=rst,From5; out→Delay21) generate frame sync.
- `pfb_fir`: in[p1=sync←pipeline3, p2-9=8 data←bus_expand], out[p10=sync→fft, p11-18=8 data→fft].
  mask: PFBSize=11,TotalTaps=4,hamming,n_inputs=3,BitWidthIn=16,BitWidthOut=24. (PFBSize=11 vs
  FFT=256 is the known harmless fe256 quirk; copy verbatim for first build, optimize later.)
- `fft`: in[p1=sync←pfb_fir, p2=shift←Constant2, p3-10=8 data←pfb_fir],
  out[p11=sync, p12-19=8 data (UFix_48_0 = re24|im24), p20=overflow→Term].
  mask: FFTSize=8(256-pt),n_inputs=3,input_bit_width=24,bin_pt_in=23,unscramble=on,Wrap.
- rfdc→bus_create(2 rfdc outs)→munge1→...→bus_expand→pfb_fir (front plumbing).

### REQUANT + WIDTH (fft 8×48b → ct_bram 256b)
Per lane UFix_48_0 → Slice re[47:24]+im[23:0] → Reinterpret Fix_24_23 → (optional gain
sw_reg Fix_18_12 mult) → Convert Fix_8_7 (Sat/Round) → 8b re + 8b im. 8 lanes ×16b = **128b**.
Concat(128b data, Constant 128b zero) = **256b** → ct_bram.port2. (Fat/padded packet OK for
first build; preserves the proven 256b corner-turn + tail exactly.) requant bit-true ref:
scratchpad earlier requant_iso/requant3 (Fix_8_7 Convert verified ≤1 LSB).

### BUILD STEPS (compile after EACH; on -1, read CompiledSampleTime of the cluster, trace up)
1. `save_system('rfsoc4x2_strm2a2', DIR'/rfsoc4x2_feng100.slx')`; compile → confirm CLEAN baseline.
2. Copy fe256 F-engine subgraph (sync_gen,sync_cntr,pfb_fir,fft,bus_expand,Constant2,+the
   pipeline/Delay alignment blocks on the sync path) into feng100, preserving internal lines.
   Feed pfb_fir data from feng100's rfdc (1 input = first bus_create pair). Terminate fft
   overflow only. DO NOT terminate fft DATA (dangling fft data = -1 island — documented).
3. Add requant (8× Slice/Reinterpret/Convert Fix_8_7) + Concat-pad-to-256b. Wire fft data →
   requant → Concat → ct_bram.port2 (delete pack4→ct_bram line). Compile → MUST be clean.
4. If clean: casper_build.sh feng100.

### ANTI-OSCILLATION (hard rules)
- If compile aborts at onehundred_gbe/tx_dest_ip: it's a VICTIM. The real -1 is upstream in
  the framing (From"rst" / Mux8 / Register7) or the F-engine→ct_bram junction. Read the
  CompiledSampleTime of From/From1/From2/Mux8/Register7/ct_bram and find which is -1/NaN.
- Same -1 twice after a fix → STOP, re-read this doc, report the cluster. Do NOT blame 100G/FFT.
- Keep ct_we0/we1 = const 1. NEVER gate corner-turn write on fft valid (broke every prior graft).
- The fe256 F-engine sync chain is PROVEN — copy it whole; do not re-derive sync.

## Reuse assets
- fe256 proven blocks: pfb_fir (4-tap hamming, 16b→24b), fft (256-pt). On acme2 in fe256 model.
- reorder map: scratchpad/reorder_map.py (plane=c*16+t). requant bit-true: requant_iso/requant3.
- harness: ~/run_m.sh (detached), ~/casper_build.sh, casper_slx.py inspect.
- char JSONs: /tmp/atasnap_{struct,rates}.json, /tmp/strm2a2_{struct,rates}.json on acme2.
