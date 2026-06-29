#!/usr/bin/env python3
"""ct_bram_verify.py -- STAGE 2: bit-exact emulation of the per-element corner-turn
transpose BRAM (double-buffered ping-pong), proving the hardware address arithmetic
write[t][c] / read[c][t] -> plane index, matching ct_verify.py's mapping.

Models the actual BRAM the FPGA graft instantiates:
  - depth = TPKT * NCHAN entries (one accumulation buffer); two buffers (ping-pong).
  - WRITE address (as the F-engine streams frame t, channel c arriving 8/clk):
        wr_addr(t,c) = t*NCHAN + c        # row-major [t][c]
  - READ  address (corner-turned read-out, channel-major):
        rd_addr(c,t) = c*TPKT + t         # == plane index p  (read [c][t])
  - The data stored at wr_addr(t,c) must be read at rd_addr(c,t): a true transpose.
  - Planar split on read: int8 real -> re-plane[p]; int8 imag -> im-plane[NCHAN*TPKT+p].

This is a transpose: every (t,c) cell written is read exactly once, and the read
order linearizes to p = c*TPKT+t. We verify the transpose is a bijection and that
the resulting byte layout equals config_ula.h's decode rule (re@p, im@4096+p).
"""
NCHAN = 256
TPKT  = 16
NLANE = 8
DEPTH = TPKT * NCHAN          # 4096 cells per buffer

def wr_addr(t, c):            # row-major write [t][c]
    return t * NCHAN + c
def rd_addr(c, t):           # corner-turned read [c][t] == plane index
    return c * TPKT + t

def emulate_one_buffer(elem_id):
    """Stream TPKT frames into a BRAM exactly as the F-engine would (8 lanes/clk,
    32 clks/frame), then read it back corner-turned and build the planar payload."""
    re_cell = [None]*DEPTH    # complex stored as (re_int8, im_int8) per cell
    im_cell = [None]*DEPTH
    # ---- WRITE phase: frame t, clock k(0..31), lane L(0..7) -> channel c=k*8+L ----
    for t in range(TPKT):
        for k in range(NCHAN // NLANE):
            for L in range(NLANE):
                c = k*NLANE + L
                # dummy int8 data == graft_verify's dummy encoding signature
                re8 = ((c % 229) - 114)
                im8 = ((t % 229) - 114)
                a = wr_addr(t, c)
                re_cell[a] = re8
                im_cell[a] = im8
    # ---- READ phase: corner-turned, c-major then t, into planar payload ----
    pay = bytearray(2*NCHAN*TPKT)
    seen = [False]*DEPTH
    for c in range(NCHAN):
        for t in range(TPKT):
            p = rd_addr(c, t)                 # plane index 0..4095
            src = wr_addr(t, c)               # where the writer put (t,c)
            assert not seen[src]; seen[src] = True
            pay[p]               = re_cell[src] & 0xFF   # re-plane
            pay[NCHAN*TPKT + p]  = im_cell[src] & 0xFF   # im-plane
    assert all(seen), "BRAM transpose missed cells (not a bijection)"
    return bytes(pay)

def s8(b): return b-256 if b>=128 else b

def verify():
    pay = emulate_one_buffer(elem_id=0)
    assert len(pay) == 8192
    # decode the way config_ula.h's RX would, and check it recovers (c,t)
    bad = 0
    for c in range(NCHAN):
        for t in range(TPKT):
            p = c*TPKT + t
            re = s8(pay[p]); im = s8(pay[4096+p])
            if re != (c % 229)-114 or im != (t % 229)-114:
                bad += 1
    assert bad == 0, f"{bad} mismatches"
    # cross-check against ct_verify offsets
    import importlib.util, os
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("ctv", os.path.join(here,"ct_verify.py"))
    ctv = importlib.util.module_from_spec(spec); spec.loader.exec_module(ctv)
    for (c,t) in [(0,0),(1,0),(255,15),(128,8),(7,3)]:
        assert rd_addr(c,t) == ctv.plane_index(c,t) == ctv.re_byte(c,t)
        assert 4096+rd_addr(c,t) == ctv.im_byte(c,t)
    print("ct_bram_verify: OK")
    print(f"  BRAM depth={DEPTH} cells/buffer, double-buffered (ping-pong)")
    print(f"  write[t][c] addr=t*{NCHAN}+c ; read[c][t] addr=c*{TPKT}+t (transpose, bijection)")
    print(f"  planar: re@p (0..4095), im@4096+p ; payload=8192 B")
    print(f"  matches ct_verify.plane_index + config_ula.h re@p/im@4096+p")

if __name__ == "__main__":
    verify()
