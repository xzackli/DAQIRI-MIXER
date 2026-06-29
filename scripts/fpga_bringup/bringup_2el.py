import casperfpga, time, glob
# manas2el bring-up with test_mode=1 RAMP into element 0 (DPRAM1).
# Run on acme2 AFTER manas2el is built. Programs the board ONCE (daemon tolerates one
# program/session -- restart tcpborphserver first if wedged; see memory BOARD RECOVERY).
FPG=sorted(glob.glob('/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas2el/outputs/manas2el_*.fpg'))[-1]
print('FPG=',FPG)
f=casperfpga.CasperFpga('192.168.2.101', timeout=12)
for a in range(2):
    try: f.upload_to_ram_and_program(FPG); f.get_system_information(FPG); print('PROGRAMMED (attempt %d)'%(a+1)); break
    except Exception as e: print('attempt',a+1,str(e)[:60]); time.sleep(8)

# *** test_mode=1 => Counter7 ramp replaces element-0 FFT; element-1 stays real(~0) ***
f.write_int('test_mode',1)
f.write_int('fft_shift',0xffff); f.write_int('acc_len',1024)
f.write_int('cnt_rst',1); f.write_int('cnt_rst',0); time.sleep(0.3)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(1)
f.write_int('eth_rst',1); f.write_int('est_rst_sync',1)
f.write_int('dest_ip',(10<<24)|2); f.write_int('dest_port',4096)
g=f.gbes['onehundred_gbe']
g.configure_core((2<<40)+(2<<32)+1,'10.0.0.1',4096)
g.set_single_arp_entry('10.0.0.2',0xb8cef6e56b5a)   # CX-5 ens5f0np0
f.write_int('eth_rst',0); f.write_int('eth_en',1); f.write_int('est_rst_sync',0)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(1)
print('test_mode=',f.read_uint('test_mode'))
t1=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count'); time.sleep(3)
t2=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count')
pps=((t2-t1)&0xffffffff)/3.0
print('BOARD TX: %.0f pps (manas2el test_mode ramp).'%pps)
print('  expect ~30-35k pps: dense (~67k for 1-elem) HALVED again by the 2-element alternation.')
print('  if pps jumps to ~1M+ => framing-in-wrong-domain bug (manas256d-class), STOP.')
