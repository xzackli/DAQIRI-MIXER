#!/usr/bin/env python3
"""Derive the CASPER reorder-block map for the per-element corner-turn.

CASPER reorder semantics (casper_library_reorder/reorder):
  - operates on a stream of length N = len(map), n_inputs lanes in parallel.
  - map[i] = the INPUT position that should appear at OUTPUT position i
    (i.e. out[i] = in[map[i]]), applied per double-buffered frame of N samples.
  - n_inputs lanes means N/n_inputs clocks per frame, lane = pos mod n_inputs.

Our corner-turn buffers one element = TPKT(16) frames x NCHAN(256) channels of the
fft. The fft delivers, within frame t, channel c on lane (c mod 8) at clock (c div 8).
We want to read out, per output sample position p, the (c,t) with plane p = c*TPKT+t.

But the reorder block reorders WITHIN one buffer pass. To corner-turn across 16 frames
we make ONE reorder buffer span all 16 frames: N = TPKT*NCHAN = 4096 samples, written
in arrival order, read in plane order.

ARRIVAL (write) linear index a(t,c): frames are consecutive; within a frame the fft
emits channels in canonical order (unscramble=on) 8/clk. So arrival index:
    a = t*NCHAN + c                      (frame-major, channel within frame)
READ (output) plane index p(c,t) = c*TPKT + t.
We want out[p] = in[ a(t,c) ] where p = c*TPKT+t. So:
    map[p] = a(t,c) = t*NCHAN + c,  with c = p//TPKT, t = p%TPKT.

That's the complex-sample reorder. Planar re/im split is a SEPARATE downstream step
(slice re byte and im byte of each reordered complex sample into two planes), OR we
double N and interleave — but cleanest: reorder the COMPLEX stream, then split.
"""
NCHAN=256; TPKT=16; N=NCHAN*TPKT  # 4096

def build_map():
    m=[0]*N
    for p in range(N):
        c=p//TPKT; t=p%TPKT
        m[p]=t*NCHAN+c
    return m

def verify():
    m=build_map()
    assert len(m)==N
    assert sorted(m)==list(range(N)), "map not a permutation"
    # check out[p] corresponds to plane p = c*16+t reading in[t*256+c]
    for p in range(N):
        c=p//TPKT; t=p%TPKT
        assert m[p]==t*NCHAN+c
    # spot
    assert m[0]==0            # p=0 -> c=0,t=0 -> in 0
    assert m[1]==NCHAN        # p=1 -> c=0,t=1 -> in 256
    assert m[TPKT]==1         # p=16 -> c=1,t=0 -> in 1
    assert m[N-1]==(TPKT-1)*NCHAN+(NCHAN-1)  # p last -> c=255,t=15 -> in 15*256+255
    print(f"reorder_map: OK  N={N} map is a permutation")
    print(f"  map[p]=t*256+c where c=p//16,t=p%16 (out plane p=c*16+t <- in arrival t*256+c)")
    print(f"  spot: map[0]={m[0]} map[1]={m[1]} map[16]={m[TPKT]} map[-1]={m[-1]}")
    # emit the map as a MATLAB-friendly vector for the reorder block
    with open('reorder_map.txt','w') as f:
        f.write('['+' '.join(str(x) for x in m)+']')
    print("  wrote reorder_map.txt (MATLAB vector)")
    return m

if __name__=='__main__':
    verify()
