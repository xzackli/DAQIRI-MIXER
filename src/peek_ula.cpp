/* peek_ula.cpp — live viewer for /dev/shm/corr_ula, the (NCHAN x NBEAM) freq-vs-angle ULA image
 * published by rx_ula_corr. Each frame: finds the peak beam at the band-center channel, converts to
 * angle (sin(theta) = 2*(k - NBEAM/2)/NBEAM), and draws an ASCII beam pattern so a moving source shows
 * up as a '#' sweeping across the angle axis. Build: g++ -O2 src/peek_ula.cpp -o peek_ula -lrt */
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#define NCHAN 256
#define NBEAM 64
#define FCEN  128                       /* band-center channel: beam bin maps directly to sin(theta) */
struct CorrULA{ uint32_t magic,nchan,nbeam; volatile uint64_t write_seq; float img[NCHAN*NBEAM]; float vmax,vmin; };

int main(int argc,char**argv){
    int fd=shm_open("/corr_ula",O_RDONLY,0); if(fd<0){perror("shm_open /corr_ula (is rx_ula_corr running?)");return 1;}
    void* p=mmap(0,sizeof(CorrULA),PROT_READ,MAP_SHARED,fd,0); close(fd);
    if(p==MAP_FAILED){perror("mmap");return 1;}
    CorrULA* c=(CorrULA*)p; uint64_t last=0; int frames=0, maxframes=(argc>1)?atoi(argv[1]):0;
    printf("peek_ula: angle axis -%d..+%d deg across %d beams; '#'=source. Ctrl-C to stop.\n",90,90,NBEAM);
    while(1){
        uint64_t s=__atomic_load_n(&c->write_seq,__ATOMIC_ACQUIRE);
        if(s==last){ usleep(20000); continue; } last=s;
        const float* row=c->img+(size_t)FCEN*NBEAM; int kp=0; float mx=-1e30f,mn=1e30f;
        for(int k=0;k<NBEAM;++k){ if(row[k]>mx){mx=row[k];kp=k;} if(row[k]<mn)mn=row[k]; }
        float sn=2.f*(kp-NBEAM/2)/(float)NBEAM; if(sn<-1)sn=-1; if(sn>1)sn=1;
        float th=asinf(sn)*180.f/(float)M_PI;
        /* global peak over ALL channels (where the source actually is) */
        int gc=0,gk=0; float gmx=-1e30f;
        for(int cc=0;cc<NCHAN;++cc)for(int kk=0;kk<NBEAM;++kk){ float v=c->img[(size_t)cc*NBEAM+kk]; if(v>gmx){gmx=v;gc=cc;gk=kk;} }
        float gsn=2.f*(gk-NBEAM/2)/(float)NBEAM; if(gsn<-1)gsn=-1; if(gsn>1)gsn=1; float gth=asinf(gsn)*180.f/(float)M_PI;
        char bar[NBEAM+1]; float rng=(mx-mn)>1e-6f?(mx-mn):1.f;
        for(int k=0;k<NBEAM;++k){ float v=(row[k]-mn)/rng; bar[k]= v>0.66f?'#': v>0.33f?'+':' '; } bar[NBEAM]=0;
        printf("\rframe %5lu  gpeak ch%3d ang %+6.1f (bandctr %+6.1f) vmax%.1e [%s]",(unsigned long)s,gc,gth,th,gmx,bar); fflush(stdout);
        if(maxframes && ++frames>=maxframes) break;
    }
    printf("\n"); munmap(p,sizeof(CorrULA)); return 0;
}
