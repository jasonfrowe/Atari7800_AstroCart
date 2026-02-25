import sys

with open("top.v", "r") as f:
    lines = f.readlines()

out = []
skip = False
for i, line in enumerate(lines):
    if "reg [7:0] latch_p4 = 0; // V71: Added" in line:
        pass # Remove this line
    elif "if (active_req_source == 3'd4) latch_p4 <= psram_dout_16[7:0];" in line:
        pass # Remove this line
    elif "always @* write_pending = write_pending_loader;" in line:
        out.append(line)
        # There's an extra "end" after this line
        skip = True
    elif skip and "end" in line.strip() and len(line.strip()) == 3:
        skip = False # Found the extra end, remove it
    elif skip:
        out.append(line) # It wasn't the end, keep it
    else:
        out.append(line)

with open("top.v", "w") as f:
    f.writelines(out)
print("Patched errors successfully")
