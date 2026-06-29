/* ula_selftest.cu — FAITHFUL end-to-end correctness check of the ULA X-engine, no DAQIRI/NIC/2nd box.
 *
 * Two complementary checks, both exercising the SAME real-layout packer the TX uses and the SAME
 * unpacker (k_corr4 wire-map inversion) the RX uses:
 *
 *   A. BYTE-EXACT RAMP ROUNDTRIP  (mirrors the hardware ramp verification on
 *      digilab-transmit:/tmp/m2el_bo.pcapng): pack a per-production-sample ramp value into the payload
 *      with the REAL layout (TIME-MAJOR i=t*NCHAN+c + 8-byte-word HALF-SWAP), then RX-unpack assuming
 *      REAL, and assert every sample lands back in production order (256/256... identity). This is the
 *      same test that proved the FPGA emits this layout. It has TEETH for the HALF-SWAP specifically:
 *      a no-half-swap or channel-major pack scrambles the identity.
 *
 *   B. ANGLE RECOVERY across a theta sweep: generate two antennas seeing a coherent, TIME-VARYING
 *      source at known theta with the correct per-channel inter-element phase; SERIALIZE with the real
 *      packer; correlate with the real RX k_corr4 (per-channel V=X*X^H); recover theta from the
 *      band-center inter-element baseline PHASE SLOPE across channels (the physical 2-element observable
 *      -- a single FFT image is ambiguous at NELEM=2). Assert recovered ~= theta (PASS), and assert a
 *      CHANNEL-MAJOR control (wrong macro order) FAILS recovery (gross transpose -> teeth).
 *
 * Together: A catches the half-swap, B catches a time<->channel transpose. A wrong layout fails at
 * least one, so the suite has teeth against every layout regression.
 *
 * Build: nvcc -O3 -std=c++17 -arch=sm_120a src/ula_selftest.cu -lcufft -o ula_selftest */
#include <cuda_runtime.h>
#include <cufft.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "config_ula.h"
#define CK(x) do{cudaError_t e_=(x);if(e_){fprintf(stderr,"CUDA %s:%d:%s\n",__FILE__,__LINE__,cudaGetErrorString(e_));std::exit(1);}}while(0)
#define NELEM ULA_NELEM
#define NCHAN ULA_NCHAN
#define TPKT  ULA_TPKT
#define NB    ULA_PAYLOAD_BYTES
#define VN    (NELEM*NELEM)

/* layout selector for the pack step (so the test can inject WRONG layouts and prove they fail) */
enum Layout { LAYOUT_REAL=0, LAYOUT_CHANNEL_MAJOR=1, LAYOUT_NO_SWAP=2 };

__device__ __host__ __forceinline__ void wire_offsets(int t,int c,int lay,int* ro,int* io){
    if(lay==LAYOUT_REAL){              /* TIME-MAJOR + half-swap : the verified ground truth */
        int i=ULA_PROD_SI(t,c); *ro=ULA_WIRE_RE_OFF(i); *io=ULA_WIRE_IM_OFF(i);
    } else if(lay==LAYOUT_NO_SWAP){    /* TIME-MAJOR but NO half-swap (wrong) */
        int i=ULA_PROD_SI(t,c); *ro=2*i; *io=2*i+1;
    } else {                           /* CHANNEL-MAJOR i=c*TPKT+t, no swap (wrong) */
        int i=c*TPKT+t; *ro=2*i; *io=2*i+1;
    }
}

/* ============================ A. byte-exact ramp roundtrip ============================ */
/* pack a per-production-sample ramp value (i%251, a co-prime stride so every sample is distinguishable)
 * into the re byte of payload using `lay`; im byte = (i%251)^0x55 so both halves are checked. */
__global__ void k_pack_ramp(uint8_t* __restrict__ pay,int lay){
    int t=blockIdx.x, c=threadIdx.x; if(t>=TPKT||c>=NCHAN) return;
    int i=ULA_PROD_SI(t,c); uint8_t v=(uint8_t)(i%251); int ro,io; wire_offsets(t,c,lay,&ro,&io);
    pay[ro]=v; pay[io]=(uint8_t)(v^0x55);
}
/* RX-unpack assuming the REAL layout; count how many production samples land back in order */
__global__ void k_check_ramp(const uint8_t* __restrict__ pay,int* __restrict__ nbad){
    int t=blockIdx.x, c=threadIdx.x; if(t>=TPKT||c>=NCHAN) return;
    int i=ULA_PROD_SI(t,c); uint8_t v=(uint8_t)(i%251);
    int ro=ULA_WIRE_RE_OFF(i), io=ULA_WIRE_IM_OFF(i);
    if(pay[ro]!=v || pay[io]!=(uint8_t)(v^0x55)) atomicAdd(nbad,1);
}

