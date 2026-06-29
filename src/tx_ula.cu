/* tx_ula.cu — synthetic 4-element UNIFORM LINEAR ARRAY source. Stands in for the FPGA F-engine:
 * emits CHANNELIZED int8 (config_ula.h wire), one packet = one element's [NCHAN x TPKT] heap. For a
 * plane wave from angle theta, element e at position e*d sees a per-channel phase
 *   phi_e,c = -pi * e * sin(theta) * (f_c / f_center),   f_c/f_center = c / (NCHAN/2)   (d = lambda/2 @ band-center)
 * so a source maps to a SLOPED track in the (channel x beam) waterfall (beam bin ∝ channel·sinθ). A source
 * swept in theta(t) is the star/planet analog -> a moving track the rx dV imager picks up.
 * Sent over the DAQIRI loopback (400G CX-7), NOT the FPGA board. Build: nvcc -arch=<sm_XX>. */
#include <cuda_runtime.h>
#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <netinet/ip.h>
#include <linux/udp.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <daqiri/daqiri.h>
#include "config_ula.h"
#define CK(x) do{cudaError_t e_=(x);if(e_!=cudaSuccess){fprintf(stderr,"CUDA %s:%d: %s\n",__FILE__,__LINE__,cudaGetErrorString(e_));std::exit(1);}}while(0)

/* generate the NELEM-element channelized int8 table for sources at sin(theta) s1 (amp a1) + s2 (amp a2).
 * one block per element, threads = channels. sample index sl = c*TPKT + t; CW source -> constant over t.
 * INTERLEAVED on wire (F-engine format): re at payload byte 2*sl, im at byte 2*sl+1. */
__global__ void k_sky_ula(uint8_t* __restrict__ sky, float s1, float a1, float s2, float a2){
    int e=blockIdx.x, c=threadIdx.x; if(e>=ULA_NELEM||c>=ULA_NCHAN) return;
    uint8_t* pay = sky + (size_t)e*ULA_PAYLOAD_BYTES;
    float fc = (float)c/(float)ULA_FCEN_CH;                 /* f_c / f_center (channel-proportional) */
    float p1 = -(float)M_PI*e*s1*fc, p2 = -(float)M_PI*e*s2*fc;
    float re = a1*cosf(p1) + a2*cosf(p2);
    float im = a1*sinf(p1) + a2*sinf(p2);
    int qr=__float2int_rn(re), qi=__float2int_rn(im);
    uint8_t rb=(uint8_t)(int8_t)(qr<-127?-127:(qr>127?127:qr));
    uint8_t ib=(uint8_t)(int8_t)(qi<-127?-127:(qi>127?127:qi));
    #pragma unroll
    for(int t=0;t<ULA_TPKT;++t){ int sl=c*ULA_TPKT+t; pay[2*sl]=rb; pay[2*sl+1]=ib; }
}

static bool parse_mac(const char* s, uint8_t mac[6]){
    return std::sscanf(s,"%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",&mac[0],&mac[1],&mac[2],&mac[3],&mac[4],&mac[5])==6; }
static uint16_t ip_checksum(const void* data, size_t len){ const uint8_t* b=(const uint8_t*)data; uint32_t s=0;
    for(size_t i=0;i+1<len;i+=2) s+=((uint32_t)b[i]<<8)|b[i+1]; while(s>>16) s=(s&0xffff)+(s>>16); return htons((uint16_t)(~s&0xffff)); }
static void build_header(uint8_t* h, const uint8_t mac_dst[6], uint32_t ip_src, uint32_t ip_dst, uint16_t port){
    std::memset(h,0,ULA_HDR_BYTES);
    auto* eth=(struct ethhdr*)h; std::memcpy(eth->h_dest,mac_dst,6); eth->h_proto=htons(ETH_P_IP);
    auto* ip=(struct iphdr*)(h+sizeof(struct ethhdr));
    ip->version=4; ip->ihl=5; ip->ttl=64; ip->protocol=IPPROTO_UDP;
    ip->tot_len=htons(ULA_WIRE_BYTES-sizeof(struct ethhdr)); ip->saddr=htonl(ip_src); ip->daddr=htonl(ip_dst);
    ip->check=0; ip->check=ip_checksum(ip,sizeof(struct iphdr));
    auto* udp=(struct udphdr*)(h+sizeof(struct ethhdr)+sizeof(struct iphdr));
    udp->source=htons(port); udp->dest=htons(port);
    udp->len=htons(ULA_WIRE_BYTES-sizeof(struct ethhdr)-sizeof(struct iphdr)); udp->check=0; }

