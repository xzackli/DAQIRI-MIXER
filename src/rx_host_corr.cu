/* rx_host_corr.cu -- realtime int8 tensor-core COVARIANCE CORRELATOR fed by a 400 GbE
 * F-engine stream. Per frequency channel: V = X*X^H (cgemm.cuh), integrated, then imaged.
 *  drain thread: thin host-bounce RX (hand snapshot ptrs, no per-pkt copy) -> GPU thread H2D corner-turn.
 *  pack: int8 wire -> int8 X and conj(X), BOTH [ch][ant][klocal] (B read col-major = conj(X)^T, free transpose).
 *  compute: cgemm_blk_t<true> accumulates V += X*X^H into a persistent int32 cube; k_flush_cube drains it
 *    to a float cube every --flush updates (no separate accumulate pass, no per-batch V buffer).
 *  science output: the integrated visibility cube g_Vcube -- the real product; --dump <path> writes it to disk ~1/s.
 *  live monitor @ fps: dV = Vcube - Vprev; grid by baseline d=a-b -> 32x32; one batched cuFFT ->
 *    128-channel (32x32) alias-free image cube -> /dev/shm/corr32 (van Cittert-Zernike).
 * Build: nvcc -arch=<sm_XX> rx_host_corr.cu -lcufft + DAQIRI libs; standard nvcuda::wmma tensor cores (cgemm.cuh).
 * Verified: star+orbiting planet, per-channel slope==c/127; ~380 G = ~98% line rate, 0-drop <~90%. */
#include <cuda_runtime.h>
#include <cufft.h>
#include "cgemm.cuh"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <pthread.h>
#include <sched.h>
#include <string>
#include <thread>
#include <vector>
#include <daqiri/daqiri.h>
#include "config.h"
#define CK(x) do{cudaError_t e_=(x);if(e_){fprintf(stderr,"CUDA %s:%d:%s\n",__FILE__,__LINE__,cudaGetErrorString(e_));std::exit(1);}}while(0)
#define NB        (MIXER_NCH*MIXER_TPKT)           /* 8192 wire bytes per heap (planar int8 re|im) */
#define SAMP_PER_HEAP (NB/2)                  /* 4096 complex samples per antenna heap */
#define NCUBE     128                         /* frequency channels (= the per-channel V planes) */
#define HBATCH    32                          /* heaps per V-update */
#define KPCH      1024                        /* samples per channel per V-update (= HBATCH*MIXER_TPKT) */
#define MM        256                         /* M = N = MIXER_NANT */
#define MN        ((size_t)MM*MM)             /* 65536 visibilities per channel */
#define TOTAL_SAMP ((size_t)HBATCH*SAMP_PER_HEAP) /* samples packed per V-update (131072) */
#define NBATCH    4
#define NCOMP     2
#define NSLOT     96
#define MR_STRIDE 16384
#define MR_ELEM_STRIDE 65536
#define MR_NBUFS  16384
#define MR_BYTES  ((size_t)MR_NBUFS*MR_ELEM_STRIDE)
#define NG        32
#define VCH       (2*MN)                      /* floats per channel visibility (planar re|im, 256x256) */
static_assert(SAMP_PER_HEAP/MIXER_TPKT==NCUBE, "wire channels (SAMP_PER_HEAP/MIXER_TPKT) must equal NCUBE");
static_assert(HBATCH*MIXER_TPKT==KPCH, "KPCH must equal HBATCH*MIXER_TPKT");

/* pack: planar int8 bb[heap][ant][re[SAMP]|im[SAMP]] -> int8 A=X and B=conj(X), BOTH [ch][ant][klocal]
 * (row-major, ld=KPCH). cgemm reads B column-major, so this same layout IS conj(X)^T -- the transpose
 * is free and A/B share one coalesced index (no scattered transpose write). One thread per (ant, global
 * sample); the frequency channel IS the split-K slot c=sl/MIXER_TPKT, klocal=heap*MIXER_TPKT+t spans the KPCH
 * of the V-update. The (ant,heap,sl) -> (c,ant,klocal) map is a bijection, so every element is written once. */
