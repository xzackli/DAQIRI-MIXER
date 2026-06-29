#!/usr/bin/env python3
# boundary_verify.py  --  GATE for the manas2el 2-element packet-boundary skew.
#
# Catches the manas256d-class "compiles-clean-but-frames-wrong" 1-cycle skew at the
# 2-element packet boundary (elemctr toggles on raw gb_eofand while the DPRAM read
# counter restarts on gb_eofand+1 via rd_eofdly => exactly the boundary word can be
# misplaced).  RFDC sim is a stub so this can ONLY be caught on real HW with a
# test_mode=1 ramp capture decoded at the packet boundary.
#
# GATEWARE FACTS (from manas2el.slx XML, verified 2026-06-28):
#  - Wire (config_ula.h): frame = 8256B = 64B hdr + 8192B payload (interleaved int8 cplx).
#    UDP payload starts at capture byte 42 (eth14+ip20+udp8, no VLAN).
#    seq    = uint32 BE @ payload byte 48..51 (free-run seqctr, +1 per *packet*).
#    elem   = uint8        @ payload byte 52  (elemctr bit0; alternates 0,1,0,1,...).
#    data   = payload bytes 64..8255 = 128 dense 64B words = 256ch x 16t x 2B for ONE element.
#  - test_mode=1: Mux1 selects Counter7 (32b free-run ramp, 0..1023 +1/read-clk, period=1)
#    in place of the element-0 FFT (bus_create -> Dual Port RAM1).  *** The ramp is injected
#    ONLY into element 0 (DPRAM1). *** Element 1 (bus_create2 -> Dual Port RAM2) has NO
#    test_mode mux, so with no analog signal it is ~all-zero.  => test_mode gives a
#    per-element-DISTINGUISHABLE pattern for free:  elem0 = structured RAMP, elem1 = ~ZERO.
#    The 1-cycle skew would smear a ramp word into the (should-be-zero) elem1 packet, or a
#    zero word into the (should-be-all-ramp) elem0 packet -- exactly at the boundary word.
#
# This script DECODES that and prints PASS/FAIL on:
#   (a) elem byte52 alternates 0,1,0,1,...        (the alternation itself)
#   (b) seq byte48 BE increments +1 per packet     (packet ordering / no drops in the run)
#   (c) elem0 packets are all-ramp (no foreign/zero words mid-body)
#   (d) elem1 packets are ~zero    (no ramp leakage)
#   (e) THE BOUNDARY: elem0-packet LAST data word is ramp (not a leaked elem1 zero), and
#       elem1-packet FIRST data word is ~zero (not a leaked elem0 ramp).  A +/-1 skew
#       lands exactly here.
#
# Usage:  python3 boundary_verify.py  <capture.pcapng>
#
# Run NOTHING here without the manas2el bitstream built + board streaming test_mode=1.

import sys, struct

HDR = 64           # ULA_HDR_BYTES
PAY = 8192         # ULA_PAYLOAD_BYTES
SEQ_OFF = 48       # ULA_SEQ_BYTE  (BE u32)
ELEM_OFF = 52      # ULA_ELEM_BYTE (u8)
WORD = 64          # dense wire word bytes
NDATA = PAY // WORD # 128 data words/packet
UDP = 42           # eth14+ip20+udp8

# tolerance: with no analog signal the elem1 / real-FFT path floors to ~0 but a couple of
# stray nonzero bytes (seq bleed / rounding) are documented as normal. A genuine leaked ramp
# word has MANY nonzero bytes and a large byte sum.
ZERO_WORD_NZ_MAX = 4        # <=4 nonzero bytes => treat as "zero" word
RAMP_WORD_NZ_MIN = 16       # >=16 nonzero bytes => treat as a "ramp/data" word

def read_frames(fn):
    """Return list of raw L2 frames. Supports pcapng (block 0x6) and classic pcap."""
    d = open(fn, 'rb').read()
    # pcapng?  first block type 0x0A0D0D0A (section header)
    if d[:4] == b'\x0a\x0d\x0d\x0a':
        frames = []; off = 0
        while off + 8 <= len(d):
            bt = struct.unpack('<I', d[off:off+4])[0]
            bl = struct.unpack('<I', d[off+4:off+8])[0]
            if bl < 12 or off + bl > len(d): break
            if bt == 0x6:  # enhanced packet block
                cl = struct.unpack('<I', d[off+8+12:off+8+16])[0]
                frames.append(d[off+8+20:off+8+20+cl])
            off += bl
        return frames
    # classic pcap
    magic = struct.unpack('<I', d[:4])[0]
    endi = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
    frames = []; off = 24
    while off + 16 <= len(d):
        _, _, caplen, _ = struct.unpack(endi+'IIII', d[off:off+16])
        off += 16
        frames.append(d[off:off+caplen]); off += caplen
    return frames

def nz_count(b):
    return sum(1 for x in b if x != 0)

def classify(word):
    n = nz_count(word)
    if n <= ZERO_WORD_NZ_MAX: return 'Z'      # zero-ish
    if n >= RAMP_WORD_NZ_MIN: return 'R'      # ramp/data
    return '?'                                # ambiguous