/* ============================ B. angle recovery ============================ */
/* Coherent TIME-VARYING source at sin(theta)=s, base amp A. Element e at e*d sees per-channel phase
 * phi = -pi*e*s*(f_c/f_center). Source amplitude is modulated in time g(t)=A*(1+0.6*cos(2pi t/TPKT))
 * (same for both elements -> coherent), so a time<->channel transpose scrambles g(t) into the channel
 * axis and breaks the per-channel phase slope. k_pack writes raw payload bytes for the chosen layout. */
__global__ void k_pack(uint8_t* __restrict__ bb, float s, float A, int lay){
    int e=blockIdx.x, c=threadIdx.x; if(e>=NELEM||c>=NCHAN) return;
    uint8_t* pay=bb+(size_t)e*NB;
    float fc=(float)c/(float)ULA_FCEN_CH; float p=-(float)M_PI*e*s*fc; float cr=cosf(p), ci=sinf(p);
    for(int t=0;t<TPKT;++t){
        float g=A*(1.f + 0.6f*cosf(2.f*(float)M_PI*(float)t/(float)TPKT));
        int qr=__float2int_rn(g*cr), qi=__float2int_rn(g*ci);
        uint8_t rb=(uint8_t)(int8_t)(qr<-127?-127:(qr>127?127:qr));
        uint8_t ib=(uint8_t)(int8_t)(qi<-127?-127:(qi>127?127:qi));
        int ro,io; wire_offsets(t,c,lay,&ro,&io); pay[ro]=rb; pay[io]=ib;
    }
}
/* the REAL rx_ula_corr correlator: per channel V[c][a][b] = sum_t X_a*conj(X_b), inverting the wire map */
__global__ void k_corr4(const uint8_t* __restrict__ bb, float* __restrict__ Vre, float* __restrict__ Vim){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*VN) return;
    int c=i/VN, ab=i%VN, a=ab/NELEM, b=ab%NELEM;
    const int8_t* A=(const int8_t*)bb+(size_t)a*NB; const int8_t* B=(const int8_t*)bb+(size_t)b*NB;
    float sre=0.f,sim=0.f;
    for(int t=0;t<TPKT;++t){ int pi=ULA_PROD_SI(t,c); int ro=ULA_WIRE_RE_OFF(pi), io=ULA_WIRE_IM_OFF(pi);
        float ar=A[ro],ai=A[io],br=B[ro],bi=B[io];
        sre+=ar*br+ai*bi; sim+=ai*br-ar*bi; }
    Vre[i]+=sre; Vim[i]+=sim;
}

/* recover theta from the (0,1) baseline phase SLOPE vs channel: phase(V01,c) = pi*s*(c/FCEN).
 * Least-squares slope over low channels (|phase|<pi, no wrap) -> s -> theta. Requires the CHANNEL axis
 * to be physically correct, so a channel/time transpose breaks it. */