__global__ void k_packAB(const uint8_t* __restrict__ bb, MixerI8* __restrict__ Are, MixerI8* __restrict__ Aim,
                         MixerI8* __restrict__ Bre, MixerI8* __restrict__ Bim){
    size_t i=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(i>=(size_t)MIXER_NANT*TOTAL_SAMP) return;
    int ant=i/TOTAL_SAMP; size_t s=i%TOTAL_SAMP;            /* global sample [0,TOTAL_SAMP) */
    int heap=s/SAMP_PER_HEAP, sl=s%SAMP_PER_HEAP, c=sl/MIXER_TPKT, t=sl%MIXER_TPKT, klocal=heap*MIXER_TPKT+t;
    size_t hb=(size_t)heap*MIXER_NANT*NB+(size_t)ant*NB;
    MixerI8 re=(MixerI8)(int8_t)__ldg(&bb[hb+sl]);                 /* int8 wire: read directly (raw byte, no decode) */
    MixerI8 im=(MixerI8)(int8_t)__ldg(&bb[hb+SAMP_PER_HEAP+sl]);
    size_t a=(size_t)c*MM*KPCH+(size_t)ant*KPCH+klocal;     /* A=X, B=conj(X): [ch][ant][klocal], shared index */
    Are[a]=re; Aim[a]=im;                                   /* A = X         */
    Bre[a]=re; Bim[a]=(MixerI8)(-im);                          /* B = conj(X)   (read col-major -> conj(X)^T) */
}
/* dV = Vsnap - Vprev over n planar floats (whole cube); Vprev <- Vsnap */
__global__ void k_diff(const float* Vs, float* Vp, float* dV, size_t n){
    size_t i=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
    dV[i]=Vs[i]-Vp[i]; Vp[i]=Vs[i];
}
/* grid all NCUBE channels: dVcube[ch] (planar) by baseline Δ=a-b -> G[ch][NG*NG] */
__global__ void k_grid_cube(const float* dV, cufftComplex* G){
    size_t idx=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(idx>=(size_t)NCUBE*MN) return;
    int ch=idx/MN; size_t i=idx%MN;
    int a=i/MIXER_NANT,b=i%MIXER_NANT, dy=(((a>>4)-(b>>4))%NG+NG)%NG, dx=(((a&15)-(b&15))%NG+NG)%NG;
    const float* dVc=dV+(size_t)ch*VCH; cufftComplex* Gc=G+(size_t)ch*NG*NG;
    atomicAdd(&Gc[dy*NG+dx].x, dVc[i]); atomicAdd(&Gc[dy*NG+dx].y, dVc[MN+i]);
}
/* flush the running int32 visibility cube into the cumulative FLOAT cube, then zero it. The GEMM accumulates
 * V += X*X^H directly into the int32 cube (Vire/Viim) every V-update -- this drains it to float every g_flush
 * updates, before int32 can overflow (g_flush*127*127*KPCH << 2^31, safe to ~127). Vcube is [NCUBE][2][M][N] planar; the
 * int32 cube is [NCUBE][M][N] per plane. NO sum across channels (a real spectral cube). */
__global__ void k_flush_cube(float* __restrict__ Vcube, int* __restrict__ Vire, int* __restrict__ Viim){
    size_t i=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(i>=(size_t)NCUBE*MN) return;
    int ch=i/MN; size_t j=i%MN;
    Vcube[(size_t)ch*VCH + j]      += (float)Vire[i]; Vire[i]=0;   /* re plane */
    Vcube[(size_t)ch*VCH + MN + j] += (float)Viim[i]; Viim[i]=0;   /* im plane */
}

/* spectral-cube shm: NCUBE freq planes of NG x NG; viewer peek32 selects a channel */
struct Corr32 { uint32_t magic, w, h, nch; volatile uint64_t write_seq; float img[NCUBE*NG*NG]; float vmax[NCUBE], vmin[NCUBE]; };
#define CORR_SHM "/corr32"
static Corr32* corr_open(){
    shm_unlink(CORR_SHM); int fd=shm_open(CORR_SHM,O_CREAT|O_RDWR,0666);
    if(fd<0){perror("shm");std::exit(1);} if(ftruncate(fd,sizeof(Corr32))){perror("ftrunc");std::exit(1);}
    void* p=mmap(0,sizeof(Corr32),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0); close(fd);
    Corr32* c=(Corr32*)p; std::memset(c,0,sizeof(Corr32)); c->magic=0x43523343; c->w=NG; c->h=NG; c->nch=NCUBE; return c;
}

