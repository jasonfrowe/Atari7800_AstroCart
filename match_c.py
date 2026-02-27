with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
total = sum(payload)
print(f"Total checksum = {hex(total)}")

target = 0x00D3973D
print(f"Target checksum = {hex(target)}")

# It shouldn't be possible for the FPGA checksum to be LARGER than the true
# payload checksum... unless it added something extra!
# Notice Target - Total = 0x00D3973D - 0x003D973D
# Wait. 0x00D3973D and 0x003D973D.
# That is exactly 0x960000 bytes larger! 

# Let's verify what FPGA checksum accumulator does:
# checksum <= checksum + sd_dout_reg;
# Ah! I know exactly what it is!
