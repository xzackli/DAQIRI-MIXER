/* rx_feng4el_corr.cu — 4-element UNIFORM LINEAR ARRAY X-engine for the real feng4el RFSoC stream.
 * Consumes CHANNELIZED int8 from the F-engine (config_feng4el.h wire). Per frequency channel it forms the
 * 4x4 covariance V = X*X^H, then beamforms a 1-D angular response (van Cittert-Zernike for a line):
 * grid V by baseline Delta = e_b - e_a (autocorrelation Delta=0 EXCLUDED), zero-pad to NBEAM, one batched
 * 1-D cuFFT per channel -> angular power. Output: a (NCHAN x NBEAM) frequency-vs-angle image to
 * /dev/shm/corr_ula. Angle map @band-center: sin(theta) = 2*(k - NBEAM/2)/NBEAM.
 *
 * SINGLE-THREADED by design: at 4 elements the data rate is tiny, so one thread drains the host-bounce RX,
 * corner-turns the PPB=4 element heaps, accumulates V (k_corr4) on ONE stream, and every 1/fps publishes the
 * beamform of the per-frame-integrated V then zeroes it. No worker/publisher race (the bug that made an
 * earlier two-thread version image garbage). Reference: scratchpad/IMAGING_REFERENCE.md (angle <=1.4 deg).
 * Build: nvcc -arch=<sm_XX> rx_ula_corr.cu -lcufft + DAQIRI libs.  4 elements = no tensor cores needed. */
#include <cuda_runtime.h>
#include <cufft.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <daqiri/daqiri.h>
#include "config_feng4el.h"
#define CK(x) do{cudaError_t e_=(x);if(e_){fprintf(stderr,"CUDA %s:%d:%s\n",__FILE__,__LINE__,cudaGetErrorString(e_));std::exit(1);}}while(0)

#define NELEM  ULA_NELEM
#define NCHAN  ULA_NCHAN
#define TPKT   ULA_TPKT
#define NBEAM  ULA_NBEAM
#define NB     ULA_PAYLOAD_BYTES            /* active payload bytes per element heap (int8 complex) */
#define SAMP   (NB/2)                       /* complex samples per heap = NCHAN*TPKT                */
#define VN     (NELEM*NELEM)                /* 16 covariance entries per channel                      */
#define MR_STRIDE      16384
#define MR_ELEM_STRIDE 65536
#define MR_NBUFS       16384
#define MR_BYTES       ((size_t)MR_NBUFS*MR_ELEM_STRIDE)
static_assert(NCHAN*TPKT==SAMP, "NCHAN*TPKT must equal SAMP_PER_HEAP");
static_assert((NBEAM&(NBEAM-1))==0, "NBEAM must be power of two");

/* V[ch][a][b] += sum_t X_a(t)*conj(X_b(t)) over this snapshot's TPKT samples.
 * bb = [NELEM][NB], each heap = the active first 512 B of a real feng4el UDP payload:
 * TIME-MAJOR production index i = t*NCHAN + c; wire byte re @ ULA_WIRE_RE_OFF(i),
 * im @ ULA_WIRE_IM_OFF(i). */
__global__ void k_corr4(const uint8_t* __restrict__ bb, float* __restrict__ Vre, float* __restrict__ Vim){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*VN) return;
    int c=i/VN, ab=i%VN, a=ab/NELEM, b=ab%NELEM;
    const int8_t* A=(const int8_t*)bb+(size_t)a*NB; const int8_t* B=(const int8_t*)bb+(size_t)b*NB;
    float sre=0.f, sim=0.f;
    #pragma unroll
    for(int t=0;t<TPKT;++t){ int pi=ULA_PROD_SI(t,c); int ro=ULA_WIRE_RE_OFF(pi), io=ULA_WIRE_IM_OFF(pi);
        float ar=A[ro], ai=A[io], br=B[ro], bi=B[io];
        sre+=ar*br+ai*bi; sim+=ai*br-ar*bi; }           /* X_a * conj(X_b) */
    Vre[i]+=sre; Vim[i]+=sim;
}
/* grid V by baseline Delta=b-a (EXCLUDE autocorr a==b) into G[ch][Delta mod NBEAM]; zero-pad rest.
 * b-a (not a-b) so the angle axis matches sin(theta)=2(k-NBEAM/2)/NBEAM (validated by ula_selftest). */
