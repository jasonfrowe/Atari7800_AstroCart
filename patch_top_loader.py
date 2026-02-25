import sys

with open("top.v", "r") as f:
    lines = f.readlines()

start_idx = -1
end_idx = -1

for i, line in enumerate(lines):
    if "wire sd_ready;" in line:
        start_idx = i
    if "if (switch_pending && a_stable == 16'hFFFC) begin" in line:
        # We need to find the end of the always block containing this
        for j in range(i, len(lines)):
            if "endcase" in lines[j]:
                end_idx = j + 2 # include the endcase and the end block
                break
        break

if start_idx != -1 and end_idx != -1:
    replacement = """
    // ========================================================================
    // 5. CART LOADER (SD to PSRAM)
    // ========================================================================
    wire write_pending_loader;
    
    cart_loader loader_inst (
        .clk_sys(sys_clk),
        .clk_sd(clk_40m5),
        .reset(sd_reset),
        
        .a_stable(a_stable),
        .d(d),
        .rw_safe(rw_safe),
        .phi2_safe(phi2_safe),
        
        .sd_cs(sd_cs),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_clk(sd_clk),
        
        .psram_busy(psram_busy),
        .psram_wr_req(psram_wr_req),
        .psram_write_addr_latched(psram_write_addr_latched),
        .acc_word0(acc_word0),
        .psram_dout_16(psram_dout_16),
        
        .game_loaded(game_loaded),
        .switch_pending(switch_pending),
        .sd_state(sd_state),
        .current_sector(current_sector),
        .byte_index(byte_index),
        .checksum(checksum),
        .last_byte_captured(last_byte_captured),
        .psram_checksum(psram_checksum),
        .crc_address(crc_address),
        .crc_scan_req(crc_scan_req),
        
        .latch_p2(latch_p2),
        .latch_p3(latch_p3),
        .latch_p5(latch_p5),
        .latch_p6(latch_p6),
        .latch_p7(latch_p7),
        
        .fb0(first_bytes[0]),
        .fb1(first_bytes[1]),
        .fb2(first_bytes[2]),
        .fb3(first_bytes[3]),
        
        .busy(busy),
        .write_pending(write_pending_loader)
    );
    
    always @* write_pending = write_pending_loader;
"""
    
    new_lines = lines[:start_idx] + [replacement] + lines[end_idx:]
    
    with open("top.v", "w") as f:
        f.writelines(new_lines)
    print("Patched loader successfully")
else:
    print(f"Failed to find indices. Start: {start_idx}, End: {end_idx}")

