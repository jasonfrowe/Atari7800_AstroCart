
import os

new_logic = """            case (sd_state)
                SD_IDLE: begin
                    // Wait for SD card ready
                    if (sd_ready && sd_status == 6) begin // 6 = IDLE
                        sd_state <= SD_LOAD_START;
                    end
                end
                
                SD_LOAD_START: begin
                    // Start reading current sector
                    sd_address <= current_sector;
                    sd_rd <= 1;
                    byte_in_sector <= 0;
                    sd_state <= SD_LOAD_WAIT;
                end
                
                SD_LOAD_WAIT: begin
                    // Wait for SD controller to start reading
                    if (!sd_ready) begin
                        sd_rd <= 0;
                        sd_state <= SD_LOAD_DATA;
                    end
                end
                
                SD_LOAD_DATA: begin
                    // Receive bytes and write to PSRAM
                    if (sd_ready && byte_in_sector < 512) begin
                        // Sector read complete or aborted early
                        sd_state <= SD_LOAD_NEXT;
                    end
                    else if (sd_byte_available && !sd_byte_available_d) begin
                        // Write to PSRAM (sequential addresses starting at 0)
                        psram_wr_req <= 1;
                        psram_load_addr <= psram_load_addr + 1;
                        byte_in_sector <= byte_in_sector + 1;
                        
                        // Check if sector complete (511 is last byte, 0-indexed)
                        if (byte_in_sector == 511) begin
                            sd_state <= SD_LOAD_NEXT;
                        end
                    end
                end
                
                SD_LOAD_NEXT: begin
                    // Clear PSRAM write request
                    psram_wr_req <= 0;
                    
                    if (current_sector == GAME_SIZE_SECTORS - 1) begin
                        // Last sector complete - done loading!
                        sd_state <= SD_COMPLETE;
                    end else begin
                        // More sectors to load
                        current_sector <= current_sector + 1;
                        sd_state <= SD_LOAD_START;
                    end
                end
                
                SD_COMPLETE: begin
                    // Loading complete - set flags and stay here
                    load_complete <= 1;
                    game_loaded <= 1;
                    // Stay in this state - loading is done
                end
                
                default: begin
                    // Safety: unknown state returns to IDLE
                    sd_state <= SD_IDLE;
                end
            endcase
"""

file_path = 'top.v'
temp_path = 'top.v.tmp'

with open(file_path, 'r') as f:
    lines = f.readlines()

# Lines to replace: 344 to 665 (1-based index)
# In 0-based list index: 343 to 665 (exclusive of 665, so up to 664)
# Wait, slice is [start:end], so lines[343:665] includes 343 up to 664. 
# Line 344 is index 343.
# Line 665 is index 664.
# We want to replace everything FROM index 343 TO index 664 inclusive.
# So slice is lines[:343] + [new_logic] + lines[665:]? 
# Let's check:
# lines[343] is "case (sd_state)\n" (Line 344)
# lines[664] is "            endcase\n" (Line 665)
# lines[665] is "        end\n" (Line 666) -> Keep this.

start_idx = 343
end_idx = 665 # This is the index of the first line to KEEP (Line 666)

with open(temp_path, 'w') as f:
    f.writelines(lines[:start_idx])
    f.write(new_logic)
    f.writelines(lines[end_idx:])

print(f"Replaced lines {start_idx+1}-{end_idx} with new logic.")
os.replace(temp_path, file_path)
