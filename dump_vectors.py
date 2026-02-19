import sys

def dump_tail(filename, count=64):
    try:
        with open(filename, 'rb') as f:
            f.seek(0, 2) # Seek to end
            size = f.tell()
            f.seek(max(0, size - count))
            data = f.read()
            
        print(f"File: {filename}")
        print(f"Total Size: {size}")
        print(f"Last {len(data)} bytes:")
        
        # Print hex dump
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            hex_str = ' '.join(f"{b:02X}" for b in chunk)
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
            offset = size - len(data) + i
            print(f"{offset:06X}: {hex_str:<48} | {ascii_str}")
            
    except FileNotFoundError:
        print(f"File not found: {filename}")

if __name__ == "__main__":
    dump_tail("astrowing.a78")
