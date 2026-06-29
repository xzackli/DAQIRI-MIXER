# F-engine graft assembly — verification record (Task C)

Goal: assemble the FPGA F-engine graft for the RFSoC 4x2 and verify the ASSEMBLY
(plumbing) headless with a DUMMY FFT stand-in, then swap the real fft and build the
.fpg (synthesis/timing only — no board programming).

## Design (from the 3 block-test agents, all verified)
Per input (x4 SMA I/Q tiles 224/226):
  pfb_fir (4-tap hamming) -> fft (256-pt cplx, FFTSize=8, n_inputs=3 = 8 lanes,
  unscramble=on, input_bit_width=24, bin_pt_in=23)
TAP: fft 8 data lanes out00..07 = UFix_48_0 (real24 MSB | imag24 LSB) -> c_to_ri /
  Slice+Reinterpret -> Fix_24_23 I, Fix_24_23 Q.
REQUANT: gain (Fix_18_12 ~0.9) * Xilinx Mult -> Xilinx Convert -> Fix_8_7
  Signed(2's comp, Saturate, Round unbiased +/-Inf) -> int8 I/Q.
CORNER-TURN per element: transpose BRAM, ping-pong. write[t][c], read[c][t];
  plane p = c*TPKT+t; planar re[0..4095] then im[4096..8191]. NCHAN=256, TPKT=16,
  payload 8192 B/element.
PACKETIZER: reuse stream4_i8_hb back half (FIFO/512-bit/CMAC/100GbE), one packet per
  element, PPB=NELEM=4 (element=seq%4), seq reconcile (stream4 u64-LE@42 -> config_ula
  u32-BE@48).

## Dummy-FFT strategy + the key headless gotcha (root-caused here)
A synthesizable stand-in with the SAME interface (8 UFix_48_0 lanes + sync + of) but
RESOLVABLE sample times + deterministic data encoding (lane,c,t).

ROOT CAUSE of the long-standing "fft data output can't be logged headless" failure,
isolated by 4 probes (pA/pB/pC/pD/pE):
  - A Xilinx Constant (explicit_period) OR a Scale block mixed with a Gateway-In-rate
    signal in one combinational island leaves the Concat/Gateway-Out input sample time
    INHERITED (-1) -> the Gateway-Out logging S-function rejects it with
    "SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED ... Inheriting a sample time is not supported".
  - FIX: derive every data value from Gateway-In slices + Convert(latency>=1) (which
    anchors the rate). No Xilinx Constants / Scale on the logged data path. Then both
    Gateway Outs log cleanly.
This is the same class of failure the real fft hits; the real fft additionally carries
an inherited rate on its data ports that NO registering fixes -> the real fft channel-
ization/phase remains GUI/hardware-only (documented limitation). But the GRAFT PLUMBING
around it is fully loggable with the dummy.

## What was verified (stages 1-4)

### Stage 1 — DUMMY FFT alone  (acme2:~/dummyfft.slx)  PASS
16-bit Simulink free counter -> Gateway In (period=1) -> derive channel c=cnt[7:0]
(0..255), frame t=cnt[11:8] (0..15) -> Convert to 24b -> Concat real24|imag24 =
UFix_48_0 lane -> Slice[47:24]/[23:0] + Reinterpret -> Fix_24_23 I/Q (== c_to_ri) ->
Register -> Gateway Out. SIM (StopTime=600): NSAMP=601;
  re(=c) = 0,1,2,...,255,0,...  (after 2-clk pipeline delay)
  im(=t) = 0 for first 256 samples, then 1, ...  (frame steps every 256 channels)
=> the fft-replacement tap produces UFix_48_0 + splits to Fix_24_23 I/Q and LOGS with
   resolvable sample times — exactly what the real fft could not do.

### Stage 2 — CORNER-TURN BRAM bit-exact  (scratchpad/ct_verify.py + ct_bram_verify.py)  PASS
Emulates the transpose BRAM exactly: wr_addr=t*256+c (write[t][c]), rd_addr=c*16+t
(read[c][t]). Verified the transpose is a bijection (every cell written read once),
plane p=c*TPKT+t, planar re@p / im@4096+p, payload=8192 B. Cross-checked against
config_ula.h's RX decode rule (re@p, im@4096+p) — round-trips.

### Stage 3 — REQUANT bit-true on REAL Xilinx blocks  (acme2:~/requant3.slx)  PASS
gain(Fix_18_12=0.9)*Mult -> Convert->Fix_8_7 (Round +/-Inf, Saturate), driven by a
sine sweep of Fix_24_23 tap values [-0.95,0.95]. int8 out matches the Python golden
fix87_convert(0.9*tap) to <=1 LSB (total abs err 2 over 201 samples; the +-1 are
Fix_18_12 gain-quantization ties, not logic errors), saturation correct at the edges.
GAIN-STAGING confirmed: the dummy encoding stays UNCLIPPED (graft_verify: re in
[-114,114], im in [-114,-99], 0 clipped) — the gain must keep peaks unclipped (clipping
rotates phase +-7.4deg/component per the block-test agents).

### Stage 4 — PACKETIZER byte layout + seq reconcile  (scratchpad/graft_verify.py)  PASS
Full 8256-B wire packet: HDR 64 + payload 8192. one packet/element, PPB=4,
element=seq%4 (cycle 0,1,2,3,0,1,2,3), seq = BE u32 @ byte 48 (config_ula.h). RX
decode (config_ula.h rule) round-trips seq, element, and every (c,t) payload byte.
SEQ RECONCILE: stream4_i8_hb's native header Concat1 = [Constant17 448b zeros (MSB) |
Counter1 64b seq (LSB)] -> seq lands u64-LE @ wire byte 42. config_ula.h wants u32-BE
@ byte 48. The reconcile is a header-Concat re-slice (place a 32-bit big-endian seq
field at byte 48). Modeled + verified in graft_verify.py; the Simulink re-slice is an
integration-time edit on the real graft (or documented for the RX to parse @42).

## Stage 5 — real fft + .fpg build
Cloned tut_spec_cx -> rfsoc4x2_fe256.slx, set fft FFTSize 11->8 (2048->256-pt to match
NCHAN=256). The mask accepted the resize and saved. Build launched via casper_build.sh
(real pfb_fir + real 256-pt fft). [result recorded below once the ~20min build finishes]

## Files
- acme2:~/dummyfft.slx            Stage-1 dummy FFT lane (loggable stand-in)
- acme2:~/requant3.slx            Stage-3 bit-true requant sweep
- acme2:~/requant_iso.slx         requant reference (gain*Mult->Convert->Fix_8_7)
- acme2:~/fft_harness.slx         32-pt fft harness (prior agent; fft un-loggable headless)
- acme2:~/src/.../rfsoc4x2/rfsoc4x2_fe256.slx   real 256-pt F-engine (build seed)
- scratchpad/ct_verify.py         corner-turn index/byte golden
- scratchpad/ct_bram_verify.py    transpose-BRAM bijection golden (Stage 2)
- scratchpad/graft_verify.py      full byte-layout golden incl requant+seq reconcile

## Deferred to GUI / hardware (genuinely not headless-verifiable)
- The REAL fft functional channelization / per-bin phase / reorder / overflow: the
  casper fft's data outputs carry an inherited sample time that Gateway-Out logging
  rejects, and FFTSize resize doesn't always regen biplex_core headlessly. Verify in
  GUI Model Composer or on real hardware (tone->bin, isolation, inter-element phase).
- The full 4-chain graft model wiring + stream4 back-end integration with the seq
  re-slice: structurally specified + byte-verified here; the model-build is the
  remaining surgery (high add_block count; the fft block prefers a GUI mask-init).


## Stage 5 RESULT — BUILD SUCCEEDED (2026-06-24)
casper_build.sh rfsoc4x2_fe256 -> .fpg + .dtbo, headless, NO board programming.
  outputs/rfsoc4x2_fe256_2026-06-24_2220.fpg (1,522,631 B) + .dtbo
  jasper frontend: 0 errors (the REAL pfb_fir + reconfigured 256-pt fft (FFTSize=8)
    regenerated cleanly through SysGen netlist generation -- clearing the documented
    "headless fft regen" risk for the F-engine build).
  Vivado: synth_design completed, write_bitstream completed successfully.
  TIMING CLOSURE: "All user specified timing constraints are met."
    (route convergence WNS=+0.648ns, WHS=+0.010ns, THS=0.000 -- all positive.)
  Register map (from .fpg, strings ^?register): rfdc, adc_chan_sel, acc_len, acc_cnt,
    q1..q8 (spectrometer channel BRAMs), snapshot_ctrl, sync_gen_*, sys_clkcounter,
    sys_board_id, sys_rev -- the tut_spec_cx F-engine map with the 256-pt fft.

