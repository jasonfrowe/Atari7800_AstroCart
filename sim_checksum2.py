import sys

def calc():
    with open('astrowing.bin', 'rb') as f:
        data_bin = f.read()
    with open('astrowing.a78', 'rb') as f:
        data_a78 = f.read()

    print(f"astrowing.bin raw sum: {sum(data_bin):08X}")
    print(f"astrowing.bin skip 128 sum: {sum(data_bin[128:]):08X}")
    print(f"astrowing.a78 raw sum: {sum(data_a78):08X}")
    print(f"astrowing.a78 skip 128 sum: {sum(data_a78[128:]):08X}")

calc()