__global__ void k_grid1d(const float* __restrict__ Vre,const float* __restrict__ Vim,cufftComplex* __restrict__ G){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*VN) return;
    int c=i/VN, ab=i%VN, a=ab/NELEM, b=ab%NELEM; if(a==b) return;       /* exclude Delta=0 pedestal */
    int d=((b-a)&(NBEAM-1));
    atomicAdd(&G[(size_t)c*NBEAM+d].x, Vre[i]); atomicAdd(&G[(size_t)c*NBEAM+d].y, Vim[i]);
}
/* fftshift (broadside -> center) + angular power -> image */
__global__ void k_publish(const cufftComplex* __restrict__ Img,float* __restrict__ img){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*NBEAM) return;
    int c=i/NBEAM, k=i%NBEAM, ks=(k+NBEAM/2)&(NBEAM-1);
    cufftComplex v=Img[(size_t)c*NBEAM+ks]; img[i]=v.x*v.x+v.y*v.y;
}

/* freq-vs-angle shm image; a viewer reads img[c*NBEAM + k] */
struct CorrULA{ uint32_t magic,nchan,nbeam; volatile uint64_t write_seq; float img[NCHAN*NBEAM]; float vmax,vmin; };
#define CORR_SHM "/corr_ula"
static CorrULA* corr_open(){ shm_unlink(CORR_SHM); int fd=shm_open(CORR_SHM,O_CREAT|O_RDWR,0666);
    if(fd<0){perror("shm");std::exit(1);} if(ftruncate(fd,sizeof(CorrULA))){perror("ftrunc");std::exit(1);}
    void* p=mmap(0,sizeof(CorrULA),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0); close(fd);
    CorrULA* c=(CorrULA*)p; std::memset(c,0,sizeof(CorrULA)); c->magic=0x554c4131; c->nchan=NCHAN; c->nbeam=NBEAM; return c; }

static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}
static int g_device=0;
static double secs_since(const std::chrono::steady_clock::time_point& t){
    return std::chrono::duration<double>(std::chrono::steady_clock::now()-t).count(); }
