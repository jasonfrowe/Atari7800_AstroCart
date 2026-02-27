with open("astrowing.a78", "rb") as f:
    d = f.read()

payload = d[128:]
total = sum(payload)

target_C = 0x003CC18F
target_P0 = 0x003B99CE

def find_match(target, name):
    print(f"Finding match for {name}: {hex(target)}")
    for start_drop in range(0, 2048):
        for drop_len in range(128, 2048):
            s = total - sum(payload[start_drop:start_drop+drop_len])
            if s == target:
                print(f"  {name} Match! Dropped contiguous {drop_len} bytes from payload offset {start_drop}")
                
    # Check front/back drops
    for front in [384, 512, 511]:
        s1 = total - sum(payload[:front])
        if s1 == target:
            print(f"  {name} Match! Dropped front {front} bytes")
        # And back
        for back in range(1, 1024):
            s2 = s1 - sum(payload[-back:])
            if s2 == target:
                print(f"  {name} Match! Dropped front {front} and back {back} bytes")

find_match(target_C, "C")
find_match(target_P0, "P0")

