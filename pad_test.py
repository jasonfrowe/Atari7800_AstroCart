with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
total = sum(payload)

# If Sector 0 was 128 bytes header + 384 bytes pad
# And the FPGA skipped 128 bytes, then wrote 384 bytes of zero pad to PSRAM[0:384]
# Then Sector 1 (which is payload[0:512]) was written to PSRAM[384:896]
# Total bytes read is 96 payload sectors * 512 = 49152 bytes.
# Wait, cart_loader reads 97 sectors total.
# Sector 0: 384 zeros written to PSRAM
# Sector 1..96: 96 * 512 = 49152 bytes written.
# Total PSRAM written: 49536 bytes.
# But PSRAM CRC only scans the first 48K (49152 bytes) of PSRAM! 
# So it scans: 384 zeros + payload[0:48768].
# Let's calculate the sum of payload[0:48768] !

psram_sum = sum(payload[0:48768])
print("Sum of shifted payload:", hex(psram_sum))

# And what is C?
# C is the `checksum` accumulator in cart_loader.
# It sums the 384 zeros of Sector 0.
# Then it sums all 512 bytes of Sector 1 to 96.
# Total C = sum(payload[0:49152]) ? Wait.
# If cart_loader reads Sector 0..96, that is 97 sectors.
# Is C accumulating Sector 1..96?
loader_sum = sum(payload)
print("Loader sum:", hex(loader_sum))

