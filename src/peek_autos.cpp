/* peek_autos.cpp — LIVE four-element AUTO-spectra debug view for /dev/shm/corr_autos, published by
 * rx_feng4el_corr (the diagonal of V: sum|X_a|^2 per channel for each element). NO beamforming, NO
 * cross-correlation -- just each element's raw power spectrum, so you can see which input carries
 * signal and at which channel. Inject a tone and it shows up as a bright vertical line.
 * feng4el_gate emits natural channel order (wire channel == FFT bin). Set
 * PEEK_AUTOS_LEGACY_PERMUTE=1 only for old stock-feng4el captures that still need bin_from_wire().
 *
 * PIXEL rendering: a true-color (24-bit ANSI) raster using upper-half-block glyphs (U+2580) so each
 * character cell packs TWO vertically-stacked pixels -> a real colormapped image in the terminal, not
 * an ASCII ramp. Frequency runs left->right (256 channels binned to W columns, max-pooled so a narrow
 * tone survives); each element is a horizontal band BAND px tall; color = power (inferno colormap) on
 * a shared scale so a driven element glows and noise stays dark.
 *
 * Needs a truecolor terminal (most modern ones; $COLORTERM=truecolor). Redraws in place on each frame.
 * usage: peek_autos [maxframes]     build: g++ -O2 src/peek_autos.cpp -o peek_autos -lrt
 */
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <csignal>
#include <algorithm>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define NELEM 4
#define NCHAN 256
#define W     128                 /* freq columns (NCHAN/W = 2 channels/column, max-pooled) */
#define BAND  8                   /* pixel rows per element band                            */
#define IMGH  (NELEM*BAND)        /* total pixel rows (must be even for half-blocks)        */

struct AutoView{ uint32_t magic,nelem,nchan; volatile uint64_t write_seq; float autos[NELEM*NCHAN]; float vmax,vmin; };
static volatile sig_atomic_t g_stop=0; static void on_sig(int){ g_stop=1; }

/* inferno-style colormap: t in [0,1] -> (r,g,b). dark=low power, bright/white=high. */
static void cmap(float t,int&R,int&G,int&B){
    if(t<0)t=0; if(t>1)t=1;
    static const float S[7][4]={{0.00f,0,0,4},{0.15f,40,11,84},{0.30f,101,21,110},
        {0.50f,159,42,99},{0.70f,212,72,66},{0.85f,245,125,21},{1.00f,252,255,164}};
    for(int i=0;i<6;++i){ if(t<=S[i+1][0]){ float f=(t-S[i][0])/(S[i+1][0]-S[i][0]);
        R=(int)(S[i][1]+f*(S[i+1][1]-S[i][1])); G=(int)(S[i][2]+f*(S[i+1][2]-S[i][2]));
        B=(int)(S[i][3]+f*(S[i+1][3]-S[i][3])); return; } }
    R=252;G=255;B=164;
}

/* Natural feng4el_gate channel order: wire channel == true FFT bin.
 * true frequency = DF_MHZ * bin. fabric 1966.08 MSPS, 512-pt real FFT -> Df=3.84 MHz,
 * Nyquist 983 MHz, no aliasing, no NCO offset.
 *
 * Legacy stock-feng4el captures used a scrambled wire order; bin_from_wire() inverts that old
 * base-4 digit rotation + LSByte-first word reversal when PEEK_AUTOS_LEGACY_PERMUTE=1. */
#define DF_MHZ 3.84f
static int bin_from_wire(int k){
    int Wd=k>>5, r=31-(k&31), c=r>>2, q=r&3;
    int s=8*((Wd+1)%8)+c;
    int t=(s-7+64)%64;
    int a2=t>>4, a1=(t>>2)&3, a0=t&3;
    int m=16*a0+4*a2+a1;
    return 4*m+q;
}

