/* bf_wire.h — the packet wire contract as compile-time constants. These #defines are what the
 * bf_tx / bf_rx CUDA code compiles against: the kernels need the seq offset, the [channel][time]
 * payload layout, NANT/NCH/TPKT, and the int4 packing at compile time to build headers and index
 * the corner-turn (you can't #include a YAML). The DAQIRI YAMLs hold the same contract for the
 * *transport* side — what daqiri needs to capture/route packets (buffer sizes, seq bit_offset,
 * packets_per_batch, flow steering). A few values appear in both (seq at bit 384, the 8256 B heap,
 * 256 packets/batch); keep them in sync — change one here and change the matching field in
 * tx_beamform.yaml / rx_beamform_host.yaml.
 *
 * Packet (raw UDP, 8256 B jumbo on the wire — a CASPER-style heap):
 *   bytes   0..41   eth(14) + ip(20) + udp(8)  — eth_src filled by NIC offload
 *   bytes  42..47   reserved (zero)
 *   bytes  48..51   seq (uint32, big-endian)    <- SEQ_BIT_OFFSET 384, width 32
 *   bytes  52..63   reserved (zero)
 *   bytes 64..8255  payload: 256 ch x 32 time int4 4+4 complex samples,
 *                   laid out [channel][time] (byte index = c*T_pkt + t)
 *
 * One packet = one antenna's [256 ch x 32 time] heap.  seq = global packet
 * counter; antenna = seq % NANT.  The reorder groups 256 consecutive seq into a
 * batch (one full 256-antenna heap = 32 time-snapshots), slot = seq % PPB =
 * antenna.  Big packets keep pps sane at line rate (real F-engine behaviour);
 * integration happens downstream in bf_rx, never on the TX. */
#pragma once

#define BF_NANT          256   /* 16x16 elements                              */
#define BF_GRID          16
#define BF_NCH           256   /* channels per antenna                        */
#define BF_TPKT          32    /* time samples per packet (CASPER heap depth) */
#define BF_PAYLOAD_BYTES 8192  /* NCH*TPKT * 1 byte (int4 re<<4 | im)         */
#define BF_HDR_BYTES     64    /* payload_byte_offset                         */
#define BF_WIRE_BYTES    8256  /* HDR + PAYLOAD (jumbo)                       */

#define BF_SEQ_BYTE       48   /* seq sits here, big-endian uint32            */
#define BF_SEQ_BIT_OFFSET 384  /* = BF_SEQ_BYTE * 8 ; matches YAML bit_offset */
#define BF_SEQ_BIT_WIDTH  32
#define BF_PPB           256   /* packets_per_batch = one full 256-antenna snapshot */

/* TIME-SPLIT multi-queue: snapshot (time-block) tb is steered to queue tb % BF_NQ
 * via udp_dst = BF_UDP_PORT + (tb % BF_NQ).  Each queue/reorder/core handles a
 * full 256-antenna, 256-channel snapshot but only 1/BF_NQ of them, cutting the
 * per-queue (single-core) reorder load by BF_NQ.  Each queue has its own
 * reorder_config named BF_REORDER<q> and udp flow BF_UDP_PORT+q. */
#define BF_NQ            1     /* number of RX queues / reorder streams (cores)  */

/* interface / reorder names — must match the YAML cfg */
#define BF_TX_IFACE   "tx_port"
#define BF_RX_IFACE   "rx_port"
#define BF_REORDER    "bf_reorder"   /* per-queue name = BF_REORDER + str(q)    */
#define BF_UDP_PORT   4096           /* queue q listens on BF_UDP_PORT + q       */

/* proven digilab link defaults (overridable on the bf_tx CLI) */
#define BF_DEF_ETH_DST "a0:88:c2:0d:5e:28"   /* digilab-receiver ens7np0 */
#define BF_DEF_IP_SRC  "10.0.0.1"
#define BF_DEF_IP_DST  "10.0.0.2"
