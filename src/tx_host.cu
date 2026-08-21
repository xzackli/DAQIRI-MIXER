/* tx_host.cu — HOST-memory analytic-sky TX: stream the star + orbiting-planet sky at LINE RATE (~380 GbE).
 *
 * Why host memory + pre-fill: writing packets straight from GPU VRAM (GPUDirect) is capped ~145 G by the
 * A6000's PCIe P2P read bandwidth, and filling each packet's payload on the CPU is memcpy-bound ~50 G --
 * neither reaches 400. But the sky varies slowly (orbit ~seconds) vs the line rate, so we PRE-FILL each host
 * TX buffer ONCE on first touch (64 B header + seq @ byte 48 + the antenna's int8 sky), and the steady-state
 * loop then just submits bursts with no per-packet writes -- the NIC streams the pre-filled sky from host
 * hugepages at line rate. When the planet moves only stale payloads are rewritten, STAGGERED a few per burst
 * (--refresh-budget) so the refresh never stalls the send. (The RX needs none of this -- its MR is a NIC
 * receive buffer the hardware refills with live packets every snapshot.)
 *
 * Invariants: a buffer reused at global index G carries antenna G%256 (num_bufs is a multiple of 256), and the
 * send order makes physical packet order == antenna order, which the RX corner-turn assumes; seq is baked at
 * first touch (the RX only uses seq%256 + per-burst realign, so a stale absolute seq is fine). The deep pool
 * (num_bufs=16384) is required -- at line rate the NIC has more packets in flight than a shallow pool holds,
 * so reusing a buffer the NIC hasn't sent yet tears packets. Build: nvcc -arch=<sm_XX>. */
#include <cuda_runtime.h>
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <netinet/ip.h>
#include <linux/udp.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>
#include <cmath>
#include <daqiri/daqiri.h>
#include "config.h"

#define CK(x) do{cudaError_t e_=(x);if(e_!=cudaSuccess){fprintf(stderr,"CUDA %s:%d: %s\n",__FILE__,__LINE__,cudaGetErrorString(e_));std::exit(1);}}while(0)

/* generate the 256-antenna int8 sky payload table for direction (l,m): payload[a] = re[4096]|im[4096],
 * re/im plane index sl = c*TPKT + t, channels c<128 active (Apl ~ sqrt(c)); matches tx_int8 wire layout. */
__global__ void k_sky(uint8_t* __restrict__ sky, float l, float m){
    const float Astar=2.0f;                           /* star amplitude (fits int8 headroom) */
    int a = blockIdx.x; int c = threadIdx.x;
    if (a >= MIXER_NANT) return;
    uint8_t* pay = sky + (size_t)a*MIXER_PAYLOAD_BYTES;
    if (c < MIXER_ACTIVE_NCH){                          /* 128 active wire channels */
        int px = a & 15, qy = a >> 4;
        float Apl = 0.71f * Astar * sqrtf(2.0f*(float)c/(float)(MIXER_NCH-1));  /* planet ~30% of star */
        float phi = (float)M_PI * (px*l + qy*m);
        /* int8 complex (8b re + 8b im), matching the CASPER FPGA wire. SCALE 25 maps |X|<~5 -> [-127,127];
         * the RX now reads these int8 bytes directly (raw byte, no decode). */
        int qr = __float2int_rn((Astar + Apl*cosf(phi)) * 25.0f);
        int qi = __float2int_rn((Apl*sinf(phi)) * 25.0f);
        uint8_t rb = (uint8_t)(int8_t)(qr<-127?-127:(qr>127?127:qr));
        uint8_t ib = (uint8_t)(int8_t)(qi<-127?-127:(qi>127?127:qi));
        const int HALF = MIXER_PAYLOAD_BYTES/2;
        #pragma unroll
        for (int t=0;t<MIXER_TPKT;++t){ int sl=c*MIXER_TPKT+t; pay[sl]=rb; pay[HALF+sl]=ib; }
    }
}

/* ---- host eth/ip/udp header template (seq slot at byte 48), same wire as tx_int8 ---- */
static bool parse_mac(const char* s, uint8_t mac[6]){
    return std::sscanf(s,"%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",&mac[0],&mac[1],&mac[2],&mac[3],&mac[4],&mac[5])==6; }
static uint16_t ip_checksum(const void* data, size_t len){
    const uint8_t* b=(const uint8_t*)data; uint32_t s=0;
    for(size_t i=0;i+1<len;i+=2) s+=((uint32_t)b[i]<<8)|b[i+1];
    while(s>>16) s=(s&0xffff)+(s>>16); return htons((uint16_t)(~s&0xffff)); }
