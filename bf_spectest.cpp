/* bf_spectest.cpp — validate the live spectral cube (/bf_corr32) from ONE frame (same instant,
 * so cross-channel ratios are clean): per-channel star-at-center + planet%, the spectral trend
 * (planet should rise ~linearly with channel), and SUM-over-all-channels == the broadband image. */
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <vector>
#define NG 32
struct Hdr { uint32_t magic, w, h, nch; volatile uint64_t write_seq; };

static void analyze(const float* im, int& pkx, int& pky, float& pk, int& ox, int& oy, float& opk) {
    pk = -1e30f; opk = -1e30f; pkx = pky = 0; ox = oy = -1;
    for (int y = 0; y < NG; y++) for (int x = 0; x < NG; x++) {
        float v = im[y*NG+x];
        if (v > pk) { pk = v; pkx = x; pky = y; }
        int dx = x - 16, dy = y - 16;
        if ((dx*dx + dy*dy) > 4 && v > opk) { opk = v; ox = x; oy = y; }
    }
}
int main() {
    int fd = shm_open("/bf_corr32", O_RDONLY, 0); if (fd < 0) { perror("shm_open"); return 1; }
    struct stat st; if (fstat(fd, &st) != 0) { perror("fstat"); return 1; }
    void* base = mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0); close(fd);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }
    Hdr* hd = (Hdr*)base; if (hd->magic != 0x43523343) { printf("bad magic %08x\n", hd->magic); return 2; }
    uint64_t ws = __atomic_load_n(&hd->write_seq, __ATOMIC_ACQUIRE);
    if (ws == 0) { printf("no frames yet\n"); return 2; }
    int nch = (int)hd->nch, npix = NG*NG;
    const float* img = (const float*)((const char*)base + sizeof(Hdr));
    printf("=== spectral cube validation (frame seq=%lu, %d channels) ===\n", (unsigned long)ws, nch);
    int a,b,c2,d; float pk,opk;
    analyze(img + (size_t)127*npix, a,b,pk,c2,d,opk); float p127 = 100*opk/pk;
    printf("%4s  %-11s  %-12s  %8s  %s\n", "ch", "star@(x,y)", "planet@(x,y)", "planet%", "ratio (vs c/127)");
    int chs[] = {0,8,16,32,48,64,96,112,127};
    for (int ch : chs) { if (ch >= nch) continue;
        const float* im = img + (size_t)ch*npix; int pkx,pky,ox,oy; float p,o; analyze(im,pkx,pky,p,ox,oy,o);
        float pct = 100*o/p;
        printf("%4d  (%2d,%2d)%s     (%2d,%2d)        %7.1f%%  %.3f  (c/127=%.3f)\n",
               ch, pkx, pky, (pkx==16&&pky==16)?" ctr":"  !!", ox, oy, pct, pct/p127, ch/127.0);
    }
    std::vector<float> sum(npix, 0.f);
    for (int ch = 0; ch < nch; ch++) { const float* im = img + (size_t)ch*npix; for (int i = 0; i < npix; i++) sum[i] += im[i]; }
    int pkx,pky,ox,oy; float p,o; analyze(sum.data(),pkx,pky,p,ox,oy,o);
    printf("SUM of all %d channels: star@(%d,%d)%s planet@(%d,%d) = %.1f%% of star  (== broadband image)\n",
           nch, pkx, pky, (pkx==16&&pky==16)?" [centered]":" [!! not centered]", ox, oy, 100*o/p);
    return 0;
}
