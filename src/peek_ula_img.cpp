/* peek_ula_img.cpp — LIVE freq-vs-angle heatmap viewer for /dev/shm/corr_ula, the (NCHAN x NBEAM)
 * beamformed image published by the feng4el 4-element ULA X-engine (rx_feng4el_corr) or the older
 * rx_ula_corr. This is the 2-D analog of peek32 (the 32x32 sky viewer for the 256-element array):
 * instead of a sky image it draws the ULA's angular response for every frequency channel, so a
 * moving/mono source shows up as a bright column that sweeps across the angle axis and (for a swept
 * tone) walks up/down the frequency axis.
 *
 *   horizontal = beam angle,  sin(theta) = 2*(k - NBEAM/2)/NBEAM,  k = 0..NBEAM-1
 *   vertical   = frequency channel (0..NCHAN-1), 4x-binned (FBIN channels/row, max-pooled so a
 *                narrow tone stays visible) -> ROWS=64 rows; low freq at bottom, high freq at top
 *   brightness = beam power, normalized by the frame's vmin..vmax (from the shm header)
 *
 * Redraws in place on every new frame (write_seq change), like peek_ula. Headless/terminal only.
 * usage: peek_ula_img [maxframes]     (0 or absent = run until Ctrl-C)
 * build: g++ -O2 src/peek_ula_img.cpp -o peek_ula_img -lrt
 */
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <csignal>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define NCHAN 256
#define NBEAM 64
#define FCEN  (NCHAN/2)            /* band-center channel: beam bin maps cleanly to sin(theta) */
#define FBIN  4                    /* frequency channels per display row (4x bin)               */
#define ROWS  (NCHAN/FBIN)         /* = 64 binned rows; each row = max over its FBIN channels    */

struct CorrULA { uint32_t magic, nchan, nbeam; volatile uint64_t write_seq; float img[NCHAN*NBEAM]; float vmax, vmin; };

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int) { g_stop = 1; }

static float beam_angle_deg(int k) {                 /* angle of beam bin k, degrees */
    float s = 2.f * (k - NBEAM/2) / (float)NBEAM;
    if (s < -1.f) s = -1.f; if (s > 1.f) s = 1.f;
    return asinf(s) * 180.f / (float)M_PI;
}

int main(int argc, char** argv) {
    int maxframes = (argc > 1) ? atoi(argv[1]) : 0;
    std::signal(SIGINT, on_sig); std::signal(SIGTERM, on_sig);

    int fd = shm_open("/corr_ula", O_RDONLY, 0);
    if (fd < 0) { perror("shm_open /corr_ula (is rx_feng4el_corr running?)"); return 1; }
    void* p = mmap(nullptr, sizeof(CorrULA), PROT_READ, MAP_SHARED, fd, 0); close(fd);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    CorrULA* c = (CorrULA*)p;
    if (c->magic != 0x554c4131) { printf("not a corr_ula shm (magic %08x)\n", c->magic); return 2; }

    const char* lut = " .:-=+*#%@";                  /* 10-level brightness ramp (matches peek32) */
    uint64_t last = 0; int frames = 0;
    printf("\033[2J");                               /* clear once; then redraw in place each frame */

    while (!g_stop) {
        uint64_t s = __atomic_load_n(&c->write_seq, __ATOMIC_ACQUIRE);
        if (s == last) { usleep(20000); continue; }
        last = s;

        float vx = c->vmax, vn = c->vmin, rng = (vx > vn) ? (vx - vn) : 1.f;

        /* global peak over the whole cube = where the source actually is */
        int gc = 0, gk = 0; float gmx = -1e30f;
        for (int cc = 0; cc < NCHAN; ++cc)
            for (int kk = 0; kk < NBEAM; ++kk) {
                float v = c->img[(size_t)cc*NBEAM + kk];
                if (v > gmx) { gmx = v; gc = cc; gk = kk; }
            }

        /* band-center recovered angle (clean sin map; low channels are DC-dominated near 0deg) */
        const float* rc = c->img + (size_t)FCEN*NBEAM; int kb = 0; float mb = -1e30f;
        for (int k = 0; k < NBEAM; ++k) if (rc[k] > mb) { mb = rc[k]; kb = k; }

        printf("\033[H");                            /* cursor home */
        printf("feng4el ULA beamform  seq=%-6lu  peak: ch%3d  %+6.1fdeg  val=%.2e   band-ctr(ch%d) %+6.1fdeg\033[K\n",
               (unsigned long)s, gc, beam_angle_deg(gk), gmx, FCEN, beam_angle_deg(kb));
        printf("angle -->  (each cell = one beam; brightness = power, normalized this frame)\033[K\n");

        /* heatmap: ROWS rows, each = MAX over its FBIN-channel bin; high freq at top */
        for (int r = 0; r < ROWS; ++r) {
            int b = ROWS - 1 - r;                  /* top row = highest-frequency bin */
            int clo = b * FBIN, chi = clo + FBIN - 1;
            char line[2*NBEAM + 1];
            for (int k = 0; k < NBEAM; ++k) {
                float mx = -1e30f;
                for (int cc = clo; cc <= chi; ++cc) { float v = c->img[(size_t)cc*NBEAM + k]; if (v > mx) mx = v; }
                float n = (mx - vn) / rng; int li = (int)(n * 9.f);
                if (li < 0) li = 0; if (li > 9) li = 9;
                line[2*k] = lut[li]; line[2*k+1] = lut[li];
            }
            line[2*NBEAM] = 0;
            printf("c%3d-%3d|%s|\033[K\n", clo, chi, line);
        }

        /* angle ruler under the map */
        char ruler[2*NBEAM + 1]; for (int i = 0; i < 2*NBEAM; ++i) ruler[i] = ' '; ruler[2*NBEAM] = 0;
        for (int deg = -90; deg <= 90; deg += 30) {
            /* find beam bin nearest this angle */
            int bk = 0; float bd = 1e30f;
            for (int k = 0; k < NBEAM; ++k) { float d = fabsf(beam_angle_deg(k) - deg); if (d < bd) { bd = d; bk = k; } }
            int col = 2*bk; char lab[8]; int n = snprintf(lab, sizeof(lab), "%+d", deg);
            for (int i = 0; i < n && col+i < 2*NBEAM; ++i) ruler[col+i] = lab[i];
        }
        printf("       %s \033[K\n", ruler);
        printf("       (angle, degrees)   vmax=%.2e vmin=%.2e   Ctrl-C to stop\033[K\n", vx, vn);
        fflush(stdout);

        if (maxframes && ++frames >= maxframes) break;
    }
    printf("\n");
    munmap(p, sizeof(CorrULA));
    return 0;
}
