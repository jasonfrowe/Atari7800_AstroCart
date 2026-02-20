with open("astrowing.a78", "rb") as f:
    data = bytearray(f.read())
    
print(f"File size: {len(data)}")

# SD Loader Logic:
# Skips first 128 bytes.
# Loads exactly 97 sectors (0 to 96) of 512 bytes = 49664.
# Payload = 49664 - 128 = 49536 bytes.
# Wait, SD Loader logic skips 128 bytes, but STILL loads 97 sectors.
# Does it append 128 bytes of junk at the end? Yes.
payload_len = 49664 - 128
payload = data[128:128+payload_len]

print(f"SD Payload extracted: {len(payload)} bytes")

# SD Checksum is a simple 32-bit arithmetic sum of bytes
sd_checksum = 0
for b in payload:
    sd_checksum = (sd_checksum + b) & 0xFFFFFFFF
    
print(f"SD Checksum (97 Sectors payload): {hex(sd_checksum)}")

# PSRAM Checksum logic:
# Sweeps from 0x000000 to 0x00BFF0 (49136 bytes)
# Reads 4 words per burst. Ends at 49152 bytes.
psram_checksum = 0
for i in range(49152):
    psram_checksum = (psram_checksum + payload[i]) & 0xFFFFFFFF
    
print(f"PSRAM Checksum (48KB bound): {hex(psram_checksum)}")