int main(int argc,char**argv){
    int maxframes=(argc>1)?atoi(argv[1]):0;
    std::signal(SIGINT,on_sig); std::signal(SIGTERM,on_sig);
    int fd=shm_open("/corr_autos",O_RDONLY,0);
    if(fd<0){ perror("shm_open /corr_autos (is rx_feng4el_corr running?)"); return 1; }
    void* p=mmap(nullptr,sizeof(AutoView),PROT_READ,MAP_SHARED,fd,0); close(fd);
    if(p==MAP_FAILED){ perror("mmap"); return 1; }
    AutoView* a=(AutoView*)p;
    if(a->magic!=0x4155544f){ printf("not a corr_autos shm (magic %08x)\n",a->magic); return 2; }
    const bool legacy_permute = std::getenv("PEEK_AUTOS_LEGACY_PERMUTE") &&
                                std::getenv("PEEK_AUTOS_LEGACY_PERMUTE")[0]=='1';

    const int BIN=NCHAN/W;
    uint64_t last=0; int frames=0;
    printf("\033[2J");

    while(!g_stop){
        uint64_t s=__atomic_load_n(&a->write_seq,__ATOMIC_ACQUIRE);
        if(s==last){ usleep(20000); continue; } last=s;

        /* per-element, per-column max-pooled power -> color value t[e][c] on a shared dB scale.
         * dB relative to the frame's peak over a DRANGE_DB window: the tone sits at t=1 (bright) while
         * the noise floor (~-20..-30 dB below a strong tone) still shows as mid-color, so the whole
         * spectrum shape is visible -- not just the single brightest channel. */
        static float t[NELEM][W]; int pkch[NELEM]; float pkv[NELEM], med[NELEM];
        const float RANGE_DB=45.f; float ref=(a->vmax>0)?a->vmax:1.f;
        static float sp_true[NELEM][NCHAN];
        for(int e=0;e<NELEM;++e){
            /* default: natural gate order. Legacy mode remaps old scrambled wire-order autos. */
            for(int c=0;c<NCHAN;++c){
                int bin = legacy_permute ? bin_from_wire(c) : c;
                sp_true[e][bin]=a->autos[(size_t)e*NCHAN+c];
            }
            const float* sp=sp_true[e]; float emax=-1e30f; int epk=0;
            for(int c=0;c<W;++c){ float m=-1e30f; for(int j=0;j<BIN;++j){ float v=sp[c*BIN+j]; if(v>m)m=v; }
                float tv=(m>0)?1.f+(10.f*log10f(m/ref))/RANGE_DB:0.f;
                if(tv<0)tv=0; if(tv>1)tv=1; t[e][c]=tv; }
            for(int ch=0;ch<NCHAN;++ch){ if(sp[ch]>emax){ emax=sp[ch]; epk=ch; } }
            std::vector<float> nz; for(int ch=0;ch<NCHAN;++ch) if(sp[ch]>0) nz.push_back(sp[ch]);
            float md=0.f; if(!nz.empty()){ std::nth_element(nz.begin(),nz.begin()+nz.size()/2,nz.end()); md=nz[nz.size()/2]; }
            pkch[e]=epk; pkv[e]=emax; med[e]=md;
        }

        printf("\033[H");
        printf("feng4el AUTO-spectra (pixel)  seq=%-6lu   FREQ MHz -->   %s order  Df=%.2fMHz  inferno=power  %.0fdB\033[K\n",
               (unsigned long)s, legacy_permute ? "legacy-permuted" : "natural", DF_MHZ, RANGE_DB);
        /* half-block raster: each text row = 2 pixel rows (top=fg, bottom=bg); element = pixelrow/BAND */
        for(int cr=0; cr<IMGH/2; ++cr){
            int etop=(2*cr)/BAND, ebot=(2*cr+1)/BAND;
            /* left gutter label at each band's middle text-row */
            int bandmid = etop*(BAND/2) + (BAND/4);
            if(cr==bandmid) printf("elem%d ", etop); else printf("      ");
            for(int c=0;c<W;++c){
                int rt,gt,bt,rb,gb,bb;
                cmap(t[etop][c],rt,gt,bt); cmap(t[ebot][c],rb,gb,bb);
                printf("\033[38;2;%d;%d;%dm\033[48;2;%d;%d;%dm\xe2\x96\x80",rt,gt,bt,rb,gb,bb);
            }
            printf("\033[0m\033[K\n");
        }
        /* frequency axis (MHz): column c holds true bins, freq = bin*DF_MHZ */
        printf("      ");
        char ruler[W+1]; for(int i=0;i<W;++i) ruler[i]=' '; ruler[W]=0;
        for(int fmhz=0; fmhz<=960; fmhz+=160){ int col=(int)(fmhz/(DF_MHZ*BIN)); if(col>W-1)col=W-1;
            char lab[8]; int n=snprintf(lab,sizeof(lab),"%d",fmhz);
            for(int i=0;i<n&&col+i<W;++i) ruler[col+i]=lab[i]; }
        printf("%s  (MHz)\033[K\n", ruler);
        printf("peaks:");
        for(int e=0;e<NELEM;++e){ float r=(med[e]>0)?pkv[e]/med[e]:0.f;
            printf("  e%d %6.1fMHz %.1e(%.0fx)", e, DF_MHZ*pkch[e], pkv[e], r); }
        printf("\033[K\n");
        fflush(stdout);
        if(maxframes && ++frames>=maxframes) break;
    }
    printf("\033[0m\n"); munmap(p,sizeof(AutoView)); return 0;
}