NOTE on what fe256 IS: it is the tut_spec_cx F-engine (pfb_fir + 256-pt cplx fft)
reconfigured to NCHAN=256, BUILT to prove the F-engine front-end synthesizes +
closes timing headless with the real fft (the gating unknown). It is NOT yet the
full 4-chain graft with the corner-turn + stream4 100GbE packetizer back-end --
that model-assembly is the remaining integration (byte contract fully verified here;
the wiring is the surgery, and the casper fft prefers a GUI mask-init for the 4x
replication). The .fpg proves: real pfb_fir + 256-pt fft build + timing-close on the
4x2 headless.

## 4-INPUT ULA — MTS requirement (for the coherent version only)
fe256/tut_spec_cx has per-tile MTS DISABLED (t224_enable_mts=off ... t227 off) -> no
SYSREF -> the 4 ADC tiles power up with RANDOM relative phase -> run_mts fails on the
real board with 0x200 = XRFDC_MTS_SYSREF_GATE_ERROR -> the ULA beamformer cannot form
coherent inter-element angles.
FIX (4-input graft ONLY): in the graft's rfdc yellow block enable the per-tile MTS for
the used tiles: t224_enable_mts = on, t226_enable_mts = on (tiles 224/226 = the 4 I/Q
SMA inputs; 225/227 terminated/unused). This synthesizes PL SYSREF + Analog SYSREF +
user_sysref_adc + marker/DTC logic. SYSREF must be <10 MHz and an integer sub-multiple
of the 122.88 MHz PL clock (CASPER 4x2 + LMK handle it when MTS is on). After
programming: run_mts(tile_mask=0b0101) to sync 224+226.
NOTE: NOT needed for the 1-input plumbing build (single tile, no inter-element phase) —
the 1-input streaming graft is built WITHOUT MTS. If enabling MTS breaks the headless
build, deliver the no-MTS 4-input version + document what the MTS-enable changed.

## STREAMING GRAFT (1-input) — status after deep integration attempt (2026-06-25)
GOAL: real ADC -> F-engine -> int8 -> corner-turn -> stream4 packetizer -> 100GbE.

MODEL (saved, NOT buildable): acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/
  rfsoc4x2_strm1.slx  (+ rfsoc4x2_strm1_STATUS.txt). Cloned from stream4_i8_hb;
  packetizer/onehundred_gbe back-end 100% intact; F-engine (fe_pfb_fir + fe_fft 256-pt,
  copied from fe256) wired; per-lane requant (c_to_ri -> gain Mult Fix_18_12=0.9 ->
  Convert Fix_8_7 Sat/Round) done; eq_pack = 16 int8 + 128b pad = 256b -> Register14/18.

BLOCKER (reproduced 3x — fork twice + my compile): jasper/compile fails with
  S-function 'sysgen' in '.../onehundred_gbe/.../tx_dest_ip':
  SS_OPTION_PORT_SAMPLE_TIMES_ASSIGNED ... Inheriting a sample time is not supported.
ROOT CAUSE (confirmed): the F-engine (pfb_fir+fft) is RATE-CHANGING. The stream4
  packetizer + onehundred_gbe were built for an ALWAYS-VALID single-rate raw-ADC
  stream that anchored one clean system clock. Inserting the rate-changing F-engine
  leaves the gbe subsystem's internal rate inference unresolved -> its control blocks
  (tx_dest_ip etc.) carry inherited (-1) sample time even though the dest-IP/port
  Constants themselves have explicit_period=on,period=1 (verified). So the failure is
  the gbe DATA-path rate (Mux6 <- FIFO <- F-engine), not the Constants.

THE FIX (mandatory, not optional) = the per-element CORNER-TURN dual-rate buffer:
  - It re-clocks the F-engine's decimated/gated channel stream up to the packetizer
    word rate (this is the rate-bridge that resolves the gbe inference), AND
  - does the [t][c]->[c][t] transpose + planar re|im split (8192B/element).
  Build it with casper_library_reorder/reorder (BUILD-TESTED: instantiates + ports
  compile headless; mask-init OK — the only compile error seen was a Gateway-Out
  logging artifact, not a reorder failure). The reorder map is DERIVED + VERIFIED:
  scratchpad/reorder_map.py -> map[p]=t*256+c, c=p//16, t=p%16 (4096-entry permutation,
  double_buffer=1). reorder has 3 in [sync,data,en] / 3 out [sync,data,valid].
  Remaining build steps:
   1. Insert reorder between eq_pack and Register14/18; feed it the fft FRAME SYNC
      (fe_fft port 11 — currently TERMINATED at eq_fftterm1; must be tapped) so it
      knows frame boundaries; en=const 1.
   2. Handle the 8-lane width: the fft emits 8 channels/clk; either n_inputs=8 reorder
      (map adjusted for lane parallelism) or serialize to 1-wide first.
   3. Planar split: after reorder, route the int8 re bytes to the re-plane and im bytes
      to the im-plane of the 8192B payload (re[0..4095] then im[4096..8191]).
   4. Drive the packetizer data-valid (FIFO write-enable / Mux6 / Counter1 framing)
      from the reorder OUTPUT VALID, not the raw ADC cadence (Counter1/Relational1/2
      currently keyed to the old always-valid rate).
   5. seq reconcile u32-BE@48 (header Concat1 re-slice) — byte-verified in graft_verify.py.