static volatile std::sig_atomic_t g_stop=0; static void on_sig(int){g_stop=1;}
static float* g_Vcube=nullptr;      /* cumulative per-channel visibilities [NCUBE][2][256][256] (the spectral cube) */
static uint8_t* g_bb[NBATCH]={0};
static MixerI8* g_Are[NBATCH]={0}; static MixerI8* g_Aim[NBATCH]={0};   /* A = X         [ch][ant][klocal] (int8)   */
static MixerI8* g_Bre[NBATCH]={0}; static MixerI8* g_Bim[NBATCH]={0};   /* B = conj(X)^T [ch][klocal][ant] (int8)   */
static int*  g_Vire=nullptr; static int* g_Viim=nullptr;          /* SINGLE running int32 visibility cube [ch][M][N], flushed to g_Vcube */
static int g_flush=4;                                             /* flush int32 cube -> float every g_flush V-updates (--flush); low=smooth live view, high (~16) = max throughput; overflow-safe to ~127 */
static cudaEvent_t g_batch_ev[NBATCH];
static std::atomic<uint64_t> g_batches{0}, g_imissed{0}, g_misalign{0};
static int g_port=0, g_device=1; static bool g_noflop=false; static int g_drain_core=10, g_gpu_core=11;
static const uint8_t* g_mr_base=nullptr; static const uint8_t* g_mr_end=nullptr;
static std::atomic<const uint8_t*> g_mr_base_raw{nullptr}; static std::atomic<bool> g_mr_ready{false};
static void pin(int c){cpu_set_t s;CPU_ZERO(&s);CPU_SET(c,&s);pthread_setaffinity_np(pthread_self(),sizeof(s),&s);}
struct Slot{const void* mr_ptr; cudaEvent_t ev;}; static Slot g_slot[NSLOT];
static std::vector<int> g_freeq,g_fillq; static std::mutex g_m; static std::condition_variable g_cv_free,g_cv_fill;
static void register_mr(const void* p){ g_mr_base=(const uint8_t*)p; size_t sz=MR_BYTES;
    cudaError_t e=cudaHostRegister((void*)g_mr_base,sz,cudaHostRegisterDefault);
    if(e) fprintf(stderr,"[corr] hostRegister FAIL %s\n",cudaGetErrorString(e));
    else  fprintf(stderr,"[corr] MR %p %zuMB HBATCH=%d\n",(void*)g_mr_base,(size_t)(sz>>20),(int)HBATCH);
    g_mr_end=g_mr_base+sz; g_mr_ready.store(true,std::memory_order_release); }
static void drain_thread(){ pin(g_drain_core);
    while(!g_stop){ daqiri::BurstParams* bu=nullptr;
        if(daqiri::get_rx_burst(&bu,g_port,0)!=daqiri::Status::SUCCESS||!bu) continue;
        int npkts=(int)daqiri::get_num_packets(bu); const uint8_t* p0=(const uint8_t*)daqiri::get_packet_ptr(bu,0);
        if(!p0){daqiri::free_all_packets_and_burst_rx(bu);continue;}
        if(!g_mr_base_raw.load(std::memory_order_relaxed)) g_mr_base_raw.store(p0,std::memory_order_release);
        if(!g_mr_ready.load(std::memory_order_acquire)){daqiri::free_all_packets_and_burst_rx(bu);continue;}
        uint32_t seq0=__builtin_bswap32(*(const uint32_t*)(p0+MIXER_SEQ_BYTE)); int off=(int)((MIXER_NANT-(seq0%MIXER_NANT))%MIXER_NANT);
        if(off) g_misalign.fetch_add(1,std::memory_order_relaxed);
        for(int st=off; st+MIXER_PPB<=npkts; st+=MIXER_PPB){ const uint8_t* base=(const uint8_t*)daqiri::get_packet_ptr(bu,st);
            if(!base) continue;
            if(base<g_mr_base||base+(size_t)(MIXER_NANT-1)*MR_STRIDE+NB+MIXER_HDR_BYTES>g_mr_end){g_misalign.fetch_add(1,std::memory_order_relaxed);continue;}
            int s=-1; {std::lock_guard<std::mutex> lk(g_m); if(!g_freeq.empty()){s=g_freeq.back();g_freeq.pop_back();}}
            if(s<0){g_imissed.fetch_add(1,std::memory_order_relaxed);continue;}
            g_slot[s].mr_ptr=base; {std::lock_guard<std::mutex> lk(g_m); g_fillq.push_back(s);} g_cv_fill.notify_one(); }
        daqiri::free_all_packets_and_burst_rx(bu); } }
