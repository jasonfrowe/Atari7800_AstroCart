import sys

def simulate_psram():
    with open('astrowing.bin', 'rb') as f:
        data = f.read()

    # Total SD sum
    print(f"SD Total: {sum(data):08X}")
    
    # 1. Simulate what is written to PSRAM if ip_cmd_addr shifts by 16 bytes but SD provides 16 bytes
    # Wait, the SD loader writes every 16 bytes of payload.
    # At payload = 0 (byte 0), it writes chunk 0 to psram_load_addr = 0x400F & ~0xF = 0x4000.
    # At payload = 16 (byte 16), it writes chunk 1 to psram_load_addr = 0x401F & ~0xF = 0x4010.
    
    # If the PSRAM IP drops the lower 4 bits of the address? No, the PSRAM IP takes the 21-bit address.
    # If PSRAM IP is WORD-addressed, then address 0x4000 means word 0x4000 (byte 0x10000).
    # Address 0x4010 means word 0x4010 (byte 0x10040).
    #
    # Then during CRC sweep, we sweep from 0x4000 to 0x10000 by 16 bytes each
    crc_addr = 0x4000
    psram_sum = 0
    while crc_addr < 0x10000:
        # At crc_addr, what chunk was written?
        # The chunk written to this address was payload chunk corresponding to (crc_addr - 0x4000).
        offset = crc_addr - 0x4000
        if offset < len(data):
            chunk = data[offset:offset+16]
            psram_sum += sum(chunk)
        crc_addr += 16
        
    print(f"PSRAM Sum (Perfect match): {psram_sum:08X}")
    
    # What if SD loader wrote 4 bytes to `0x4000`, wait.. P7 captured 0x00A925AB.
    # Where does 0x00A925AB appear in the file?
    for i in range(len(data)-3):
        if data[i:i+4] == bytes([0xAB, 0x25, 0xA9, 0x00]):
            print(f"Found AB 25 A9 00 at file offset: 0x{i:04X}")

    for i in range(len(data)-3):
        if data[i:i+4] == bytes([0x00, 0xA9, 0x25, 0xAB]):
            print(f"Found 00 A9 25 AB at file offset: 0x{i:04X}")

simulate_psram()