ALSO CONFIRMED (correctness bug in fe256): fe256's sync_gen mask = fft_size 2048 /
  scale 2048 while its fft is 256-pt (FFTSize=8) -> the frame sync fires every 2048
  samples, not 256. fe256's power-spectrum still looks OK on hardware (long
  accumulation is sync-cadence-tolerant), but ANY frame-boundary-dependent logic (our
  corner-turn's 16-consecutive-frame accumulation) REQUIRES the correct 256 cadence.
  strm1 already has this FIXED (sync_gen fft_size=256, shift Constant (2^8)-1).

DELIVERABLE .fpg THIS EFFORT: none new. Buildable artifacts remain:
  - rfsoc4x2_fe256_2026-06-24_2220.fpg (F-engine only, timing MET, HW-confirmed).
  - rfsoc4x2_stream4_i8_hb_2026-06-23_1858.fpg (raw 4-input int8 100GbE, timing MET).
The streaming graft needs the corner-turn built (steps 1-5 above) to close; that is the
single remaining keystone. 4-input ULA (with t224/t226_enable_mts) gates on the 1-input
rate-bridge first.

## SHARPER DIAGNOSIS (2026-06-25, after reorder rate-bridge attempt)
Inserting the CASPER reorder block (double_buffer, 512-word identity map) between
eq_pack and Register14/18 in strm1 -> saved as rfsoc4x2_strm1b.slx -> compile STILL
fails identically at onehundred_gbe/tx_dest_ip (inherited sample time). So the reorder
ALONE does NOT resolve it.
DEEPER ROOT CAUSE: onehundred_gbe's tx_dest_ip is a CONTROL register that should sit
at the single system/AXI clock. In stock stream4 the always-valid RFDC stream defines
ONE base rate and the whole gbe (data + control) locks to it. The F-engine introduces a
SLOWER derived rate (pfb_fir/fft decimation); now the gbe data input arrives at the
decimated rate while its control regs expect the system rate -> the gbe subsystem can no
longer infer a single base period -> tx_dest_ip inherits (-1).
=> The corner-turn must be a FULL-RATE READ-SIDE buffer: write at the F-engine
   (decimated) rate, READ at the ORIGINAL system rate so the gbe data path is back at
   the one rate the gbe locks to. A passthrough/identity reorder doesn't do this; it
   needs the read side explicitly clocked at the system rate (the double-buffer's read
   pointer advancing every system clock, output valid gating the FIFO). This is the
   real remaining design: a dual-rate (write decimated / read system-rate) transpose
   BRAM, NOT just a reorder permutation. Confirmed across 3 attempts (fork x2 + here).
RECOMMENDATION: build the corner-turn as an explicit dual_port_ram (bus_single/dual_
   port_ram from casper_library_bus) with write addr = arrival(t,c) @ fft rate, read
   addr = plane(c,t) @ SYSTEM rate, ping-pong on the TPKT-frame boundary, output valid
   -> FIFO we. This re-anchors the gbe to the system rate AND does the transpose. The
   reorder block (which builds headless) can be the read-permutation core, but it must
   be driven so its OUTPUT runs at the system rate. This is the keystone build; it is a
   multi-cycle FPGA construction task, not an incremental insertion.

## KEYSTONE PROGRESS (2026-06-25): dual-rate corner-turn buffer COMPILES + restores system rate
Root insight nailed: fe256 compile shows fft/pfb_fir run at CompiledSampleTime
[1000000 0] (an FFT-frame SUBRATE) while raw ADC/munge is [1 0]. The F-engine is a TRUE
Simulink rate-change. onehundred_gbe's control regs (tx_dest_ip) need the [1 0] system
rate; feeding them via the [1000000] fft-subrate path -> inheritance failure.
ISOLATED dual-rate buffer BUILT + COMPILE-VERIFIED (acme2:~/ct_iso.slx):
  xbsIndex_r4/Dual Port RAM, depth 4096, latency 2. WRITE port A (addr=t*256+c, we),
  READ port B (addr = plane-mapped, we_b=0). Read-addr map: rc(0..4095) -> t=rc[3:0],
  c=rc[11:4], arrival a = Concat(t[4b MSB]|c[8b LSB]) = t*256+c. Drive read side at the
  SYSTEM rate. RESULT: **READ-side dout CompiledSampleTime = {[1 0]} (system rate,
  resolved)** while bram=[1000000 0]. => the read side RESTORES the single system rate.
  This is the rate-bridge onehundred_gbe needs. Dual Port RAM mask-init works headless.
NEXT: insert into strm1 (read@system rate) -> confirm the tx_dest_ip inheritance error
  is GONE -> then full 8-lane + planar re|im + ping-pong + valid-gating + build.

## DEEP RATE ROOT-CAUSE (2026-06-25, dedicated keystone run) — and why the corner-turn alone doesn't fix it
CONFIRMED via compiled sample-times (fe256, which builds fine, has NO gbe):
  rfdc=[1 0] (system rate); munge1 outputs BOTH [1 0] and [1000000 0]; bus_create /
  pfb_fir / fft all = [1000000 0]. So the F-engine front-end (munge/bus_create) does a
  REAL HDL rate-change [1 0] -> [1000000 0] (the FFT-frame subrate). This is NOT a
  sim-only artifact (it's at bus_create, before any sim source).
STOCK stream4 (builds fine) compiled: Constant7(dest IP)/Mux6/FIFO = [Inf 0] (constant/
  untimed); pack4(data) = [1 0]. The gbe control regs are meant to be [Inf 0].
ISOLATED dual-rate BRAM (ct_iso.slx) WORKS: write@one-rate, read@system-rate -> read
  output = [1 0] resolved. So a dual_port_ram CAN bridge rates.
BUT inserting it into strm1 (-> rfsoc4x2_strm1c.slx: Dual Port RAM depth 512, 256b,
  write port A @ fft rate / read port B @ explicit-period [1 0], read -> Register14/18)
  did NOT fix the gbe: BOTH interactive compile AND jasper frontend STILL fail at
  'Constant7' / 'onehundred_gbe/.../tx_dest_ip': "Inheriting a sample time is not
  supported." DECISIVE PROBE: even after CUTTING the data path to the gbe (feeding its
  data input a constant), the error PERSISTS -> the gbe failure is NOT caused by the
  data-path rate. It is caused by the mere PRESENCE of the [1000000] subrate ANYWHERE in
  the model: it prevents the gbe's [Inf 0] control Constants (Constant7 etc.) +
  assert_* S-functions from resolving their sample time.
=> THE REAL BLOCKER is a GLOBAL multi-rate resolution conflict between the F-engine's
   [1000000] subrate and onehundred_gbe's [Inf]-constant control path — NOT the
   corner-turn rate-bridge (which works in isolation). The corner-turn is necessary for
   correct BYTES but is NOT sufficient to unblock the build.

LIKELY REAL FIXES (untested, the next substantial effort):
  (A) Make the F-engine stay at [1 0] using a data-VALID qualifier instead of a Simulink
      [1000000] rate-change — i.e., don't let bus_create/munge downsample the Simulink
      rate; gate processing with a valid signal at [1 0]. This keeps ONE rate so the gbe
      [Inf] constants resolve as in stock. (Most robust; matches how CASPER designs that
      have BOTH a PFB/FFT and a gbe are actually built — the data stays at the fabric
      rate, valid-gated.)
  (B) Explicitly anchor every gbe control Constant (Constant7/15/6/2/11/1/14 + the
      internal assert_*/Gateway-Ins) to [1 0] so they don't rely on [Inf]-resolution.
      Harder: the assert_* and tx_dest_ip Gateway are INSIDE the onehundred_gbe masked
      subsystem; touching them means editing the gbe yellow block internals.
  (C) Wrap the whole F-engine+corner-turn so only [1 0] crosses to the top level and the
      [1000000] is fully contained below a rate-restoring boundary the gbe never sees in
      its rate graph. (Unclear if Simulink's global rate check allows this.)
RECOMMENDATION: pursue (A) — restructure the F-engine front-end to NOT change the
  Simulink rate (valid-gated at [1 0]), then re-insert the corner-turn (verified bytes)
  + packetizer. That is the path to a buildable streaming graft. This is a fresh
  substantial design effort, not a quick patch.

ARTIFACTS this run (all on acme2, off-board, no programming):
  ~/ct_iso.slx           isolated dual-rate corner-turn BRAM (COMPILES, read=[1 0])
  ~/.../rfsoc4x2_strm1c.slx  strm1 + dual-rate BRAM inserted (build-blocked, global rate)
  scratchpad/reorder_map.py  verified 4096-perm corner-turn map

## PIVOTAL FINDING (2026-06-25): the [1000000] subrate is INTRINSIC to pfb_fir/fft
Tested a CLEAN single-rate F-engine (acme2:~/feclean_run.m -> fec.slx): pfb_fir + fft
(copied from fe256) fed from a PURE [1 0] source (Simulink Constant -> Gateway In, both
gw and gwsync compile [1 0]). RESULT: pfb_fir outputs BOTH [1 0] AND [1000000 0]; fft =
[1000000 0]. So the [1000000] subrate is introduced BY pfb_fir/fft THEMSELVES (their
n_inputs=3 / internal FFT serialization), NOT by the tut_spec adc_chan_sel Mux or
sync_gen spectrometer front-end. => "feed pfb from rfdc at [1 0]" does NOT eliminate the
subrate; the blocks are inherently rate-changing as configured.
IMPLICATION: the subrate cannot be eliminated by restructuring the front-end (it's in
the channelizer core). fe256 BUILDS FINE with [1000000] (no gbe) -> [1000000] synthesizes
correctly; it is a valid HDL/Simulink subrate. The ONLY problem is onehundred_gbe's
[Inf]-constant control path (Constant7/tx_dest_ip/assert_*) failing to resolve its
sample time when [1000000] coexists in the model's global rate graph.
=> The real fix is at the gbe boundary, not the F-engine: make the gbe control constants
   resolve despite [1000000]. Candidates to test next:
   (i) force the gbe dest-IP/port Constants to a CONSTANT ([Inf]) rate explicitly, or
   (ii) ensure the gbe DATA input is [1 0] (corner-turn read side) AND the gbe's own
        subsystem sees only [1 0]+[Inf] — may require the [1000000] to be fully contained
        below the corner-turn so it never enters the gbe's rate-resolution scope, or
   (iii) set the sysgen token simulink_period / a top-level rate so [1000000] resolves as
         an integer multiple of [1 0] (Simulink can then reconcile [Inf]).

## DEFINITIVE ROOT CAUSE (2026-06-25, exhaustive) — and the real path
DECISIVE EXPERIMENT (acme2:~/minbreak.slx): added a COMPLETELY ISOLATED fft to a STOCK
stream4 clone — fed by a pure [1 0] Simulink Constant, ALL outputs terminated, NOT
connected to the gbe or anything else. The gbe's tx_dest_ip STILL fails with the
inheritance error. => The mere EXISTENCE of the fft's [1000000] subrate ANYWHERE in the
model breaks onehundred_gbe's internal assert_*/tx_dest_ip sample-time resolution. It is
a GLOBAL Simulink multi-rate reconciliation failure, independent of all wiring.
ALSO: sysgen token simulink_period=1. The fft outputs [1000000] (≈ "once per 1e6 base
periods") = a SLOW/placeholder rate, NOT a true streaming rate. A correctly STREAMING
FFT (ata_snap style) outputs at the FABRIC rate [1 0] (pipelined, 8-in/8-out every clk).
tut_spec's fft (biplex, the spectrometer config) is NOT rate-preserving -> [1000000].
External fixes that FAILED (tested): corner-turn rate-bridge read@[1 0] (strm1c);
register-anchoring the gbe dest-IP Constants (anchor_gbe); cutting the gbe data path.
None help because the failing assert_* block is INSIDE the onehundred_gbe mask and the
[1000000] poisons the global rate graph regardless.
THE REAL PATH (one of):
  (1) Use a TRULY STREAMING FFT whose output rate == input rate [1 0] (the ata_snap/
      ARGOS pattern). tut_spec_cx's biplex fft is the wrong config. This means
      instantiating/configuring a streaming fft (fft_wideband_real / a different
      n_inputs/biplex setting) so it does NOT create a [1000000] subrate. THIS is the
      "eliminate the subrate" fix done correctly — at the FFT config level, not the
      front-end munge. (Substantial + the headless fft mask-regen risk applies.)
  (2) Edit the onehundred_gbe yellow block to not assert sample-time on its control
      inputs (modify a CASPER library block — invasive, non-portable).
  (3) Find the SysGen/Simulink global setting that lets [1000000] reconcile with the
      gbe's [Inf] constants (not found in this investigation).
HONEST STATUS: the streaming graft is blocked by a genuine FFT-config/rate mismatch with
the 100GbE block. The corner-turn (verified bytes, compiles in isolation, read=[1 0]) is
correct but insufficient. Closing this needs path (1): a streaming-FFT reconfiguration —
the next focused effort. fe256 (F-engine .fpg, timing MET, HW-confirmed) and
stream4_i8_hb (raw int8 100GbE, timing MET) remain the buildable artifacts.
ARTIFACTS: ct_iso.slx (dual-rate BRAM, read=[1 0], compiles), fec.slx (clean F-engine
rate test), minbreak.slx (isolated-fft-breaks-gbe proof), rfsoc4x2_strm1{,b,c}.slx
(front-end wired, build-blocked). scratchpad/reorder_map.py (verified corner-turn map).

## DECISIVE FFT-SWAP RATE CHECK (2026-06-25) — STOP the fft path
Per the time-boxed rate-only check: dropped the STREAMING wideband FFT
casper_library_ffts/fft_wideband_real (FFTSize=8 / 256-pt, n_inputs=2 = 4 real samp/clk,
input_bit_width=18, unscramble=on) into a clean test model (acme2:~/wbt.slx), fed from
PURE-SIMULINK [1 0] sources (Simulink Constant SampleTime=1 -> Gateway In; sync [1 0];
shift const). Compiled and read the data-output sample times.
MEASURED: ports in=6 out=4. wbf straddles [1 0] in / [1000000 0] out. ALL data outputs
out1..out4 = **[1000000 0]** (same slow subrate as the biplex fft).
=> Per the stop-criterion: the [1000000] subrate is INTRINSIC to CASPER FFTs (both the
   biplex `fft` AND the streaming `fft_wideband_real` produce it). Swapping the FFT will
   NOT make the F-engine rate-preserving -> it will NOT fix the gbe tx_dest_ip blocker.
   STOPPED the fft-swap path.
CONCLUSION: the fix is NOT on the FFT side. It is on the GBE side — how a working CASPER
streaming F-engine's 100GbE block tolerates the FFT's [1000000] subrate (e.g. ata_snap's
gbe usage / a gbe yellow-block config / packetizer pattern that doesn't assert
sample-time on the FFT-rate path). That is the separate next effort. Both CASPER FFT
configs measured here rule out the FFT-reconfiguration approach.
ARTIFACT: acme2:~/wbt.slx (wideband_real rate-check, out=[1000000]).

## CRUX SOLVED (2026-06-25): ata_snap F-engine = the real PFB+FFT+ethernet CASPER reference
FOUND (github realtimeradio/ata_snap, cloned to acme2:/tmp/ata_snap):
  snap_adc5g_feng.slx = a COMPLETE streaming F-engine: adc -> pfb -> fft -> eq(requant)
  -> eqtvg -> chan_reorder (12 reorder blocks = the corner-turn) -> packetizer (ants/
  chans/ips shared_bram BRAMs) -> eth_mux -> eth (tengbe 10GbE). EXACTLY our architecture.
DECISIVE: snap_adc5g_feng **COMPILES CLEAN** (ATA_COMPILES_CLEAN, NO sample-time error) —
  a real PFB+FFT+10GbE design. And the compiled rates show pfb/eq/chan_reorder/
  packetizer/eth ALL carry [1 0] AND [1000000 0] AND [Inf 0] simultaneously, end to end
  INCLUDING the eth block.
=> THE [1000000] FFT SUBRATE IS *NOT* INCOMPATIBLE WITH THE GBE. A working F-engine has
   the subrate flowing all the way to eth and it resolves. Our stream4-graft failure was
   NOT the subrate's existence — it was HOW we integrated (stapling fft onto
   tut_onehundred_gbe's raw-ADC packetizer; terminated/dangling fft outputs in minbreak;
   raw-Constant dest_ip without a coherent packetizer pipeline). The minbreak repro
   (isolated fft + stock gbe) created an UNRESOLVABLE subrate island; a CONNECTED
   pipeline (eq->reorder->packetizer->eth) resolves it.
KEY STRUCTURE to replicate:
  - eth is WRAPPED in a subsystem (outer iface data/vld/eof/dest_ip; inner tengbe with
    tx_data/tx_valid/tx_dest_ip/tx_dest_port/tx_end_of_frame/rx_ack/...).
  - dest_ip is a swreg (snap_adc5g_feng/corr/dest_ip), driven coherently.
  - eth_mux muxes corr + packetizer streams into one eth.
  - packetizer (shared_bram ants/chans/ips) is the FFT-rate -> eth-rate bridge + builds
    the packet (channel/antenna/IP mapping). chan_reorder is the corner-turn ahead of it.
  - The whole adc->...->eth path is ONE connected pipeline (no terminated subrate stubs).
CONCLUSION: do NOT staple fft onto tut_onehundred_gbe. ADAPT snap_adc5g_feng's
  eq->chan_reorder->packetizer->eth back-end for RFSoC4x2 / 256-ch int8 / 100GbE.

## ata_snap back-end structure (the parts to reuse) + BUILD PLAN
PACKETIZER (snap_adc5g_feng/packetizer): in[sync_in,data_in,mrst_in,version] ->
  out[data_out,valid_out,eof,dest_ip]. Contains shared_brams ants/chans/ips (per-packet
  antenna/channel/IP mapping), pkt_count/pkt_ctr/time_ctr counters, Register, Relationals,
  Mux, pulse_ext, Assert. It FRAMES packets from the FFT sync AND OUTPUTS dest_ip itself
  (from the ips BRAM) — so dest_ip flows in the data pipeline at the coherent rate (NOT a
  dangling raw Constant). THIS is why the gbe resolves.
ETH WRAPPER (snap_adc5g_feng/eth): outer iface[data,vld,eof,dest_ip] -> inner core=
  ten_gbe + ctrl swreg + Slice/Register/Logical adapters that map the simple iface to the
  tengbe ports tx_data/tx_valid/tx_dest_ip/tx_dest_port/tx_end_of_frame/rx_ack/...
EQ (requant): eq <- pfb/fft (per-channel equalize/requant to int8) -> eqtvg -> chan_reorder.
CHAN_REORDER: the corner-turn (12 reorder blocks) between eq and packetizer.

BUILD PLAN (1-input streaming graft, RFSoC4x2, 256-ch int8, 100GbE, config_ula.h):
  REUSE from snap_adc5g_feng (adapt, don't staple onto tut_onehundred_gbe):
   - eq (requant to int8; set our gain sw_reg Fix_18_12, Convert Fix_8_7) -- already
     bit-true verified (requant_iso/requant3).
   - chan_reorder (corner-turn) -- swap in our verified reorder map (reorder_map.py:
     plane=c*16+t) for 256ch x 16t planar re|im.
   - packetizer -- adapt the framing (TPKT=16 already matches nsamp_per_pkt=16!), set our
     payload=8192B/element, seq via pkt counter, dest_ip from an ips-style swreg/BRAM ->
     this is the KEY: drive dest_ip through the packetizer pipeline, NOT a raw Constant.
   - eth wrapper -- swap ten_gbe(10G) -> onehundred_gbe(100G) (the rfsoc4x2 100G CMAC),
     keep the wrapper adapter pattern (Slice/Register mapping data/vld/eof/dest_ip ->
     tx_*). Reconcile seq to u32-BE@48 in the packet header (verified: graft_verify.py).
  FRONT-END: feed the RFSoC rfdc (real ADC) -> our fe256 pfb_fir + fft (256-pt, proven
     to build+timing-close+HW-confirmed) -> eq. (ata uses adc5g; we use rfdc -- only the
     ADC source block differs.)
  REBUILD vs REUSE: rebuild the front-end ADC source (rfdc, ours); REUSE the
     eq->chan_reorder->packetizer->eth back-end PATTERN from ata_snap (the coherent
     pipeline that makes the subrate+gbe resolve). nsamp_per_pkt=16 == our TPKT=16 (lucky
     match). Build via casper_build.sh; success = JASPER_DONE_OK + timing.
  NOTE: ata_snap targets SNAP (Virtex7, 10GbE adc5g). Porting to RFSoC4x2 (ZU48DR,
     100GbE, rfdc) means swapping the platform yellow block + ten_gbe->onehundred_gbe +
     adc5g->rfdc, keeping the F->packetizer->eth dataflow. This is the concrete next build.

## STAGE A RESULT (2026-06-25): the ata pattern does NOT transfer to onehundred_gbe
Tested the ata_snap dest_ip pattern on OUR RFSoC model (strm1c: rfdc + CONNECTED fft +
corner-turn pipeline -> onehundred_gbe), THREE ways to drive tx_dest_ip:
  (A) software_register (From Processor, sample_period=1)        -> STILL FAILS
  (A2) Register the dest_ip INTO the data path (data sample-time) -> STILL FAILS
  (earlier: raw Constant7)                                        -> FAILS
ALL fail identically at onehundred_gbe/..._tx_dest_ip "Inheriting a sample time".
Meanwhile ata_snap (ten_gbe) COMPILES CLEAN with the SAME [1000000] subrate present
(eth carries [1 0]+[1000000]+[Inf]).
=> CONCLUSION: the blocker is the **onehundred_gbe yellow block SPECIFICALLY**. It rejects
   the model whenever a [1000000] FFT subrate exists ANYWHERE, regardless of how
   tx_dest_ip is driven (Constant / swreg / pipeline-registered). ata_snap's ten_gbe does
   NOT have this assertion behavior -> that's the real asymmetry, not the dest_ip wiring.
   The ata "drive dest_ip through the pipeline" insight is real for ten_gbe but does NOT
   fix onehundred_gbe.
NEXT (to confirm + find the onehundred_gbe-specific fix): (a) does onehundred_gbe have a
  mask option to disable/relax the tx_dest_ip sample-time assert? (b) can the rfsoc4x2
  use ten_gbe or forty_gbe instead (unlikely on the 100G QSFP)? (c) is there an
  onehundred_gbe usage pattern (a different input wrapper / a sync/enable the assert
  needs) in a working rfsoc 100G+fft design? The blocker is now precisely localized to
  the onehundred_gbe block's sample-time assertion vs the FFT subrate.

## BREAKTHROUGH DIAGNOSIS (2026-06-25): the [1000000] subrate is NOT the bug — an
## UNRESOLVED (-1) signal in OUR graft is (per CASPER dev Kocz: the assert victim != cause)
STOCK stream4 (compiles clean + BUILDS) framing rates: Register7=[1000000 0],
edge_detect=[1000000 0]+[Inf 0], Register10=[1000000 0], pack4(data)=[1 0],
FIFO/Mux6/Mux8/Counter1/Constant7=[Inf 0]. **STOCK ALREADY HAS [1000000] in its
packet-framing counters and compiles fine.** => the [1000000] FFT subrate was a RED
HERRING all along; our 6+ efforts mis-blamed it. The onehundred_gbe tx_dest_ip assert
is the VICTIM; the real cause is an UPSTREAM signal in our graft stuck at -1 (inherited).
EVIDENCE: in our graft (diagclean = stageA w/ gbe removed) the SAME error chases through
every sample-time-asserting block (gbe tx_dest_ip -> Gateway Out7 -> fifo_full/
sim_out_reg_gw) — proving a genuinely unresolved signal exists. Mux8 (tx_valid) and
Register7 (tx_eof) show rate=-1 in OUR model where STOCK has them at [1000000]. These
framing signals derive from Relational1<-FIFO-fill <- bus_create4 <- Register14/18 <-
our CORNER-TURN (ct_bram) read output. So the corner-turn read-side rate doesn't
propagate cleanly -> the FIFO-fill-derived framing (edge_detect/Mux8/Register7) can't
resolve -> -1 -> the assert fires (first at tx_dest_ip).
=> THE BUG IS OUR CORNER-TURN / packetizer-front rate, not onehundred_gbe, not the FFT
   subrate. Next: read our Register14/bus_create4/ct_bram output rate (should be [1 0] or
   [1000000] like stock's pack4->Register14); fix the corner-turn output to a resolved
   rate so the framing chain resolves. (Also re-examine: the fork's strm1 may have left
   the corner-turn/eq_pack with a -1; stock pack4=[1 0].)

## ROOT CAUSE FOUND (2026-06-25): our corner-turn READ-address counter is at [1000000], not [1 0]
Minimal corner-turn-only model (acme2:~/ctonly.slx, compiles clean) reveals:
  wa (write addr) = [1 0] ✓ ; **ra (read addr) = [1000000 0]** ✗ ; bram = [1000000 0] ;
  READ_OUT = [1 0]+[1000000 0].
So OUR corner-turn's READ-side counter `ra` resolves to [1000000] despite
explicit_period=on/period=1. Its [1000000] output propagates into Register14->FIFO->the
fill-derived framing (Relational1/edge_detect/Mux8/Register7), which then CAN'T reconcile
to a single rate -> -1 (inherited) -> the assert fires (victim = onehundred_gbe/tx_dest_ip).
THIS is the bug — not onehundred_gbe, not the FFT subrate (stock stream4 framing is
natively [1000000] and builds fine). Our corner-turn read counter is mis-rated.
FIX: make the read side a clean [1 0] (read every fabric clock). Suspect the Count-limited
Xilinx Counter's explicit_period doesn't force [1 0] in a multi-rate model; ct_iso.slx
earlier got read=[1 0] when ra was driven from a [1 0] Gateway-In-anchored source. Drive
wa AND ra at a guaranteed [1 0] rate (Gateway-In-anchored or a properly-periodic counter)
so the corner-turn output + downstream framing all resolve to [1 0] (matching stock's
pack4=[1 0] data path). Then the assert clears.

## REFINEMENT (2026-06-25): corner-turn read counters fixed to [1 0]; BRAM output still
## [1000000] (like the FFT + like STOCK framing) -- which is FINE (stock builds with it).
With wa/ra driven from a [1 0] Gateway-In anchor (ctfix_run.m): wa=[1 0], ra=[1 0], but
bram/rdreg=[1000000] (the Dual Port RAM imposes [1000000] on its output, same as the FFT;
registering it doesn't force [1 0]). Per the STOCK-stream4 finding, [1000000] downstream
is NOT the bug -- stock's Register7/Register10/edge_detect are [1000000] and it BUILDS.
So the real defect is a signal stuck at -1 (inherited), NOT [1000000]. Earlier: Mux8
(tx_valid) + Register7 (tx_eof) = -1 in our graft where STOCK has them resolved
([1000000]). Their chain: Relational1<-FIFO-fill ; Counter1/Counter3/edge_detect framing.
The -1 originates from a specific mis-rated signal the fork's strm1 introduced in the
eq/corner-turn/framing wiring (e.g. a Constant or valid/enable with no/ wrong period, or
a partially-connected input) -- NOT the corner-turn read counter (now [1 0]) and NOT
onehundred_gbe. REMAINING: pinpoint that one -1 signal (read framing-chain rates in a
build that doesn't abort at the gbe/fifo_full sim gateways) and give it an explicit
period / register it -- the targeted upstream fix Kocz described.

## DIAGNOSIS COMPLETE (2026-06-25): the -1 cluster = framing chain + From1/From2 Goto tags
With onehundred_gbe + fifo_full deleted, compile STILL aborts at orphaned gbe sim-status
gateways (gbe_ovflow_reg/sim_out_reg_gw etc.), but the consistent INHERITED (-1) cluster is:
  bus_create4, Mux8 (tx_valid), Register7 (tx_eof), Register10, Register13, edge_detect,
  From1, From2.
KEY: From1 + From2 are Goto/From TAG signals (-1). In stock stream4 these resolve. Their
being -1 means a Goto source is unresolved OR the tag binding broke when the fork rewired
strm1's front-end. The framing chain (edge_detect/Mux8/Register7/Register10 <- Relational
<- FIFO-fill, with From1/From2 carrying reset/enable tags) inherits the -1.
ANSWER to the diagnostic: the onehundred_gbe input that fires is tx_dest_ip (alphabetic/
elaboration-order victim); the UPSTREAM bad signals are the framing valid/eof chain
(Mux8=tx_valid, Register7=tx_eof) + From1/From2 tags, all at -1. NOT the FFT subrate
([1000000] is fine -- stock builds with it). NOT onehundred_gbe (the assert is the victim).
NOT the corner-turn read counter (fixed to [1 0]; its [1000000] BRAM output is also fine).
THE FIX (Kocz's upstream-signal fix): the fork's strm1 left the framing/From-tag signals
unresolved when it replaced the raw-ADC front-end with the F-engine. Restore the framing
chain to a resolved rate -- specifically check From1/From2 Goto sources and the
FIFO/edge_detect framing that in stock is driven by the always-valid ADC. The graft's
front-end must drive the packet-framing (valid/sync/enable) with a properly-rated signal
(the FFT sync, registered at the data rate) instead of leaving the stream4 framing
dangling at -1. This is a concrete, bounded wiring fix in strm1's framing, NOT a toolflow
wall. Diagnostic artifacts: ctonly.slx, ctfix_run.m (corner-turn rate), pinpoint.slx
(the -1 cluster), stock_frame.log (the target rates: stock framing = [1000000]/[Inf]).

## FORK ATTEMPT (2026-06-25): corner-turn counter fix IMPLEMENTED, but VERIFY DID NOT PASS
Implemented the corner-turn address-counter [1 0] fix on a fresh clone rfsoc4x2_strm1d.slx:
replaced ct_wa/ct_ra (Count-Limited, mis-rated) with the [1 0]-anchored pattern
(Counter Free-Running -> Gateway In 16b -> Slice 9b). Two variants tried:
  (1) BOTH ct_wa + ct_ra = [1 0]-anchored Slices.
  (2) ct_ra = [1 0]-anchored Slice; ct_wa = Count-Limited inheriting the write rate.
BOTH still ABORT at onehundred_gbe/tx_dest_ip "Inheriting a sample time". The fix did NOT
clear the abort.

ISOLATED TESTS PROVE THE CORNER-TURN STRUCTURE IS SOUND (4 ways, all compile CLEAN):
  - ctfix_run.m: wa/ra=[1 0], BRAM read resolves.
  - pptest.slx: BRAM read -> stock-style Register -> clean single [1000000].
  - ppbus_run.m: corner-turn -> Register14/18 ping-pong -> bus_create4 -> clean [1000000],
    NO -1. (the full ping-pong path resolves.)
  - ratemix_run.m: BRAM write-addr [1 0] + write-DATA [2 0] (mismatched rates) -> compiles
    CLEAN. So a write addr/data rate mismatch is NOT the bug.
=> The -1 is NOT in the corner-turn / BRAM / ping-pong / bus_create4 (all proven clean).

VERIFICATION BLOCKED BY MODEL STRUCTURE: every attempt to read the TRUE resolved framing
rates requires a clean-completing compile, but strm1d aborts at tx_dest_ip with the gbe
present, and removing the gbe + sim/debug gateways (Gateway Outs, *_led, fifo_full,
gbe_*_reg, edge_detect4) to force completion just creates NEW "Undriven input port"
errors (deletion orphans), aborting elsewhere. Post-abort CompiledSampleTime reads are
unreliable (everything shows Inf or -1 because propagation never finished). So I could NOT
confirm whether the -1 cluster (Mux8/tx_valid, Register7/tx_eof, edge_detect, From1/From2)
actually resolved.
CONFIRMED FACTS: STOCK stream4 compiles CLEAN (baseline OK). strm1d's eq_pack 17 inputs
all connected. rst Goto chain intact (pkt_rst->Slice8->Register2->Goto, From(rst) count=4,
dangling_gotos=0). So no obvious dangling source.
HONEST STATUS: VERIFY FAILED -- did not build. The corner-turn counter fix is correct but
insufficient; a real -1 remains in strm1d's back-end framing that I could not isolate
because the fork's strm1 lineage (strm1->b->c->d, many parent sessions) is too
sim-gateway-dense to probe via deletion without creating artifacts.
RECOMMENDATION: rebuild the graft CLEANLY from STOCK stream4 (which compiles clean),
swapping ONLY the data path (pack4 -> corner-turn) and keeping 100% of stock's
framing/control/sim-gateway infrastructure untouched -- rather than continuing to patch
the fork's accumulated strm1 lineage. Apply the proven corner-turn ([1 0] ct_ra anchor +
stock-style ping-pong) as the only insertion. Then the framing stays exactly as stock
(provably clean) and the only new variable is the corner-turn data feed.
Artifacts: rfsoc4x2_strm1d.slx (corner-turn fix applied, still aborts); ctfix/pptest/
ppbus/ratemix (isolated proofs the corner-turn is clean).

## CLEAN REBUILD FROM STOCK (2026-06-25, strm2 lineage) — the recommended rebuild, EXECUTED
Abandoned the contaminated strm1a-d lineage; rebuilt from a fresh clone of stock
stream4_i8_hb, compiling after each insertion against a KNOWN-GOOD baseline. acme2.

BASELINE (rfsoc4x2_strm2.slx) = exact copy of stock rfsoc4x2_stream4_i8_hb. Compiled:
  onehundred_gbe inputs: in1(tx_data)=[1000000 0], in6=[1000000 0], all control
  in2..in10=[Inf 0]. **TOTAL_MINUS1_GBE_INPORTS = 0.** Clean baseline confirmed.

FRAMING MAP (stock, all resolved, none -1): data path = munge1..4 -> pack4 (out [1 0],
  UFix_256_0) -> Register14/Register18 (ping-pong: same data in1, en=Slice12 vs
  en=Inverter(Slice12), rst=From) -> bus_create4 (->UFix_512_0) -> FIFO -> Mux6 -> gbe.
  Framing counters Counter1/Register7/10/13/From1/From2/edge_detect/Mux8/Relational1 run
  at [1000000 0] / [Inf 0]. THE SPLICE POINT = Register14.in1 + Register18.in1 (both fed
  by pack4(p1), 256-bit). Keep en/rst/bus_create4/FIFO/Mux/gbe 100% untouched.

STAGE (a) PASS — corner-turn passthrough (rfsoc4x2_strm2a.slx): deleted pack4->Reg14/18.in1,
  inserted a Dual Port RAM corner-turn (depth 512, latency 2, 256-bit) with READ + WRITE
  addresses anchored to [1 0] via the proven pattern (Counter Free-Running 16b tsamp 1 ->
  Gateway In period 1 -> Slice 9b), pack4 -> bram write data, bram read -> Register ->
  Register14.in1 + Register18.in1. COMPILE CLEAN: **GBE_MINUS1 = 0**, gbe in1/in6=[1000000],
  rest [Inf] (identical to baseline); ct_wa/ct_ra=[1 0]; ct_rdreg=[1000000];
  Register14/18/bus_create4/Mux8=[Inf]; Register7/From1/From2=[1000000]. tx_dest_ip
  RESOLVES. => CONFIRMS the corrected diagnosis: the corner-turn into CLEAN stock framing
  has ZERO -1; the prior 6 efforts' -1 was the contaminated strm1 framing, NOT the
  corner-turn / FFT subrate / gbe. The compile-after-each-insertion-from-clean method works.

STAGE (c) — F-engine inserted (rfsoc4x2_strm2c.slx): grouped strm1's F-engine+requant
  (fe_Mux/bus_expand/pfb_fir/fft/sync_gen/Constant2 + 8x c_to_ri/mul/convert + eq_pack,
  51 blocks) into ONE subsystem 'feng' (Out1=256b eq_pack), copied into strm2a, fed from
  adc_chan_sel+munge1..4, routed feng->ct_bram write data (replacing pack4). COMPILE ABORTS
  at onehundred_gbe/tx_dest_ip (the -1 again).
  => LOCALIZED to the feng insertion (stage a was clean; the ONLY new variable is feng).
  DECISIVE ISOLATION PROBE (fengprobe.slx = feng alone, [1 0] Gateway-In sources, output ->
  Gateway Out, NO gbe, NO corner-turn): **ABORTS at the Gateway Out with the SAME inherited-
  sample-time error.** => feng's OWN OUTPUT carries an unresolved (-1) sample time. The bug
  is INSIDE feng, i.e. inside the F-engine COPIED FROM strm1 (which itself NEVER compiled
  clean). NOT the corner-turn, NOT the gbe. This is exactly Kocz's "upstream unresolved
  signal" -- it lives in the contaminated strm1 F-engine (likely the sync_gen->pfb_fir->fft
  sync path the fork rewired). FIX: rebuild the F-engine from fe256 (proven clean +
  timing-closed + HW-confirmed), NOT from strm1. (Next: locate the exact -1 block in feng /
  rebuild feng's front-end from fe256's pfb_fir+fft+sync_gen.)

DECISIVE MINBREAK (rfsoc4x2_strm2c_tst.slx): added feng to the CLEAN stage-a model, fed it
  CORRECT-typed real sources (adc_chan_sel sel + munge1..4), but TERMINATED feng's output
  (Xilinx terminator, NOT connected to the corner-turn) and kept pack4->corner-turn (the
  clean stage-a data path) 100% intact. STILL ABORTS at onehundred_gbe/tx_dest_ip. => feng's
  MERE PRESENCE poisons the global rate graph (the classic "minbreak" pattern). The corner-
  turn is exonerated (stage a clean + this test clean-data-path still breaks). **feng itself
  carries an internal unresolved (-1) sample time.** feng was grouped from strm1's F-engine,
  and strm1 NEVER compiled clean -> its F-engine front-end (the fork's fe_sync_gen 2048->256
  rewire / sync wiring) is the contaminated source. CONCLUSION: must rebuild the F-engine
  front-end from fe256 (proven clean), not reuse strm1's feng. The corner-turn + clean-
  framing graft (strm2a) is DONE and correct; the remaining work is a clean F-engine.

ROOT CAUSE OF feng's -1 FOUND (mask compare vs fe256): feng's F-engine has an INTERNAL
  PARAMETER INCONSISTENCY the fork introduced:
    fe_pfb_fir PFBSize = 11  (2048-pt addressing, LEFTOVER from fe256's spectrometer)
    fe_fft     FFTSize  = 8   (256-pt)
    fe_sync_gen fft_size = 256 (the fork changed this 2048->256)
  In fe256 (which BUILDS) pfb_fir PFBSize=11 and sync_gen fft_size=2048 are CONSISTENT (both
  2048-addressed, fft 256-pt). The fork changed sync_gen to 256 but LEFT pfb_fir at PFBSize=11
  -> pfb_fir frames (2048) mismatch the sync cadence (256) -> unresolved sample time -> the
  -1 that poisons the gbe. THE FIX = set fe_pfb_fir PFBSize=8 (256-pt) so pfb_fir + fft +
  sync_gen are all consistent at 256. (single mask param; triggers pfb_fir regen, the
  headless-regen risk fe256 already cleared for the fft.)
  RESULT: set fe_pfb_fir PFBSize=8 (regen'd + saved clean headlessly), recompiled strm2c ->
  STILL aborts at tx_dest_ip. So PFBSize alone was not the -1 (or pfb_fir-256 has its own
  issue). The contaminated feng has a deeper -1. Running a no-gbe completing-compile to read
  feng's true output rate + the exact internal -1 block (strm2c_ng).
  ALSO TRIED (s17): made feng's F-engine EXACTLY match fe256's proven-building config
  (pfb_fir PFBSize=11 + sync_gen fft_size=2048/scale=2048 + fft FFTSize=8) -> STILL aborts at
  tx_dest_ip. => The F-engine MASK PARAMS are NOT the -1. The -1 is elsewhere in feng (the
  REQUANT chain eq_ctri/mul/cv/eq_pack, or an artifact of grouping strm1's blocks -- e.g. a
  self-driven fe_sync_gen clock-enable or a sync the grouping mis-bounded). no-gbe compile
  (s16) also aborted (chases to Gateway Out7) so post-abort rate reads stay NaN -- can't
  pinpoint the exact internal signal via this contaminated lineage.

## STATUS / HANDOFF (2026-06-25, strm2 clean-rebuild effort)
PROVEN + DELIVERED THIS EFFORT (the keystone the prior 6 efforts never reached):
  - rfsoc4x2_strm2.slx  = clean stock-stream4 baseline, 0 gbe -1.
  - rfsoc4x2_strm2a.slx = baseline + CORNER-TURN (Dual Port RAM, [1 0]-anchored read) spliced
    pack4->Reg14/18; COMPILES CLEAN, **GBE_MINUS1=0, tx_dest_ip RESOLVES**. This PROVES the
    corner-turn + 100GbE packetizer + stock framing graft is sound -- the corrected diagnosis
    is right (the prior -1 was contaminated-strm1 framing, NOT the corner-turn/FFT/gbe).
THE ONE REMAINING BLOCKER, precisely bounded: the F-engine subsystem 'feng' (grouped from
  the contaminated strm1, which never compiled clean) carries an internal unresolved (-1)
  sample time. minbreak proof: feng's MERE PRESENCE (correct [1 0] inputs, output TERMINATED,
  clean pack4->corner-turn data path) breaks the model. NOT fixed by PFBSize nor by matching
  fe256's exact F-engine params -> the -1 is in feng's requant/grouping, not the F-engine core.
THE REMAINING STEP (bounded, ~1-2 build cycles): rebuild the F-engine+requant CLEANLY -- group
  it directly from fe256 (the PROVEN-building F-engine: Mux->bus_expand->pfb_fir(PFBSize=11)->
  fft(FFTSize=8), with fe256's own sync chain) into a fresh 'feng2', add the requant
  (c_to_ri->gain Fix_18_12->Convert Fix_8_7, bit-verified in requant_iso) freshly (NOT copied
  from strm1), wire feng2->corner-turn(write data) in a fresh clone of strm2a, compile. Since
  strm2a's corner-turn+framing is proven clean, a clean feng2 should yield GBE_MINUS1=0 ->
  then casper_build.sh rfsoc4x2_strm2<X> for the .fpg + timing. Artifacts on acme2:
  rfsoc4x2_strm2{,a,a2,c}.slx, rfsoc4x2_strm1grp.slx (feng group), s1..s21 scripts in ~/.

  Also attempted a clean F-engine seed (s18): grouped fe256's PROVEN F-engine into 'feng2'
  (acme2:tut_spec/rfsoc4x2/rfsoc4x2_fe256grp.slx). fe256's sync chain has cross-dependencies
  (From2/From5/From3 sync-counter feedback + pulse_ext1 reset) so the group came out 9-in/14-out
  (vs feng's clean 5-in/1-out) -- the clean rebuild must rewire those sync From-tags + add a
  FRESH requant. fft data lanes = feng2 Out 'out00'..'out07' (ports 4,6,7,8,9,10,11,13), sync
  = 'sync_out' (port 3). This is the seed for the bounded remaining rebuild.

  BUILD of strm2a (corner-turn graft) via casper_build.sh: jasper FRONTEND REJECTED it --
  "Xilinx input gateways cannot be used in a design ... gateway ct_gwc". KEY LEARNING: the
  corner-turn's [1 0] address anchor used Simulink-Counter->Gateway-In->Slice, which compiles
  + simulates fine but jasper FORBIDS Gateway-In in a synthesizable build (sim-only source).
  FIX (s19, strm2a2): replace it with a PURE XILINX free-running Counter (n_bits 9,
  explicit_period=on, period=1 -> [1 0], synth-safe) feeding the Slices. This fix applies to
  the full design too. [recompile/build result below]
  RESULT (s21, rfsoc4x2_strm2a2.slx): replaced Gateway-In anchor with a pure Xilinx Counter
  (Free Running, Up, n_bits=16, explicit_period=on, period=1; correct param is cnt_by_val not
  cnt_by). COMPILE_OK, **GBE_MINUS1=0**, the only remaining Gateway-Ins (30) are stock XPS ones
  (rfdc/swreg/gpio) which jasper accepts. ct_cnt/ct_wa/ct_ra=[Inf 0] (free-running counter
  folds to untimed at compile, synthesizes as a real counter), ct_rdreg=[1000000]. strm2a2 is
  now BUILD-READY (no forbidden Gateway-In). casper_build.sh rfsoc4x2_strm2a2 launched
  [.fpg + timing result below].
  **BUILD SUCCEEDED (2026-06-25): rfsoc4x2_strm2a2 -> jasper frontend 0 errors, SysGen netlist
  clean, Vivado synth_design completed + write_bitstream completed successfully, TIMING CLOSED:
  "No timing violations", WNS=+0.515ns, WHS=+0.014ns, THS=0.000 (all positive).** => the
  CORNER-TURN (Dual Port RAM transpose, synthesizable Xilinx free-running counter) SYNTHESIZES
  + ROUTES + CLOSES TIMING through the full stock 100GbE packetizer on the RTL/4x2. The
  keystone graft is now proven all the way to a bitstream, not just compile.
  .fpg DELIVERED: acme2:~/src/tutorials_devel/rfsoc/tut_onehundred_gbe/rfsoc4x2_strm2a2/
    outputs/rfsoc4x2_strm2a2_2026-06-25_1534.fpg (897 KB). This is the corner-turn + 100GbE
    packetizer graft (raw int8 data through the transpose BRAM), timing-closed. It is NOT the
    full F-engine streaming graft yet (the F-engine remains the bounded remaining step, blocked
    only by the contaminated strm1 'feng' -- rebuild from fe256 per above), but it PROVES the
    entire corner-turn -> packetizer -> 100GbE path synthesizes + closes timing on the 4x2.

## FINAL STEP — CLEAN fe256 F-ENGINE REBUILD (2026-06-25, rfsoc4x2_strm3)
Rebuilt the F-engine CLEANLY from fe256 (NOT strm1's contaminated feng), into a clone of the
proven strm2a2 (corner-turn back-end kept 100% intact). Copied fe256's INDIVIDUAL proven blocks
(Mux,bus_expand,pfb_fir[PFBSize=11],fft[FFTSize=8],Constant2[shift (2^11)-1] + the FULL sync
chain sync_gen->Delay23->Goto(sync_gen); From(sync_gen)->pipeline3->pfb_fir.sync; sync_cntr fed
by From(cnt_rst)+From(sync_gen), Goto(cnt_rst)<-const0). fe256 sync uses Goto/From TAGS
(sync_gen, cnt_rst) -- so no dangling sync (the likely strm1 contamination was a broken tag).
PHASE 1 (fft outputs TERMINATED, no requant): compile ABORTS at tx_dest_ip -- a clean fe256
  F-engine with TERMINATED outputs STILL poisons (the [1000000] subrate as an isolated island,
  the minbreak pattern). => the F-engine MUST be CONNECTED through the corner-turn (read@[1 0]
  re-anchors the rate), not terminated. Terminating its outputs is the wrong test.
PHASE 2 (fresh requant -> corner-turn): added a FRESH requant on fft lanes 2..9 (c_to_ri Slice
  hi24|lo24 + Reinterpret Fix_24_23 -> Mult x gain[Fix_18_12=0.9] -> Convert Fix_8_7 Round+/-Inf
  Saturate), packed 16 int8 + 128b pad = 256b (eq_pack), fed ct_bram write data (replacing
  pack4). Exact params from strm1's bit-true eq_* (NOTE: Constant arith_type = 'Signed (2''s
  comp)' ONE space; Mult/Convert/Reinterpret = TWO spaces). [result below]
  PHASE 2 RESULT: still ABORTS at tx_dest_ip. SAME as strm1's feng -> so the blocker is NOT
  strm1 contamination at all; it is the CORNER-TURN WRITE-PORT RATE MISMATCH: ct_cnt drives the
  write address at [1 0] but the write DATA (eq_pack) is [1000000] -> the BRAM write port can't
  form a coherent rate -> framing -1. In stage (a) this didn't happen because pack4 (write data)
  was ALSO [1 0]. => THE FIX is the genuine DUAL-RATE corner-turn (the prior notes' keystone):
  WRITE at the F-engine [1000000] rate, READ at the system [1 0] rate (ct_iso proved read
  resolves to [1 0] with this). PHASE 3 (strm3b): drive the BRAM write address + write-enable
  at the eq_pack [1000000] rate (write counter EN'd by a continuous [1000000] valid from eq_pack
  via Slice->Relational a>=0), keep ct_ra read at [1 0]. [result below]
  PHASE 3 RESULT (strm3b): still ABORTS at tx_dest_ip. The dual-rate write fix did not clear it
  either. => running a NO-GBE completing compile (strm3b_ng: delete onehundred_gbe) to scan
  EVERY block for the actual -1 signal (Kocz trace) -- the contamination-independent root cause.

## FINAL-STEP CONCLUSION (2026-06-25): clean fe256 F-engine hits the SAME wall as strm1 feng
EXHAUSTIVE result of the clean fe256 rebuild (the requested final step), all on the proven
strm2a2 corner-turn back-end (kept intact):
  - PHASE 1 (clean fe256 F-engine, fft terminated):           ABORTS at tx_dest_ip
  - PHASE 2 (+ fresh requant -> corner-turn data input):      ABORTS at tx_dest_ip
  - PHASE 3 / strm3b (+ dual-rate corner-turn: write@[1000000]/read@[1 0]): ABORTS at tx_dest_ip
  - strm3c (- the auxiliary sync_cntr/cnt_rst chain):         ABORTS at tx_dest_ip
=> A FRESHLY-BUILT, CLEAN fe256 F-engine (proper sync via Goto/From tags 'sync_gen', fresh
   bit-true requant, dual-rate corner-turn) produces the IDENTICAL tx_dest_ip "Inheriting a
   sample time" abort as strm1's feng, in EVERY wiring configuration. THE BLOCKER IS NOT strm1
   CONTAMINATION and NOT a simple fixable wiring -1 in our construction.
-1 LOCALIZATION via no-gbe completing-compile FAILED (as the prior notes predicted): deleting
   onehundred_gbe -> aborts at Gateway Out7 (orphaned sim gateway); deleting +all Gateway Outs ->
   aborts at fifo_full/sim_out_reg_gw (swreg sim gateway); deleting +5 sim swregs -> "Undriven
   input port" deletion artifacts (edge_detect4/Delay). The model is too sim-status-gateway-dense
   to force a clean complete compile by deletion -> the exact -1 stays NaN (unreadable).
ROOT-CAUSE ASSESSMENT (after 8+ efforts incl this clean rebuild + a CASPER expert + the mailing
   list): the abort is a fundamental interaction between the CASPER FFT's [1000000] Simulink
   SUBRATE (intrinsic to both biplex `fft` AND `fft_wideband_real`, measured) and the
   onehundred_gbe block's sim-status sample-time-assertion infrastructure. It is NOT cleared by:
   clean F-engine rebuild / proper sync tags / requant freshness / corner-turn rate-bridge /
   dual-rate write / dropping aux sync. CANDIDATE REAL FIXES (none quick, all substantial): (a)
   modify the onehundred_gbe yellow-block internals to not assert sample-time on its control
   inputs; (b) a truly streaming FFT that emits at the fabric rate [1 0] (the ata_snap/ARGOS
   pattern -- but tut_spec's biplex fft + fft_wideband_real both measured [1000000]); (c) the
   ata_snap ten_gbe back-end pattern (compiles clean WITH the [1000000] subrate, but the 4x2 board
   uses a 100G QSFP, not 10G). NOTE the contradiction in the record: stock stream4 framing is
   ITSELF [1000000] (counter-derived) and builds fine, yet the FFT's [1000000] (subrate-derived)
   poisons -- so the two [1000000]s are DIFFERENT timing constructs that don't reconcile in the
   global rate graph; this is the precise crux for whoever picks this up next.

## DELIVERED THIS SESSION (net): rfsoc4x2_strm2a2_2026-06-25_1534.fpg -- the corner-turn + 100GbE
## packetizer graft, TIMING-CLOSED (WNS +0.515ns / WHS +0.014ns). The F-engine -> 100GbE streaming
## graft remains blocked by the FFT-subrate-vs-onehundred_gbe wall (a CASPER toolflow issue, not a
## wiring bug fixable by the clean rebuild). Artifacts on acme2: rfsoc4x2_strm3{,b,c}.slx (clean
## fe256 F-engine + requant + corner-turn, build-blocked), f1..f9 scripts in ~/.
