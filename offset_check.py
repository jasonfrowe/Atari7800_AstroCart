with open("astrowing.a78", "rb") as f:
    data = f.read()

idx = data.find(b'\xa9\x50\x85\x3c')
print(f"Original A9 50 85 3C found at byte index: {idx}")

