import sys

def find_all(filename, target_seq):
    with open(filename, 'rb') as f:
        data = f.read()
    
    count = 0
    idx = 0
    while True:
        idx = data.find(bytes(target_seq), idx)
        if idx == -1: break
        print(f"Found at offset: {hex(idx)} ({idx} bytes)")
        idx += 1
        count += 1
    print(f"Total occurrences: {count}")

print("Searching for P2 (25 A9 00 8D):")
find_all('astrowing.a78', [0x25, 0xa9, 0x00, 0x8d])

print("\nSearching for P3 (AB 25 A9 00):")
find_all('astrowing.a78', [0xab, 0x25, 0xa9, 0x00])

