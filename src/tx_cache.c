/*
 * tx_cache.c — static-buffer 400GbE TX flood (digilab-transmit CX-7).
 *
 * The two-DIMM Xeon 4410T cannot feed 400G if packets are generated or
 * copied per-send (write+read doubles DRAM traffic). Instead we pre-fill
 * a small ring of jumbo packets ONCE and transmit the SAME mbufs forever:
 * before each enqueue the refcount is bumped, so the PMD's per-completion
 * "free" only decrements it back and the buffer is never recycled or
 * rewritten. DRAM then carries only the NIC's single read stream
 * (~45 GB/s at 366 Gbps), which two DIMMs sustain.
 *
 * Measured 2026-08-20 (IMC CAS counters): CX-7 DMA reads on this box are
 * NEVER served from CPU caches — DRAM read == TX rate for any working-set
 * size, NoSnoop on or off, even with payload demand-resident in L2. So
 * --prefetch/--touch (kept for experiments) only burn core cycles and DRAM
 * slots: leave them 0. The DEFAULTS (2 queues x 256 pkts x 8972B payload,
 * burst 32) are the best measured config: 364-366 Gbps L2 (~365-367 wire),
 * receiver-phy-confirmed, flat -- this box's read-path ceiling. Plain
 * `./tx_cache -l 7,8,9 -a c7:00.0` reproduces it.
 *
 * Build: gcc -O3 -march=native tx_cache.c -o tx_cache $(pkg-config --cflags --libs libdpdk)
 * Run:   ./tx_cache -l 7,8,9 -a c7:00.0 -- [--queues N] [--pkts-per-q N]
 *                   [--payload B] [--secs S] [--dst-mac xx:..:xx]
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ip.h>
#include <rte_udp.h>
#include <rte_ether.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_prefetch.h>
#include <rte_mbuf_dyn.h>

#define MAX_BURST 1024
#define MAX_Q 8

static volatile int force_quit;

struct qctx {
    uint16_t qid;
    uint32_t npkts;
    struct rte_mbuf **pkts;   /* static, pre-filled, never freed */
    uint64_t tx_pkts;
    uint64_t sink;
};

static struct {
    uint16_t nq;
    uint32_t pkts_per_q;
    uint32_t payload;
    uint32_t secs;
    struct rte_ether_addr dst;
    struct rte_ether_addr src;
    uint32_t pf_ahead;
    uint32_t touch;
    uint32_t burst;
    uint32_t repeat;
    double pace_gbps;         /* 0 = flood; >0 = hw pacing via SEND_ON_TIMESTAMP */
    int ts_off;               /* mbuf dynfield offset for tx timestamp */
    uint64_t ts_flag;
    double clk_per_ns;        /* device clock units per ns, calibrated */

    struct qctx q[MAX_Q];
} G = { .nq = 2, .pkts_per_q = 256, .payload = 8972, .secs = 20,
        .dst = {{0xa0,0x88,0xc2,0x0d,0x5e,0x28}}, .pf_ahead = 0, .burst = 32, .repeat = 1 };

static void sig(int s){ (void)s; force_quit = 1; }

static void fill_pkt(struct rte_mbuf *m, uint32_t id)
{
    uint32_t plen = G.payload;
    uint32_t frame = plen + sizeof(struct rte_ether_hdr)
                   + sizeof(struct rte_ipv4_hdr) + sizeof(struct rte_udp_hdr);
    char *p = rte_pktmbuf_append(m, frame);
    struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
    rte_ether_addr_copy(&G.dst, &eth->dst_addr);
    rte_ether_addr_copy(&G.src, &eth->src_addr);
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);

    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    memset(ip, 0, sizeof(*ip));
    ip->version_ihl = RTE_IPV4_VHL_DEF;
    ip->total_length = rte_cpu_to_be_16(frame - sizeof(*eth));
    ip->time_to_live = 64;
    ip->next_proto_id = IPPROTO_UDP;
    ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10,0,0,1));
    ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10,0,0,2));
    ip->hdr_checksum = rte_ipv4_cksum(ip);

    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);
    udp->src_port = rte_cpu_to_be_16(50000);
    udp->dst_port = rte_cpu_to_be_16(60000);
    udp->dgram_len = rte_cpu_to_be_16(plen + sizeof(*udp));
    udp->dgram_cksum = 0;                       /* legal for IPv4 */

    uint64_t *d = (uint64_t *)(udp + 1);
    for (uint32_t i = 0; i < plen / 8; i++)
        d[i] = ((uint64_t)id << 32) | i;        /* written ONCE, ever */
}

