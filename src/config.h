/* config.h — the packet wire contract as compile-time constants. These #defines are what the
 * tx / rx CUDA code compiles against: the kernels need the seq offset, the [channel][time]
 * payload layout, NANT/NCH/TPKT, and the int8 packing at compile time to build headers and index
 * the corner-turn (you can't #include a YAML). The DAQIRI YAMLs hold the same contract for the
 * *transport* side — what DAQIRI needs to capture/route packets (buffer sizes, seq bit_offset,
 * packets_per_batch, flow steering). A few values appear in both (seq at bit 384, the 8256 B heap,
 * 256 packets/batch); keep them in sync — change one here and change the matching field in
 * tx_host.yaml / rx_beamform_host.yaml.
 *
 * Packet (raw UDP, 8256 B jumbo on the wire — a CASPER-style heap):
 *   bytes   0..41   eth(14) + ip(20) + udp(8)  — eth_src filled by NIC offload
 *   bytes  42..47   reserved (zero)
 *   bytes  48..51   seq (uint32, big-endian)    <- SEQ_BIT_OFFSET 384, width 32
 *   bytes  52..63   reserved (zero)
 *   bytes 64..8255  payload: 128 active ch x 32 time, int8 complex (8b re + 8b im),
 *                   PLANAR: re[4096] then im[4096]; plane index = c*T_pkt + t
 *                   (int8 matches the CASPER FPGA wire; was fp8 e4m3 before 2026-06-24)
 *
 * One packet = one antenna's [128 ch x 32 time] int8-complex heap.  seq = global packet
 * counter; antenna = seq % NANT.  The reorder groups 256 consecutive seq into a
 * batch (one full 256-antenna heap = 32 time-snapshots), slot = seq % PPB =
 * antenna.  Big packets keep pps sane at line rate (real F-engine behaviour);
 * integration happens downstream in rx, never on the TX. */
#pragma once

#define MIXER_NANT          256   /* 16x16 elements                              */
#define MIXER_GRID          16
#define MIXER_NCH           256   /* channels per antenna                        */
#define MIXER_TPKT          32    /* time samples per packet (CASPER heap depth) */
#define MIXER_PAYLOAD_BYTES 8192  /* NCH*TPKT * 1 byte (int4 re<<4 | im)         */
#define MIXER_HDR_BYTES     64    /* payload_byte_offset                         */
#define MIXER_WIRE_BYTES    8256  /* HDR + PAYLOAD (jumbo)                       */

#define MIXER_SEQ_BYTE       48   /* seq sits here, big-endian uint32            */
#define MIXER_SEQ_BIT_OFFSET 384  /* = MIXER_SEQ_BYTE * 8 ; matches YAML bit_offset */
#define MIXER_SEQ_BIT_WIDTH  32
#define MIXER_PPB           256   /* packets_per_batch = one full 256-antenna snapshot */

/* TIME-SPLIT multi-queue: snapshot (time-block) tb is steered to queue tb % MIXER_NQ
 * via udp_dst = MIXER_UDP_PORT + (tb % MIXER_NQ).  Each queue/reorder/core handles a
 * full 256-antenna, 256-channel snapshot but only 1/MIXER_NQ of them, cutting the
 * per-queue (single-core) reorder load by MIXER_NQ.  Each queue has its own
 * reorder_config named MIXER_REORDER<q> and udp flow MIXER_UDP_PORT+q. */
#define MIXER_NQ            1     /* number of RX queues / reorder streams (cores)  */

/* interface / reorder names — must match the YAML cfg */
#define MIXER_TX_IFACE   "tx_port"
#define MIXER_RX_IFACE   "rx_port"
#define MIXER_REORDER    "reorder"   /* per-queue name = MIXER_REORDER + str(q)    */
#define MIXER_UDP_PORT   4096           /* queue q listens on MIXER_UDP_PORT + q       */

/* proven digilab link defaults (overridable on the tx CLI) */
#define MIXER_DEF_ETH_DST "a0:88:c2:0d:5e:28"   /* digilab-receiver ens7np0 */
#define MIXER_DEF_IP_SRC  "10.0.0.1"
#define MIXER_DEF_IP_DST  "10.0.0.2"
