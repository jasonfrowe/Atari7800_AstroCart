with open('astrowing.a78', 'rb') as f:
    data = f.read()

payload = data[128:]
print("Total Expected:", hex(sum(payload)))

for start_sector in range(10):
    for skip in range(0, 513):
        # build a checksum assuming some bytes were dropped
        # let's try dropping the first 512 bytes
        s = sum(payload[512:])
        if s == 0x003B99CE: print("Exactly matches Payload starting at 512")
        
        # what if we missed block 1 AND something else?
