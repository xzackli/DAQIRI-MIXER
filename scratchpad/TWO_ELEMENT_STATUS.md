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
