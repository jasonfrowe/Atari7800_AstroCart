with open("astrowing.a78", "rb") as f:
    data = f.read()[128:]
checksum = sum(data)
print(f"Checksum: {checksum:08X}")
