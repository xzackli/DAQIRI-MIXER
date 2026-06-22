/* bf_cgemm.cuh -- complete int8 tensor-core COVARIANCE CORRELATOR. Standard nvcuda::wmma only: no ccglib,
 * no inline PTX, no patches. One kernel computes V = X * X^H per batch (= per frequency channel).
 *
 * MATH: complex GEMM C = A*B, planar int8 in / int32 accumulate. A is row-major [M][K]; B is COLUMN-major
 * [K][N]. For V = X*X^H pass A = X and B = conj(X) in the SAME [row][K] layout (B = X with imag negated): the
 * column-major read turns it into conj(X)^T for free, so the packer writes A and B identically (coalesced, no
 * transpose). One complex tile = four real matmuls:  C_re = A_re*B_re - A_im*B_im ,  C_im = A_re*B_im + A_im*B_re.
 *
 * SPEED: each warp computes a BF_SM x BF_SN block of 16x16 tiles, loading each A-row / B-col fragment ONCE per
 * k-step and reusing it across the block -> ~half the L2 operand traffic of one-tile-per-warp (the naive kernel
 * is L2-bandwidth bound, not compute bound). 2x2 clears the per-channel line-rate budget (~380 G end-to-end).
 * ACC=true seeds the accumulators from the current C tile, so a PERSISTENT int32 cube becomes the running sum
 * V += X*X^H -- the integrate is fused into the GEMM (no separate accumulate pass). Caller must single-write C
 * across streams and flush int32->float before overflow (~BF_SM*BF_SN-free; per entry 127*127*K per update).
 * The last ~2% and the Hermitian-triangle 2x need mma.sync+ldmatrix+cp.async (ccglib / Romein's libtcc). */
#pragma once
#include <mma.h>
#define BF_WT 16                        /* wmma tile = 16x16x16 */
#ifndef BF_SM
#define BF_SM 2                         /* output tiles per warp along M (register-blocking factor) */
#endif
#ifndef BF_SN
#define BF_SN 2                         /* ...and along N. 2x2 is the sweet spot; 4x4 spills registers. */
#endif
using BfI8 = signed char;

/* ACC=false: C = X*X^H (overwrite).  ACC=true: C += X*X^H (integrate into a persistent int32 cube). */
template<bool ACC>
__global__ void bf_cgemm_blk_t(int M, int N, int K,
                               const BfI8* Are, const BfI8* Aim, const BfI8* Bre, const BfI8* Bim,
                               int* Cre, int* Cim) {
    using namespace nvcuda;
    size_t b = blockIdx.z;                                  /* batch = frequency channel */
    Are += b*(size_t)M*K; Aim += b*(size_t)M*K;             /* A = X        [M ant][K samples], row-major   */
    Bre += b*(size_t)K*N; Bim += b*(size_t)K*N;             /* B = conj(X)  same layout, read column-major  */
    Cre += b*(size_t)M*N; Cim += b*(size_t)M*N;             /* C = V        [M][N] visibility, int32        */
    int ntN = N/(BF_WT*BF_SN);                              /* map warp -> one SMxSN block of 16x16 tiles */
    int warp = (blockIdx.x*blockDim.x + threadIdx.x)/32, bN = warp%ntN, bM = warp/ntN;
    if (bM >= M/(BF_WT*BF_SM)) return;
    int tM0 = bM*BF_SM, tN0 = bN*BF_SN;                     /* first tile of this warp's block */
    wmma::fragment<wmma::accumulator,BF_WT,BF_WT,BF_WT,int> cre[BF_SM][BF_SN], cim[BF_SM][BF_SN];
    for (int i=0;i<BF_SM;i++) for (int j=0;j<BF_SN;j++)     /* seed accumulators: 0, or the running V if ACC */
        if (ACC) { wmma::load_matrix_sync(cre[i][j], Cre+(size_t)(tM0+i)*BF_WT*N+(tN0+j)*BF_WT, N, wmma::mem_row_major);
                   wmma::load_matrix_sync(cim[i][j], Cim+(size_t)(tM0+i)*BF_WT*N+(tN0+j)*BF_WT, N, wmma::mem_row_major); }
        else     { wmma::fill_fragment(cre[i][j],0); wmma::fill_fragment(cim[i][j],0); }
    for (int k=0; k<K; k+=BF_WT) {                          /* contract over the K samples, 16 at a time */
        wmma::fragment<wmma::matrix_a,BF_WT,BF_WT,BF_WT,BfI8,wmma::row_major> are[BF_SM], aim[BF_SM], aneg[BF_SM];
        wmma::fragment<wmma::matrix_b,BF_WT,BF_WT,BF_WT,BfI8,wmma::col_major> bre[BF_SN], bim[BF_SN];
        for (int i=0;i<BF_SM;i++) {                         /* load each A-row ONCE -> reused across BF_SN cols */
            wmma::load_matrix_sync(are[i], Are+(size_t)(tM0+i)*BF_WT*K+k, K);
            wmma::load_matrix_sync(aim[i], Aim+(size_t)(tM0+i)*BF_WT*K+k, K);
            for (int e=0;e<aim[i].num_elements;e++) aneg[i].x[e] = -aim[i].x[e];   /* -A_im for the C_re term */
        }
        for (int j=0;j<BF_SN;j++) {                         /* load each B-col ONCE -> reused across BF_SM rows */
            wmma::load_matrix_sync(bre[j], Bre+(size_t)(tN0+j)*BF_WT*K+k, K);      /* col-major: B[k][n] @ n*K+k */
            wmma::load_matrix_sync(bim[j], Bim+(size_t)(tN0+j)*BF_WT*K+k, K);
        }
        for (int i=0;i<BF_SM;i++) for (int j=0;j<BF_SN;j++) {                      /* the 4 real matmuls / tile */
            wmma::mma_sync(cre[i][j], are[i],  bre[j], cre[i][j]);   /* C_re += A_re*B_re    */
            wmma::mma_sync(cre[i][j], aneg[i], bim[j], cre[i][j]);   /* C_re += (-A_im)*B_im */
            wmma::mma_sync(cim[i][j], are[i],  bim[j], cim[i][j]);   /* C_im += A_re*B_im    */
            wmma::mma_sync(cim[i][j], aim[i],  bre[j], cim[i][j]);   /* C_im += A_im*B_re    */
        }
    }
    for (int i=0;i<BF_SM;i++) for (int j=0;j<BF_SN;j++) {   /* store the block's int32 V tiles */
        wmma::store_matrix_sync(Cre+(size_t)(tM0+i)*BF_WT*N+(tN0+j)*BF_WT, cre[i][j], N, wmma::mem_row_major);
        wmma::store_matrix_sync(Cim+(size_t)(tM0+i)*BF_WT*N+(tN0+j)*BF_WT, cim[i][j], N, wmma::mem_row_major);
    }
}
