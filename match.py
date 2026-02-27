with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
target = 0x003B99CE
total = sum(payload)

# Using moving sums for O(N) complexity
prefix_sums = [0] * (len(payload) + 1)
for i in range(len(payload)):
    prefix_sums[i+1] = prefix_sums[i] + payload[i]

def get_sum(start, end):
    if end <= start: return 0
    return prefix_sums[end] - prefix_sums[start]

for start_drop in range(0, min(1024, len(payload))):
    for chunk_len in range(128, 2048):
        s = total - get_sum(start_drop, start_drop + chunk_len)
        if s == target:
            print(f"Match 1! Dropped {chunk_len} bytes starting at {start_drop}")

# What if two chunks are dropped? (e.g., sector 0 and sector N)
for drop1 in [384, 512, 1024]:
    # Sector 0 is size 384
    s1 = total - get_sum(0, drop1)
    if s1 == target:
        print(f"Match 2! Dropped {drop1} bytes at front.")
    # Maybe front AND some other block?
    for drop2_start in range(drop1, len(payload)):
        for drop2_len in [384, 512, 1024]:
            if drop2_start + drop2_len <= len(payload):
                s2 = s1 - get_sum(drop2_start, drop2_start + drop2_len)
                if s2 == target:
                    print(f"Match 3! Dropped front {drop1} AND middle {drop2_len} at {drop2_start}")

# Check missing a single byte payload shift
for drop in range(0, 1024):
    s = total - payload[drop]
    if s == target:
         print(f"Match 4! Dropped single byte {drop}")
         
print("Done")
