target = 0x00D3973D
true_val = 0x003D973D
diff = target - true_val

print("Diff:", hex(diff), "Decimal:", diff)
print("Diff / 49152:", diff / 49152)

# If diff / 49152 = 200...
# Wait! 200 is 0xC8. What is 0xC8?
# P0 jumped from 3B5 to 3C7D58! 
# Let's check 3C7D58 - 3B5
p0 = 0x003C7D58
p0_start = 0x03B5
p0_diff = p0 - p0_start
print("P0_diff:", hex(p0_diff), "Decimal:", p0_diff)
print("P0_diff / 49152:", p0_diff / 49152)
# P0_diff / 49152 = 80 (0x50)