static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [--seconds N][--device D][--eth-dst MAC][--amp A][--sweep DEG][--tsweep S][--batch N]\n",argv[0]);return 1;}
    const char* yaml=argv[1]; int seconds=0, device=0, batch=256; float amp=100.f, sweepdeg=40.f, tsweep=5.f;
    std::string eth_dst=ULA_DEF_ETH_DST;
    for(int i=2;i<argc;++i){ std::string a=argv[i];
        if(a=="--seconds"&&i+1<argc)seconds=atoi(argv[++i]); else if(a=="--device"&&i+1<argc)device=atoi(argv[++i]);
        else if(a=="--eth-dst"&&i+1<argc)eth_dst=argv[++i]; else if(a=="--amp"&&i+1<argc)amp=atof(argv[++i]);
        else if(a=="--sweep"&&i+1<argc)sweepdeg=atof(argv[++i]); else if(a=="--tsweep"&&i+1<argc)tsweep=atof(argv[++i]);
        else if(a=="--batch"&&i+1<argc)batch=atoi(argv[++i]); }
    std::signal(SIGINT,on_sig); std::signal(SIGTERM,on_sig); CK(cudaSetDevice(device));
    uint8_t mac[6]; if(!parse_mac(eth_dst.c_str(),mac)){fprintf(stderr,"bad MAC %s\n",eth_dst.c_str());return 1;}
    uint8_t h_hdr[ULA_HDR_BYTES];
    build_header(h_hdr,mac,ntohl(inet_addr(ULA_DEF_IP_SRC)),ntohl(inet_addr(ULA_DEF_IP_DST)),(uint16_t)ULA_UDP_PORT);

    uint8_t *d_sky=nullptr, *h_sky=nullptr;
    CK(cudaMalloc(&d_sky,(size_t)ULA_NELEM*ULA_PAYLOAD_BYTES));
    CK(cudaHostAlloc((void**)&h_sky,(size_t)ULA_NELEM*ULA_PAYLOAD_BYTES,cudaHostAllocDefault));
    /* sky: a SINGLE source swept in angle theta(t) -- the moving-source validation (angle readout sweeps) */
    auto gen=[&](float ssrc){ k_sky_ula<<<ULA_NELEM,ULA_NCHAN>>>(d_sky,ssrc,amp,0.f,0.f); CK(cudaDeviceSynchronize());
        CK(cudaMemcpy(h_sky,d_sky,(size_t)ULA_NELEM*ULA_PAYLOAD_BYTES,cudaMemcpyDeviceToHost)); };
    gen(0.f);

    if(daqiri::daqiri_init(yaml)!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    const int port_id=daqiri::get_port_id(ULA_TX_IFACE); if(port_id<0){fprintf(stderr,"no TX iface %s\n",ULA_TX_IFACE);return 1;}
    fprintf(stderr,"[tx_ula] 4-elem ULA -> %s udp %d: single source swept +-%.0fdeg over %.1fs, amp %.0f\n",
            eth_dst.c_str(),ULA_UDP_PORT,sweepdeg,tsweep,amp);

    const float w=2.0f*(float)M_PI/tsweep, srad=sweepdeg*(float)M_PI/180.f;
    uint64_t G=0, snaps=0; const auto t0=std::chrono::steady_clock::now(); double lastgen=-1;
    while(!g_stop){
        double tnow=std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
        if(seconds>0 && tnow>=seconds) break;
        if(tnow-lastgen>0.02){ gen(std::sin(srad*std::sin(w*tnow))); lastgen=tnow; }   /* sweep the planet ~50 Hz */
        auto* msg=daqiri::create_tx_burst_params();
        daqiri::set_header(msg,(uint16_t)port_id,0,batch,1);
        if(!daqiri::is_tx_burst_available(msg)){daqiri::free_tx_metadata(msg);std::this_thread::sleep_for(std::chrono::microseconds(50));continue;}
        if(daqiri::get_tx_packet_burst(msg)!=daqiri::Status::SUCCESS){daqiri::free_tx_metadata(msg);continue;}
        int n=(int)daqiri::get_num_packets(msg);
        for(int i=0;i<n;++i){ int e=(int)((G+i)%ULA_NELEM);
            uint8_t* p=(uint8_t*)daqiri::get_segment_packet_ptr(msg,0,i); if(!p) continue;
            std::memcpy(p,h_hdr,ULA_HDR_BYTES);
            uint32_t seqbe=htonl((uint32_t)(G+i)); std::memcpy(p+ULA_SEQ_BYTE,&seqbe,sizeof(seqbe));
            p[ULA_ELEM_BYTE]=(uint8_t)e;   /* drop-immune antenna ID: rx keys on this, not seq%NELEM */
            std::memcpy(p+ULA_HDR_BYTES,h_sky+(size_t)e*ULA_PAYLOAD_BYTES,ULA_PAYLOAD_BYTES); }
        G+=n;
        daqiri::set_all_packet_lengths(msg,{ULA_WIRE_BYTES});
        if(daqiri::send_tx_burst(msg)==daqiri::Status::SUCCESS){ snaps+=n/ULA_NELEM;
            if((snaps&131071)==0) fprintf(stderr,"[tx_ula] snaps=%lu t=%.1f\n",(unsigned long)snaps,tnow);
        } else daqiri::free_all_packets_and_burst_tx(msg);
    }
    g_stop=1; fprintf(stderr,"[tx_ula] stop: %lu snapshots, G=%lu\n",(unsigned long)snaps,(unsigned long)G);
    daqiri::print_stats(); daqiri::shutdown(); return 0;
}
