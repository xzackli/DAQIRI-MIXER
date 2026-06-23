/* tx_fp8.cu — DAQIRI TX: generate the analytic sky as per-antenna int4 4+4
 * channelised voltages and DMA them to the NIC via GPUDirect.  Each packet is
 * one antenna's 256-channel snapshot; a CUDA kernel writes the eth/ip/udp
 * header + seq + payload directly into the device packet buffers (no H2D copy
 * of payload).  seq = global packet counter; antenna = seq % NANT.  The planet
 * position advances with wall-clock time so the orbit is real-time.
 *
 * Build (link against DAQIRI):
 *   nvcc -O3 -std=c++17 -arch=<sm_XX> tx_fp8.cu -I/opt/daqiri/include \
 *        -L/opt/daqiri/lib -ldaqiri -lcudart -Xlinker -rpath -Xlinker /opt/daqiri/lib -o tx_fp8
 */
#include <cuda_runtime.h>
#include <cuda_fp8.h>

#include <arpa/inet.h>
#include <linux/if_ether.h>   /* match daqiri/types.h header set (ethhdr) */
#include <netinet/ip.h>       /* iphdr */
#include <linux/udp.h>        /* udphdr */

#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <daqiri/daqiri.h>
#include "config.h"

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "CUDA %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(e_)); \
  std::exit(1); } } while (0)

__device__ inline int q_int4(float v) {
    int i = __float2int_rn(v);
    return i < -8 ? -8 : (i > 7 ? 7 : i);
}

/* One block per packet, MIXER_NCH threads per block (one per channel).
 * Writes header template + seq (big-endian @ byte 48) + int4 4+4 payload. */
__global__ void k_tx_fill(uint8_t* const* pkts, int npkts, uint32_t seq_base,
                          float l, float m, float Astar, const uint8_t* hdr) {
    int i = blockIdx.x;
    if (i >= npkts) return;
    int c = threadIdx.x;                       // channel 0..255
    uint8_t* pkt = pkts[i];
    uint32_t seq = seq_base + (uint32_t)i;
    int a  = seq & (MIXER_NANT - 1);              // antenna = seq % 256
    int px = a & 15, qy = a >> 4;

    if (c < MIXER_HDR_BYTES) pkt[c] = hdr[c];     // copy eth/ip/udp template
    __syncthreads();
    if (c == 0) {                              // seq, big-endian, bytes 48..51
        pkt[MIXER_SEQ_BYTE + 0] = (uint8_t)(seq >> 24);
        pkt[MIXER_SEQ_BYTE + 1] = (uint8_t)(seq >> 16);
        pkt[MIXER_SEQ_BYTE + 2] = (uint8_t)(seq >> 8);
        pkt[MIXER_SEQ_BYTE + 3] = (uint8_t)(seq);
    }
    // PLANAR fp8 wire: payload = re[4096] | im[4096] = 128 ch x 32 t (4096 samples).
    // fp8 e4m3 has range/precision; no int4 clamp. Beamform math is identical to int4.
    if (c < MIXER_NCH / 2) {                          // 128 active channels
        float Apl = Astar * sqrtf(2.0f * (float)c / (float)(MIXER_NCH - 1));
        float phi = (float)M_PI * (px * l + qy * m);
        uint8_t rb = __nv_fp8_e4m3(Astar + Apl * cosf(phi)).__x;
        uint8_t ib = __nv_fp8_e4m3(Apl * sinf(phi)).__x;
        const int HALF = MIXER_PAYLOAD_BYTES / 2;     // 4096
        #pragma unroll
        for (int t = 0; t < MIXER_TPKT; ++t) {
            int sl = c * MIXER_TPKT + t;              // sample 0..4096
            pkt[MIXER_HDR_BYTES + sl]        = rb;    // re plane
            pkt[MIXER_HDR_BYTES + HALF + sl] = ib;    // im plane
        }
    }
}

