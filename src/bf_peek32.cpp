/* bf_peek32.cpp — ascii view of ONE frequency channel of the correlator SPECTRAL CUBE (/bf_corr32).
 * usage: bf_peek32 [channel]   (default: the channel with the brightest planet).
 * Star sits at center (16,16); the planet is off-center and -- because the TX planet amplitude grows
 * with channel (Apl ~ sqrt(c)) -- gets brighter at higher channels. Layout mirrors Corr32 in
 * bf_rx_host_corr.cu: {magic,w,h,nch, write_seq} then img[nch*32*32], vmax[nch], vmin[nch]. */
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#define NG 32
struct Hdr { uint32_t magic, w, h, nch; volatile uint64_t write_seq; };  /* img/vmax/vmin follow */

int main(int argc, char** argv) {
    int want = argc > 1 ? atoi(argv[1]) : -1;          /* -1 = auto (brightest planet) */
    int fd = shm_open("/bf_corr32", O_RDONLY, 0);
    if (fd < 0) { perror("shm_open"); return 1; }
    struct stat st; if (fstat(fd, &st) != 0) { perror("fstat"); return 1; }
    void* p = mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0); close(fd);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    Hdr* hd = (Hdr*)p;
    if (hd->magic != 0x43523343) { printf("not a spectral-cube shm (magic %08x)\n", hd->magic); return 2; }
    uint64_t ws = __atomic_load_n(&hd->write_seq, __ATOMIC_ACQUIRE);
    if (ws == 0) { printf("no frames yet\n"); return 2; }
    int nch = (int)hd->nch, npix = NG * NG;
    const float* img  = (const float*)((const char*)p + sizeof(Hdr));
    const float* vmax = img + (size_t)nch * npix;
    const float* vmin = vmax + nch;
    int ch = want;
    if (ch < 0) {                                      /* auto: channel with the brightest off-center pixel */
        float best = -1e30f; ch = nch - 1;
        for (int c = 0; c < nch; c++) {
            const float* im = img + (size_t)c * npix; float o = -1e30f;
            for (int y = 0; y < NG; y++) for (int x = 0; x < NG; x++) {
                int dx = x - 16, dy = y - 16; if ((dx*dx + dy*dy) > 4) { float v = im[y*NG+x]; if (v > o) o = v; } }
            if (o > best) { best = o; ch = c; }
        }
    }
    if (ch >= nch) ch = nch - 1; if (ch < 0) ch = 0;
    const float* im = img + (size_t)ch * npix; float vx = vmax[ch], vn = vmin[ch];
    printf("corr cube seq=%lu  channel %d/%d  vmax=%.3g vmin=%.3g  [32x32 alias-free]\n",
           (unsigned long)ws, ch, nch, vx, vn);
    const char* lut = " .:-=+*#%@";
    int pkx = 0, pky = 0; float pk = -1e30f;
    int ox = -1, oy = -1; float opk = -1e30f;
    for (int y = 0; y < NG; y++) for (int x = 0; x < NG; x++) {
        float v = im[y*NG+x];
        if (v > pk) { pk = v; pkx = x; pky = y; }
        int dx = x - 16, dy = y - 16;
        if ((dx*dx + dy*dy) > 4 && v > opk) { opk = v; ox = x; oy = y; }
    }
    for (int y = 0; y < NG; y++) {
        for (int x = 0; x < NG; x++) {
            float v = im[y*NG+x];
            float n = (vx > vn) ? (v - vn) / (vx - vn) : 0.f;
            int li = (int)(n * 9.f); if (li < 0) li = 0; if (li > 9) li = 9;
            printf("%c%c", lut[li], lut[li]);
        }
        printf("\n");
    }
    printf("star peak (x=%d,y=%d) val=%.3g  [center=(16,16)]\n", pkx, pky, pk);
    printf("planet    (x=%d,y=%d) val=%.3g  (%.1f%% of star)\n", ox, oy, opk, 100.0*opk/pk);
    return 0;
}
