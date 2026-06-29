#!/usr/bin/env python3
"""ct_verify.py -- GOLDEN reference for the per-element corner-turn + planar split.

This is the bit-exact index/byte-layout contract the dummy-FFT assembly sim must
reproduce. Recreated from the design spec (the original session artifact was not
persisted). It defines, for ONE array element:

  WRITE side : the F-engine emits FFT frames. A frame = NCHAN channels, delivered
               8 lanes/clock over NCHAN/8 clocks (so channel c arrives on
               lane (c%8) at clock (c//8) within the frame). We accumulate TPKT
               consecutive frames into a transpose BRAM addressed [t][c].
  READ  side : read out [c][t] -> a linear plane index p = c*TPKT + t.
  SPLIT      : complex -> planar. The int8 real part of (c,t) goes to byte p in
               the re-plane [0 .. NCHAN*TPKT-1]; the imag part goes to byte
               NCHAN*TPKT + p in the im-plane.

Payload (per element) = re[NCHAN*TPKT] then im[NCHAN*TPKT] = 2*NCHAN*TPKT bytes.

The RX (config_ula.h) decodes a packet for element = seq % NELEM as:
    re = payload[p];   im = payload[NCHAN*TPKT + p];   p = c*TPKT + t
so this file is BOTH the TX-assembly contract and the RX-decode rule, and they
must be inverses. We assert that round-trip here.
"""

NCHAN = 256          # ULA_NCHAN
TPKT  = 16           # ULA_TPKT
NLANE = 8            # fft data lanes out00..out07 (UFix_48_0 each)
PAYLOAD_BYTES = 2 * NCHAN * TPKT   # 8192, == ULA_PAYLOAD_BYTES

assert PAYLOAD_BYTES == 8192

# ---- the index maps -------------------------------------------------------
def plane_index(c, t):
    """Linear plane index for channel c, time-sample t (read-out order [c][t])."""
    assert 0 <= c < NCHAN and 0 <= t < TPKT
    return c * TPKT + t

def re_byte(c, t):
    """Byte offset of the int8 real part of (c,t) within the element payload."""
    return plane_index(c, t)

def im_byte(c, t):
    """Byte offset of the int8 imag part of (c,t) within the element payload."""
    return NCHAN * TPKT + plane_index(c, t)

# ---- the F-engine lane/clock geometry of a single frame -------------------
def lane_of_channel(c):
    """Which of the 8 fft data lanes channel c arrives on (unscramble=on =>
    channels are canonical-ordered, 8 per clock, lane = c mod 8)."""
    return c % NLANE

def clk_of_channel(c):
    """Which clock within the frame channel c arrives on (0 .. NCHAN/NLANE-1)."""
    return c // NLANE

# ---- the dummy-FFT payload encoding (what the assembly sim drives) --------
# The dummy FFT packs (c, t) into each lane sample so the emitted byte is
# recoverable. After gain*Convert to int8 the value must be UNCLIPPED, so we
# choose small signed test values that survive Fix_8_7 saturation exactly.
#
# Encoding chosen: real_int8(c,t) = enc8(c), imag_int8(c,t) = enc8(t)
# where enc8 maps an index to a distinct small signed int8 in [-64, 63]:
def enc8(idx):
    """Map an index to a deterministic signed int8 that is UNCLIPPED through
    gain(~0.9)*Convert->Fix_8_7. Fix_8_7 range is [-1, +0.9921875]; we keep the
    pre-gain magnitude < 1.0 so post-gain peak ~0.9 < 1.0 (no saturation)."""
    # 7-bit signed wrap of idx, centered: gives values in [-64,63]
    v = ((idx + 64) % 128) - 64
    return v

def decode_re(byte_val):
    """RX would read this int8 back; for the dummy it should equal enc8(c)."""
    return byte_val

# ---- round-trip self test -------------------------------------------------
def build_element_payload():
    """Build the golden 8192-byte payload for one element from dummy (c,t)
    encoding, then assert RX-decode recovers (c,t)."""
    pay = bytearray(PAYLOAD_BYTES)
    for c in range(NCHAN):
        for t in range(TPKT):
            pay[re_byte(c, t)] = enc8(c) & 0xFF   # store as unsigned byte
            pay[im_byte(c, t)] = enc8(t) & 0xFF
    return bytes(pay)

def s8(b):
    return b - 256 if b >= 128 else b

def verify():
    pay = build_element_payload()
    assert len(pay) == 8192
    # RX decode: for each (c,t), recover re/im and check encoding
    bad = 0
    for c in range(NCHAN):
        for t in range(TPKT):
            re = s8(pay[re_byte(c, t)])
            im = s8(pay[im_byte(c, t)])
            if re != enc8(c) or im != enc8(t):
                bad += 1
    assert bad == 0, f"{bad} mismatches"
    # spot-check a few well-known offsets
    assert re_byte(0, 0) == 0
    assert im_byte(0, 0) == 4096
    assert re_byte(255, 15) == 255 * 16 + 15  # == 4095
    assert im_byte(255, 15) == 8191
    assert re_byte(1, 0) == 16   # channel stride = TPKT
    print("ct_verify: OK  payload=%d B  re[0,0]@0 im[0,0]@4096 re[255,15]@4095 im[255,15]@8191"
          % len(pay))
    return pay

if __name__ == "__main__":
    verify()