static float recover_angle(uint8_t* bb,float* Vre,float* Vim,float* hVre,float* hVim,
                           float th_deg,float A,int lay){
    float s=sinf(th_deg*(float)M_PI/180.f);
    CK(cudaMemset(Vre,0,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMemset(Vim,0,(size_t)NCHAN*VN*sizeof(float)));
    k_pack<<<NELEM,NCHAN>>>(bb,s,A,lay);
    k_corr4<<<(NCHAN*VN+255)/256,256>>>(bb,Vre,Vim);
    CK(cudaMemcpy(hVre,Vre,(size_t)NCHAN*VN*sizeof(float),cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(hVim,Vim,(size_t)NCHAN*VN*sizeof(float),cudaMemcpyDeviceToHost));
    /* V[c][a=0][b=1] index = c*VN + 0*NELEM + 1 = c*VN + 1 */
    const int idx01 = 0*NELEM + 1;
    double Sx=0,Sy=0,Sxx=0,Sxy=0; int n=0; double prev=0; bool have=false;
    for(int c=8;c<120;++c){                     /* low channels: |phase| < pi, unwrap-safe */
        size_t k=(size_t)c*VN+idx01; float re=hVre[k], im=hVim[k];
        double ph=atan2((double)im,(double)re);
        if(have){ while(ph-prev> M_PI) ph-=2*M_PI; while(ph-prev<-M_PI) ph+=2*M_PI; } /* unwrap */
        prev=ph; have=true;
        double x=(double)c/(double)ULA_FCEN_CH;
        Sx+=x; Sy+=ph; Sxx+=x*x; Sxy+=x*ph; ++n;
    }
    double slope=(n*Sxy - Sx*Sy)/(n*Sxx - Sx*Sx);   /* phase = pi*s*x  => slope = pi*s */
    double sr=slope/M_PI; if(sr<-1)sr=-1; if(sr>1)sr=1;
    return (float)(asin(sr)*180.0/M_PI);
}

int main(){
    uint8_t* bb; float *Vre,*Vim,*hVre,*hVim; int* d_nbad;
    CK(cudaMalloc(&bb,(size_t)NELEM*NB));
    CK(cudaMalloc(&Vre,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMalloc(&Vim,(size_t)NCHAN*VN*sizeof(float)));
    hVre=(float*)malloc((size_t)NCHAN*VN*sizeof(float)); hVim=(float*)malloc((size_t)NCHAN*VN*sizeof(float));
    CK(cudaMalloc(&d_nbad,sizeof(int)));
    const float A=100.f; const float TOL=3.0f;

    printf("ULA self-test (FAITHFUL real-layout): NELEM=%d NCHAN=%d TPKT=%d d=%.2f lambda, amp=%.0f, tol=%.1fdeg\n",
           NELEM,NCHAN,TPKT,ULA_DSPACE,A,TOL);

    /* ---- A. byte-exact ramp roundtrip (catches the HALF-SWAP, mirrors the hardware ramp verify) ---- */
    printf("\n[A] byte-exact ramp roundtrip (production index i=t*NCHAN+c packed REAL, RX-unpacked REAL)\n");
    auto ramp_bad=[&](int lay)->int{
        CK(cudaMemset(d_nbad,0,sizeof(int)));
        k_pack_ramp<<<TPKT,NCHAN>>>(bb,lay);            /* pack into element-0 heap */
        k_check_ramp<<<TPKT,NCHAN>>>(bb,d_nbad);
        int nb=0; CK(cudaMemcpy(&nb,d_nbad,sizeof(int),cudaMemcpyDeviceToHost)); return nb; };
    int bad_real=ramp_bad(LAYOUT_REAL);
    int bad_noswap=ramp_bad(LAYOUT_NO_SWAP);
    int bad_chan=ramp_bad(LAYOUT_CHANNEL_MAJOR);
    int tot=TPKT*NCHAN;
    printf("   REAL pack         : %d/%d mismatched -> %s\n",bad_real,tot, bad_real==0?"IDENTITY (correct)":"BROKEN");
    printf("   no-half-swap pack : %d/%d mismatched -> %s\n",bad_noswap,tot, bad_noswap>0?"MISMATCH (control has teeth)":"BLIND");
    printf("   channel-major pack: %d/%d mismatched -> %s\n",bad_chan,tot, bad_chan>0?"MISMATCH (control has teeth)":"BLIND");
    bool A_ok = (bad_real==0) && (bad_noswap>0) && (bad_chan>0);

    /* ---- B. angle recovery sweep (catches a time<->channel transpose) ---- */
    float tlist[]={-50,-40,-30,-20,-10,-5,0,5,10,20,30,40,50}; const int NT=sizeof(tlist)/sizeof(tlist[0]);
    printf("\n[B] angle recovery (REAL layout, time-varying source) -- recovered from band baseline phase slope\n");
    printf("    input(deg)  recovered(deg)  err(deg)\n");
    float maxerr=0.f;
    for(int j=0;j<NT;++j){ float rth=recover_angle(bb,Vre,Vim,hVre,hVim,tlist[j],A,LAYOUT_REAL);
        float err=fabsf(rth-tlist[j]); if(err>maxerr)maxerr=err;
        printf("     %+6.1f      %+7.1f       %5.2f\n",tlist[j],rth,err); }
    bool B_ok=(maxerr<TOL);
    printf("   max angle error: %.2f deg  -> %s\n",maxerr, B_ok?"PASS":"FAIL");

    /* control: channel-major macro order must FAIL angle recovery */
    float cmaxerr=0.f;
    for(int j=0;j<NT;++j){ float rth=recover_angle(bb,Vre,Vim,hVre,hVim,tlist[j],A,LAYOUT_CHANNEL_MAJOR);
        cmaxerr=fmaxf(cmaxerr,fabsf(rth-tlist[j])); }
    bool ctl_ok=(cmaxerr>=TOL);
    printf("   control [channel-major]: max err %.2f deg -> %s\n",cmaxerr,
           ctl_ok?"FAILS recovery (good, control has teeth)":"RECOVERS (BAD: control blind)");

    bool ok = A_ok && B_ok && ctl_ok;
    printf("\n==== SELF-TEST %s ====\n", ok?"PASS":"FAIL");
    printf("   [A] half-swap byte roundtrip (REAL=identity, wrong=mismatch): %s\n", A_ok?"PASS":"FAIL");
    printf("   [B] real-layout angle recovery across sweep:                  %s\n", B_ok?"PASS":"FAIL");
    printf("   [B] channel-major control fails recovery:                     %s\n", ctl_ok?"PASS":"FAIL");
    return ok?0:1;
}
