import casperfpga, time
FPG='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas256/outputs/manas256_2026-06-27_0944.fpg'
f=casperfpga.CasperFpga('192.168.2.101', timeout=10)
try:
    n=len(f.listdev()); print('daemon OK, listdev=%d (board still programmed)'%n)
except Exception as e:
    print('WEDGED again:', str(e)[:50]); raise SystemExit('needs tcpborphserver restart')
f.get_system_information(FPG)  # load regmap from file, NO reprogram
f.write_int('fft_shift',0xffff); f.write_int('acc_len',1024)
f.write_int('cnt_rst',1); f.write_int('cnt_rst',0); time.sleep(0.3)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(1)
f.write_int('eth_rst',1); f.write_int('est_rst_sync',1); f.write_int('dest_ip',(10<<24)|2); f.write_int('dest_port',4096)
g=f.gbes['onehundred_gbe']; g.configure_core((2<<40)+(2<<32)+1,'10.0.0.1',4096); g.set_single_arp_entry('10.0.0.2',0xb8cef6e56b5a)
f.write_int('eth_rst',0); f.write_int('eth_en',1); f.write_int('est_rst_sync',0)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(1)
t1=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count'); time.sleep(2); t2=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count')
print('BOARD TX: %.0f pps (manas256 working, recovered)'%((t2-t1)/2.0))
