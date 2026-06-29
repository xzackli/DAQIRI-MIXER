# 2-element manas2el F-engine — overnight build + HW verify (2026-06-29 ~06:30)

## BUILT + PROGRAMMED + STREAMS (manas2el_2026-06-28_2254.fpg, WNS +0.270ns, JASPER_DONE_OK)
The 2-element F-engine (n_streams=2 FFT + 2 parallel pfb_fir_real + twin proven DPRAMs +
rd_sel_mux + 2-sweep readout + seqctr@48 + elem@52) builds, times-closes, programs, and
streams clean on hardware:
- ADC0 + ADC2 both locked (State 15).
- CX-5: 100% jumbo (8192-10239 bucket), ~240k pps, **rx_discards +0** (no drops, no tiny pkts
  -> NOT the manas256d tiny-packet failure).
- Regmap confirms both edits: adc_snapshot1_ss_* (tile226) present; eth_en_gated/period_ok/
  acc_thresh/mts_period_ok GONE (broken interlock removed -> direct eth_en, streaming unbroken).

## FRAMING STRUCTURALLY CORRECT, ONE FIXABLE CONTENT SKEW (the test_mode gate caught it)
test_mode=1 ramp capture + boundary decode (the manas256d-class gate):
- seq (BE u32 @48) increments +1/packet ✓; elem@52 alternates 1,0,1,0 ✓ (elem == seq%2).
- BUT a CONSTANT boundary skew: element0 (ramp) packets have their FIRST 72 BYTES = ZERO and
  the ramp from byte 72; element1 (~zero) packets have 72 bytes of ramp-like data at the START.
  So exactly the first 72 bytes (= 9 read-words = 1 dense-word(8) + 1 read-word) are displaced
  between the two elements, consistently, every boundary (1495/1495).
- ROOT CAUSE: the element-select (rd_sel_mux via elemctr, toggled on gb_eofand) acts at the
  gearbox INPUT, but the packet eof is at the gearbox OUTPUT -> they differ by the gearbox
  pipeline depth (gb_cat512 8-word collect + gb_pipe512 1-word delay = 9 read-words = 72 bytes).
  This is precisely the 1-word-class skew Reviewer 2 flagged; the test_mode boundary capture
  (element0=ramp / element1=zero) made it unambiguous.
- FIX (gated, in progress): phase-align the elemctr/rd_sel_mux select with the gearbox output
  by delaying the select ~9 read-words (1 dense word), OR equivalently compensate the boundary.
  Control-net delay only; does NOT touch the explicit_period anchor / corner-turn / channelizer.

## VERIFY status
- Build verify-execute: PASS (timing + regmap).
- Stream/jumbo/discards: PASS.
- Boundary framing: FAIL (the 72-byte skew) -> fix + rebuild + re-capture.
- MTS run_mts + coherent-tone alignment: pending (8MHz LMK staged; tone needs the bench).
- byte52 antenna-ID drop-immunity: pending two-box run.

Scripts: scripts/fpga_bringup/{bringup_2el,boundary_verify,mts_bringup,mts_verify}.py;
overnight: ~/prog_2el.py, ~/bringup_tm.py, /tmp/skew.py (the decode).
manas256f/manas256 untouched fallbacks.

## SKEW FIX — diagnosis REFINED + verified-direction (gated plan->verify, 2026-06-29 ~07:00)
Two gated plan->verify passes nailed the fix DIRECTION (a wrong one was caught before any rebuild):
- The skew = the gearbox OUTPUT pipeline: rd_sel_mux.sel = elemctr (toggles on gb_eofand = OUTPUT
  eof at gb_wctr==128), but the selected DPRAM data traverses gb_cat512(8 collect)+gb_pipe512(+1)
  = 9 read-words before output. So the input-side mux switches 9 read-words too LATE vs the output
  packet boundary. A cycle-accurate read-clock sim confirms: baseline 9 mismatch/boundary (=72B,
  matches HW 1495/1495); ADVANCE-select-by-9 -> 0 mismatch; delay-by-9 -> 18 (worse); advance-by-8
  -> 1 residual (the +1 = the gb_pipe512 dense-word quantum). 9 read-words = 1 dense-word(8) + 1.
- WRONG approach caught by verify: driving a new select counter's enable from rd_eofdly (= gb_eofand
  DELAYED 1) DELAYS the select by +1 (makes skew ~10), does NOT advance. rd_eofdly is structurally
  incapable of a 9-word advance. (The 'delay ~9' note in the earlier memo had the sign loose.)