/* ---- host header template (eth/ip/udp); eth_src left 0 -> NIC offload fills - */
static bool parse_mac(const char* s, uint8_t mac[6]) {
    return std::sscanf(s, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
                       &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) == 6;
}
static uint16_t ip_checksum(const void* data, size_t len) {
    const uint8_t* b = (const uint8_t*)data; uint32_t sum = 0;
    for (size_t i = 0; i + 1 < len; i += 2)
        sum += ((uint32_t)b[i] << 8) | b[i + 1];
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return htons((uint16_t)(~sum & 0xffff));
}
static void build_header(uint8_t* h, const uint8_t mac_dst[6],
                         uint32_t ip_src, uint32_t ip_dst, uint16_t port) {
    std::memset(h, 0, MIXER_HDR_BYTES);
    auto* eth = (struct ethhdr*)h;
    std::memcpy(eth->h_dest, mac_dst, 6);     // h_source = 0 (NIC tx_eth_src offload)
    eth->h_proto = htons(ETH_P_IP);
    auto* ip = (struct iphdr*)(h + sizeof(struct ethhdr));
    ip->version = 4; ip->ihl = 5; ip->ttl = 64; ip->protocol = IPPROTO_UDP;
    ip->tot_len = htons(MIXER_WIRE_BYTES - sizeof(struct ethhdr));
    ip->saddr = htonl(ip_src); ip->daddr = htonl(ip_dst);
    ip->check = 0; ip->check = ip_checksum(ip, sizeof(struct iphdr));
    auto* udp = (struct udphdr*)(h + sizeof(struct ethhdr) + sizeof(struct iphdr));
    udp->source = htons(port); udp->dest = htons(port);
    udp->len = htons(MIXER_WIRE_BYTES - sizeof(struct ethhdr) - sizeof(struct iphdr));
    udp->check = 0;                           // 0 = no UDP checksum (valid)
}

