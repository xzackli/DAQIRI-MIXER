/* chan_id.cu — RAW wire channel-ID for feng4el_gate hardware validation (NO un-permute).
 * Captures raw packets via DAQIRI ibverbs, accumulates per-element per-channel power
 * directly from wire byte order: spectrum @frame byte 106, 256 ch x [Im(even),Re(odd)] int8.
 * seq = BE uint32 @90, elem = uint8 @94. Also framing spot-check: seq%4==elem, seq monotonic.
 * usage: chan_id <yaml> [bursts=2000]
 */
#include <daqiri/daqiri.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <csignal>
static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}
#define NCH 256
#define SPEC_OFF 106
#define SEQ_OFF 90
#define ELEM_OFF 94
int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [bursts]\n",argv[0]);return 1;}
    int MAXB=(argc>2)?atoi(argv[2]):2000;
    std::signal(SIGINT,on_sig);
    if(daqiri::daqiri_init(argv[1])!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    int port=daqiri::get_port_id("rx_port"); if(port<0){fprintf(stderr,"no rx_port\n");return 1;}
    double pw[4][NCH]; memset(pw,0,sizeof(pw));
    long npkt[4]={0,0,0,0}; long tot=0;
    int iplen_min=1<<30, iplen_max=0;
    static int maxabs[1024]; memset(maxabs,0,sizeof(maxabs)); /* per frame-offset max|v| over payload */
    long tag_ok=0, tag_bad=0; long seq_incr_ok=0, seq_incr_bad=0;
    uint32_t last_seq=0; bool have_last=false; int dumped=0;
    int elem_hist[8]={0};
    while(!g_stop && tot/1000<MAXB){
        daqiri::BurstParams* bu=nullptr;
        if(daqiri::get_rx_burst(&bu,port,0)!=daqiri::Status::SUCCESS||!bu) continue;
        int n=(int)daqiri::get_num_packets(bu);
        for(int i=0;i<n;++i){
            const uint8_t* p=(const uint8_t*)daqiri::get_packet_ptr(bu,i); if(!p) continue;
            int iplen=((int)p[16]<<8)|p[17]; if(iplen<iplen_min)iplen_min=iplen; if(iplen>iplen_max)iplen_max=iplen;
            int frlen=14+iplen; if(frlen>1024)frlen=1024;
            for(int k=106;k<frlen;++k){ int v=(int8_t)p[k]; if(v<0)v=-v; if(v>maxabs[k])maxabs[k]=v; }
            uint32_t seq=((uint32_t)p[SEQ_OFF]<<24)|((uint32_t)p[SEQ_OFF+1]<<16)|((uint32_t)p[SEQ_OFF+2]<<8)|p[SEQ_OFF+3];
            uint8_t el=p[ELEM_OFF];
            elem_hist[el&7]++;
            if((seq&3)==(el&3)) tag_ok++; else tag_bad++;
            if(have_last){ if(seq==last_seq+1) seq_incr_ok++; else seq_incr_bad++; }
            last_seq=seq; have_last=true;
            if(el>3) continue;
            if(dumped<4){ printf("sample pkt: seq=%u elem=%u bytes[88..96]:",seq,el);
                for(int k=88;k<97;++k) printf(" %02x",p[k]); printf("\n"); dumped++; }
            for(int c=0;c<NCH;++c){
                int im=(int8_t)p[SPEC_OFF+2*c], re=(int8_t)p[SPEC_OFF+2*c+1];
                pw[el][c]+=(double)re*re+(double)im*im;
            }
            npkt[el]++; tot++;
        }
        daqiri::free_all_packets_and_burst_rx(bu);
    }
    printf("\nIP total length min=%d max=%d (frame=14+len, UDP payload=len-28)\n",iplen_min,iplen_max);
    { int nz=0; printf("payload frame-offsets with nonzero max|v|:");
      for(int k=106;k<1024;++k) if(maxabs[k]){ if(nz<24) printf(" %d(%d)",k,maxabs[k]); nz++; }
      printf("  [total %d nonzero offsets]\n",nz); }
    printf("total pkts=%ld  per-elem:",tot);
    for(int e=0;e<4;++e) printf(" e%d=%ld",e,npkt[e]);
    printf("\nelem tag hist 0..7:"); for(int e=0;e<8;++e) printf(" %d",elem_hist[e]);
    printf("\nframing: seq%%4==elem ok=%ld bad=%ld | consecutive seq+1 ok=%ld bad=%ld (note: bad also counts burst boundaries)\n",
        tag_ok,tag_bad,seq_incr_ok,seq_incr_bad);
    for(int e=0;e<4;++e){
        if(!npkt[e]) { printf("elem%d: NO PACKETS\n",e); continue; }
        /* mean power per channel; find top 5 */
        double mean=0; for(int c=0;c<NCH;++c) mean+=pw[e][c]; mean/=NCH;
        int top[5]={-1,-1,-1,-1,-1};
        for(int t=0;t<5;++t){ double best=-1; int bi=-1;
            for(int c=0;c<NCH;++c){ bool used=false; for(int u=0;u<t;++u) if(top[u]==c) used=true;
                if(!used&&pw[e][c]>best){best=pw[e][c];bi=c;} } top[t]=bi; }
        printf("elem%d: mean_ch_pw=%.3g ; top5 wire channels:",e,mean/npkt[e]);
        for(int t=0;t<5;++t) printf(" ch%d(%.3g)",top[t],pw[e][top[t]]/npkt[e]);
        printf("\n");
    }
    daqiri::shutdown(); return 0;
}
