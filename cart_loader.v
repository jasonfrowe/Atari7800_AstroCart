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
    
    // PSRAM physical interface
    input        psram_busy,
    output reg   psram_wr_req,
    output reg [22:0] psram_write_addr_latched,
    output reg [15:0] acc_word0,
    input [15:0] psram_dout_16,
    
    // Status/Debug outputs used in top.v
    output reg   game_loaded,
    output reg   switch_pending,
    output reg [3:0] sd_state,
    output reg [6:0] current_sector,
    output reg [9:0] byte_index,
    output reg [31:0] checksum,
    output reg [7:0] last_byte_captured,
    output reg [31:0] psram_checksum,
    output reg [22:0] crc_address,
    output reg crc_scan_req,
    
    // Diagnostic latches
    output reg [31:0] latch_p2,
    output reg [31:0] latch_p3,
    output reg [7:0]  latch_p5,
    output reg [7:0]  latch_p6,
    output reg [31:0] latch_p7,
    
    // First Bytes
    output reg [7:0] fb0, output reg [7:0] fb1, output reg [7:0] fb2, output reg [7:0] fb3,
    
    // Flags
    output reg busy,
    output reg write_pending // passed to smart_blinkers
);

    // SD Controller signals
    wire sd_ready;
    wire [7:0] sd_dout;
    wire sd_byte_available;
    wire [4:0] sd_status;
    wire [7:0] sd_recv_data;
    
    reg sd_rd;
    reg [31:0] sd_address;
    wire sd_sclk_internal;
    reg crc_busy_wait;

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
        .recv_data(sd_recv_data)
    );
    assign sd_clk = sd_sclk_internal;

    // Simplified Sequential Loader
    localparam SD_IDLE       = 0;
    localparam SD_START      = 1;
    localparam SD_WAIT       = 2;
    localparam SD_DATA       = 3;
    localparam SD_NEXT       = 4;
    localparam SD_COMPLETE   = 5;

    localparam SD_CRC_START  = 6;
    localparam SD_CRC_WAIT   = 7;
    localparam SD_CRC_NEXT   = 8;
    localparam SD_DRAIN      = 9; // [FIX] Wait for last write to finish

    reg [7:0] sd_dout_reg;
    reg [22:0] psram_load_addr;
    reg [7:0] d_latched;
    
    // Address-based data capture logic
    reg trigger_we_prev;
    reg trigger_eval;
    reg trigger_lock_active;
    reg [7:0] drain_timer;
    reg [7:0] d_pipe [0:2];

    always @(posedge clk_sys) begin
        if (reset) begin
             sd_state <= SD_IDLE;
             sd_rd <= 0;
             sd_address <= 0;
             byte_index <= 0;
             game_loaded <= 0;
             switch_pending <= 0;
             psram_wr_req <= 0;
             crc_scan_req <= 0;
             acc_word0 <= 0;
             write_pending <= 0;
             busy <= 0; // Starts 0 now. Wait for $2200 trigger.
             
             trigger_we_prev <= 0;
             trigger_eval <= 0;
             trigger_lock_active <= 0;
             
             current_sector <= 0;
             psram_load_addr <= 23'h000000;
             checksum <= 0;
             sd_dout_reg <= 0;
             drain_timer <= 0;
        end else begin
             trigger_we_prev <= trigger_we;
             
             if (psram_wr_req) begin
                  psram_wr_req <= 0;
              end else if (write_pending && !psram_busy) begin
                   psram_wr_req <= 1;
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
                SD_IDLE: begin
                    // TRIGGER: Only latch command when the SD controller is initialized and ready.
                    // Act purely on the transition edge of the write cycle to ignore noisy intermediate states.
                    if (trigger_eval && sd_ready) begin
                        
                        if (!game_loaded && (d_latched >= 8'h80 && d_latched <= 8'h8F)) begin
                            // The payload is the game index
                            // current_sector maps to Start_Block = 1 + (game_idx * 100)
                            sd_address <= 1 + ((d_latched & 8'h7F) * 100); 
                            current_sector <= 0;
                            
                            sd_state <= SD_START;
                            busy <= 1;
                            checksum <= 0;
                            psram_load_addr <= 0;
                        end
                        else if (d_latched == 8'h5A) begin
                             // RELOAD: Magic Key 0x5A
                             sd_address <= 1; // Default to Game 0
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             checksum <= 0;
                             busy <= 1;
                             game_loaded <= 0; // Force unload
                             switch_pending <= 0;
                        end
                        // Add catch for $64 (100) soft-reload as well for joystick shortcut
                        else if (d_latched == 8'h40) begin
                             sd_address <= 1; // Default to Game 0
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             checksum <= 0;
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
                             
                             checksum <= checksum + sd_dout_reg;
                             last_byte_captured <= sd_dout_reg;
                             
                             if (current_sector == 1) begin
                                 if (byte_index == 0) fb0 <= sd_dout_reg;
                                 else if (byte_index == 1) fb1 <= sd_dout_reg;
                                 else if (byte_index == 2) fb2 <= sd_dout_reg;
                                 else if (byte_index == 3) fb3 <= sd_dout_reg;
                             end
                             
                             psram_load_addr <= psram_load_addr + 1; 
                         end
                         
                         byte_index <= byte_index + 1;
                         sd_state <= SD_WAIT;
                  end

                 SD_NEXT: begin
                     psram_wr_req <= 0;
                     if (current_sector < 96) begin // 97 sectors total per game
                          current_sector <= current_sector + 1;
                          sd_address <= sd_address + 1; // Advance true SD Block Address
                          sd_state <= SD_START;
                      end else begin
                          sd_state <= SD_DRAIN; // [FIX] Go to drain state instead of CRC start
                          crc_address <= 23'h000000;
                          psram_checksum <= 0;
                          drain_timer <= 0;
                      end
                  end

                  SD_DRAIN: begin
                      // Wait ~400ns (32 cycles @ 81MHz) to ensure last write is fully committed
                      drain_timer <= drain_timer + 1;
                      if (drain_timer == 32) 
                          sd_state <= SD_CRC_START;
                  end
                  
                  SD_CRC_START: begin
                      if (!psram_busy) begin 
                           crc_scan_req <= 1;
                           sd_state <= SD_CRC_WAIT;
                           // V100: Wait for busy to assert first, then de-assert
                           crc_busy_wait <= 1; 
                      end
                  end
                  
                  SD_CRC_WAIT: begin
                      // top.v psram_rd_req tracking is handled by top.v. We just wait for busy sequence.
                      
                      if (crc_busy_wait) begin
                          if (psram_busy) begin
                              crc_busy_wait <= 0; // Saw it assert!
                              crc_scan_req <= 0; // Safe to drop the request now
                          end
                      end
                      else if (!psram_busy) begin // Now wait for it to fall (read complete)
                          psram_checksum <= psram_checksum + 
                                            {24'b0, psram_dout_16[7:0]} + 
                                            {24'b0, psram_dout_16[15:8]};
                          latch_p5 <= psram_dout_16[7:0];
                          
                          if (crc_address == 23'h000000) latch_p7 <= {16'b0, psram_dout_16};
                          if (crc_address == 23'h000002) latch_p2 <= {16'b0, psram_dout_16};
                          if (crc_address == 23'h000004) latch_p3 <= {16'b0, psram_dout_16};
                                            
                          sd_state <= SD_CRC_NEXT; // Done with this word
                      end
                  end
                  
                  SD_CRC_NEXT: begin
                      if (crc_address < 23'h00BFFE) begin 
                          crc_address <= crc_address + 2; 
                          sd_state <= SD_CRC_START;
                      end else begin
                          latch_p6 <= crc_address[7:0];
                          sd_state <= SD_COMPLETE;
                          busy <= 0;
                      end
                  end
                 
                 SD_COMPLETE: begin
                     if (trigger_eval) begin
                         if (!game_loaded && d_latched == 8'hA5) begin
                             switch_pending <= 1;
                         end
                         else if (!game_loaded && (d_latched >= 8'h80 && d_latched <= 8'h8F) && !trigger_lock_active) begin
                             // User selected a new game from the menu! Re-trigger load.
                             sd_address <= 1 + ((d_latched & 8'h7F) * 100); 
                             current_sector <= 0;
                             sd_state <= SD_START;
                             busy <= 1;
                             checksum <= 0;
                             psram_load_addr <= 0;
                             trigger_lock_active <= 1; // Prevent continuous reloading!
                         end
                         else if (d_latched == 8'h5A) begin
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             checksum <= 0;
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
             endcase
             
             // Unlock trigger only when the menu clears the trigger byte (e.g. to 0)
             if (d_latched == 0) trigger_lock_active <= 0;
             
        end
    end

endmodule
