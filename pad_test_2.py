with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
print("Actual sum of full Payload:", hex(sum(payload)))

target_c = 0x00D3973D
print("Target C:", hex(target_c))
print("Difference:", hex(target_c - sum(payload)))

# Wait, the target is LARGER than the true payload checksum by 0x960000!
