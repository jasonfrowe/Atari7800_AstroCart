# Save as rom_gen.py
import sys

# Usage: python rom_gen.py choplifter.bin
input_file = sys.argv[1]
output_file = "game.hex"

with open(input_file, "rb") as f:
    data = f.read()

# Check size
if len(data) != 49152:
    print(f"Warning: ROM size is {len(data)} bytes. Expected 49152 (48KB).")

# Write Hex format for Verilog $readmemh
with open(output_file, "w") as f:
    for byte in data:
        f.write(f"{byte:02x}\n")

print(f"Converted {input_file} to {output_file} successfully.")