static void build_header(uint8_t* h, const uint8_t mac_dst[6], uint32_t ip_src, uint32_t ip_dst, uint16_t port){
    std::memset(h,0,MIXER_HDR_BYTES);
    auto* eth=(struct ethhdr*)h; std::memcpy(eth->h_dest,mac_dst,6); eth->h_proto=htons(ETH_P_IP);
    auto* ip=(struct iphdr*)(h+sizeof(struct ethhdr));
    ip->version=4; ip->ihl=5; ip->ttl=64; ip->protocol=IPPROTO_UDP;
    ip->tot_len=htons(MIXER_WIRE_BYTES-sizeof(struct ethhdr));
    ip->saddr=htonl(ip_src); ip->daddr=htonl(ip_dst);
    ip->check=0; ip->check=ip_checksum(ip,sizeof(struct iphdr));
    auto* udp=(struct udphdr*)(h+sizeof(struct ethhdr)+sizeof(struct iphdr));
    udp->source=htons(port); udp->dest=htons(port);
    udp->len=htons(MIXER_WIRE_BYTES-sizeof(struct ethhdr)-sizeof(struct iphdr)); udp->check=0; }

static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [--seconds N][--rho R][--torbit S][--device D][--eth-dst MAC][--nbufs N][--batch N][--refresh-hz F]\n",argv[0]);return 1;}
    const char* yaml=argv[1]; int seconds=0, device=0, nbufs=16384, batch=1024, refbudget=96; float refhz=8.f;
    float rho=0.525f, torbit=3.0f; std::string eth_dst=MIXER_DEF_ETH_DST;
    for(int i=2;i<argc;++i){std::string a=argv[i];
        if(a=="--seconds"&&i+1<argc)seconds=atoi(argv[++i]);
        else if(a=="--rho"&&i+1<argc)rho=atof(argv[++i]); else if(a=="--device"&&i+1<argc)device=atoi(argv[++i]);
        else if(a=="--eth-dst"&&i+1<argc)eth_dst=argv[++i]; else if(a=="--nbufs"&&i+1<argc)nbufs=atoi(argv[++i]);
        else if(a=="--batch"&&i+1<argc)batch=atoi(argv[++i]); else if(a=="--torbit"&&i+1<argc)torbit=atof(argv[++i]);
        else if(a=="--refresh-hz"&&i+1<argc)refhz=atof(argv[++i]); else if(a=="--refresh-budget"&&i+1<argc)refbudget=atoi(argv[++i]);}
    std::signal(SIGINT,on_sig); std::signal(SIGTERM,on_sig); CK(cudaSetDevice(device));
    uint8_t mac[6]; if(!parse_mac(eth_dst.c_str(),mac)){fprintf(stderr,"bad MAC %s\n",eth_dst.c_str());return 1;}
    uint8_t h_hdr[MIXER_HDR_BYTES];
    build_header(h_hdr,mac,ntohl(inet_addr(MIXER_DEF_IP_SRC)),ntohl(inet_addr(MIXER_DEF_IP_DST)),(uint16_t)MIXER_UDP_PORT);

    /* double-buffered sky payload table; a background thread regenerates it for the orbiting planet
     * (l,m) = rho*(cos,sin)(wt) and bumps cur_gen. Slot G%nbufs always carries antenna G%256 (nbufs%256==0),
     * so the TX loop refreshes a buffer's payload only when its baked generation is stale. */
    uint8_t *d_sky=nullptr, *h_sky[2]={nullptr,nullptr};
    CK(cudaMalloc(&d_sky,(size_t)MIXER_NANT*MIXER_PAYLOAD_BYTES));
    for(int b=0;b<2;++b) CK(cudaHostAlloc((void**)&h_sky[b],(size_t)MIXER_NANT*MIXER_PAYLOAD_BYTES,cudaHostAllocDefault));
    auto gen_sky=[&](uint8_t* dst,float l,float m){ k_sky<<<MIXER_NANT,MIXER_NCH>>>(d_sky,l,m);
        CK(cudaDeviceSynchronize()); CK(cudaMemcpy(dst,d_sky,(size_t)MIXER_NANT*MIXER_PAYLOAD_BYTES,cudaMemcpyDeviceToHost)); };
    gen_sky(h_sky[0],rho,0.0f);                            /* initial frame (l=rho, m=0) */
    std::atomic<int> active{0}; std::atomic<uint32_t> cur_gen{1}; std::atomic<bool> motion{false};

    if(daqiri::daqiri_init(yaml)!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    const int port_id=daqiri::get_port_id(MIXER_TX_IFACE);
    if(port_id<0){fprintf(stderr,"no TX iface %s\n",MIXER_TX_IFACE);return 1;}
    fprintf(stderr,"[tx_host] host-memory sky firehose -> %s udp %d, orbiting planet rho=%.2f Torbit=%.1fs, %d bufs, refresh %.0f Hz\n",
            eth_dst.c_str(),MIXER_UDP_PORT,rho,torbit,nbufs,refhz);

    /* sky-update thread: regenerate the moving sky into the idle buffer, publish (swap + bump gen) */
    std::thread sky([&]{ cudaSetDevice(device); const float w=2.0f*(float)M_PI/torbit;
        const auto tm0=std::chrono::steady_clock::now();
        while(!g_stop){ if(!motion.load()){std::this_thread::sleep_for(std::chrono::milliseconds(2));continue;}
            double t=std::chrono::duration<double>(std::chrono::steady_clock::now()-tm0).count();
            int idle=1-active.load(); gen_sky(h_sky[idle],rho*std::cos(w*t),rho*std::sin(w*t));
            active.store(idle); cur_gen.fetch_add(1);
            std::this_thread::sleep_for(std::chrono::duration<double>(1.0/refhz)); } });

    std::vector<uint32_t> bgen(nbufs,0);                  /* baked generation per slot (= G%nbufs) */
    std::unordered_set<const void*> filled; filled.reserve(nbufs*2);
    bool steady=false; uint64_t G=0, snaps=0; const auto t0=std::chrono::steady_clock::now();
    while(!g_stop){
        if(seconds>0 && std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count()>=seconds) break;
        auto* msg=daqiri::create_tx_burst_params();
        daqiri::set_header(msg,(uint16_t)port_id,0,batch,1);
        if(!daqiri::is_tx_burst_available(msg)){daqiri::free_tx_metadata(msg);std::this_thread::sleep_for(std::chrono::microseconds(20));continue;}
        if(daqiri::get_tx_packet_burst(msg)!=daqiri::Status::SUCCESS){daqiri::free_tx_metadata(msg);continue;}
        int n=(int)daqiri::get_num_packets(msg);
        uint32_t cg=cur_gen.load(); const uint8_t* sky=h_sky[active.load()];   /* consistent within burst */
        int budget=refbudget;                              /* cap payload refreshes per burst -> no stall (staggered over the update period) */
        for(int i=0;i<n;++i){ uint32_t slot=(uint32_t)((G+i)%nbufs); int ant=(int)((G+i)%MIXER_NANT);
            if(!steady){ const void* ptr=daqiri::get_segment_packet_ptr(msg,0,i);
                if(ptr && filled.insert(ptr).second){      /* first touch: bake header + seq@48 + payload */
                    uint8_t* p=(uint8_t*)ptr;
                    std::memcpy(p,h_hdr,MIXER_HDR_BYTES);
                    uint32_t seqbe=htonl((uint32_t)(G+i)); std::memcpy(p+MIXER_SEQ_BYTE,&seqbe,sizeof(seqbe));
                    std::memcpy(p+MIXER_HDR_BYTES,sky+(size_t)ant*MIXER_PAYLOAD_BYTES,MIXER_PAYLOAD_BYTES);
                    bgen[slot]=cg; }
            } else if(bgen[slot]!=cg && budget>0){          /* planet moved: refresh just this payload (budgeted) */
                uint8_t* p=(uint8_t*)daqiri::get_segment_packet_ptr(msg,0,i);
                if(p){ std::memcpy(p+MIXER_HDR_BYTES,sky+(size_t)ant*MIXER_PAYLOAD_BYTES,MIXER_PAYLOAD_BYTES); bgen[slot]=cg; --budget; }
            }
        }
        G+=n;
        if(!steady && (int)filled.size()>=nbufs){ steady=true; motion.store(true); }
        daqiri::set_all_packet_lengths(msg,{MIXER_WIRE_BYTES});
        if(daqiri::send_tx_burst(msg)==daqiri::Status::SUCCESS){ snaps+=n/MIXER_NANT;
            if((snaps&65535)==0) fprintf(stderr,"[tx_host] snaps=%lu gen=%u steady=%d filled=%zu\n",(unsigned long)snaps,cg,(int)steady,filled.size());
        } else daqiri::free_all_packets_and_burst_tx(msg);
    }
    g_stop=1; if(sky.joinable())sky.join();
    fprintf(stderr,"[tx_host] stop: %lu snapshots, G=%lu, gen=%u\n",(unsigned long)snaps,(unsigned long)G,cur_gen.load());
    daqiri::print_stats(); daqiri::shutdown(); return 0;
}