static int tx_loop(void *arg)
{
    struct qctx *q = arg;
    uint32_t pos = 0, rep = 0;
    const uint32_t B = G.burst, R = G.repeat;
    struct rte_mbuf *burst[MAX_BURST];
    /* hw pacing state: per-packet departure timestamps in device clock units */
    const int pace = G.pace_gbps > 0;
    double ts_next = 0, ts_step = 0;
    if (pace) {
        uint64_t now; rte_eth_read_clock(0, &now);
        /* wire bits per frame / (queues share the target rate) */
        double wire_bits = 8.0 * (G.payload + 42 + 24);
        ts_step = wire_bits / (G.pace_gbps / G.nq) * G.clk_per_ns;
        ts_next = (double)now + 1e6 * G.clk_per_ns;   /* start 1 ms out */
    }

    while (!force_quit) {
        if (pace) {
            uint64_t now; rte_eth_read_clock(0, &now);
            if (ts_next < (double)now) ts_next = (double)now;
        }
        for (uint32_t i = 0; i < B; i++) {
            struct rte_mbuf *m = q->pkts[pos];
            /* Re-pull payload of a packet AHEAD of the NIC into cache:
             * SPR LLC is non-inclusive and DMA reads don't allocate, so
             * without this every byte streams from the two DIMMs forever. */
            if (G.pf_ahead) {
                uint32_t fpos = pos + G.pf_ahead;
                if (fpos >= q->npkts) fpos -= q->npkts;
                struct rte_mbuf *f = q->pkts[fpos];
                const char *p = rte_pktmbuf_mtod(f, const char *);
                uint32_t len = f->data_len;
                if (G.touch) {              /* demand reads: not droppable */
                    uint64_t sum = 0;
                    for (uint32_t off = 0; off < len; off += 64)
                        sum += *(const volatile uint64_t *)(p + off);
                    q->sink += sum;
                } else {
                    for (uint32_t off = 0; off < len; off += 64)
                        rte_prefetch2(p + off);
                }
            }
            /* --repeat R: enqueue the same packet R times back-to-back */
            if (++rep >= R) {
                rep = 0;
                pos = (pos + 1 == q->npkts) ? 0 : pos + 1;
            }
            if (pace) {
                *RTE_MBUF_DYNFIELD(m, G.ts_off, uint64_t *) = (uint64_t)ts_next;
                m->ol_flags |= G.ts_flag;
                ts_next += ts_step;
            }
            /* keep it alive across the PMD's completion "free" */
            rte_mbuf_refcnt_update(m, 1);
            burst[i] = m;
        }
        uint32_t n = 0;
        while (n < B && !force_quit)
            n += rte_eth_tx_burst(0, q->qid, burst + n, B - n);
        /* un-bump anything not accepted (only possible on quit) */
        for (uint32_t i = n; i < B; i++)
            rte_mbuf_refcnt_update(burst[i], -1);
        q->tx_pkts += n;
    }
    return 0;
}

static void usage_die(void){
    rte_exit(EXIT_FAILURE,
      "args: [--queues N] [--pkts-per-q N] [--payload B] [--secs S] [--dst-mac m] [--prefetch P]\n");
}

