#!/usr/bin/env python3
import sys, os, glob

def dump_a78(path):
    with open(path, 'rb') as f:
        data = f.read()
    h = data[:128]
    rom = data[128:]
    print(f"\n=== {os.path.basename(path)} ===")
    print(f"  Total: {len(data)} bytes, ROM payload: {len(rom)} bytes ({len(rom)//1024}KB)")
    print(f"  h[0]  version : {hex(h[0])}")
    print(f"  h[17..48] title: {h[17:49].decode('ascii','replace').strip(chr(0))}")
    size_be = int.from_bytes(h[49:53], 'big')
    print(f"  h[49..52] size : {[hex(x) for x in h[49:53]]} = {size_be} bytes ({size_be//1024}KB)")
    print(f"  h[53] flags_hi: {bin(h[53])} = {hex(h[53])}")
    print(f"  h[54] flags_lo: {bin(h[54])} = {hex(h[54])}")
    print(f"  h[64] mapper  : {hex(h[64])}")
    print(f"  h[65] opts    : {hex(h[65])} = {bin(h[65])}")
    print(f"  h[66]         : {hex(h[66])}")
    print(f"  h[67] audio   : {hex(h[67])} = {bin(h[67])}")

    # Analyse ROM: check reset vector in last bank (0x3C000..0x3FFFF in PSRAM = last 16KB of ROM)
    if len(rom) >= 16384:
        last_bank = rom[-16384:]
        reset_lo = last_bank[0x3FFC - 0xC000]
        reset_hi = last_bank[0x3FFD - 0xC000]
        print(f"  Reset vector  : ${reset_hi:02X}{reset_lo:02X} (from last 16KB, offset $3FFC-$3FFD)")
        # Show first bytes of each 16KB bank
        num_banks = len(rom) // 16384
        print(f"  Banks         : {num_banks}")
        for b in range(min(num_banks, 16)):
            first4 = rom[b*16384:b*16384+4]
            print(f"    Bank {b:2d}  PSRAM 0x{b*0x4000:05X}: first bytes {[hex(x) for x in first4]}")

for path in sorted(glob.glob('/Users/rowe/Software/FPGA/Atari7800_AstroCart/**/*.a78', recursive=True)):
    dump_a78(path)
