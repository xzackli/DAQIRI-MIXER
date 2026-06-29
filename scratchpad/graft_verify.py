#!/usr/bin/env python3
"""graft_verify.py -- GOLDEN byte-layout model for the full F-engine graft, end to
end: dummy-FFT encoding -> tap (c_to_ri) -> requant (gain*Convert->Fix_8_7) ->
corner-turn (write[t][c]/read[c][t], planar split) -> packetizer (one packet per
element, PPB=NELEM, seq reconcile) -> the on-wire bytes config_ula.h's RX decodes.

This is the reference the Simulink dummy-FFT assembly sim must match bit-exact.
Run: python3 graft_verify.py
"""
import struct

# ---- contract constants (mirror config_ula.h) ----
NELEM         = 4
NCHAN         = 256
TPKT          = 16
NLANE         = 8
PAYLOAD_BYTES = 8192          # 2*NCHAN*TPKT
HDR_BYTES     = 64
WIRE_BYTES    = 8256
SEQ_BYTE      = 48            # config_ula.h: u32 BIG-endian at byte 48
PPB           = NELEM

# stream4_i8_hb legacy header puts a u64 LE seq at wire byte 42 (CASPER raw).
STREAM4_SEQ_BYTE = 42

assert PAYLOAD_BYTES == 2*NCHAN*TPKT == 8192
assert WIRE_BYTES == HDR_BYTES + PAYLOAD_BYTES

# ================= requant (bit-true model of Xilinx Convert->Fix_8_7) =========
# gain*Convert: Signed(2's comp), n_bits=8, bin_pt=7, Round(unbiased +/-Inf),
# overflow=Saturate, latency irrelevant to value. Fix_8_7 represents v/128 with
# v in [-128,127]; real range [-1.0, +0.9921875].
def fix87_convert(x_real):
    """x_real: a real number (already gain-applied). Returns the stored int8 v
    such that the Fix_8_7 value is v/128, with round-half-away-from-zero and
    saturation to [-128,127]."""
    scaled = x_real * 128.0
    # round half away from zero (unbiased +/- Inf)
    if scaled >= 0:
        v = int(scaled + 0.5)
    else:
        v = -int(-scaled + 0.5)
    if v > 127:  v = 127
    if v < -128: v = -128
    return v

# ================= dummy-FFT encoding (must stay UNCLIPPED through requant) =====
# The dummy packs (c,t) so the emitted int8 byte recovers them. We encode the
# *pre-requant* tap value (Fix_24_23, range [-1,1)) so that after gain(0.9)*Convert
# the int8 equals a deterministic function of (c,t) with NO saturation.
GAIN = 0.9
def enc_tap_real(c):
    """tap real value (Fix_24_23 domain, [-1,1)) chosen so int8 out = c-dependent
    and unclipped. Map c in [0,256) -> a value whose 0.9*Convert lands in
    [-115,114] (well inside +/-127, no clip)."""
    # target int8 = ((c % 229) - 114)  -> in [-114,114]
    tgt = (c % 229) - 114
    return (tgt / GAIN) / 128.0          # invert gain+Fix_8_7 scaling
def enc_tap_imag(t):
    tgt = (t % 229) - 114                # t in [0,16) -> [-114,-98], distinct
    return (tgt / GAIN) / 128.0

def dummy_int8(c, t):
    """The int8 (re,im) the requant emits for dummy channel c, time t."""
    re = fix87_convert(GAIN * enc_tap_real(c))
    im = fix87_convert(GAIN * enc_tap_imag(t))
    return re, im

# ================= corner-turn + planar split (per element) ====================
def plane_index(c, t):
    return c * TPKT + t                  # read-out [c][t]
def re_off(c, t):
    return plane_index(c, t)             # re-plane [0 .. 4095]
def im_off(c, t):
    return NCHAN*TPKT + plane_index(c, t)  # im-plane [4096 .. 8191]

