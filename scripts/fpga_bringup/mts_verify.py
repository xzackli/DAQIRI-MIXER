#!/usr/bin/env python
# mts_verify.py -- prove MTS sample-alignment between tile224 & tile226 by cross-correlation.
# RUN WITH:  ~/miniconda3/envs/casper/bin/python ~/mts_verify.py
# Method adapted from Xilinx RFSoC-MTS RFSoC4x2 notebook:
#   broadcast ONE coherent tone to BOTH SMAs, snapshot ADC from each tile, fftconvolve(t226, t224[::-1]),
#   assert argmax == lag 0 EVERY capture, repeat >=16x across power-cycles.
#   Tile224-ch0 has a PCB POLARITY SWAP -> NEGATE tile224 before correlating (can't dodge: RefTile=tile224 is hardcoded).
#
# *** GATEWARE GAP (FLAG) ***
#   manas2el has exactly ONE adc_snapshot block, wired to the FIRST rfdc ADC output (m00 = tile224/ADC0).
#   There is NO per-tile snapshot for tile226 (m20). So this script CANNOT capture both tiles from
#   one bitstream as written. Options to make the verify runnable:
#     (A) [recommended] add a SECOND adc_snapshot (or a 2-input snapshot) tapping m20=tile226 in manas2el.slx
#         (gateware add to the build) -> then set CAP = {'ADC0':(<ctrl>,<bram>), 'ADC2':(<ctrl>,<bram>)} below.
#     (B) capture tile224 here; capture tile226 via the 100GbE stream/another tap; align timestamps.
#   Until (A) lands, this script captures the ONE available tile (tile224) and reports that tile226
#   capture is missing -- it is a CORRELATE-READY harness, not yet a 2-tile proof.

import casperfpga, time, struct, sys
import numpy as np
try:
    from scipy.signal import fftconvolve
except Exception:
    fftconvolve = None

BOARD = '192.168.2.101'
N_ITERS = 16

# adc_snapshot block (matches ~/adc_snap.py convention): ctrl reg + bram, 8192 x int16, big-endian.
SNAP_CTRL = 'adc_snapshot_ss_ctrl'
SNAP_BRAM = 'adc_snapshot_ss_bram'
SNAP_NBYTES = 16384   # 8192 int16

# Per-tile capture map. With current gateware only tile224 exists.
# After gateware add (B-side snapshot on m20), fill in tile226's ctrl/bram names here:
CAP = {
    'ADC0': (SNAP_CTRL, SNAP_BRAM),   # tile224 = m00 (the ONE existing snapshot)
    # 'ADC2': ('adc_snapshot2_ss_ctrl', 'adc_snapshot2_ss_bram'),  # tile226 = m20 -- ADD IN GATEWARE
}

def capture(f, ctrl, bram):
    f.write_int(ctrl, 3); time.sleep(0.05); f.write_int(ctrl, 0)
    raw = f.read(bram, SNAP_NBYTES)
    return np.array(struct.unpack('>%dh' % (SNAP_NBYTES // 2), raw), dtype=np.float64)

def main():
    f = casperfpga.CasperFpga(BOARD, timeout=10)
    print('connected =', f.is_connected())
    try:
        f.listdev()
    except Exception as e:
        print('FAIL: daemon wedged (%s) -- run ~/pty_killrestart.py' % str(e)[:50]); sys.exit(1)
    # NOTE: assumes the board is already programmed + MTS-aligned by mts_bringup.py this session.

    have226 = 'ADC2' in CAP
    if not have226:
        print('*** WARNING: tile226 snapshot NOT present in manas2el gateware ***')
        print('    Capturing tile224 only -- this is NOT yet a 2-tile alignment proof.')
        print('    ADD a snapshot on rfdc m20 (tile226) and fill CAP["ADC2"], then re-run for the real verify.\n')

    print('BRING-UP NOTE (user): broadcast ONE coherent CW tone (e.g. ~100-400 MHz, in-band)')
    print('  split equally to BOTH SMAs feeding tile224-ch0 and tile226-ch0 (matched cable lengths).\n')

    lags = []
    for it in range(N_ITERS):
        c224 = capture(f, *CAP['ADC0'])
        # POLARITY FIX: tile224-ch0 PCB swap -> negate before correlating
        c224 = -c224
        if have226:
            c226 = capture(f, *CAP['ADC2'])
            if fftconvolve is None:
                print('FAIL: scipy not available for fftconvolve'); sys.exit(1)
            xc = fftconvolve(c226, c224[::-1], mode='full')
            lag = int(np.argmax(np.abs(xc))) - (len(c224) - 1)
            lags.append(lag)
            print('iter %2d: argmax lag = %d  (rms224=%.1f rms226=%.1f)' % (it, lag, c224.std(), c226.std()))
        else:
            print('iter %2d: tile224 rms=%.1f  min=%d max=%d  (tile226 capture UNAVAILABLE)'
                  % (it, c224.std(), int(c224.min()), int(c224.max())))
        time.sleep(0.2)

    if have226:
        lags = np.array(lags)
        n0 = int(np.sum(lags == 0))
        print('\nlag-0 hits: %d/%d ; lag spread [%d, %d]' % (n0, len(lags), lags.min(), lags.max()))
        if n0 == len(lags):
            print('PASS: argmax==lag0 on every capture -> tile224 & tile226 are sample-aligned (MTS GOOD).')
            print('  (For the full proof, also re-run across >=16 POWER-CYCLES and confirm lag stays 0.)')
        else:
            print('FAIL: argmax not consistently lag0 -> NOT aligned; re-power-cycle, recheck SYSREF/AXIS-clk.')
    else:
        print('\nVERDICT: harness ran on tile224 only. Add the tile226 snapshot (gateware) for the real >=16x lag-0 test.')

if __name__ == '__main__':
    main()
