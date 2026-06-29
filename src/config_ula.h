/* config_ula.h — wire + geometry contract for the UNIFORM LINEAR ARRAY (ULA) demo.
 *
 * This is the GPU X-engine's input contract: CHANNELIZED data, exactly what the F-engine
 * (FPGA PFB+FFT on the manas2el 4x2 build) emits. The synthetic TX (tx_ula.cu) bakes this
 * BYTE-IDENTICALLY to stand in for the F-engine; the RX (rx_ula_corr.cu) inverts the wire
 * mapping, correlates NELEMxNELEM per channel, and beamforms to a 1-D angular response.
 *
 * Transport wire (seq@48 BE u32, 64 B header, 8256 B jumbo heap) matches the proven MIXER
 * host-bounce path so we reuse the working DAQIRI yamls + drain plumbing.
 *
 * ====================================================================================
 * REAL FPGA WIRE LAYOUT (reverse-engineered + VERIFIED from a hardware test_mode ramp
 * capture: digilab-transmit:/tmp/m2el_bo.pcapng, 2026-06-29). Ground truth — TX must
 * EMIT this; RX must INVERT it.
 *   - Frame = 8256 B: 64 B header then 8192 B payload. One packet = ONE element.
 *     seq = uint32 BIG-ENDIAN @ byte 48; element id (0/1) @ byte 52; payload @ byte 64.
 *     Packets alternate element 0,1,0,1; element == seq%2, but ROUTE by byte52 (drop-immune).
 *   - Payload = NCHAN x TPKT complex int8 (re@2*si, im@2*si+1), 2 B/sample, 4096 samples.
 *   - MACRO ORDER = TIME-MAJOR (spectrum-major): production sample index i = t*NCHAN + c
 *     (t=0..TPKT-1, c=0..NCHAN-1). All NCHAN channels of time 0 contiguous, then time 1, ...
 *   - WITHIN-WORD HALF-SWAP: payload grouped into 8-byte words (= 4 consecutive production
 *     samples = 4 consecutive channels at fixed t). Within each 8-byte word the two 4-byte
 *     halves (2 samples each) are SWAPPED: production [s0,s1,s2,s3] -> wire [s2,s3,s0,s1].
 *     This is the gearbox Concat1 32-bit half-swap; identical on both elements. The map is
 *     its own inverse (+2 mod 4), so TX-emit and RX-invert use the SAME formula:
 *         ULA_WIRE_SI(i) = 4*(i/4) + ((i%4)+2)%4
 *         wire byte:  re @ 2*ULA_WIRE_SI(i),  im @ 2*ULA_WIRE_SI(i)+1
 *     VERIFIED: applying ULA_WIRE_SI to the raw ramp payload yields a smooth +1 ramp in
 *     production order i=t*NCHAN+c (2045/2047 increments are +1; the 2 breaks are test_mode
 *     counter quirks, not layout). Confirmed byte-identical to the 8-byte-word half-swap.
 * ==================================================================================== */
#pragma once

/* ---- array (manas2el = 2-element F-engine build) ---- */
#define ULA_NELEM   2      /* elements in the line (manas2el 4x2 build emits 2)        */
#define ULA_DSPACE  0.5f   /* element spacing in wavelengths at band center (lambda/2) */

/* ---- channelization (F-engine output the X-engine consumes) ---- */
#define ULA_NCHAN   256    /* frequency channels per element (256-pt cplx FFT F-engine) */
#define ULA_TPKT    16     /* time samples/ch/packet (16 keeps payload<=8192 at 256 ch) */
#define ULA_FCEN_CH (ULA_NCHAN/2)  /* channel index taken as band center for d/lambda  */

/* ---- payload / wire ---- */
#define ULA_PAYLOAD_BYTES 8192   /* NCHAN*TPKT*2 = 256*16*2                            */
#define ULA_HDR_BYTES     64     /* payload_byte_offset                               */
#define ULA_WIRE_BYTES    8256   /* HDR + PAYLOAD (jumbo)                             */
#define ULA_SEQ_BYTE      48     /* seq: big-endian uint32 (bytes 48-51, ordering)    */
#define ULA_SEQ_BIT_OFFSET 384   /* = ULA_SEQ_BYTE*8 ; matches the YAML bit_offset    */
#define ULA_SEQ_BIT_WIDTH 32
#define ULA_ELEM_BYTE     52     /* element/antenna index (uint8): drop-immune ID,    */
                                 /* keyed directly instead of seq%NELEM               */
#define ULA_PPB           ULA_NELEM   /* packets per batch = one full array snapshot  */

/* ---- REAL-LAYOUT mapping: ONE shared definition used by TX (emit) and RX (invert). ----
 * Production sample index (TIME-MAJOR): i = t*NCHAN + c, t in [0,TPKT), c in [0,NCHAN).
 * Wire sample index after the 8-byte-word half-swap (its own inverse):
 *     ULA_WIRE_SI(i) = 4*(i/4) + ((i%4)+2)%4
 * On the wire, production sample i lives at payload bytes:
 *     re @ 2*ULA_WIRE_SI(i),  im @ 2*ULA_WIRE_SI(i)+1   (relative to payload start). */
#define ULA_PROD_SI(t,c)  ((t)*ULA_NCHAN + (c))               /* time-major production index */
#define ULA_WIRE_SI(i)    (4*((i)/4) + (((i)%4)+2)%4)         /* half-swap (self-inverse)    */
#define ULA_WIRE_RE_OFF(i) (2*ULA_WIRE_SI(i))                 /* payload byte offset of re   */
#define ULA_WIRE_IM_OFF(i) (2*ULA_WIRE_SI(i) + 1)             /* payload byte offset of im   */

/* ---- beamforming (1-D angular response of the line) ---- */
#define ULA_NBEAM   64     /* zero-padded 1-D FFT length -> NBEAM angular bins         */
                           /* baselines span Delta = e_a - e_b in [-(NELEM-1), NELEM-1] */

/* ---- interface / reorder names (match the YAML cfg; reuse MIXER transport) ---- */
#define ULA_TX_IFACE   "tx_port"
#define ULA_RX_IFACE   "rx_port"
#define ULA_UDP_PORT   4096

/* proven digilab link defaults (overridable on the tx CLI) */
#define ULA_DEF_ETH_DST "a0:88:c2:0d:5e:28"   /* digilab-receiver ens7np0 */
#define ULA_DEF_IP_SRC  "10.0.0.1"
#define ULA_DEF_IP_DST  "10.0.0.2"
