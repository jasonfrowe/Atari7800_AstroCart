with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
print("Full Payload Sum:", hex(sum(payload)))

target_p0 = 0x003C7D58
print("Target P0:", hex(target_p0))
print("Diff:", hex(sum(payload) - target_p0))

# Try dropping front/back combinations to find P0
total = sum(payload)
for front in range(0, 1024):
    for back in range(0, 1024):
        if total - sum(payload[:front]) - sum(payload[len(payload)-back:]) == target_p0:
            print(f"Match! Dropped front {front} and back {back}")

