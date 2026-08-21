/* dram_bw.c — sample DRAM read/write bandwidth via IMC CAS counters (SPR).
 * Each CAS = 64B. Sums across all uncore_imc_N PMUs.
 * Build: gcc -O2 dram_bw.c -o dram_bw
 * Run (root): ./dram_bw [seconds]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

#define MAX_IMC 16
static int rd_fd[MAX_IMC], wr_fd[MAX_IMC], nimc;

static int open_ev(int type, uint64_t config)
{
    struct perf_event_attr a; memset(&a, 0, sizeof(a));
    a.type = type; a.size = sizeof(a); a.config = config;
    return syscall(SYS_perf_event_open, &a, -1, 0, -1, 0);
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 30;
    DIR *d = opendir("/sys/bus/event_source/devices");
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "uncore_imc_", 11) || strstr(e->d_name, "free"))
            continue;
        char p[256]; snprintf(p, sizeof(p),
            "/sys/bus/event_source/devices/%s/type", e->d_name);
        FILE *f = fopen(p, "r"); int type; fscanf(f, "%d", &type); fclose(f);
        rd_fd[nimc] = open_ev(type, 0x05 | (0xcfULL << 8));  /* CAS_COUNT.RD */
        wr_fd[nimc] = open_ev(type, 0x05 | (0xf0ULL << 8));  /* CAS_COUNT.WR */
        if (rd_fd[nimc] < 0 || wr_fd[nimc] < 0) { perror(e->d_name); return 1; }
        nimc++;
    }
    closedir(d);
    fprintf(stderr, "sampling %d IMCs, %d s\n", nimc, secs);
    uint64_t r0 = 0, w0 = 0, v;
    for (int i = 0; i < nimc; i++) {
        read(rd_fd[i], &v, 8); r0 += v;
        read(wr_fd[i], &v, 8); w0 += v;
    }
    for (int t = 1; t <= secs; t++) {
        sleep(1);
        uint64_t r1 = 0, w1 = 0;
        for (int i = 0; i < nimc; i++) {
            read(rd_fd[i], &v, 8); r1 += v;
            read(wr_fd[i], &v, 8); w1 += v;
        }
        printf("[%3ds] DRAM rd %7.2f GB/s  wr %7.2f GB/s\n",
               t, (r1-r0)*64.0/1e9, (w1-w0)*64.0/1e9);
        fflush(stdout);
        r0 = r1; w0 = w1;
    }
    return 0;
}
