# Let's map out exactly what is going into the IP to find the 24-byte shift.
psram_load_addr = 0
for i in range(32): # 32 bytes = 2 burst writes
    word_sel = (psram_load_addr >> 2) & 3
    byte_sel = psram_load_addr & 3
    print(f"Byte {i:2d} -> Word {word_sel} Byte {byte_sel}")
    psram_load_addr += 1
