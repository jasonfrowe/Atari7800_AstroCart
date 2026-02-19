import sys

def calculate_sum(filename, skip_header=0):
    try:
        with open(filename, 'rb') as f:
            data = f.read()
            
        if skip_header > 0:
            print(f"Skipping {skip_header} bytes header for {filename}")
            processing_data = data[skip_header:]
        else:
            processing_data = data
            
        total_sum = sum(processing_data)
        print(f"File: {filename}")
        print(f"Total Bytes: {len(data)}")
        print(f"Sum (Hex): {total_sum:08X}")
        print(f"Sum (Dec): {total_sum}")
        return total_sum
    except FileNotFoundError:
        print(f"File not found: {filename}")
        return None

if __name__ == "__main__":
    # Check astrowing.a78 (Standard A78 file, usually has 128 byte header)
    calculate_sum("astrowing.a78", skip_header=128)
    print("-" * 20)
    # Check astrowing.bin (Raw binary, usually no header)
    # But if the FPGA skips 128 bytes, maybe we should check what happens if we treat it as A78?
    calculate_sum("astrowing.bin", skip_header=0)
