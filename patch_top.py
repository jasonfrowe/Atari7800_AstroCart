import sys

with open("top.v", "r") as f:
    lines = f.readlines()

start_idx = -1
end_idx = -1

for i, line in enumerate(lines):
    if "function [7:0] to_hex_ascii" in line:
        start_idx = i
    if "else if (rom_index < 49152)" in line:
        end_idx = i
        break

if start_idx != -1 and end_idx != -1:
    replacement = """    wire [7:0] diag_data_out;
    diag_rom diag_inst (
        .a_stable(a_stable),
        .sd_state(sd_state),
        .byte_index(byte_index),
        .current_sector(current_sector),
        .last_byte_captured(last_byte_captured),
        .checksum(checksum),
        .psram_checksum(psram_checksum),
        .latch_p2(latch_p2),
        .latch_p3(latch_p3),
        .latch_p4(latch_p4),
        .latch_p5(latch_p5),
        .latch_p6(latch_p6),
        .latch_p7(latch_p7),
        .fb0(first_bytes[0]),
        .fb1(first_bytes[1]),
        .fb2(first_bytes[2]),
        .fb3(first_bytes[3]),
        .data_out(diag_data_out)
    );

    // ROM Fetch / PSRAM Read / Status Read
    always @(posedge sys_clk) begin
        if (game_loaded) begin
             // [OPTIMIZATION] Fast Data Capture: Bypass synced latch entirely
             // Data connects directly combinationally to the FPGA pins from ip_data_buffer
             // data_out <= ip_data_buffer; 
        end else begin
            // --- DIAGNOSTIC ROM OVERRIDE ---
            if (a_stable >= 16'h7F00 && a_stable <= 16'h7FBF) data_out <= diag_data_out;
            else if (rom_index < 49152) data_out <= rom_memory[rom_index];
"""
    
    new_lines = lines[:start_idx] + [replacement] + lines[end_idx+1:]
    
    with open("top.v", "w") as f:
        f.writelines(new_lines)
    print("Patched successfully")
else:
    print(f"Failed to find indices. Start: {start_idx}, End: {end_idx}")

