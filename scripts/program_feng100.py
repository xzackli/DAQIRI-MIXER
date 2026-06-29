#!/usr/bin/env python3
"""Program + smoke-test the feng100 PFB+100GbE F-engine on the RFSoC 4x2.

Run ON acme2 with the casper conda python:
    ~/miniconda3/envs/casper/bin/python program_feng100.py <FPG> [--board 192.168.2.101]

Programs the .fpg, confirms the design is alive (sys clk ticking), preloads the
100GbE ARP for the CX-5 capture NIC, and reports the tx packet counter climbing —
i.e. the F-engine is channelizing real ADC data and the CMAC is emitting packets.
Downstream capture/correlation is rx_ula_corr on digilab-transmit (already deployed).

Based on the proven bring-up runbook (memory: rfsoc-4x2-casper-ingest,
daqiri-rfsoc-hw-validation). casperfpga gotchas handled: always pass the FPG to
get_system_information (py3 bytes bug otherwise); gbes/adcs are objects not names.
"""
import sys, time, argparse

CX5_MAC = 0xb8cef6e56b5a   # digilab-transmit CX-5 port0 (ens5f0np0) — board must unicast here
CAP_IP  = "10.0.0.2"       # ARP entry lands at cache index = last octet (2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fpg")
    ap.add_argument("--board", default="192.168.2.101")
    ap.add_argument("--no-arp", action="store_true", help="skip ARP preload")
    a = ap.parse_args()

    import casperfpga
    print(f"[*] connecting {a.board}")
    f = casperfpga.CasperFpga(a.board)
    print(f"[*] programming {a.fpg}")
    f.upload_to_ram_and_program(a.fpg)
    f.get_system_information(a.fpg)        # MUST pass fpg (py3 bytes bug otherwise)

    regs = f.listdev()
    print(f"[*] {len(regs)} registers; F-engine/gbe regs present:")
    for key in ("sys_clkcounter", "acc_len", "acc_cnt", "sync_cnt", "cnt_rst",
                "fft_shift", "gain", "adc_chan_sel"):
        hits = [r for r in regs if key in r]
        if hits:
            print(f"    {key:16} -> {hits[:4]}")

    # alive check: sys clock ticking
    c0 = f.read_uint("sys_clkcounter"); time.sleep(1.0)
    c1 = f.read_uint("sys_clkcounter")
    print(f"[*] sys_clkcounter {c0} -> {c1}  ({'TICKING ~%.1f MHz' % ((c1-c0)/1e6) if c1!=c0 else 'STALLED!'})")

    # 100GbE: preload ARP so the board unicasts to the CX-5 (else it broadcasts -> 0 captured)
    try:
        eth = list(f.gbes)[0]
        print(f"[*] gbe = {eth.name}")
        if not a.no_arp:
            eth.set_single_arp_entry(CAP_IP, CX5_MAC)
            print(f"[*] ARP preloaded {CAP_IP} -> {CX5_MAC:012x}")
    except Exception as e:
        print(f"[!] gbe/ARP step failed (board may need power-cycle if AXI wedged): {e}")

    # tx packet counter climbing => packetizer emitting
    txregs = [r for r in regs if "tx_packet_count" in r or "tx_pkt" in r]
    if txregs:
        p0 = f.read_uint(txregs[0]); time.sleep(1.0); p1 = f.read_uint(txregs[0])
        print(f"[*] {txregs[0]} {p0} -> {p1}  ({'EMITTING' if p1>p0 else 'no packets (check sync/valid)'})")
    print("[*] done. capture on digilab-transmit: rx_ula_corr (sm_86) + peek_ula.")


if __name__ == "__main__":
    main()
