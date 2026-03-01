#!/usr/bin/env python3
"""Timing analysis and menu ROM audit for AstroCart."""

import os

# -------------------------------------------------------------------
# 1. PSRAM timing vs Maria DMA
# -------------------------------------------------------------------
sys_clk = 81e6
cycle_ns = 1e9 / sys_clk

# psram_controller.v: cycles_sr starts at bit1, READ_ST sets wait_for_rd_data
# at cycles_sr[9].  With LATENCY=3 the HyperRAM clock DDR output means
# tACC = LATENCY / (clk/2) = 3 / 40.5MHz = 74ns, plus the CA phase.
# Empirical from the shift register: data ready around cycle ~10-12.
psram_cycles = 12
psram_ns = psram_cycles * cycle_ns

# Maria DMA: NTSC pixel clock = 7.16MHz * 2 colour clocks = 14.32MHz
# Each pixel = 69.8ns.  Maria fetches one byte per 4 colour clocks = 279ns
# (based on 7800 hardware manual: each DMA read takes 4 colour clocks)
pixel_ns = 1e9 / 14.32e6
maria_dma_hold_ns = 4 * pixel_ns

# a_stable glitch filter adds 2 sys_clk cycles
glitch_ns = 2 * cycle_ns

pipeline_ns = glitch_ns + psram_ns

print("=" * 60)
print("PSRAM vs Maria timing budget")
print("=" * 60)
print(f"  sys_clk period      : {cycle_ns:.1f} ns")
print(f"  PSRAM read latency  : {psram_cycles} cycles = {psram_ns:.0f} ns")
print(f"  a_stable glitch flt : 2 cycles   = {glitch_ns:.0f} ns")
print(f"  Total pipeline      :             = {pipeline_ns:.0f} ns")
print(f"  Maria DMA hold time : 4 colour clocks = {maria_dma_hold_ns:.0f} ns")
margin = maria_dma_hold_ns - pipeline_ns
print(f"  Margin              : {margin:.0f} ns  {'✓ SAFE' if margin > 0 else '✗ PROBLEM'}")
print()
print("  CPU cycle = {:.0f} ns — no constraint. PSRAM is fine for CPU reads.".format(1e9/1.79e6))
print()
print("  VERDICT: PSRAM is NOT the bottleneck.")
print("  Same PSRAM works for Astro Wing; issue must be in bank-switch logic.")

# -------------------------------------------------------------------
# 2. Menu ROM audit
# -------------------------------------------------------------------
print()
print("=" * 60)
print("Menu ROM audit")
print("=" * 60)

menu_path = "menu/menu.bas.a78"
with open(menu_path, 'rb') as f:
    data = f.read()

has_header = data[1:10] == b'ATARI7800'
if has_header:
    rom = data[128:]
    size_be = int.from_bytes(data[49:53], 'big')
    flags = (data[53] << 8) | data[54]
    print(f"  File         : {menu_path}")
    print(f"  Has header   : yes")
    print(f"  Declared size: {size_be} bytes ({size_be//1024} KB)")
    print(f"  ROM payload  : {len(rom)} bytes ({len(rom)//1024} KB)")
    print(f"  Cardtype     : {hex(flags)} (bit1={'SG' if flags&2 else 'no'})")
else:
    rom = data
    size_be = len(rom)
    print(f"  File         : {menu_path}  (no header)")
    print(f"  ROM size     : {len(rom)} bytes ({len(rom)//1024} KB)")

# Find actual used region (last non-pad byte)
used_end = 0
for i in range(len(rom) - 1, -1, -1):
    if rom[i] not in (0x00, 0xFF):
        used_end = i
        break
# rom is placed at end of 48KB window: base = 0xFFFF - 48KB + 1 = 0x4000
# The standard loader does: psram_load_addr = 49152 - size_be
# So the rom is loaded starting at PSRAM offset (49152 - size_be)
# and ends at PSRAM offset 49151.
rom_start_ofs = 49152 - size_be
rom_end_ofs   = 49151

print(f"  Loaded into rom_memory at offsets {hex(rom_start_ofs)}..{hex(49151)}")
print(f"  = CPU addresses ${0x4000+rom_start_ofs:04X}..${0xFFFF:04X}")
print()
print(f"  Last non-padding byte at rom offset: {hex(used_end)}")
print(f"  Dead trailing padding  : {len(rom) - 1 - used_end} bytes")
print(f"  Effective used payload : {used_end + 1} bytes ({(used_end+1)//1024} KB)")

# rom_memory is always declared [0:49151] = 48KB regardless of game size.
# The BSRAM usage comes from the rom_memory array declaration.
# GW1NR-9C BSRAM: 26 blocks.  Each block is a True Dual Port 9Kbit BRAM.
# Configured as 8-bit wide: 9Kbits = 9*1024/8 ~ 1152 bytes (rounded to 1K)
# But Gowin typically reports 1 BSRAM = stores 1Kx9 = 1024 8-bit words.
# The synthesizer groups the 49152-byte array into ceil(49152/1024) = 48 blocks,
# but since only 26 are available, the rest spill to LUT/distributed RAM.
# With 24/26 BSRAMs used = 24KB in BSRAM, the other ~25KB uses LUT RAM.
bsram_words = 1024  # effective words per BSRAM block (8-bit)
bsram_total_bytes = 26 * bsram_words
bsram_used = 24 * bsram_words
print()
print("BSRAM layout (GW1NR-9C):")
print(f"  Total: 26 blocks × ~1KB = {bsram_total_bytes//1024} KB")
print(f"  Used : 24/26 blocks     = {bsram_used//1024} KB")
print(f"  Free : 2 blocks         = {2*bsram_words} bytes — NOT enough for a useful cache")
print()

# What if we shrink rom_memory to actual needed size?
if used_end + 1 < size_be:
    needed_kb = (used_end + 1 + 1023) // 1024
    saved_kb = size_be // 1024 - needed_kb
    saved_blocks = saved_kb  # ~1 block per KB
    print(f"  If menu shrunk to {needed_kb}KB:")
    print(f"    Would save ~{saved_kb}KB = ~{saved_blocks} BSRAM blocks")
    print(f"    Still not enough for a 16KB bank cache ({16 - saved_blocks} blocks short)")
else:
    print("  Menu is fully packed — no dead space to trim.")