static void gpu_thread(){ pin(g_gpu_core); CK(cudaSetDevice(g_device));
    while(!g_stop){ const uint8_t* b=g_mr_base_raw.load(std::memory_order_acquire);
        if(b){register_mr(b);break;} std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
    cudaStream_t copy_stream, comp_stream[NCOMP];
    CK(cudaStreamCreateWithFlags(&copy_stream,cudaStreamNonBlocking));
    for(int c=0;c<NCOMP;++c) CK(cudaStreamCreateWithFlags(&comp_stream[c],cudaStreamNonBlocking));
    dim3 gemm_grid((((MM/(MIXER_WT*MIXER_SM))*(MM/(MIXER_WT*MIXER_SN)))*32+255)/256, 1, NCUBE);  /* (8,1,128): one warp per SMxSN tile-block, z=channel */
    cudaEvent_t vacc_ev; CK(cudaEventCreateWithFlags(&vacc_ev,cudaEventDisableTiming)); /* serialize g_V += across comp streams */
    int packT=256, packG=(int)(((size_t)MIXER_NANT*TOTAL_SAMP+packT-1)/packT);
    int cur=0,hc=0,flushc=0; uint64_t bc=0; bool started[NBATCH]={false}; std::vector<int> inflight; size_t ih=0;
    while(true){
        while(ih<inflight.size()){int s=inflight[ih]; if(cudaEventQuery(g_slot[s].ev)==cudaSuccess){{std::lock_guard<std::mutex> lk(g_m);g_freeq.push_back(s);}g_cv_free.notify_one();ih++;} else break;}
        if(ih>2048){inflight.erase(inflight.begin(),inflight.begin()+ih);ih=0;}
        int s=-1; {std::unique_lock<std::mutex> lk(g_m); g_cv_fill.wait_for(lk,std::chrono::milliseconds(1),[&]{return !g_fillq.empty()||g_stop;});
            if(!g_fillq.empty()){s=g_fillq.front();g_fillq.erase(g_fillq.begin());}}
        if(s<0){if(g_stop&&ih>=inflight.size())break; continue;}
        CK(cudaMemcpy2DAsync(g_bb[cur]+(size_t)hc*MIXER_NANT*NB,NB,(const uint8_t*)g_slot[s].mr_ptr+MIXER_HDR_BYTES,MR_STRIDE,NB,MIXER_NANT,cudaMemcpyHostToDevice,copy_stream));
        CK(cudaEventRecord(g_slot[s].ev,copy_stream)); inflight.push_back(s);
        if(++hc==(int)HBATCH){ if(!g_noflop){ int cm=(int)(bc%NCOMP);
                CK(cudaStreamWaitEvent(comp_stream[cm],g_slot[s].ev,0));
                k_packAB<<<packG,packT,0,comp_stream[cm]>>>(g_bb[cur],g_Are[cur],g_Aim[cur],g_Bre[cur],g_Bim[cur]);
                /* V += X*X^H accumulated DIRECTLY into the running int32 cube (register-blocked int8 wmma, z=channel);
                 * the cube RMW must be single-writer across comp streams -> serialize with vacc_ev. */
                if(bc>0) CK(cudaStreamWaitEvent(comp_stream[cm],vacc_ev,0));
                cgemm_blk_t<true><<<gemm_grid,256,0,comp_stream[cm]>>>(MM,MM,KPCH,g_Are[cur],g_Aim[cur],g_Bre[cur],g_Bim[cur],g_Vire,g_Viim);
                if(++flushc>=g_flush){ k_flush_cube<<<((size_t)NCUBE*MN+255)/256,256,0,comp_stream[cm]>>>(g_Vcube,g_Vire,g_Viim); flushc=0; }
                CK(cudaEventRecord(vacc_ev,comp_stream[cm]));   /* next gemm/flush waits: cube RMW + zero are ordered */
                CK(cudaEventRecord(g_batch_ev[cur],comp_stream[cm])); started[cur]=true; }
            g_batches.fetch_add(HBATCH,std::memory_order_relaxed); bc++; cur=(cur+1)%NBATCH; hc=0;
            if(started[cur]) CK(cudaStreamWaitEvent(copy_stream,g_batch_ev[cur],0)); } }
    for(;ih<inflight.size();++ih) cudaEventSynchronize(g_slot[inflight[ih]].ev);
    cudaEventDestroy(vacc_ev);
    for(int c=0;c<NCOMP;++c) cudaStreamDestroy(comp_stream[c]); cudaStreamDestroy(copy_stream); }

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <yaml> [--seconds N][--fps F][--device D][--noflop][--flush N][--dump PATH]\n",argv[0]);return 1;}
    const char* yaml=argv[1]; int seconds=0; float fps=20.f; const char* dumpPath=nullptr;
    for(int i=2;i<argc;++i){std::string a=argv[i];
        if(a=="--seconds"&&i+1<argc)seconds=atoi(argv[++i]); else if(a=="--fps"&&i+1<argc)fps=atof(argv[++i]);
        else if(a=="--device"&&i+1<argc)g_device=atoi(argv[++i]); else if(a=="--noflop")g_noflop=true;
        else if(a=="--flush"&&i+1<argc)g_flush=atoi(argv[++i]); else if(a=="--dump"&&i+1<argc)dumpPath=argv[++i];}
    std::signal(SIGINT,on_sig); std::signal(SIGTERM,on_sig); CK(cudaSetDevice(g_device));
    if(daqiri::daqiri_init(yaml)!=daqiri::Status::SUCCESS){fprintf(stderr,"daqiri_init failed\n");return 1;}
    g_port=daqiri::get_port_id(MIXER_RX_IFACE); if(g_port<0){fprintf(stderr,"no RX iface\n");return 1;}
    size_t cubeBytes=(size_t)NCUBE*VCH*sizeof(float);        /* 64 MB cumulative cube [NCUBE][2][256][256] */
    CK(cudaMalloc(&g_Vcube,cubeBytes)); CK(cudaMemset(g_Vcube,0,cubeBytes)); /* zeroed once */
    CK(cudaMalloc(&g_Vire,(size_t)NCUBE*MN*sizeof(int))); CK(cudaMemset(g_Vire,0,(size_t)NCUBE*MN*sizeof(int))); /* running int32 cube, 32 MB */
    CK(cudaMalloc(&g_Viim,(size_t)NCUBE*MN*sizeof(int))); CK(cudaMemset(g_Viim,0,(size_t)NCUBE*MN*sizeof(int))); /* 32 MB */
    for(int b=0;b<NBATCH;++b){ CK(cudaMalloc(&g_bb[b],(size_t)HBATCH*MIXER_NANT*NB));
        CK(cudaMalloc(&g_Are[b],(size_t)NCUBE*MM*KPCH)); CK(cudaMalloc(&g_Aim[b],(size_t)NCUBE*MM*KPCH));   /* 32 MB each */
        CK(cudaMalloc(&g_Bre[b],(size_t)NCUBE*KPCH*MM)); CK(cudaMalloc(&g_Bim[b],(size_t)NCUBE*KPCH*MM));   /* 32 MB each */
        CK(cudaEventCreateWithFlags(&g_batch_ev[b],cudaEventDisableTiming)); }
    for(int i=0;i<NSLOT;++i){CK(cudaEventCreateWithFlags(&g_slot[i].ev,cudaEventDisableTiming));g_freeq.push_back(i);}
    Corr32* out=corr_open();
    /* publish-side GPU resources (whole spectral cube: NCUBE planes) */
    cudaStream_t pub; CK(cudaStreamCreate(&pub));
    size_t cubeF=(size_t)NCUBE*VCH;                 /* floats in the cube (planar re|im over all channels) */
    float *g_Vprev,*g_dV; cufftComplex *g_G,*g_Img;
    CK(cudaMalloc(&g_Vprev,cubeF*4)); CK(cudaMemset(g_Vprev,0,cubeF*4));
    CK(cudaMalloc(&g_dV,cubeF*4));
    CK(cudaMalloc(&g_G,(size_t)NCUBE*NG*NG*sizeof(cufftComplex)));
    CK(cudaMalloc(&g_Img,(size_t)NCUBE*NG*NG*sizeof(cufftComplex)));
    cufftHandle plan; int nfft[2]={NG,NG};         /* one batched plan: NCUBE transforms of NGxNG */
    cufftPlanMany(&plan,2,nfft,NULL,1,NG*NG,NULL,1,NG*NG,CUFFT_C2C,NCUBE); cufftSetStream(plan,pub);
    fprintf(stderr,"[corr] THIN-DRAIN RX -> int8 SPECTRAL CORRELATOR -> %d-channel cube of %dx%d alias-free images (HBATCH=%d) dev %d @ %.0f Hz, shm %s\n",NCUBE,NG,NG,(int)HBATCH,g_device,fps,CORR_SHM);
    std::thread gpu(gpu_thread), drain(drain_thread);
    cufftComplex* h=(cufftComplex*)malloc((size_t)NCUBE*NG*NG*sizeof(cufftComplex));
    float* hVcube=nullptr; FILE* dumpf=nullptr;     /* --dump: persist the integrated V cube (the science product) to disk ~1/s */
    if(dumpPath){ dumpf=fopen(dumpPath,"wb"); if(!dumpf){perror("dump fopen");return 1;} hVcube=(float*)malloc(cubeBytes);
        fprintf(stderr,"[corr] --dump: integrated V cube [%d][2][%d][%d] float (%zu MB/record) -> %s ~1/s\n",NCUBE,MM,MM,(size_t)(cubeBytes>>20),dumpPath); }
    const auto t0=std::chrono::steady_clock::now(); auto next=t0; uint32_t frame=0; uint64_t total=0;
    while(!g_stop){
        if(seconds>0&&std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count()>=seconds) break;
        next+=std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(1.0/fps));
        std::this_thread::sleep_until(next);
        /* live monitor: dV = current integrated cube - last frame (benign race w/ the comp-stream flush) -> grid -> FFT */
        k_diff<<<(unsigned)((cubeF+255)/256),256,0,pub>>>(g_Vcube,g_Vprev,g_dV,cubeF);
        CK(cudaMemsetAsync(g_G,0,(size_t)NCUBE*NG*NG*sizeof(cufftComplex),pub));
        k_grid_cube<<<(unsigned)(((size_t)NCUBE*MN+255)/256),256,0,pub>>>(g_dV,g_G);
        cufftExecC2C(plan,g_G,g_Img,CUFFT_FORWARD);
        CK(cudaMemcpyAsync(h,g_Img,(size_t)NCUBE*NG*NG*sizeof(cufftComplex),cudaMemcpyDeviceToHost,pub));
        bool dumpNow=dumpf&&(frame%(uint32_t)fps==0);   /* ~1/s: snapshot the integrated visibility cube to disk */
        if(dumpNow) CK(cudaMemcpyAsync(hVcube,g_Vcube,cubeBytes,cudaMemcpyDeviceToHost,pub));
        CK(cudaStreamSynchronize(pub));
        if(dumpNow){ fwrite(hVcube,1,cubeBytes,dumpf); fflush(dumpf); fprintf(stderr,"[corr] dumped integrated V (%zu MB) -> %s\n",(size_t)(cubeBytes>>20),dumpPath); }
        uint64_t bsum=g_batches.exchange(0,std::memory_order_relaxed); total+=bsum;
        /* fftshift + real -> cube, per-channel min/max; track the brightest channel */
        float gmax=-1e30f; int gmaxch=0;
        for(int ch=0;ch<NCUBE;++ch){ const cufftComplex* hc=h+(size_t)ch*NG*NG; float* oc=out->img+(size_t)ch*NG*NG;
            float vmax=-1e30f,vmin=1e30f;
            for(int y=0;y<NG;y++)for(int x=0;x<NG;x++){ float v=hc[((y+NG/2)%NG)*NG+((x+NG/2)%NG)].x;
                oc[y*NG+x]=v; vmax=v>vmax?v:vmax; vmin=v<vmin?v:vmin; }
            out->vmax[ch]=vmax; out->vmin[ch]=vmin; if(vmax>gmax){gmax=vmax;gmaxch=ch;} }
        __atomic_store_n(&out->write_seq,(uint64_t)frame+1,__ATOMIC_RELEASE);
        if(frame%(uint32_t)fps==0) fprintf(stderr,"[corr] frame %u snaps=%lu peak-ch=%d vmax=%.3g imissed=%lu misalign=%lu\n",
            frame,(unsigned long)bsum,gmaxch,gmax,(unsigned long)g_imissed.load(),(unsigned long)g_misalign.load());
        frame++; }
    g_stop=1; g_cv_fill.notify_all(); g_cv_free.notify_all();
    if(drain.joinable())drain.join(); if(gpu.joinable())gpu.join();
    fprintf(stderr,"[corr] stop after %u frames; V-updates=%lu imissed=%lu misalign=%lu\n",frame,(unsigned long)total,(unsigned long)g_imissed.load(),(unsigned long)g_misalign.load());
    if(dumpf){fclose(dumpf); free(hVcube);}
    if(g_mr_base)cudaHostUnregister((void*)g_mr_base); munmap(out,sizeof(Corr32)); shm_unlink(CORR_SHM);
    daqiri::print_stats(); daqiri::shutdown(); return 0;
}
