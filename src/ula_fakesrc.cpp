/* ula_fakesrc.cpp — write a synthetic moving-source (NCHAN x NBEAM) image to /dev/shm/corr_ula so
 * peek_ula_img / peek_ula can be demoed WITHOUT the board streaming. A point source sweeps in angle
 * (a slow sinusoid) inside a band of channels, with a soft main lobe + noise floor. NOT science -- a
 * viewer test fixture only. usage: ula_fakesrc [frames] [fps]   build: g++ -O2 src/ula_fakesrc.cpp -o ula_fakesrc -lrt
 */
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <csignal>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#define NCHAN 256
#define NBEAM 64
struct CorrULA { uint32_t magic, nchan, nbeam; volatile uint64_t write_seq; float img[NCHAN*NBEAM]; float vmax, vmin; };
struct AutoView { uint32_t magic, nelem, nchan; volatile uint64_t write_seq; float autos[4*NCHAN]; float vmax, vmin; };
static volatile sig_atomic_t g_stop = 0; static void on_sig(int){ g_stop = 1; }

static AutoView* auto_open() {
    shm_unlink("/corr_autos");
    int fd = shm_open("/corr_autos", O_CREAT|O_RDWR, 0666);
    if (fd < 0) { perror("shm_open autos"); return nullptr; }
    if (ftruncate(fd, sizeof(AutoView))) { perror("ftruncate autos"); return nullptr; }
    void* p = mmap(nullptr, sizeof(AutoView), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0); close(fd);
    if (p == MAP_FAILED) { perror("mmap autos"); return nullptr; }
    AutoView* a = (AutoView*)p; std::memset(a, 0, sizeof(AutoView));
    a->magic = 0x4155544f; a->nelem = 4; a->nchan = NCHAN; return a;
}

int main(int argc, char** argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 0; float fps = argc > 2 ? atof(argv[2]) : 15.f;
    std::signal(SIGINT, on_sig); std::signal(SIGTERM, on_sig);
    shm_unlink("/corr_ula");
    int fd = shm_open("/corr_ula", O_CREAT|O_RDWR, 0666);
    if (fd < 0) { perror("shm_open"); return 1; }
    if (ftruncate(fd, sizeof(CorrULA))) { perror("ftruncate"); return 1; }
    void* p = mmap(nullptr, sizeof(CorrULA), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0); close(fd);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    CorrULA* c = (CorrULA*)p; std::memset(c, 0, sizeof(CorrULA));
    c->magic = 0x554c4131; c->nchan = NCHAN; c->nbeam = NBEAM;
    AutoView* aout = auto_open();   /* also feed the 4-auto debug view (/corr_autos) */
    fprintf(stderr, "ula_fakesrc: writing /corr_ula (%dx%d) + /corr_autos @ %.0f Hz\n", NCHAN, NBEAM, fps);

    for (uint64_t f = 0; !g_stop && (frames == 0 || (int)f < frames); ++f) {
        float t = f / fps;
        float sn = 0.8f * sinf(0.6f * t);                 /* source direction sweeps in sin(theta)  */
        float k0 = NBEAM/2 + sn * (NBEAM/2);              /* main-lobe beam bin                       */
        float vx = -1e30f, vn = 1e30f;
        for (int ch = 0; ch < NCHAN; ++ch) {
            float band = expf(-0.5f * powf((ch - 150) / 40.f, 2.f));   /* source lives in a channel band */
            for (int k = 0; k < NBEAM; ++k) {
                float lobe = expf(-0.5f * powf((k - k0) / 3.0f, 2.f)); /* ULA main lobe ~few bins wide  */
                float noise = 0.02f * ((ch*131 + k*977 + (int)f*17) % 100) / 100.f;
                float v = 1.0e6f * (band * lobe + noise);
                c->img[(size_t)ch*NBEAM + k] = v;
                if (v > vx) vx = v; if (v < vn) vn = v;
            }
        }
        c->vmax = vx; c->vmin = vn;
        __atomic_store_n(&c->write_seq, f + 1, __ATOMIC_RELEASE);

        if (aout) {                                   /* 4 auto-spectra: e1,e2 driven with a drifting tone */
            float amx = -1e30f, amn = 1e30f;
            int tch = (int)(128 + 40 * sinf(0.3f * t));
            for (int e = 0; e < 4; ++e) {
                bool driven = (e == 1 || e == 2);
                for (int ch = 0; ch < NCHAN; ++ch) {
                    float noise = 1.0e4f * (0.5f + ((ch*53 + e*911 + (int)f*7) % 100) / 100.f);
                    float tone  = driven ? 1.0e6f * expf(-0.5f * powf((ch - tch) / 2.0f, 2.f)) : 0.f;
                    float v = tone + noise; aout->autos[e*NCHAN + ch] = v;
                    if (v > amx) amx = v; if (v < amn) amn = v;
                }
            }
            aout->vmax = amx; aout->vmin = amn;
            __atomic_store_n(&aout->write_seq, f + 1, __ATOMIC_RELEASE);
        }
        usleep((useconds_t)(1e6f / fps));
    }
    munmap(p, sizeof(CorrULA));
    fprintf(stderr, "\nula_fakesrc: done\n");
    return 0;
}
