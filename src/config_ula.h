/* config_ula.h — wire + geometry contract for the 4-element UNIFORM LINEAR ARRAY (ULA) demo.
 *
 * This is the GPU X-engine's input contract: CHANNELIZED data, exactly what the F-engine
 * (FPGA PFB+FFT on the board — CASPER tut_spec style — the decided architecture) emits. The synthetic TX
 * (tx_ula.cu) bakes this directly to stand in for the F-engine; the RX (rx_ula_corr.cu)
 * correlates 4x4 per channel and beamforms to a 1-D angular response.
 *
 * Transport wire is kept identical to the proven MIXER host-bounce path (seq@48 BE u32,
 * 64 B header, 8256 B jumbo heap) so we reuse the working DAQIRI yamls + drain plumbing.
 * Only the array shrinks: NELEM=4 (was 256), one packet = one element's [NCHAN x TPKT]
 * int8-complex heap, INTERLEAVED (re,im) per complex sample -- the RFSoC F-engine's natural
 * on-wire format (re,im adjacent bytes per channel). Sample index sl = c*TPKT + t; the complex
 * sample at sl is two adjacent payload bytes: re at byte 2*sl, im at byte 2*sl+1. seq = global
 * packet counter; element = seq % NELEM; PPB = NELEM consecutive packets = one full array snapshot.
 *
 * Board mapping (later): when the real 4x2 feeds this, its raw wire is seq@42 / payload@106;
 * that remap (and FPGA-vs-GPU PFB) is an integration-time concern, not baked here. */
#pragma once

/* ---- array ---- */
#define ULA_NELEM   4      /* elements in the line (the 4x2's 4 ADC inputs)            */
#define ULA_DSPACE  0.5f   /* element spacing in wavelengths at band center (lambda/2) */

/* ---- channelization (F-engine output the X-engine consumes) ---- */
#define ULA_NCHAN   256    /* frequency channels per element (256-pt cplx FFT F-engine) */
#define ULA_TPKT    16     /* time samples/ch/packet (16 keeps payload<=8192 at 256 ch) */
#define ULA_FCEN_CH (ULA_NCHAN/2)  /* channel index taken as band center for d/lambda  */

/* ---- payload / wire (interleaved int8 complex: per sample sl=c*TPKT+t, re@2*sl, im@2*sl+1) ---- */
#define ULA_PAYLOAD_BYTES 8192   /* NCHAN*TPKT*2 = 256*16*2                            */
#define ULA_HDR_BYTES     64     /* payload_byte_offset                               */
#define ULA_WIRE_BYTES    8256   /* HDR + PAYLOAD (jumbo)                             */
#define ULA_SEQ_BYTE      48     /* seq: big-endian uint32 (bytes 48-51, ordering)    */
#define ULA_SEQ_BIT_OFFSET 384   /* = ULA_SEQ_BYTE*8 ; matches the YAML bit_offset    */
#define ULA_SEQ_BIT_WIDTH 32
#define ULA_ELEM_BYTE     52     /* element/antenna index (uint8): drop-immune ID,    */
                                 /* keyed directly instead of seq%NELEM               */
#define ULA_PPB           ULA_NELEM   /* packets per batch = one full array snapshot  */

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