static volatile std::sig_atomic_t g_stop = 0;
static void on_sig(int) { g_stop = 1; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <config.yaml> [--seconds N] [--rate S] "
        "[--astar A] [--rho R] [--torbit S] [--device D] [--eth-dst MAC]\n", argv[0]);
        return 1; }
    const char* yaml = argv[1];
    int   seconds = 0, device = 0;
    float Astar = 2.0f, rho = 0.35f, torbit = 3.0f, rate = 0.0f;
    std::string eth_dst = MIXER_DEF_ETH_DST;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if      (a == "--seconds" && i+1<argc) seconds = std::atoi(argv[++i]);
        else if (a == "--rate"    && i+1<argc) rate    = std::atof(argv[++i]);  /* snaps/s; 0=unthrottled */
        else if (a == "--astar"   && i+1<argc) Astar   = std::atof(argv[++i]);
        else if (a == "--rho"     && i+1<argc) rho     = std::atof(argv[++i]);
        else if (a == "--torbit"  && i+1<argc) torbit  = std::atof(argv[++i]);
        else if (a == "--device"  && i+1<argc) device  = std::atoi(argv[++i]);
        else if (a == "--eth-dst" && i+1<argc) eth_dst = argv[++i];
    }
    std::signal(SIGINT, on_sig); std::signal(SIGTERM, on_sig);
    CK(cudaSetDevice(device));

    uint8_t mac[6];
    if (!parse_mac(eth_dst.c_str(), mac)) { fprintf(stderr, "bad MAC %s\n", eth_dst.c_str()); return 1; }
    /* one header template per queue: udp_dst = MIXER_UDP_PORT + q (time-split) */
    uint8_t h_hdr[MIXER_NQ * MIXER_HDR_BYTES];
    for (int q = 0; q < MIXER_NQ; ++q)
        build_header(h_hdr + q * MIXER_HDR_BYTES, mac, ntohl(inet_addr(MIXER_DEF_IP_SRC)),
                     ntohl(inet_addr(MIXER_DEF_IP_DST)), (uint16_t)(MIXER_UDP_PORT + q));
    uint8_t* d_hdr = nullptr; CK(cudaMalloc(&d_hdr, MIXER_NQ * MIXER_HDR_BYTES));
    CK(cudaMemcpy(d_hdr, h_hdr, MIXER_NQ * MIXER_HDR_BYTES, cudaMemcpyHostToDevice));

    if (daqiri::daqiri_init(yaml) != daqiri::Status::SUCCESS) {
        fprintf(stderr, "daqiri_init failed\n"); return 1; }
    const int port_id = daqiri::get_port_id(MIXER_TX_IFACE);
    if (port_id < 0) { fprintf(stderr, "no TX iface %s\n", MIXER_TX_IFACE); return 1; }

    cudaStream_t stream; CK(cudaStreamCreate(&stream));
    std::vector<uint8_t*> h_ptrs(MIXER_PPB);
    uint8_t** d_ptrs = nullptr; CK(cudaMalloc(&d_ptrs, MIXER_PPB * sizeof(uint8_t*)));

    fprintf(stderr, "[tx] sending to %s udp %d..%d (time-split %dq), rate=%s, Astar=%.2f rho=%.2f Torbit=%.1fs\n",
            eth_dst.c_str(), MIXER_UDP_PORT, MIXER_UDP_PORT + MIXER_NQ - 1, MIXER_NQ,
            rate > 0.0f ? (std::to_string((int)rate) + " snaps/s").c_str() : "unthrottled",
            Astar, rho, torbit);

    const float w = 2.0f * (float)M_PI / torbit;
    /* pace one snapshot per interval so we don't overdrive the receiver's GPU
     * beamform (a real F-engine streams at a fixed ADC rate, not link-max). */
    const std::chrono::duration<double> interval(rate > 0.0f ? 1.0 / rate : 0.0);
    const auto t0 = std::chrono::steady_clock::now();
    auto next = t0;
    uint32_t seq_base = 0; uint64_t snaps = 0;
    while (!g_stop) {
        if (rate > 0.0f) {   /* gate the send rate; if behind, fire immediately */
            std::this_thread::sleep_until(next);
            next += std::chrono::duration_cast<std::chrono::steady_clock::duration>(interval);
        }
        double t = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - t0).count();
        if (seconds > 0 && t >= seconds) break;
        float l = rho * std::cos(w * t), m = rho * std::sin(w * t);

        auto* msg = daqiri::create_tx_burst_params();
        daqiri::set_header(msg, (uint16_t)port_id, 0, MIXER_PPB, 1);
        if (!daqiri::is_tx_burst_available(msg)) {
            daqiri::free_tx_metadata(msg);
            std::this_thread::sleep_for(std::chrono::microseconds(50));
            continue;
        }
        if (daqiri::get_tx_packet_burst(msg) != daqiri::Status::SUCCESS) {
            daqiri::free_tx_metadata(msg); continue;
        }
        int npkts = (int)daqiri::get_num_packets(msg);
        for (int i = 0; i < npkts; ++i)
            h_ptrs[i] = (uint8_t*)daqiri::get_segment_packet_ptr(msg, 0, i);
        CK(cudaMemcpyAsync(d_ptrs, h_ptrs.data(), npkts * sizeof(uint8_t*),
                           cudaMemcpyHostToDevice, stream));
        /* time-split: this burst is snapshot tb = seq_base/256 -> queue tb % MIXER_NQ */
        const uint8_t* d_hdr_q = d_hdr + ((seq_base / MIXER_NANT) % MIXER_NQ) * MIXER_HDR_BYTES;
        k_tx_fill<<<npkts, MIXER_NCH, 0, stream>>>(d_ptrs, npkts, seq_base, l, m, Astar, d_hdr_q);
        daqiri::set_all_packet_lengths(msg, {MIXER_WIRE_BYTES});
        CK(cudaStreamSynchronize(stream));
        if (daqiri::send_tx_burst(msg) == daqiri::Status::SUCCESS) {
            seq_base += (uint32_t)npkts; snaps += npkts / MIXER_NANT;
            if ((snaps & 8191) == 0)
                fprintf(stderr, "[tx] t=%.2fs snaps=%lu l=%+.2f m=%+.2f\n",
                        t, (unsigned long)snaps, l, m);
        } else {
            daqiri::free_all_packets_and_burst_tx(msg);
        }
    }
    fprintf(stderr, "[tx] stopping (%lu snapshots)\n", (unsigned long)snaps);
    daqiri::print_stats();
    daqiri::shutdown();
    return 0;
}
