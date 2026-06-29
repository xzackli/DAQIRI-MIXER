#!/usr/bin/env python
# mts_bringup.py -- MTS bring-up for the 2-element (tile224+tile226) manas2el design.
# RUN WITH:  ~/miniconda3/envs/casper/bin/python ~/mts_bringup.py
#
# GATE / DISCIPLINE:
#   * Board one-program discipline: ONE upload_to_ram_and_program per session.
#     If the daemon is wedged, recover with:  ~/miniconda3/envs/casper/bin/python ~/pty_killrestart.py
#   * POWER-CYCLE the board before the FIRST MTS of a session (warm reload mis-locks SYSREF capture).
#   * The CRITICAL FIX vs the old bring-up: rfdc.init() is called WITH the 8 MHz-SYSREF
#     LMK + 512 MHz LMX files (upload=True), NOT bare. Bare init() programs NO PLL and
#     inherits the board-default (122.88M/491.52M ALPACA) SYSREF which is NOT a <10MHz
#     divisor of 128 -> run_mts would fail 0x1000(FREQ_NDONE)/0x800(GATE).
#
# CLOCK PLAN (manas256f / manas2el): 2.048 GSPS, Refclk 512 MHz, PLL x4, Fabric 256, PL 128.
#   LMK file: rfsoc4x2_lmk_CLKin0_extref_5M_PL_128M_LMXREF_256M.txt
#     -> decoded: VCO=2560 MHz, SYSREF_DIV(R0x13A/0x13B)=320 -> SYSREF = 2560/320 = 8.000 MHz,
#        SYSREF_MUX(R0x139)=3 = CONTINUOUS. 8 MHz divides PL(128) and AXIS(256) evenly, <10 MHz -> LEGAL.
#   LMX file: rfsoc4x2_lmx_inputref_256M_outputref_512M.txt  (256M ref in -> 512M sample-clock ref out).
#   The same LMK device-clock tree drives the PL clock; the PL-SYSREF (pl_sysref) into the
#   mts_pl_sysref_sync 2-FF CDC is the SAME LMK 8 MHz SYSREF -> analog + PL SYSREF same freq/phase (PG269 req).

import casperfpga, time, glob, sys, os

BOARD = '192.168.2.101'
LMK   = '/tmp/vdif_misc/rfsoc4x2_lmk_CLKin0_extref_5M_PL_128M_LMXREF_256M.txt'  # SYSREF = 8 MHz
LMX   = '/tmp/vdif_misc/rfsoc4x2_lmx_inputref_256M_outputref_512M.txt'
# manas2el .fpg -- update glob once the build lands (currently NO manas2el fpg exists; manas2el.slx is built-pending)
FPG_GLOB = '/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas2el/outputs/manas2el_*.fpg'

REF_TILE_NAME = 'ADC0'        # tile224 = RefTile=0, hardcoded master in board-side rfdc-run-mts
MTS_TILES     = ['ADC0','ADC2']   # 224 + 226
TILE_MASK     = 0b0101            # ADC tile224(bit0) + tile226(bit2)

def die(msg): print('FAIL:', msg); sys.exit(1)

for p in (LMK, LMX):
    if not os.path.exists(p): die('missing clock file %s' % p)
fl = sorted(glob.glob(FPG_GLOB))
if not fl: die('no manas2el .fpg yet at %s (build the bitstream first)' % FPG_GLOB)
FPG = fl[-1]; print('FPG =', FPG)

f = casperfpga.CasperFpga(BOARD, timeout=12)
print('connected =', f.is_connected())
try:
    f.listdev()
except Exception as e:
    die('daemon wedged (%s) -- run ~/pty_killrestart.py then retry' % str(e)[:50])

# --- ONE program (one-program discipline) ---
print('programming manas2el (ONE upload)...')
f.upload_to_ram_and_program(FPG)
f.get_system_information(FPG)
print('  programmed; listdev=%d' % len(f.listdev()))

rfdc = f.adcs['rfdc']

# --- THE FIX: program the 8 MHz-SYSREF PLLs (upload local files to board) ---
print('rfdc.init(lmk=%s, lmx=%s, upload=True)...' % (os.path.basename(LMK), os.path.basename(LMX)))
rfdc.init(lmk_file=LMK, lmx_file=LMX, upload=True)
time.sleep(2.0)   # let PLLs lock

# --- confirm BOTH tile224 AND tile226 reach State 15 + PLL locked ---
st = rfdc.status()
print('rfdc tile status:', st)
ok = True
for t in MTS_TILES:
    d = st.get(t, {})
    state = d.get('State', -1); pll = d.get('PLL', 0)
    print('  %s: State=%s PLL=%s' % (t, state, 'locked' if pll else 'NO-LOCK'))
    if state != 15 or not pll: ok = False
if not ok: die('tile(s) not State 15 / PLL-locked -- check SYSREF/clock or power-cycle')

# --- run MTS on the 2-element mask, RefTile=tile224 (hardcoded board-side) ---
print('run_mts(tile_mask=0b0101)...')
rfdc.run_mts(tile_mask=TILE_MASK)
print('--- raw MTS report ---')
rfdc.get_mts_report()

# --- parse report: ADCn: Latency(T1) =NNN, ... Offset(Tx) =NNN ; ASSERT equal Latency across 224+226 ---
import re
lat = {}; off = {}
for m in rfdc.mts_report:
    s = m.arguments[0].decode() if hasattr(m, 'arguments') else str(m)
    mm = re.search(r'ADC(\d+).*Latency\(T1\)\s*=\s*(-?\d+).*Offset\(T\d+\)\s*=\s*(-?\d+)', s)
    if mm:
        idx = int(mm.group(1)); lat[idx] = int(mm.group(2)); off[idx] = int(mm.group(3))
# map ADC index: tile224=0, tile226=2
print('parsed latency:', lat, ' offset:', off)
want = [0, 2]
missing = [i for i in want if i not in lat]
if missing: die('no latency parsed for ADC tile(s) %s -- inspect raw report above (0x200 NOT_ENABLED? 0x800 GATE? 0x1000 FREQ_NDONE?)' % missing)
lvals = [lat[i] for i in want]
print('Latency[224]=%d  Latency[226]=%d  Offset[224]=%d  Offset[226]=%d' % (lat[0], lat[2], off[0], off[2]))
if lvals[0] == lvals[1]:
    print('PASS: equal latency across tile224 & tile226 (MTS aligned). Now run mts_verify.py to prove sample-alignment.')
else:
    die('UNEQUAL latency (%d vs %d) -- MTS did NOT align; re-power-cycle and retry, check AXIS clk = PL clk not clk_adcN' % (lvals[0], lvals[1]))
