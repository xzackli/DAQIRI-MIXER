import casperfpga, time
FPG='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe/manas256/outputs/manas256_2026-06-27_0944.fpg'
f=casperfpga.CasperFpga('192.168.2.101', timeout=12)
print('connected=', f.is_connected())
for attempt in range(3):
    try:
        f.upload_to_ram_and_program(FPG); f.get_system_information(FPG)
        print('PROGRAMMED manas256 OK (attempt %d); listdev=%d regs'%(attempt+1,len(f.listdev())))
        break
    except Exception as e:
        print('attempt %d: %s'%(attempt+1,str(e)[:70])); time.sleep(8)
