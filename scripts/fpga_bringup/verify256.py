import casperfpga, time, struct
f=casperfpga.CasperFpga('192.168.2.101')
FPG='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas256/outputs/manas256_2026-06-27_0944.fpg'
print('programming manas256...'); f.upload_to_ram_and_program(FPG); f.get_system_information(FPG)
rfdc=f.adcs['rfdc']; rfdc.init()
st=rfdc.status(); print('rfdc ADC0=%s ADC2=%s'%(st['ADC0'],st['ADC2']))
f.write_int('fft_shift',0xffff); f.write_int('acc_len',16384)
f.write_int('cnt_rst',1); f.write_int('cnt_rst',0); time.sleep(0.3)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(2)
a1=f.read_uint('acc_cnt'); time.sleep(0.5); a2=f.read_uint('acc_cnt'); print('acc_cnt %d->%d (accumulating=%s)'%(a1,a2,a2!=a1))
# read 256-bin spectrum: q1/q2 = 128 bins each now
def rc(nm,total,ch=8192):
    b=b'';o=0
    while o<total: s=min(ch,total-o); b+=f.read(nm,s,o); o+=s
    return b
NB=128
q1=struct.unpack('>%dQ'%NB, rc('q1',NB*8)); q2=struct.unpack('>%dQ'%NB, rc('q2',NB*8))
spec=[]
for i in range(NB): spec+=[q1[i],q2[i]]
N=len(spec); mx=max(spec); mxb=spec.index(mx); nz=sum(1 for x in spec if x>0)
print('SPECTRUM(256ch): %d bins, max=%d @bin%d, DC=%d, nonzero=%d/%d'%(N,mx,mxb,spec[0],nz,N))
with open('/home/zackli/manas256_spec.txt','w') as fh:
    for x in spec: fh.write('%d\n'%x)
# eth bring-up + tx rate
f.write_int('eth_rst',1); f.write_int('est_rst_sync',1)
f.write_int('dest_ip',(10<<24)|2); f.write_int('dest_port',4096)
g=f.gbes['onehundred_gbe']; g.configure_core((2<<40)+(2<<32)+1,'10.0.0.1',4096); g.set_single_arp_entry('10.0.0.2',0xb8cef6e56b5a)
f.write_int('eth_rst',0); f.write_int('eth_en',1); f.write_int('est_rst_sync',0)
f.write_int('sync',1); time.sleep(0.05); f.write_int('sync',0); time.sleep(1)
t1=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count'); time.sleep(2); t2=f.read_uint('onehundred_gbe_gmac_reg_tx_packet_count')
print('BOARD TX: %.0f pps'%((t2-t1)/2.0))
