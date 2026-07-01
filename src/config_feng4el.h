/* config_feng4el.h — real RFSoC feng4el packet contract.
 *
 * Verified from the 2026-07-01 hardware capture and DAQIRI capture_dump:
 *   - UDP payload = 640 B: 64 B header + 576 B payload words.
 *   - pcap/UDP offsets: seq = uint32 big-endian @ byte 48, elem = uint8 @ byte 52.
 *   - DAQIRI raw pointer includes Ethernet+IPv4+UDP (42 B), so the GPU receiver uses
 *     frame offsets: seq @ 90, elem @ 94, active payload @ 106.
 *   - tags cycle 0,1,2,3 and seq % 4 == elem.
 *   - The first 512 payload bytes contain one complete 256-channel int8-complex spectrum.
 *
 * The last 64 payload bytes are currently ignored by the GPU receiver. They are packetizer
 * padding/extra word relative to one full 256-channel spectrum, and the hardware decoder
 * used for proof also ignored them.
 */
#pragma once

/* ---- array ---- */
#define ULA_NELEM   4      /* feng4el emits tags 0..3                                  */
#define ULA_DSPACE  0.5f   /* element spacing in wavelengths at band center (lambda/2) */

/* ---- channelization (F-engine output the X-engine consumes) ---- */
#define ULA_NCHAN   256    /* frequency channels per element (256-pt cplx FFT F-engine) */
#define ULA_TPKT    1      /* one complete spectrum per packet                         */
#define ULA_FCEN_CH (ULA_NCHAN/2)  /* channel index taken as band center for d/lambda  */

/* ---- payload / wire ---- */
#define ULA_PAYLOAD_BYTES 512    /* active spectrum bytes: NCHAN*TPKT*2 = 256*1*2       */
#define ULA_UDP_PAYLOAD_BYTES 640 /* full UDP payload captured from the board            */
#define ULA_L2UDP_BYTES   42     /* Ethernet + IPv4 + UDP bytes before CASPER header  */
#define ULA_HDR_BYTES     106    /* DAQIRI frame offset of active int8 spectrum       */
#define ULA_WIRE_BYTES    682    /* L2 frame bytes through UDP payload                */
#define ULA_SEQ_BYTE      90     /* DAQIRI frame offset: 42 + UDP-payload byte 48     */
#define ULA_SEQ_BIT_OFFSET 720   /* = ULA_SEQ_BYTE*8                                  */
#define ULA_SEQ_BIT_WIDTH 32
#define ULA_ELEM_BYTE     94     /* DAQIRI frame offset: 42 + UDP-payload byte 52     */
                                 /* keyed directly instead of seq%NELEM               */
#define ULA_PPB           ULA_NELEM   /* packets per batch = one full array snapshot  */

/* Production sample index (TIME-MAJOR): i = t*NCHAN + c. The hardware proof decoder treats
 * the first 512 payload bytes as directly interleaved int8 complex. If a later ramp capture
 * proves a gearbox half-swap is present, change only ULA_WIRE_SI here. */
#define ULA_PROD_SI(t,c)  ((t)*ULA_NCHAN + (c))               /* time-major production index */
#define ULA_WIRE_SI(i)    (i)
#define ULA_WIRE_RE_OFF(i) (2*ULA_WIRE_SI(i))                 /* payload byte offset of re   */
#define ULA_WIRE_IM_OFF(i) (2*ULA_WIRE_SI(i) + 1)             /* payload byte offset of im   */

/* ---- beamforming (1-D angular response of the line) ---- */
#define ULA_NBEAM   64     /* zero-padded 1-D FFT length -> NBEAM angular bins         */
                           /* baselines span Delta = e_a - e_b in [-(NELEM-1), NELEM-1] */

/* ---- interface / reorder names (match the YAML cfg; reuse MIXER transport) ---- */
#define ULA_TX_IFACE   "tx_port"
#define ULA_RX_IFACE   "rx_port"
#define ULA_UDP_PORT   60000

/* proven RFSoC capture path */
#define ULA_DEF_ETH_DST "b8:ce:f6:e5:6b:5a"   /* digilab-transmit ens5f0np0 */
#define ULA_DEF_IP_SRC  "10.0.0.1"
#define ULA_DEF_IP_DST  "10.0.0.2"
