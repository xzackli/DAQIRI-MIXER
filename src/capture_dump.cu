/* capture_dump.cu — capture raw packets via DAQIRI (ibverbs) and histogram the int8 payload.
 * The gain-staging check for real RFSoC data: is the signal in the int8 range (RMS ~10-30) or
 * near-zero (RFDC gain too low -> high-byte ~0)? Also dumps a header/payload sample to verify offsets.
 * usage: capture_dump <yaml> [payload_offset=106] [payload_len=8192]   (stream4_i8_hb wire: seq@42, payload@106)
 * Build: nvcc -arch=sm_86 capture_dump.cu + DAQIRI libs. */
#include <daqiri/daqiri.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <csignal>
static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}
int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [payoff=106] [paylen=8192]\n",argv[0]);return 1;}
    const char* yaml=argv[1];
    int PAYOFF=(argc>2)?atoi(argv[2]):106, PAYLEN=(argc>3)?atoi(argv[3]):8192;
    std::signal(SIGINT,on_sig);
    if(daqiri::daqiri_init(yaml)!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    int port=daqiri::get_port_id("rx_port"); if(port<0){fprintf(stderr,"no rx_port\n");return 1;}
    long hist[256]={0}; long n=0; int bursts=0; bool dumped=false;
    while(!g_stop && bursts<400){
        daqiri::BurstParams* bu=nullptr;
        if(daqiri::get_rx_burst(&bu,port,0)!=daqiri::Status::SUCCESS||!bu) continue;
        int npkts=(int)daqiri::get_num_packets(bu);
        for(int i=0;i<npkts && i<128;++i){
            const uint8_t* p=(const uint8_t*)daqiri::get_packet_ptr(bu,i); if(!p) continue;
            if(!dumped){ printf("frame bytes [40..52] (seq region):"); for(int k=40;k<52;++k) printf(" %02x",p[k]);
                printf("\npayload int8 [%d..%d]:",PAYOFF,PAYOFF+16); for(int k=PAYOFF;k<PAYOFF+16;++k) printf(" %d",(int)(int8_t)p[k]);
                printf("\n"); dumped=true; }
            for(int j=0;j<PAYLEN;++j){ int8_t v=(int8_t)p[PAYOFF+j]; hist[(uint8_t)v]++; ++n; }
        }
        daqiri::free_all_packets_and_burst_rx(bu); ++bursts;
    }
    if(n==0){ printf("NO DATA captured (link/flow?)\n"); daqiri::shutdown(); return 1; }
    double mean=0,sq=0; int mn=127,mx=-128; long zero=0;
    for(int v=-128;v<128;++v){ long c=hist[(uint8_t)(int8_t)v]; if(c){ if(v<mn)mn=v; if(v>mx)mx=v; } if(v==0)zero=c; mean+=(double)v*c; }
    mean/=n; for(int v=-128;v<128;++v){ long c=hist[(uint8_t)(int8_t)v]; sq+=(double)c*(v-mean)*(v-mean); }
    double rms=std::sqrt(sq/n);
    printf("\ncaptured %ld int8 samples over %d bursts\n",n,bursts);
    printf("min=%d max=%d mean=%.2f RMS=%.2f  exactly-zero=%.1f%%  saturated(|v|=127)=%.3f%%\n",
        mn,mx,mean,rms,100.0*zero/n,100.0*(hist[127]+hist[(uint8_t)(int8_t)-127]+hist[128/*-128*/])/n);
    printf("histogram (16-wide bins):\n");
    for(int b=0;b<16;++b){ long c=0; for(int v=-128+b*16;v<-128+(b+1)*16;++v) c+=hist[(uint8_t)(int8_t)v];
        printf(" [%+4d..%+4d] %8ld %s\n",-128+b*16,-128+(b+1)*16-1,c,(c>n/40)?"#":""); }
    printf("VERDICT: %s\n", (rms<2.0)?"GAIN TOO LOW (signal not reaching high byte -> raise RFDC gain)":
                            (mx>=127||mn<=-127)?"CLIPPING present (lower RFDC gain)":"gain-staging looks healthy");
    daqiri::shutdown(); return 0;
}