static uint32_t load_be32_unaligned(const uint8_t* p){
    uint32_t v;
    std::memcpy(&v,p,sizeof(v));
    return __builtin_bswap32(v);
}

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [--seconds N][--fps F][--device D]\n",argv[0]);return 1;}
    const char* yaml=argv[1]; int seconds=0; float fps=20.f;
    for(int i=2;i<argc;++i){ std::string a=argv[i];
        if(a=="--seconds"&&i+1<argc)seconds=atoi(argv[++i]); else if(a=="--fps"&&i+1<argc)fps=atof(argv[++i]);
        else if(a=="--device"&&i+1<argc)g_device=atoi(argv[++i]); }
    std::signal(SIGINT,on_sig); std::signal(SIGTERM,on_sig); CK(cudaSetDevice(g_device));
    if(daqiri::daqiri_init(yaml)!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    int port=daqiri::get_port_id(ULA_RX_IFACE); if(port<0){fprintf(stderr,"no RX iface\n");return 1;}
    uint8_t* g_bb; float *g_Vre,*g_Vim,*d_img; cufftComplex *g_G,*g_Img;
    CK(cudaMalloc(&g_bb,(size_t)NELEM*NB));
    CK(cudaMalloc(&g_Vre,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMemset(g_Vre,0,(size_t)NCHAN*VN*sizeof(float)));
    CK(cudaMalloc(&g_Vim,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMemset(g_Vim,0,(size_t)NCHAN*VN*sizeof(float)));
    CK(cudaMalloc(&g_G,(size_t)NCHAN*NBEAM*sizeof(cufftComplex)));
    CK(cudaMalloc(&g_Img,(size_t)NCHAN*NBEAM*sizeof(cufftComplex)));
    CK(cudaMalloc(&d_img,(size_t)NCHAN*NBEAM*sizeof(float)));
    cudaStream_t cs; CK(cudaStreamCreate(&cs));
    cufftHandle plan; int n1[1]={NBEAM};
    cufftPlanMany(&plan,1,n1,NULL,1,NBEAM,NULL,1,NBEAM,CUFFT_C2C,NCHAN); cufftSetStream(plan,cs);
    CorrULA* out=corr_open();
    float* h_img=(float*)malloc((size_t)NCHAN*NBEAM*sizeof(float));
    const uint8_t* mr_base=nullptr; const uint8_t* mr_end=nullptr; bool mr_reg=false;
    uint64_t snaps=0, imissed=0, snaps_pub=0; uint32_t frame=0;
    fprintf(stderr,"[ula] %d-elem ULA X-engine (single-thread) -> %d ch x %d beams (d=%.2f lambda) dev %d @ %.0f Hz, shm %s\n",
            NELEM,NCHAN,NBEAM,ULA_DSPACE,g_device,fps,CORR_SHM);
    auto t0=std::chrono::steady_clock::now(); auto last_pub=t0;
    while(!g_stop){
        if(seconds>0 && secs_since(t0)>=seconds) break;
        /* drain one burst, corner-turn + correlate each PPB=4 snapshot (all on cs) */
        daqiri::BurstParams* bu=nullptr; uint64_t snaps0=snaps;
        if(daqiri::get_rx_burst(&bu,port,0)==daqiri::Status::SUCCESS && bu){
            int npkts=(int)daqiri::get_num_packets(bu);
            const uint8_t* p0=(const uint8_t*)daqiri::get_packet_ptr(bu,0);
            if(p0){
                if(!mr_reg){ mr_base=p0; CK(cudaHostRegister((void*)mr_base,MR_BYTES,cudaHostRegisterDefault));
                    mr_end=mr_base+MR_BYTES; mr_reg=true; fprintf(stderr,"[ula] MR %p %zuMB\n",(void*)mr_base,(size_t)(MR_BYTES>>20)); }
                uint32_t seq0=load_be32_unaligned(p0+ULA_SEQ_BYTE);
                int off=(int)((NELEM-(seq0%NELEM))%NELEM);   /* seq -> snapshot framing/ordering only */
                for(int st=off; st+ULA_PPB<=npkts; st+=ULA_PPB){
                    /* Route each of the PPB packets into g_bb by its OWN byte-52 element index, so a
                     * dropped packet can't rotate antenna identity (reviewer-4 drop-immune keying).
                     * Also require the four packets to share one sequence base; an element mask alone
                     * would allow mixed-time covariance after a pathological drop/reorder window. */
                    unsigned seen_mask=0;
                    bool seq_ok=true;
                    uint32_t seq_base=0;
                    for(int j=0;j<ULA_PPB;++j){
                        const uint8_t* pk=(const uint8_t*)daqiri::get_packet_ptr(bu,st+j); if(!pk) continue;
                        if(pk<mr_base||pk+NB+ULA_HDR_BYTES>mr_end){imissed++;continue;}
                        uint32_t seq=load_be32_unaligned(pk+ULA_SEQ_BYTE);
                        int e=(int)pk[ULA_ELEM_BYTE]; if(e<0||e>=NELEM){imissed++;continue;}
                        uint32_t base=seq & ~(uint32_t)(NELEM-1);
                        if(j==0) seq_base=base;
                        if(base!=seq_base || (seq % NELEM)!=(uint32_t)e) seq_ok=false;
                        CK(cudaMemcpyAsync(g_bb+(size_t)e*NB,pk+ULA_HDR_BYTES,NB,cudaMemcpyHostToDevice,cs));
                        seen_mask |= (1u << e); }
                    if(!seq_ok || seen_mask != ((1u << NELEM) - 1u)){imissed++;continue;}   /* incomplete/mixed snapshot */
                    k_corr4<<<(NCHAN*VN+255)/256,256,0,cs>>>(g_bb,g_Vre,g_Vim);
                    snaps++; }
            }
            daqiri::free_all_packets_and_burst_rx(bu);
        }
        /* publish on the fps timer, but ONLY when new snapshots have accumulated (else V is empty -> blank frame) */
        if(secs_since(last_pub) >= 1.0/fps && snaps>snaps_pub){
            CK(cudaStreamSynchronize(cs));                       /* all k_corr4 for this frame done */
            CK(cudaMemsetAsync(g_G,0,(size_t)NCHAN*NBEAM*sizeof(cufftComplex),cs));
            k_grid1d<<<(NCHAN*VN+255)/256,256,0,cs>>>(g_Vre,g_Vim,g_G);
            cufftExecC2C(plan,g_G,g_Img,CUFFT_FORWARD);
            k_publish<<<(NCHAN*NBEAM+255)/256,256,0,cs>>>(g_Img,d_img);
            CK(cudaMemcpyAsync(h_img,d_img,(size_t)NCHAN*NBEAM*sizeof(float),cudaMemcpyDeviceToHost,cs));
            CK(cudaStreamSynchronize(cs));
            float vmax=-1e30f,vmin=1e30f;
            for(int j=0;j<NCHAN*NBEAM;++j){ float v=h_img[j]; out->img[j]=v; vmax=v>vmax?v:vmax; vmin=v<vmin?v:vmin; }
            /* recovered angle from the BAND-CENTER channel (clean sin map; low channels are DC-dominated near 0deg) */
            int gc=ULA_FCEN_CH, gk=NBEAM/2; float rmax=-1e30f; const float* row=h_img+(size_t)ULA_FCEN_CH*NBEAM;
            for(int k=0;k<NBEAM;++k) if(row[k]>rmax){rmax=row[k];gk=k;}
            float gsn=2.f*(gk-NBEAM/2)/(float)NBEAM; if(gsn<-1)gsn=-1; if(gsn>1)gsn=1;
            float gth=asinf(gsn)*180.f/(float)M_PI;   /* recovered source angle @ band-center channel */
            out->vmax=vmax; out->vmin=vmin; __atomic_store_n(&out->write_seq,(uint64_t)frame+1,__ATOMIC_RELEASE);
            CK(cudaMemsetAsync(g_Vre,0,(size_t)NCHAN*VN*sizeof(float),cs));   /* reset integration for next frame */
            CK(cudaMemsetAsync(g_Vim,0,(size_t)NCHAN*VN*sizeof(float),cs));
            if(frame%(uint32_t)fps==0) fprintf(stderr,"[ula] frame %u snaps=%lu angle=%+.1fdeg ch=%d vmax=%.2g imissed=%lu\n",
                frame,(unsigned long)snaps,gth,gc,vmax,(unsigned long)imissed);
            snaps_pub=snaps; last_pub=std::chrono::steady_clock::now(); frame++;
        }
        if(snaps==snaps0) usleep(150);   /* no new burst this iter -> brief sleep, don't busy-spin */
    }
    fprintf(stderr,"[ula] stop after %u frames; snaps=%lu imissed=%lu\n",frame,(unsigned long)snaps,(unsigned long)imissed);
    if(mr_reg)cudaHostUnregister((void*)mr_base); munmap(out,sizeof(CorrULA)); shm_unlink(CORR_SHM);
    daqiri::print_stats(); daqiri::shutdown(); return 0;
}
