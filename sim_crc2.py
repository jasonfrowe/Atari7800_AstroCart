import os

with open('astrowing.bin', 'rb') as f:
    data = bytearray(f.read())
data.extend(b'\x00' * (98304 - len(data)))

checksum = 0
crc_address = 0

# Simulating exactly what top.v lines 1107-1135 do to the IP:
# crc_address increments by 16 words (32 bytes) per loop.
# loop terminates at crc_address >= 0x00BFF0 (49136 words = 98272 bytes)

while crc_address <= 0x00BFF0: # Actually logic is: if (crc_address < 23'h00BFF0)
    byte_addr = crc_address * 2
    
    # 3 cycles fetched into accumulator (due to == 3 state break before 4th)
    for i in range(3): 
        word = data[byte_addr + i*4 : byte_addr + i*4 + 4]
        for b in word:
            checksum += b
            
    # And then top.v does:
    crc_address += 16

print(f'{checksum:08X}')
