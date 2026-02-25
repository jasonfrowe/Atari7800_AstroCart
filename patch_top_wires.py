import sys

with open("top.v", "r") as f:
    lines = f.readlines()

out = []
for i, line in enumerate(lines):
    if "reg [31:0] checksum;" in line:
        replacement = """
    // Diagnostics Wires from Cart Loader
    wire [9:0] byte_index;
    wire [6:0] current_sector;
    wire [7:0] last_byte_captured;
    wire [31:0] checksum;
    wire [31:0] psram_checksum;
    wire [22:0] crc_address;
    wire crc_scan_req;
    
    wire [31:0] latch_p2;
    wire [31:0] latch_p3;
    wire [31:0] latch_p4 = {24'b0, psram_write_addr_latched[15:8]}; // P4 is mid address
    wire [7:0]  latch_p5;
    wire [7:0]  latch_p6;
    wire [31:0] latch_p7;
    
    wire [7:0] first_bytes_0;
    wire [7:0] first_bytes_1;
    wire [7:0] first_bytes_2;
    wire [7:0] first_bytes_3;
    
    wire game_loaded;
    wire switch_pending;
"""
        out.append(replacement)
    elif "fb0(first_bytes[0])" in line:
        out.append("        .fb0(first_bytes_0),\n")
    elif "fb1(first_bytes[1])" in line:
        out.append("        .fb1(first_bytes_1),\n")
    elif "fb2(first_bytes[2])" in line:
        out.append("        .fb2(first_bytes_2),\n")
    elif "fb3(first_bytes[3])" in line:
        out.append("        .fb3(first_bytes_3),\n")
    elif "reg [31:0] latch_p2" in line or "reg [31:0] latch_p3" in line or "reg [31:0] latch_p4" in line or "reg [7:0] latch_p5" in line or "reg [7:0] latch_p6" in line or "reg [31:0] latch_p7" in line:
        # Delete old latch regs
        pass
    else:
        out.append(line)

with open("top.v", "w") as f:
    f.writelines(out)
print("Patched wires successfully")