def main():
    if len(sys.argv) < 2:
        print("usage: boundary_verify.py <capture.pcapng>"); sys.exit(2)
    frames = read_frames(sys.argv[1])
    pkts = [f[UDP:] for f in frames if len(f) >= UDP + HDR + PAY]
    print("frames=%d  full-jumbo-payload pkts=%d" % (len(frames), len(pkts)))
    if len(pkts) < 4:
        print("FAIL: need >=4 consecutive jumbo packets to test a boundary"); sys.exit(1)

    fails = []

    # (a) elem alternation + (b) seq +1
    elems = [p[ELEM_OFF] for p in pkts]
    seqs  = [struct.unpack('>I', p[SEQ_OFF:SEQ_OFF+4])[0] for p in pkts]
    alt_ok = all(elems[i] != elems[i+1] and elems[i] in (0,1) for i in range(len(elems)-1))
    print("\n(a) elem byte52 first 16:", elems[:16])
    print("    alternates 0/1 strictly:", alt_ok)
    if not alt_ok: fails.append("(a) elem byte52 not strictly alternating 0/1")

    sdeltas = [(seqs[i+1]-seqs[i]) & 0xffffffff for i in range(len(seqs)-1)]
    seq_ok = all(d == 1 for d in sdeltas)
    print("(b) seq byte48 BE first 8:", seqs[:8], " deltas:", sdeltas[:12])
    print("    seq increments +1/packet:", seq_ok)
    if not seq_ok: fails.append("(b) seq @byte48 not +1/packet (drops or wrong counter)")

    # also sanity: seq%2 should match elem (the GPU keys element = seq % NELEM)
    seqmod_ok = all((seqs[i] & 1) == elems[i] for i in range(len(elems)))
    print("    elem == seq%%2 for every packet:", seqmod_ok)
    if not seqmod_ok: fails.append("(*) elem byte52 disagrees with seq%2 (header desync)")

    # per-packet word classification
    def words(p):
        body = p[HDR:HDR+PAY]
        return [classify(body[w*WORD:w*WORD+WORD]) for w in range(NDATA)]

    # (c)/(d) body purity per element
    e0_bad = e1_bad = 0
    for p in pkts:
        e = p[ELEM_OFF]; cl = words(p)
        if e == 0:
            # elem0 should be ALL ramp
            if any(c != 'R' for c in cl): e0_bad += 1
        else:
            # elem1 should be ALL zero
            if any(c != 'Z' for c in cl): e1_bad += 1
    print("\n(c) elem0 packets with a non-ramp word in body:", e0_bad)
    print("(d) elem1 packets with a non-zero word in body :", e1_bad)
    if e0_bad: fails.append("(c) elem0 body not pure ramp (foreign/zero word inside)")
    if e1_bad: fails.append("(d) elem1 body not pure zero (ramp leaked into elem1)")

    # (e) THE BOUNDARY -- check the LAST word of each elem0 pkt and FIRST word of each elem1
    # pkt explicitly, since that is the unique word a +/-1 skew misplaces.
    print("\n(e) BOUNDARY check (last word of elem0 pkt / first word of next elem1 pkt):")
    b_fail = 0; b_checked = 0
    for i in range(len(pkts)-1):
        a, b = pkts[i], pkts[i+1]
        if a[ELEM_OFF] == 0 and b[ELEM_OFF] == 1:
            b_checked += 1
            a_last  = a[HDR+PAY-WORD: HDR+PAY]          # elem0 last data word -> must be R
            b_first = b[HDR: HDR+WORD]                  # elem1 first data word -> must be Z
            la, fb = classify(a_last), classify(b_first)
            ok = (la == 'R') and (fb == 'Z')
            tag = "ok" if ok else "**SKEW**"
            if not ok: b_fail += 1
            if i < 8 or not ok:
                print("    seq %d->%d  elem0.last=%s(nz=%2d)  elem1.first=%s(nz=%2d)  %s" % (
                    seqs[i], seqs[i+1], la, nz_count(a_last), fb, nz_count(b_first), tag))
    # also the symmetric 1->0 boundary: elem1 last must be Z, elem0 first must be R
    for i in range(len(pkts)-1):
        a, b = pkts[i], pkts[i+1]
        if a[ELEM_OFF] == 1 and b[ELEM_OFF] == 0:
            b_checked += 1
            a_last  = a[HDR+PAY-WORD: HDR+PAY]          # elem1 last -> Z
            b_first = b[HDR: HDR+WORD]                  # elem0 first -> R
            la, fb = classify(a_last), classify(b_first)
            ok = (la == 'Z') and (fb == 'R')
            if not ok:
                b_fail += 1
                print("    seq %d->%d  elem1.last=%s(nz=%2d)  elem0.first=%s(nz=%2d)  **SKEW**" % (
                    seqs[i], seqs[i+1], la, nz_count(a_last), fb, nz_count(b_first)))
    print("    boundaries checked:", b_checked, " boundary failures:", b_fail)
    if b_fail: fails.append("(e) BOUNDARY word misplaced -> 1-cycle elemctr/read-counter skew")

    print("\n" + "="*60)
    if fails:
        print("RESULT: *** FAIL *** boundary integrity NOT proven")
        for fmsg in fails: print("   -", fmsg)
        sys.exit(1)
    else:
        print("RESULT: PASS -- 2-element framing + boundary integrity verified")
        print("   elem alternates, seq+1, elem0=ramp, elem1=zero, boundary words placed correctly.")
        sys.exit(0)

if __name__ == '__main__':
    main()
