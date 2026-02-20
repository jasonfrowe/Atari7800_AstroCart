import sys

def find_seq(filename, target_seq):
    with open(filename, 'rb') as f:
        data = f.read()
    
    idx = data.find(bytes(target_seq))
    if idx != -1:
        print(f"Found sequence at offset: {hex(idx)} ({idx} bytes)")
        print("Sequence context:")
        start = max(0, idx - 16)
        end = min(len(data), idx + 32)
        print(data[start:end].hex(' '))
    else:
        print("Sequence not found")

# P7 reversed: 25 A9 00 8D
# P2 reversed: AB 25 A9 00 (AB might be a typo for AC)
# Let's just search for the 4 bytes of P7: 25 a9 00 8d
target = [0x25, 0xa9, 0x00, 0x8d]
find_seq('astrowing.a78', target)

# Also try searching for P3 reversed: 3C 8D 4D 25
target2 = [0x3c, 0x8d, 0x4d, 0x25]
find_seq('astrowing.a78', target2)

