/* ula_selftest.cu — standalone correctness check of the 4-element ULA X-engine MATH, no DAQIRI/NIC/2nd box.
 * Generates a source at a known angle with the TX sky law, runs it through the REAL rx kernels
 * (k_corr4 -> grid V excl Delta=0 -> 1-D cuFFT -> publish), finds the peak beam at band-center,
 * recovers the angle (sinθ = 2(k-NBEAM/2)/NBEAM), and reports error across a θ sweep.
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
#define NBEAM ULA_NBEAM
#define NB    ULA_PAYLOAD_BYTES
#define SAMP  (NB/2)
#define VN    (NELEM*NELEM)

/* single source at sin(theta)=s, amp A -> channelized int8 heaps bb[NELEM][NB] (same law as tx_ula) */
__global__ void k_sky1(uint8_t* __restrict__ bb, float s, float A){
    int e=blockIdx.x, c=threadIdx.x; if(e>=NELEM||c>=NCHAN) return;
    uint8_t* pay=bb+(size_t)e*NB; float fc=(float)c/(float)ULA_FCEN_CH; float p=-(float)M_PI*e*s*fc;
    int qr=__float2int_rn(A*cosf(p)), qi=__float2int_rn(A*sinf(p));
    uint8_t rb=(uint8_t)(int8_t)(qr<-127?-127:(qr>127?127:qr)), ib=(uint8_t)(int8_t)(qi<-127?-127:(qi>127?127:qi));
    for(int t=0;t<TPKT;++t){ int sl=c*TPKT+t; pay[2*sl]=rb; pay[2*sl+1]=ib; }   /* INTERLEAVED re,im */
}
/* --- the real rx_ula_corr kernels (copied verbatim) --- */
__global__ void k_corr4(const uint8_t* __restrict__ bb, float* __restrict__ Vre, float* __restrict__ Vim){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*VN) return;
    int c=i/VN, ab=i%VN, a=ab/NELEM, b=ab%NELEM;
    const int8_t* A=(const int8_t*)bb+(size_t)a*NB; const int8_t* B=(const int8_t*)bb+(size_t)b*NB;
    float sre=0.f,sim=0.f;
    for(int t=0;t<TPKT;++t){ int sl=c*TPKT+t; float ar=A[2*sl],ai=A[2*sl+1],br=B[2*sl],bi=B[2*sl+1];
        sre+=ar*br+ai*bi; sim+=ai*br-ar*bi; }
    Vre[i]+=sre; Vim[i]+=sim;
}
__global__ void k_grid1d(const float* __restrict__ Vr,const float* __restrict__ Vi,cufftComplex* __restrict__ G){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*VN) return;
    int c=i/VN, ab=i%VN, a=ab/NELEM, b=ab%NELEM; if(a==b) return;
    int d=((b-a)&(NBEAM-1)); atomicAdd(&G[(size_t)c*NBEAM+d].x,Vr[i]); atomicAdd(&G[(size_t)c*NBEAM+d].y,Vi[i]);
}
__global__ void k_publish(const cufftComplex* __restrict__ Img,float* __restrict__ img){
    int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=NCHAN*NBEAM) return;
    int c=i/NBEAM,k=i%NBEAM,ks=(k+NBEAM/2)&(NBEAM-1); cufftComplex v=Img[(size_t)c*NBEAM+ks]; img[i]=v.x*v.x+v.y*v.y;
}

int main(){
    uint8_t* bb; float *Vre,*Vim,*d_img,*h_img; cufftComplex *G,*Img;
    CK(cudaMalloc(&bb,(size_t)NELEM*NB));
    CK(cudaMalloc(&Vre,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMalloc(&Vim,(size_t)NCHAN*VN*sizeof(float)));
    CK(cudaMalloc(&G,(size_t)NCHAN*NBEAM*sizeof(cufftComplex))); CK(cudaMalloc(&Img,(size_t)NCHAN*NBEAM*sizeof(cufftComplex)));
    CK(cudaMalloc(&d_img,(size_t)NCHAN*NBEAM*sizeof(float))); h_img=(float*)malloc((size_t)NCHAN*NBEAM*sizeof(float));
    cufftHandle plan; int n1[1]={NBEAM}; cufftPlanMany(&plan,1,n1,NULL,1,NBEAM,NULL,1,NBEAM,CUFFT_C2C,NCHAN);
    const float A=100.f; float tlist[]={-50,-40,-30,-20,-10,0,10,20,30,40}; float maxerr=0.f;
    printf("ULA self-test: NELEM=%d NCHAN=%d NBEAM=%d d=%.2f lambda, amp=%.0f\n",NELEM,NCHAN,NBEAM,ULA_DSPACE,A);
    printf("  input(deg)  recovered(deg)  err(deg)\n");
    for(float th: tlist){ float s=sinf(th*(float)M_PI/180.f);
        CK(cudaMemset(Vre,0,(size_t)NCHAN*VN*sizeof(float))); CK(cudaMemset(Vim,0,(size_t)NCHAN*VN*sizeof(float)));
        k_sky1<<<NELEM,NCHAN>>>(bb,s,A);
        k_corr4<<<(NCHAN*VN+255)/256,256>>>(bb,Vre,Vim);
        CK(cudaMemset(G,0,(size_t)NCHAN*NBEAM*sizeof(cufftComplex)));
        k_grid1d<<<(NCHAN*VN+255)/256,256>>>(Vre,Vim,G);
        cufftExecC2C(plan,G,Img,CUFFT_FORWARD);
        k_publish<<<(NCHAN*NBEAM+255)/256,256>>>(Img,d_img);
        CK(cudaMemcpy(h_img,d_img,(size_t)NCHAN*NBEAM*sizeof(float),cudaMemcpyDeviceToHost));
        const float* row=h_img+(size_t)ULA_FCEN_CH*NBEAM; int kpk=0; float mx=-1e30f;   /* band-center channel */
        for(int k=0;k<NBEAM;++k) if(row[k]>mx){mx=row[k];kpk=k;}
        float rs=2.f*(kpk-NBEAM/2)/(float)NBEAM; float rth=asinf(fmaxf(-1.f,fminf(1.f,rs)))*180.f/(float)M_PI;
        float err=fabsf(rth-th); if(err>maxerr)maxerr=err;
        printf("   %+6.1f      %+7.1f       %5.2f\n",th,rth,err); }
    printf("max angle error: %.2f deg  -> %s\n",maxerr, maxerr<3.0f?"PASS":"CHECK");
    return 0;
}