int main(int argc, char **argv)
{
    int ret = rte_eal_init(argc, argv);
    if (ret < 0) rte_exit(EXIT_FAILURE, "EAL init failed\n");
    argc -= ret; argv += ret;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--queues") && i+1 < argc) G.nq = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pkts-per-q") && i+1 < argc) G.pkts_per_q = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--payload") && i+1 < argc) G.payload = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--secs") && i+1 < argc) G.secs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--prefetch") && i+1 < argc) G.pf_ahead = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--touch")) G.touch = 1;
        else if (!strcmp(argv[i], "--burst") && i+1 < argc) G.burst = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--repeat") && i+1 < argc) G.repeat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pace-gbps") && i+1 < argc) G.pace_gbps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--dst-mac") && i+1 < argc) {
            if (rte_ether_unformat_addr(argv[++i], &G.dst) < 0) usage_die();
        } else usage_die();
    }
    if (G.nq > MAX_Q || G.nq < 1) usage_die();
    if (G.burst < 1 || G.burst > MAX_BURST || G.repeat < 1) usage_die();
    if (G.nq > rte_lcore_count() - 1)
        rte_exit(EXIT_FAILURE, "need %u worker lcores (have %u)\n",
                 G.nq, rte_lcore_count() - 1);

    uint32_t frame = G.payload + 42;
    double footprint_mb = (double)G.nq * G.pkts_per_q * frame / (1<<20);
    printf("cache working set: %u q x %u pkts x %uB frame = %.1f MiB (L3=26.3)\n",
           G.nq, G.pkts_per_q, frame, footprint_mb);

    uint16_t port = 0;
    if (rte_eth_dev_count_avail() == 0) rte_exit(EXIT_FAILURE, "no ports\n");

    struct rte_eth_conf conf; memset(&conf, 0, sizeof(conf));
    struct rte_eth_dev_info di;
    rte_eth_dev_info_get(port, &di);
    conf.txmode.offloads = 0;
    conf.rxmode.mtu = G.payload + 28 > 9000 ? G.payload + 28 : 9000;
    if (G.pace_gbps > 0) {
        if (!(di.tx_offload_capa & RTE_ETH_TX_OFFLOAD_SEND_ON_TIMESTAMP))
            rte_exit(EXIT_FAILURE,
                "pacing needs SEND_ON_TIMESTAMP (pass devarg tx_pp=500?)\n");
        conf.txmode.offloads |= RTE_ETH_TX_OFFLOAD_SEND_ON_TIMESTAMP;
        int ret2 = rte_mbuf_dyn_tx_timestamp_register(&G.ts_off, &G.ts_flag);
        if (ret2 < 0) rte_exit(EXIT_FAILURE, "timestamp dynfield failed\n");
    }

    ret = rte_eth_dev_configure(port, 1, G.nq, &conf);
    if (ret < 0) rte_exit(EXIT_FAILURE, "configure failed %d\n", ret);
    rte_eth_macaddr_get(port, &G.src);

    /* mempool sized just above the static set; extra for the RX queue */
    uint32_t nmb = G.nq * G.pkts_per_q + 1024;
    uint32_t droom = conf.rxmode.mtu + 18 + RTE_PKTMBUF_HEADROOM;
    if (droom < G.payload + 42 + RTE_PKTMBUF_HEADROOM + 64)
        droom = G.payload + 42 + RTE_PKTMBUF_HEADROOM + 64;
    struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", nmb, 256, 0,
        droom, rte_socket_id());
    if (!mp) rte_exit(EXIT_FAILURE, "mempool failed\n");

    ret = rte_eth_rx_queue_setup(port, 0, 512, rte_socket_id(), NULL, mp);
    if (ret < 0) rte_exit(EXIT_FAILURE, "rxq failed\n");
    for (uint16_t q = 0; q < G.nq; q++) {
        ret = rte_eth_tx_queue_setup(port, q,
            G.burst > 256 ? 4096 : 1024, rte_socket_id(), NULL);
        if (ret < 0) rte_exit(EXIT_FAILURE, "txq %u failed\n", q);
    }
    ret = rte_eth_dev_start(port);
    if (ret < 0) rte_exit(EXIT_FAILURE, "start failed\n");

    /* pre-fill the static packet set — the only payload writes in the run */
    for (uint16_t q = 0; q < G.nq; q++) {
        struct qctx *c = &G.q[q];
        c->qid = q; c->npkts = G.pkts_per_q;
        c->pkts = malloc(sizeof(void*) * c->npkts);
        for (uint32_t i = 0; i < c->npkts; i++) {
            c->pkts[i] = rte_pktmbuf_alloc(mp);
            if (!c->pkts[i]) rte_exit(EXIT_FAILURE, "alloc failed\n");
            fill_pkt(c->pkts[i], q * G.pkts_per_q + i);
        }
    }

    signal(SIGINT, sig); signal(SIGTERM, sig);

    if (G.pace_gbps > 0) {     /* calibrate device clock rate */
        uint64_t c0, c1;
        if (rte_eth_read_clock(port, &c0) != 0)
            rte_exit(EXIT_FAILURE, "rte_eth_read_clock unsupported\n");
        rte_delay_us_sleep(200000);
        rte_eth_read_clock(port, &c1);
        G.clk_per_ns = (double)(c1 - c0) / 2e8;
        printf("pacing %.1f Gbps, device clock %.4f ticks/ns\n",
               G.pace_gbps, G.clk_per_ns);
    }

    uint16_t q = 0; unsigned lc;
    RTE_LCORE_FOREACH_WORKER(lc) {
        if (q < G.nq) rte_eal_remote_launch(tx_loop, &G.q[q], lc);
        q++;
    }

    struct rte_eth_stats s0, s1;
    rte_eth_stats_get(port, &s0);
    uint64_t hz = rte_get_tsc_hz(), t0 = rte_get_tsc_cycles();
    uint32_t elapsed = 0;
    while (!force_quit && elapsed < G.secs) {
        rte_delay_us_sleep(1000000);
        elapsed++;
        rte_eth_stats_get(port, &s1);
        double dt = (double)(rte_get_tsc_cycles() - t0) / hz;
        double gbps  = 8.0 * (s1.obytes - s0.obytes) / dt / 1e9;
        double mpps  = (s1.opackets - s0.opackets) / dt / 1e6;
        double wire  = gbps + mpps * 1e6 * 24 * 8 / 1e9; /* +FCS/preamble/IFG */
        printf("[%3us] %7.2f Gbps L2  (%.2f wire)  %.3f Mpps  oerr=%"PRIu64"\n",
               elapsed, gbps, wire, mpps, s1.oerrors);
        fflush(stdout);
        s0 = s1; t0 = rte_get_tsc_cycles();
    }
    force_quit = 1;
    rte_eal_mp_wait_lcore();
    rte_eth_dev_stop(port);
    rte_eth_dev_close(port);
    return 0;
}
