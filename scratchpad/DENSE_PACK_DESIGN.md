# manas256e — dense-pack design (2026-06-27)

## STEP 1 — MEASURED 64b corner-turn word layout (compiled widths, manas256)
- complex_convert / complex_convert1: IN UFix_36_0 (18b re ++ 18b im FFT sample), OUT UFix_16_0
  => each spectral sample is requantized to **int8 complex = 8b re + 8b im = 2 bytes**. NO int16->int8
     requant needed; config_ula.h int8 already matches.
- bus_create: IN1=16b (fft0 via complex_convert), IN2=16b (fft1 via complex_convert1), OUT=UFix_32_0
  => 2 channels written per clock (the FFT's 2 complex bins/clk). hi=fft0 sample, lo=fft1 sample.
- Dual Port RAM1: data IN2=UFix_32_0 (32b write/clk), read OUT2=UFix_64_0 (64b/clk).
  => width-doubling corner-turn: each READ word = 64b = **4 channels x int8-complex = 8 bytes real**.
- Delay4 / txd512.lo / Mux3 / Counter1(seq) / DPRAM-read all = UFix_64_0, ST [1000000 0].
- txd512 = Concat(c_pad448[448b zero=hi] ++ Delay4[64b real=lo]) = UFix_512_0  => 64B wire word =
  **8 B real (4 ch) + 56 B ZERO PAD**.

### byte order in the 64b real word (MSB->LSB, Concat hi->lo):
  bus_create hi = complex_convert(fft0) = fft bin 2k ; lo = complex_convert1(fft1) = bin 2k+1.
  DPRAM read packs 2 writes -> 64b = [write_n+1(2ch)] ++ [write_n(2ch)] (read addr 2x write stride).
  Each 16b complex sample = [re8 ++ im8] (complex_convert outputs re in hi byte, im in lo). 
  => 64b word carries 4 consecutive channels, each as (re,im) int8. Exact MSB/LSB channel order
     to be confirmed against config_ula.h planar layout on the wire capture; GPU contract is PLANAR
     re[NCHAN*TPKT] then im[NCHAN*TPKT] which differs from this INTERLEAVED (re,im per ch) on-wire
     order -> a GPU-side or remap concern, NOT a framing concern (see note at bottom).

## CURRENT manas256 framing (PROVEN, padded)
- 1 wire word = 1 DPRAM read word = 64B (8B real + 56B pad).
- pulse_ext4=128 => Counter5 (DPRAM read addr) enabled 128 clk => 128 read words/packet.
- 128 read words x 4 ch = 512 ch-slots = **2 spectra (256 ch each) = 2 time samples** per packet.
- payload = 128 x 64B = 8192B (but only 128 x 8B = 1024B real). +1 seq word (pulse_ext3=129) => 8256B.
- Trigger: Counter3 (12b write-word counter from fft_sync edge); c3_lo8>=cns_mux_en1(127) OR
  Counter3>=cns_mux_en3(4095) -> Logical1 -> Logical2(&first_sync) -> pulse_ext3/4.
- seq = Counter1 (64b free-run) muxed into word 0 (Mux3/From_tx_data3). Board ~1.0M pps.

## DENSE-PACK ARITHMETIC (target = config_ula.h: 8192B = 256ch x 16t x 2B)
- real bytes / read-word = 8 (4 ch). To fill 512b (64B) wire word w/ NO pad: **N=8 read-words -> 1 dense word**.
- payload 8192B = 8192/64 = **128 dense wire words** = 128 x 8 read-words = **1024 read-words**
  = 1024 x 4 ch = 4096 ch-slots = 256 ch x **16 time samples** = EXACTLY config_ula.h [256ch x 16t]. GOOD.
- +1 seq word => 129 dense wire words => **8256B frame** (same frame size as now, 16x the real data).

### RATE DOMAINS (THE TRAP that broke manas256d):
- READ-CLOCK domain: DPRAM read words, 1 per clk during readout. Need 1024 reads/packet => pulse_ext4 128->1024.
- DENSE-WORD domain: 1 dense word per 8 read clks. tx_valid high only on those 1-in-8 clks. eof once per 128 dense.
- A mod-8 strobe (from a counter on the read-clock, reset at window start) gates: (a) the dense-word register
  latch, (b) tx_valid. seq inserted as dense word 0.

## DESIGN (Option B: keep DPRAM + trigger + Counter3/Counter5 read machinery; widen readout; add 8:1 gearbox)
Edits, each compile-checked:
1. pulse_ext4 128 -> 1024  (read 1024 words/packet = 16 spectra). Counter5 must address >=1024 reads:
   Counter5 is 11b (0..2047) already -> OK, no width change (do NOT touch DPRAM depth; only 0..1023 used,
   DPRAM is 4096 deep). The DPRAM WRITE side already fills the buffer each spectrum; reading 1024 words
   reads 16 spectra worth IF 16 spectra are resident. **RISK: the corner-turn buffer may only hold a few
   spectra; reading 1024 words may re-read / wrap.** -> verify on HW (data content), framing is the gate here.
2. Replace txd512 (Concat pad448++Delay4) with an 8:1 SERIAL->PARALLEL gearbox:
   - 8-tap delay line OR 8 registers capturing 8 consecutive 64b read words -> Concat(512b) NO pad.
   - mod-8 counter (reset by window-start / first read) -> strobe on count==7.
   - dense_valid = strobe AND (within readout window). Put explicit_period=1 on the gearbox output reg if -1.
3. tx_valid / tx_eof in DENSE domain:
   - tx_valid = dense_valid (1-in-8). Must be high for 129 dense words (128 data + seq).
   - simplest: count dense strobes; assert tx_valid for 129 strobes; eof on the 129th. OR reuse pulse_ext3
     but RE-RATE it to the dense strobe (pulse_ext3 currently counts read clocks). 
   - seq dense word 0 via Mux3 (unchanged structurally; just in dense domain).

## ANTI-OSCILLATION SUCCESS CRITERIA
- compile clean (no -1) after EACH edit.
- HW: board tx ~125k pps (8x LOWER than manas256's ~1.0M). If rate goes UP -> bug repeated, STOP.
- CX-5: jumbo bucket rx_8192_to_10239 climbing at ~125k pps, 0 discards, BYTE rate ~8x lower than... no,
  byte rate roughly SAME frame size but 8x fewer frames => ~8x lower total bytes. Real-data fraction now ~100%.

## NOTE: on-wire byte order vs config_ula.h
config_ula.h wants PLANAR re[256*16] then im[256*16]. The F-engine emits INTERLEAVED (re,im) per channel,
spectrum-major. This is a CONTENT-LAYOUT remap (GPU ingest / reorder yaml), NOT the dense-pack framing task.
Dense-pack delivers CONTIGUOUS real int8 (no pad) = 8192B of [ (re,im) per ch, 4 ch/word, 64 words/spectrum,
16 spectra ]. The GPU remap from interleaved->planar is the integration concern flagged in config_ula.h.

## SEQ HEADER FIX — manas256f (2026-06-27)
### ROOT CAUSE of manas256e constant-0x01 seq (diagnosed, not guessed):
- manas256e word0 = gb_seq512 = Concat(gb_seqhi[448b 0, HI] ++ Counter1[64b, LO]). Counter1 in the LO 64b.
- Baseline manas256 wire proof: seq = LITTLE-ENDIAN uint32 at UDP-payload bytes 0-3 (Counter1 LSB-byte at
  payload byte0; LE32 increments +1/packet: 9881079,80,81...). So Concat LO 8b -> tx_data byte0 -> wire payload
  byte0.
- BUT manas256e captured word0 = `01 00 00..00` CONSTANT across all packets (NO byte varies; Counter1's nominal
  bytes 56-63 read 0). => Counter1 is NOT reaching the seq word as a live incrementing value.
- Counter1.en = edge_detect4 <- From(tx_valid tag) <- Goto_tx_data6 <- data_delay2 <- Mux4 <- pulse_ext3 (the
  OLD read-clock-domain tx_valid, still published). Counter1.rst = From(rst_tx) <- rst_count reg.
  The dense rewire moved the GBE tx_valid to gb_vand but LEFT Counter1 keyed to the old tx_valid edge; the net
  effect on HW was Counter1 not advancing in the seq word (stuck/zeroed) + a stray 0x01 at byte0. Rather than
  untangle the fragile shared Counter1, manas256f uses a FRESH dedicated seq counter on a KNOWN-GOOD enable.

### manas256f FIX (built on a COPY; manas256e + manas256 kept as fallbacks):
- NEW `seqctr` = 32b Free-Running Counter, **en = gb_eofand** (the dense tx_eof = strobe & wctr==128 = EXACTLY
  one pulse/packet, unambiguous), rst = From(cnt_rst). +1 per packet by construction.
- BE byte-swap: 4x Slice (seq_b0=[7:0],b1=[15:8],b2=[23:16],b3=[31:24]) -> seq32be = Concat(hi=b0,b1,b2,lo=b3)
  so the field's LO 8b (=lowest tx_data byte of the field) = b3 = MSB => BIG-ENDIAN on the wire.
- PLACEMENT at config_ula.h offset (seq uint32 BE @ UDP-payload byte 48): gb_seq512f = Concat(hi=zero96[96b] ++
  seq32be[32b] ++ lo=zero384[384b]). LO 384b = tx_data bytes 0-47 = zero; next 32b = tx_data bytes 48-51 =
  seq32be (BE); hi 96b = bytes 52-63 = zero. => seq lands at UDP-payload bytes 48-51, big-endian.
- gb_mux512 d0 (in:2) rewired from old gb_seq512 -> gb_seq512f. Compiles CLEAN (seqctr UFix_32_0, seq32be
  UFix_32_0, gb_seq512f UFix_512_0, gb_mux512 UFix_512_0, all [1000000 0]).
- VERIFY target: capture consecutive CX-5 frames, confirm uint32 BE @ payload byte48 INCREMENTS +1/packet,
  still jumbo + 0 discards + ~67k pps.
