module cart_loader (
    input clk_sys,        // 81MHz system clock
    input clk_sd,         // 40.5MHz SD clock
    input reset,          // Active high reset (from PLL !lock)
    
    // Atari CPU interface
    input [15:0] a_stable,
    input [7:0]  d,
    input        rw_safe,
    input        phi2_safe,
    input        trigger_we,
    
    // SD Card physical interface
    output       sd_cs,
    output       sd_mosi,
    input        sd_miso,
    output       sd_clk,
    
    // PSRAM write interface (reads handled by top.v directly)
    input        psram_busy,
    output reg   psram_wr_req,
    output reg [22:0] psram_write_addr_latched,
    output reg [15:0] acc_word0,
    
    // Status outputs
    output reg   game_loaded,
    output reg   switch_pending,
    output reg [3:0] sd_state,
    output reg   busy,
    output reg   write_pending,
    
    // BRAM Write Interface (title scan -> menu RAM)
    output reg bram_we,
    output reg [15:0] bram_addr,
    output reg [7:0] bram_data,

    // Cart configuration (from header)
    output reg [31:0] cart_rom_size,
    output reg cart_has_pokey,
    output reg [15:0] cart_pokey_addr
);

    // SD Controller signals
    wire sd_ready;
    wire [7:0] sd_dout;
    wire sd_byte_available;
    wire [4:0] sd_status;
    
    reg sd_rd;
    reg [31:0] sd_address;
    wire sd_sclk_internal;

    sd_controller sd_ctrl (
        .cs(sd_cs),
        .mosi(sd_mosi),
        .miso(sd_miso),
        .sclk(sd_sclk_internal),
        .rd(sd_rd),
        .dout(sd_dout),
        .byte_available(sd_byte_available),
        .wr(1'b0),
        .din(8'h00),
        .ready_for_next_byte(),
        .reset(reset),
        .ready(sd_ready),
        .address(sd_address),
        .clk(clk_sd),
        .status(sd_status),
        .recv_data()
    );
    assign sd_clk = sd_sclk_internal;

    // Simplified Sequential Loader
    localparam SD_IDLE       = 0;
    localparam SD_START      = 1;
    localparam SD_WAIT       = 2;
    localparam SD_DATA       = 3;
    localparam SD_NEXT       = 4;
    localparam SD_COMPLETE   = 5;
    localparam SD_DRAIN      = 9; // Wait for last PSRAM write to commit
    
    localparam SD_SCAN_START = 10;
    localparam SD_SCAN_WAIT  = 11;
    localparam SD_SCAN_DATA  = 12;
    localparam SD_SCAN_NEXT  = 13;

    // Internal tracking registers
    reg [9:0] current_sector;
    reg [9:0] byte_index;

    reg [7:0] sd_dout_reg;
    reg [22:0] psram_load_addr;
    reg [7:0] d_latched;
    
    // Address-based data capture logic
    reg trigger_we_prev;
    reg trigger_eval;
    reg trigger_lock_active;
    reg [7:0] drain_timer;
    reg [7:0] d_pipe [0:2];
    
    reg [4:0] scan_game_idx; // Scan up to 32 games

    // Header capture registers
    reg [7:0] h49, h50, h51, h52; // Size
    reg [7:0] h53, h54;           // Flags

    wire [31:0] size_be_wire = {h49, h50, h51, h52};
    wire [31:0] size_le_wire = {h52, h51, h50, h49};
    wire is_be_valid = (size_be_wire == 32'd16384 || size_be_wire == 32'd32768 || size_be_wire == 32'd49152);

    always @(posedge clk_sys) begin
        if (reset) begin
             sd_state <= SD_SCAN_START; // Start by scanning headers
             sd_rd <= 0;
             sd_address <= 1;
             byte_index <= 0;
             game_loaded <= 0;
             switch_pending <= 0;
             psram_wr_req <= 0;
             acc_word0 <= 0;
             write_pending <= 0;
             busy <= 1; // Busy during initial scan
             
             trigger_we_prev <= 0;
             trigger_eval <= 0;
             trigger_lock_active <= 0;
             
             current_sector <= 0;
             psram_load_addr <= 23'h000000;
             sd_dout_reg <= 0;
             drain_timer <= 0;
             
             scan_game_idx <= 0;
             bram_we <= 0;
             bram_addr <= 0;
             bram_data <= 0;

             cart_rom_size <= 49152;
             cart_has_pokey <= 1;
             cart_pokey_addr <= 16'h0450;
        end else begin
             trigger_we_prev <= trigger_we;
             
             if (psram_wr_req) begin
                  psram_wr_req <= 0;
              end else if (write_pending && !psram_busy) begin
                   // [FIX] Gate writes when game loaded to prevent corruption
                   if (!game_loaded) psram_wr_req <= 1;
                   write_pending <= 0;
              end
             
              // Keep a history of the unsynchronized data bus 'd'
              // This is critical because trigger_we is built from a_stable and rw_safe,
              // which are delayed by top.v synchronizers (~3 cycles). 
              // By the time trigger_we evaluates or falls, the live 'd' bus has already changed
              // to the 6502's next instruction cycle!
              d_pipe[0] <= d;
              d_pipe[1] <= d_pipe[0];
              d_pipe[2] <= d_pipe[1];
              
              // Only evaluate the trigger command once the write pulse ENDS,
              // but grab the data from back in time when it was actually stable on the bus!
              if (trigger_we_prev && !trigger_we) begin
                  // Using d_pipe[2] grabs the data from exactly 3 sys_clk ticks ago (~37ns),
                  // properly aligning with the end of the delayed write cycle.
                  d_latched <= d_pipe[2];
                  trigger_eval <= 1;
              end else begin
                  trigger_eval <= 0;
              end
             
            case (sd_state)
                // --- NORMAL OPERATION ---
                SD_IDLE: begin
                    // TRIGGER: Only latch command when the SD controller is initialized and ready.
                    // Act purely on the transition edge of the write cycle to ignore noisy intermediate states.
                    if (trigger_eval && sd_ready) begin
                        
                        if (!game_loaded && (d_latched >= 8'h80 && d_latched <= 8'h8F)) begin
                            // The payload is the game index
                            // current_sector maps to Start_Block = 1 + (game_idx * 1024)
                            sd_address <= 1 + ((d_latched & 8'h7F) * 1024); 
                            current_sector <= 0;
                            
                            sd_state <= SD_START;
                            busy <= 1;
                            psram_load_addr <= 0;
                            
                            cart_rom_size <= 49152;
                            cart_has_pokey <= 1;
                            cart_pokey_addr <= 16'h0450;
                        end
                        else if (d_latched == 8'h5A) begin
                             // RELOAD: Magic Key 0x5A
                             sd_address <= 1;
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             busy <= 1;
                             game_loaded <= 0;
                             switch_pending <= 0;
                        end
                        else if (d_latched == 8'h40) begin
                             sd_address <= 1;
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             busy <= 1;
                             game_loaded <= 0;
                             switch_pending <= 0;
                        end
                    end
                end
                                 SD_START: begin
                     psram_wr_req <= 0;
                     if (sd_ready) begin
                         sd_rd <= 1; // Assert RD to kick off block load
                     end
                     else if (sd_rd) begin
                         sd_rd <= 0; // sd_ready went low, it heard us!
                         byte_index <= 0;
                         sd_state <= SD_WAIT;
                     end
                 end
                 
                 SD_WAIT: begin
                     // 4-Phase Handshake Drop:
                     if (sd_rd && !sd_byte_available) begin
                         sd_rd <= 0; // Drop ACK when we see it was received 
                     end
                     
                     if (sd_byte_available && !sd_rd && !write_pending) begin
                         sd_dout_reg <= sd_dout;     // Capture Data
                         sd_rd <= 1;                 // Assert ACK
                         sd_state <= SD_DATA;        // Handle PSRAM Write
                     end else if (!sd_byte_available && !sd_rd && byte_index >= 512 && !write_pending) begin
                         sd_state <= SD_NEXT;
                     end else if (sd_ready && !sd_rd && byte_index < 512) begin
                         sd_state <= SD_NEXT; // Abort on read error
                     end
                 end
                  
                  SD_DATA: begin
                         if (current_sector > 0) begin
                             // Handle Payload Sectors (Sector > 0)
                             if (psram_load_addr[0] == 0) acc_word0[7:0] <= sd_dout_reg;
                             else acc_word0[15:8] <= sd_dout_reg;
                             
                             // Trigger Write on ODD byte
                             if (psram_load_addr[0] == 1'b1) begin
                                  write_pending <= 1;
                                  psram_write_addr_latched <= {psram_load_addr[22:1], 1'b0};
                             end
                             
                             psram_load_addr <= psram_load_addr + 1; 
                         end else begin
                             // Sector 0: Capture Header Bytes
                             case (byte_index)
                                 49: h49 <= sd_dout_reg;
                                 50: h50 <= sd_dout_reg;
                                 51: h51 <= sd_dout_reg;
                                 52: h52 <= sd_dout_reg;
                                 53: h53 <= sd_dout_reg;
                                 54: h54 <= sd_dout_reg;
                             endcase
                         end
                         
                         byte_index <= byte_index + 1;
                         sd_state <= SD_WAIT;
                  end

                 SD_NEXT: begin
                     psram_wr_req <= 0;
                     
                     // Analyze Header after Sector 0 is done
                     if (current_sector == 0) begin
                         // 1. Determine Size, Offset & Endianness
                         cart_has_pokey <= 0;
                         
                         if (is_be_valid) begin
                             // Big Endian (Astrowing)
                             cart_rom_size <= size_be_wire;
                             psram_load_addr <= 49152 - size_be_wire;
                             
                             // BE Flags: h53=High, h54=Low
                             // Bit 6 ($450) is in Low Byte (h54)
                             if (h54[6]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0450; end
                             else if (h54[0]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h4000; end
                             else if (h53[2]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0440; end
                             else if (h53[7]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0800; end
                         end else begin
                             // Little Endian (Standard) or Default
                             if (size_le_wire == 32'd16384 || size_le_wire == 32'd32768 || size_le_wire == 32'd49152) begin
                                 cart_rom_size <= size_le_wire;
                                 psram_load_addr <= 49152 - size_le_wire;
                             end else begin
                                 cart_rom_size <= 49152;
                                 psram_load_addr <= 0;
                             end
                             
                             // LE Flags: h54=High, h53=Low
                             if (h53[6]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0450; end
                             else if (h53[0]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h4000; end
                             else if (h54[2]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0440; end
                             else if (h54[7]) begin cart_has_pokey <= 1; cart_pokey_addr <= 16'h0800; end
                         end
                     end

                     if (current_sector < 512) begin // 256KB total per game
                          current_sector <= current_sector + 1;
                          sd_address <= sd_address + 1; // Advance true SD Block Address
                          sd_state <= SD_START;
                      end else begin
                          sd_state <= SD_DRAIN;
                          drain_timer <= 0;
                      end
                  end

                  SD_DRAIN: begin
                      // Wait ~400ns (32 cycles @ 81MHz) to ensure last write is committed
                      drain_timer <= drain_timer + 1;
                      if (drain_timer == 32) begin
                          sd_state <= SD_COMPLETE;
                          busy <= 0;
                      end
                  end
                 
                 SD_COMPLETE: begin
                     busy <= 0;
                     if (trigger_eval) begin
                         if (!game_loaded && d_latched == 8'hA5) begin
                             switch_pending <= 1;
                         end
                         else if (!game_loaded && (d_latched >= 8'h80 && d_latched <= 8'h8F) && !trigger_lock_active) begin
                             sd_address <= 1 + ((d_latched & 8'h7F) * 1024); 
                             current_sector <= 0;
                             sd_state <= SD_START;
                             busy <= 1;
                             psram_load_addr <= 0;
                             trigger_lock_active <= 1;
                         end
                         else if (d_latched == 8'h5A) begin
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             busy <= 1;
                             game_loaded <= 0; 
                             switch_pending <= 0;
                         end
                     end
                     
                     if (switch_pending && a_stable == 16'hFFFC) begin
                         game_loaded <= 1;
                         switch_pending <= 0;
                     end
                 end
                 
                 // --- HEADER SCANNING (METADATA) ---
                 SD_SCAN_START: begin
                     // Read Block 1 + (Index * 1024)
                     // [FIX] Address is now pre-calculated to avoid race condition with sd_rd
                     byte_index <= 0;
                     bram_we <= 0;
                     
                     if (sd_ready) begin
                         sd_rd <= 1;
                     end
                     else if (sd_rd) begin
                         sd_rd <= 0;
                         sd_state <= SD_SCAN_WAIT;
                     end
                 end
                 
                 SD_SCAN_WAIT: begin
                     bram_we <= 0; // Pulse low
                     if (sd_rd && !sd_byte_available) sd_rd <= 0;
                     
                     if (sd_byte_available && !sd_rd) begin
                         sd_dout_reg <= sd_dout;
                         sd_rd <= 1;
                         sd_state <= SD_SCAN_DATA;
                     end else if (!sd_byte_available && !sd_rd && byte_index >= 512) begin
                         sd_state <= SD_SCAN_NEXT;
                     end else if (sd_ready && !sd_rd && byte_index < 512) begin
                         // [FIX] Abort if controller goes IDLE prematurely (timeout/error)
                         sd_state <= SD_SCAN_NEXT;
                     end
                 end
                 
                 SD_SCAN_DATA: begin
                     // Extract Title (Bytes 17-48)
                     // Map to BRAM $6000 + (GameIdx * 32) + CharIdx
                     if (byte_index >= 17 && byte_index <= 48) begin
                         bram_we <= 1;
                         bram_data <= sd_dout_reg;
                         // Base $6000 + Offset
                         bram_addr <= 16'h6000 + (scan_game_idx * 32) + (byte_index - 17);
                     end
                     
                     byte_index <= byte_index + 1;
                     sd_state <= SD_SCAN_WAIT;
                 end
                 
                 SD_SCAN_NEXT: begin
                     if (scan_game_idx < 15) begin // Scan first 16 games
                         scan_game_idx <= scan_game_idx + 1;
                         sd_address <= 1 + ((scan_game_idx + 1) * 1024); // [FIX] Pre-calculate for next slot
                         sd_state <= SD_SCAN_START;
                     end else begin
                         // Done scanning
                         sd_state <= SD_IDLE;
                         busy <= 0;
                     end
                 end
                 
             endcase
             
             // Unlock trigger only when the menu clears the trigger byte (e.g. to 0)
             if (d_latched == 0) trigger_lock_active <= 0;
             
        end
    end

endmodule
