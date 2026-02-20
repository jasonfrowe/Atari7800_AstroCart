import os

target_sum = 0x0037D400

for filename in ['astrowing.a78', 'astrowing.bin', 'menu/menu.bas', 'menu/menu.a78']:
    if not os.path.exists(filename): continue
    with open(filename, 'rb') as f:
        data = f.read()
    
    # What if it summed ALL bytes without dropping?
    total = sum(data)
    print(f"{filename} total sum: {total} ({hex(total)})")
    
    # What if it sums 48KB but it's partially zero?
    