def build_element_payload(elem):
    """8192-byte payload for one element. The dummy data is element-independent in
    (c,t); to make the element recoverable too we XOR the element id into a header
    field, not the payload. Payload stays the pure (c,t) encoding so the corner-turn
    is what's under test."""
    pay = bytearray(PAYLOAD_BYTES)
    # WRITE side: TPKT frames, each NCHAN channels over NCHAN/NLANE clocks.
    # We simulate exactly that traversal to prove the address arithmetic:
    for t in range(TPKT):                       # frame index
        for k in range(NCHAN // NLANE):         # clock within frame (0..31)
            for L in range(NLANE):              # lane 0..7
                c = k * NLANE + L               # canonical channel (unscramble=on)
                re, im = dummy_int8(c, t)
                pay[re_off(c, t)] = re & 0xFF
                pay[im_off(c, t)] = im & 0xFF
    return bytes(pay)

# ================= packetizer + seq reconcile =================================
def build_wire_packet(seq):
    """Full 8256-byte wire packet for global packet counter `seq`.
    element = seq % NELEM. Header carries seq as BIG-endian u32 at byte 48
    (config_ula.h contract), reconciled from stream4's native u64-LE@42 slot."""
    elem = seq % NELEM
    pkt = bytearray(WIRE_BYTES)
    # --- seq reconcile: config_ula.h wants BE u32 @ 48 ---
    struct.pack_into('>I', pkt, SEQ_BYTE, seq & 0xFFFFFFFF)
    # (the stream4 back-end's u64-LE@42 slot is repurposed; we leave it documented.
    #  In the graft the header Concat is re-sliced so the seq lands at byte 48 BE.)
    pkt[HDR_BYTES:WIRE_BYTES] = build_element_payload(elem)
    return bytes(pkt), elem

# ================= RX decode (config_ula.h rule) =============================
def s8(b): return b-256 if b>=128 else b

def rx_decode(pkt):
    """Decode a wire packet the way rx_ula_corr.cu / config_ula.h would."""
    seq = struct.unpack_from('>I', pkt, SEQ_BYTE)[0]
    elem = seq % NELEM
    pay = pkt[HDR_BYTES:HDR_BYTES+PAYLOAD_BYTES]
    return seq, elem, pay

# ================= self test ================================================
def verify():
    # corner-turn round trip for a packet
    for seq in range(0, 9):                       # >2 full PPB batches
        pkt, elem = build_wire_packet(seq)
        assert len(pkt) == WIRE_BYTES
        dseq, delem, pay = rx_decode(pkt)
        assert dseq == seq and delem == elem
        # check every (c,t) decodes to the dummy encoding
        bad = 0
        for c in range(NCHAN):
            for t in range(TPKT):
                re = s8(pay[re_off(c, t)])
                im = s8(pay[im_off(c, t)])
                ere, eim = dummy_int8(c, t)
                if re != ere or im != eim:
                    bad += 1
        assert bad == 0, f"seq={seq}: {bad} payload mismatches"
    # no requant value clips (the dummy must stay unclipped)
    clipped = 0
    for c in range(NCHAN):
        for t in range(TPKT):
            re, im = dummy_int8(c, t)
            if re in (127,-128) or im in (127,-128):
                clipped += 1
    assert clipped == 0, f"{clipped} dummy values CLIPPED -- encoding too hot"
    # element cycling
    elems = [build_wire_packet(s)[1] for s in range(8)]
    assert elems == [0,1,2,3,0,1,2,3]
    # spot offsets
    assert re_off(0,0)==0 and im_off(0,0)==4096
    assert re_off(255,15)==4095 and im_off(255,15)==8191
    print("graft_verify: OK")
    print(f"  wire={WIRE_BYTES}B hdr={HDR_BYTES} payload={PAYLOAD_BYTES} seq@{SEQ_BYTE}(BE u32)")
    print(f"  PPB={PPB} elem=seq%%{NELEM} cycle={elems}")
    print(f"  dummy int8 ranges: re in [{min(dummy_int8(c,0)[0] for c in range(NCHAN))},"
          f"{max(dummy_int8(c,0)[0] for c in range(NCHAN))}] "
          f"im in [{min(dummy_int8(0,t)[1] for t in range(TPKT))},"
          f"{max(dummy_int8(0,t)[1] for t in range(TPKT))}] -- 0 clipped")
    print(f"  corner-turn: write[t][c] -> read[c][t] -> plane=c*TPKT+t, re@p im@4096+p")

if __name__ == "__main__":
    verify()