- CORRECT fix (advance the rd_sel_mux DATA-select by 9 read-words; KEEP elem@52/seq header as-is):
  the select must toggle 9 read-words BEFORE the elemctr/output-eof. Cleanest realizations:
  (B1) a dedicated early-toggle pulse anchored at read-word 1015 (=1024-9) within the readout window
       (the select counter enabled by that pulse) -- phase-pin the exact read-word via a Gateway-out
       probe / the cycle-sim when the model is open (NOT rd_eofdly).
  (B2-fixed) co-align by construction: carry the element tag for the HEADER through the SAME
       gb_pipe512 pipeline as the data so they emerge together -- but note a packet has ONE elem@52,
       so this only helps if framed as advancing the select; the DATA-select advance is the real fix.
  Control-net/1-bit-select ONLY; anchor (DPRAM explicit_period), Counter5/Counter3 widths,
  channelizer, seqctr all untouched. Low design risk; the ONLY uncertainty is the exact sub-dense
  phase, best pinned interactively (program/capture/adjust) since sim-vs-HW phase may differ by 1.
- STATUS: fix DIRECTION verified (advance-by-9). Exact phase-pin = the last step (1 short edit + a
  rebuild, possibly one phase-trim iteration). Left for an interactive pass rather than blind
  overnight rebuild-looping on a 1-read-word phase. manas2el streams correctly TODAY except this
  72-byte boundary displacement; manas256f/manas256 untouched fallbacks; the test_mode gate + decode
  (boundary_verify.py) is the ready, proven check for the fixed build (target 0/1495).

## MTS PROVEN ON HARDWARE — first-ever run_mts, tiles 224+226 ALIGNED (2026-06-29 ~07:30)
No-FPGA-reprogram MTS run on the programmed manas2el (rfdc.init with the 8MHz-SYSREF LMK +512M LMX
upload, then run_mts): **run_mts -> True; ADC0 Latency(T1)=104, ADC2 Latency(T1)=104 = EQUAL** (Offset
0, Marker_Delay 15 both). This is the deterministic-alignment success criterion. CONFIRMS in one shot:
- the t224/t226 enable_mts gateware is correct (no 0x200 NOT_ENABLED);
- the 8MHz SYSREF (LMK rfsoc4x2_lmk_..._PL_128M...; SYSREF_DIV=320 -> 8.000MHz) is legal (no 0x800/0x1000);
- the PG269/ALPACA AXIS-clock-from-PL topology IS valid for MTS on the stock rfsoc4x2 (the net named
  adc_clk = the pl_clk MMCM output) -> the whole AXIS-clock investigation conclusion is HW-confirmed.
ADC0/ADC2 State 15/PLL1 after the 8MHz init; ADC1/ADC3 State 12 (not in the 0b0101 group, expected).
STILL PENDING (bench): the coherent-tone fftconvolve argmax==0 phase-stability proof (needs a split CW
tone to the SMAs) + repeatability across reprograms; run_mts alignment itself is now PROVEN. Script: ~/mts_run.py.

## SKEW FIX APPLIED — canonical post-gearbox mux (2026-06-29 ~08:30, building)
Explore-before-fix (2 explorations: local CASPER designs + web prior art) converged on ONE rule:
the element-select must be CO-TIMED with the data it gates (never select-at-input toggled-by-output).
Gated plan->verify->modify->verify (each with an INDEPENDENT cycle-accurate read-clock sim) chose+applied
CANDIDATE 1 = MUX POST-GEARBOX (the ata_snap/LFAA "select at the framing stage" structure):
  - Sim proof (3 independent models, baseline reproduces HW 9/72B exactly): post_gearbox = 0 mismatch
    AND offset-INDEPENDENT; advance9 = 0 but KNIFE-EDGE (+-1 -> 1, the sim-vs-HW fragility -> rejected);
    sideband-tag = 9 (relabels only); rd_eofdly = 10 (worse). Decisive: post-gearbox is phase-trim-free.
  - Edit: DELETE rd_sel_mux (input-side); feed DPRAM1 -> existing gearbox A; ADD a BIT-FOR-BIT LOCKSTEP
    gearbox B on DPRAM2 (reuse the single gb_streq/gb_wctr/gb_eofand strobes, no new explicit_period);
    mux the two fully-gearboxed 512b words by elem_outmux (sel=elemctr, kept en=gb_eofand) at the OUTPUT,
    feeding gb_mux512.in3. Select + packet boundary now both in the OUTPUT dense domain -> 0 skew by
    construction. ~13 blocks, 100% downstream of the DPRAM explicit_period anchor.
  - GATE CATCH: executor measured gearbox-A input latency = 3 (data_delay1+Mux3+Delay4), NOT the 2 the
    plan listed; added a matching 'midb' stage so A and B stay lockstep (the decisive requirement).
    verify-modify independently confirmed input-A=3 == input-B=3, anchor/channelizer/seqctr/elem@52 header
    byte-identical. ready_to_rebuild=TRUE.
  - REMAINING: rebuild .fpg (in progress) -> program -> test_mode ramp capture + boundary_verify.py,
    target 0/1495 boundaries skewed. The phase-pin "advance-9" idea is DROPPED (knife-edge).
