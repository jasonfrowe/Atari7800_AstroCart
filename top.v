module top (
    input clk,              // 27MHz System Clock
    
    // Atari Interface
    input [15:0] a,         // Address Bus
    inout [7:0]  d,         // Data Bus
    input        phi2,      // Phase 2 Clock
    input        rw,        // Read/Write
    input        halt,      // Halt Line
    input        irq,       // IRQ Line
    
    // Buffer Control
    output reg   buf_dir,   // Buffer Direction
    output reg   buf_oe,    // Buffer Enable
    
    // SD Card (SPI Mode)
    output       sd_cs,     // SPI Chip Select (active low)
    output       sd_mosi,   // SPI MOSI (Master Out, Slave In)
    input        sd_miso,   // SPI MISO (Master In, Slave Out)
    output       sd_clk,    // SPI Clock
    
    // PSRAM (Tang Nano 9K - Gowin IP Core)
    output wire [0:0] O_psram_ck,      // Clock
    output wire [0:0] O_psram_ck_n,    // Clock inverted
    output wire [0:0] O_psram_cs_n,    // CS#
    output wire [0:0] O_psram_reset_n, // Reset#
    inout [7:0]       IO_psram_dq,     // 8-bit Data
    inout [0:0]       IO_psram_rwds,   // RWDS
    
    output       audio,     // Audio PWM
    output [5:0] led,       // Debug LEDs
    
    // High-speed debug pins
    output       debug_pin1,
    output       debug_pin2
);

    // ========================================================================
    // 0. CLOCK GENERATION (27MHz native for Atari, 81MHz PSRAM, 81MHz Sys)
    // ========================================================================
    wire clk_81m;           // Declared here for sys_clk assignment
    wire sys_clk = clk_81m; // 81MHz System Clock
    wire clk_40m5;          // 40.5MHz for SD Card
    wire external_clk = clk;

    // ========================================================================
    // 1. INPUT SYNCHRONIZATION
    // ========================================================================
    reg [15:0] a_safe;
    reg phi2_safe;
    reg rw_safe;
    reg halt_safe;

    // NEW: Glitch Filter for Address Bus
    reg [15:0] a_delay;
    reg [15:0] a_stable;

    // Run synchronization on FAST clock
    always @(posedge sys_clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
        
        // Only accept the address if it hasn't changed for 2 clock ticks (~50ns)
        a_delay <= a_safe;
        if (a_safe == a_delay) a_stable <= a_safe;
    end

    // ========================================================================
    // 2. MEMORY & DECODING
    // ========================================================================
    reg [7:0] rom_memory [0:49151]; 
    reg [7:0] data_out;
    initial $readmemh("game.hex", rom_memory);

    wire [15:0] rom_index = a_stable - 16'h4000;
    
    // PSRAM / System status
    wire clk_81m_shifted;
    wire pll_lock;
    
    // Handover Registers
    reg busy;
    reg armed;
    wire [3:0] sd_state; // Moved up for visibility
    
    // Status Byte: 0x00=Busy (Loading), 0x80=Done/Ready
    wire [7:0] status_byte = busy ? 8'h00 : 8'h80;

    // Checksum Logic

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
    wire [7:0]  latch_p4 = psram_write_addr_latched[15:8]; // P4 is mid address
    wire [7:0]  latch_p5;
    wire [7:0]  latch_p6;
    wire [31:0] latch_p7;
    
    wire [7:0] first_bytes_0;
    wire [7:0] first_bytes_1;
    wire [7:0] first_bytes_2;
    wire [7:0] first_bytes_3;
    
    wire game_loaded;
    wire switch_pending;
    
    // Hex-to-ASCII converter helper
    wire [7:0] diag_data_out;
    diag_rom diag_inst (
        .a_stable(a_stable), // Glitch suppressed address
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
        .fb0(first_bytes_0),
        .fb1(first_bytes_1),
        .fb2(first_bytes_2),
        .fb3(first_bytes_3),
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
            else data_out <= 8'hFF;
        end
    end
    // Decoders (Using STABLE address to prevent bus contention during transitions)
    wire is_rom   = (a_stable[15] | a_stable[14]);               // $4000-$FFFF
    wire is_pokey = (a_stable[15:4] == 12'h045);               // $0450-$045F
    wire is_2200  = (a_stable == 16'h2200) && !game_loaded;    // $2200 (Menu Control disabled in game)

    // ========================================================================
    // 3. BUS ARBITRATION
    // ========================================================================
    
    // Drive Enable (Read from ROM)
    // Simplified logic: Drive whenever address is in ROM range and R/W is Read.
    wire should_drive = is_rom && rw_safe;

    // Write Enables
    wire pokey_we   = is_pokey && !rw_safe && phi2_safe;
    wire trigger_we = is_2200  && !rw_safe && phi2_safe;

    // ========================================================================
    // 4. OUTPUTS
    // ========================================================================

    // [FIX] Always-Enabled Transceiver Control
    // User Request: "buf_oe is controlled by FPGA alone. Keep buf_oe low all the time."
    // Direction (buf_dir) controlled by our drive logic + sticky hold.
    always @(posedge sys_clk) begin
        // Direction:
        // High (1) = Output (FPGA -> Atari) when we should drive.
        // Low (0)  = Input  (Atari -> FPGA) default.
        if (should_drive || pokey_we || trigger_we) begin 
            // pokey_we/trigger_we are WRITES (Atari -> FPGA, Input, DIR=0).
            // should_drive is READ (FPGA -> Atari, Output, DIR=1).
            
            if (should_drive) buf_dir <= 1'b1; // Output
            else buf_dir <= 1'b0;                // Input
        end else begin
            buf_dir <= 1'b0; // Default to Input
        end

        // Output Enable: ALWAYS ON (Low)
        buf_oe <= 1'b0; 
    end


    // FPGA Tristate (Bypass data_out sync for game data to save 1 sys_clk latency)
    assign d = (should_drive) ? (game_loaded ? ip_data_buffer : data_out) : 8'bz;

    // ========================================================================
    // 5. POKEY AUDIO INSTANCE
    // ========================================================================
    
    // Clock Divider (81MHz -> 1.79MHz)
    // 81 / 1.79 ~= 45.25. Use 45.
    reg [5:0] clk_div;
    wire tick_179 = (clk_div == 44);
    
    always @(posedge sys_clk) begin
        if (clk_div >= 44) clk_div <= 0;
        else clk_div <= clk_div + 1;
    end

    pokey_advanced my_pokey (
        .clk(sys_clk),
        .enable_179mhz(tick_179),
        .reset_n(pll_lock),
        .addr(a_stable[3:0]),  // Register 0-F
        .din(d),             // Input Data (from Atari)
        .we(pokey_we),       // Synchronized Write Enable
        .audio_pwm(audio)
    );

    // ========================================================================
    // 6. SD CARD - calint sd_controller (Tang 9K proven)
    // ========================================================================
    
    // Power-on reset for SD controller
    // Use PLL lock as reset - gives ~50ms initialization time
    wire sd_reset = !pll_lock;

    // ========================================================================
    // 7. PSRAM CONTROLLER (Gowin IP)
    // ========================================================================
    
    gowin_pll pll_inst (
        .clkin(external_clk),
        .clkout(clk_81m),
        .clkoutp(clk_81m_shifted),
        .clkoutd(clk_40m5),
        .lock(pll_lock)
    );
    
    // PSRAM Signals - original interface
    reg psram_rd_req;
    wire psram_wr_req;
    wire [15:0] psram_dout_16;
    
    // PSRAM Interface Signals
    wire [7:0] psram_dout = psram_cmd_addr[0] ? psram_dout_16[15:8] : psram_dout_16[7:0];
    
    // --- Clock Domain Crossing (CDC) ---
    // Synchronize 27MHz Requests -> 81MHz Pulses
    reg [2:0] wr_req_sync;
    reg [2:0] rd_req_sync;
    always @(posedge clk_81m) begin
         wr_req_sync <= {wr_req_sync[1:0], psram_wr_req};
         rd_req_sync <= {rd_req_sync[1:0], psram_rd_req};
    end
    wire psram_cmd_write = (wr_req_sync[2:1] == 2'b01); // Clean 1-cycle 81MHz pulse
    wire psram_cmd_read  = (rd_req_sync[2:1] == 2'b01);
    
    // Synchronize 81MHz Busy -> 27MHz Safe Level
    wire psram_busy_raw;
    reg [1:0] psram_busy_sync;
    always @(posedge sys_clk) begin
         psram_busy_sync <= {psram_busy_sync[0], psram_busy_raw};
    end
    wire psram_busy = psram_busy_sync[1];
    
    // [FIX 4] Latch Address for IP Stability
    // We cannot drive IP address directly from 'a_safe' via MUX because 'a_safe' changes
    // while IP is busy. We must latch it.
    reg [22:0] latched_ip_addr_reg; // V68: Fixed width to 23 bits
    
    // V94: Use sd_state to determine CRC mode. This is stable and robust.
    // SD_CRC_START(6), SD_CRC_WAIT(7), SD_CRC_NEXT(8)
    wire is_crc_mode = (sd_state >= 4'd6 && sd_state <= 4'd8);
    wire [22:0] psram_cmd_addr = (is_crc_mode) ? crc_address : {1'b0, psram_addr_mux};
    
    wire is_psram_diag0 = (!game_loaded && a_stable >= 16'h7F40 && a_stable <= 16'h7F4F);
    wire is_psram_diag1 = (!game_loaded && a_stable >= 16'h7F50 && a_stable <= 16'h7F5F);
    wire is_psram_diag2 = (!game_loaded && a_stable >= 16'h7F60 && a_stable <= 16'h7F6F);
    wire is_psram_diag3 = (!game_loaded && a_stable >= 16'h7F70 && a_stable <= 16'h7F7F);
    wire is_psram_diag4 = (!game_loaded && a_stable >= 16'h7F80 && a_stable <= 16'h7F8F);
    wire is_psram_diag5 = (!game_loaded && a_stable >= 16'h7F90 && a_stable <= 16'h7F9F);
    wire is_psram_diag6 = (!game_loaded && a_stable >= 16'h7FA0 && a_stable <= 16'h7FAF);
    wire is_psram_diag7 = (!game_loaded && a_stable >= 16'h7FB0 && a_stable <= 16'h7FBF);
    
    // [FIX 2] Simplified Address Mux
    // P2(Diag2), P3(Diag3), P7(Diag6) ALL READ ADDRESS 0
    // V62: Use LATCHED write address for IP to avoid race with loop increment
    wire [22:0] psram_write_addr_latched;
    
    wire [21:0] psram_addr_mux = (game_loaded)   ? {6'b0, a_stable} - 22'h004000 : 
                                 (is_psram_diag0) ? 22'h000000 : 
                                 (is_psram_diag1) ? 22'h000001 : 
                                 (is_psram_diag2) ? 22'h000000 : 
                                 (is_psram_diag3) ? 22'h000000 : 
                                 (is_psram_diag4) ? 22'h000000 : 
                                 (is_psram_diag6) ? 22'h000000 : 
                                 {psram_write_addr_latched[21:0]};
    
    reg [7:0] psram_read_latch;
    
    wire [15:0] acc_word0; // Reduced to 16-bit for custom controller
    reg [22:0] burst_start_addr; 
 
    reg write_pending;
    
    reg [7:0] ip_data_buffer;

    // Instantiate Custom PSRAM Controller
    PsramController #(
        .FREQ(81_000_000),
        .LATENCY(3)
    ) psram_ctrl (
        .clk(clk_81m),
        .clk_p(clk_81m_shifted),
        .resetn(pll_lock),
        .read(psram_cmd_read),    // Use 81MHz Synchronized Pulse
        .write(psram_cmd_write),  // Use 81MHz Synchronized Pulse
        .addr(psram_cmd_addr[21:0]),
        .din(acc_word0[15:0]),
        .byte_write(1'b0),
        .dout(psram_dout_16),
        .busy(psram_busy_raw),    // Raw 81MHz output to be synchronized down to 27MHz
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );
    
    assign O_psram_reset_n = 1'b1;
    
    // Data Capture Logic
    always @* begin
        // Simple byte selection from 16-bit word
        ip_data_buffer = (psram_cmd_addr[0]) ? psram_dout_16[15:8] : psram_dout_16[7:0];
    end

    // PSRAM Read/Write Logic (CDC Handshake)
    
    // 1. Read Logic (Game Mode)
    // Trigger read on Address Change (Prefetch) to gain timing margin.
    reg should_drive_d;
    always @(posedge sys_clk) should_drive_d <= should_drive;
    
    reg [15:0] a_prev; // Used for edge detection
    reg rw_prev;
    
    // Diagnostic read-once latches (prevent continuous re-reading)
    reg diag0_read_done;
    reg diag1_read_done;
    reg diag2_read_done;
    reg diag3_read_done;
    reg diag4_read_done;
    reg diag5_read_done;
    reg diag6_read_done;
    reg diag7_read_done;
    reg p7_one_shot_fired; // Added for persistent capture
    
    // Detect when we're in any diagnostic region
    wire in_any_diag = is_psram_diag0 || is_psram_diag1 || is_psram_diag2 || is_psram_diag3 ||
                       is_psram_diag4 || is_psram_diag5 || is_psram_diag6 || is_psram_diag7;
    
    // Only trigger read once per entry to diagnostic region AND only when cart_loader is NOT busy
    wire diag_read_trigger = !game_loaded && rw_safe && !busy && 
                            ((is_psram_diag0 && !diag0_read_done) ||
                             (is_psram_diag1 && !diag1_read_done) ||
                             (is_psram_diag2 && !diag2_read_done) ||
                             (is_psram_diag3 && !diag3_read_done) ||
                             (is_psram_diag4 && !diag4_read_done) ||
                             (is_psram_diag5 && !diag5_read_done) ||
                             (is_psram_diag6 && !p7_one_shot_fired) || // Use persistent one-shot flag
                             (is_psram_diag7 && !diag7_read_done));
    
    reg [7:0] trigger_counter;
    reg [11:0] diag_exit_timer;
    
    // V52: Dedicated Diagnostic Latches
    // V52: Dedicated Diagnostic Latches
    reg [2:0] active_req_source; // V71: Extended to 3 bits (support up to 7)
    
    reg [15:0] last_req_addr;
    reg last_req_rw;
    
    // Capture diagnostic data on falling edge of busy
    reg psram_busy_d;
    always @(posedge sys_clk) begin
        psram_busy_d <= psram_busy;
        if (psram_busy_d && !psram_busy) begin
        end
    end
    
    always @(posedge sys_clk) begin
        a_prev <= a_stable;
        rw_prev <= rw_safe;
        
        // Reset diagnostic read-done flags ONLY on System Reset or new SD Load
        if (sd_reset || (sd_state == 4'd1 && current_sector == 0)) begin // 4'd1 = SD_START
            diag0_read_done <= 0;
            diag1_read_done <= 0;
            diag2_read_done <= 0;
            diag3_read_done <= 0;
            diag4_read_done <= 0;
            diag5_read_done <= 0;
            diag6_read_done <= 0;
            diag7_read_done <= 0;
            p7_one_shot_fired <= 0;
            last_req_addr <= 16'hFFFF; // Force initial mismatch
            last_req_rw <= 1'b0;
        end
        
        // [FIX 1] Clear Source in the SAME BLOCK to avoid Multi-Driver error
        // V94: Simplified clear. We no longer use source 6 for CRC.
        if (!psram_busy) active_req_source <= 0;
        
        if (!sd_reset) begin
             // READ REQUEST (Trigger on Address change, OR diag peak)
             // CRITICAL FIX: PREFETCH ENABLED
             // We trigger the read the moment `a_safe` changes, regardless of `phi2` state.
             // The 6502 asserts the address during PHI1 (or late PHI2 of prev cycle). 
             // We want the 750ns PSRAM IP to start working IMMEDIATELY.
             // READ REQUEST (Trigger on Address change, OR diag peak)
             if ((game_loaded && (a_stable[15] | a_stable[14]) && !psram_busy && (a_stable != last_req_addr)) || 
                 (diag_read_trigger && !psram_busy) ||
                 (crc_scan_req && !psram_busy)) begin
                   psram_rd_req <= 1;
                   last_req_addr <= a_stable; // Record the STABLE address
                   last_req_rw <= rw_safe;
                   
                   // Mark diagnostic region as read & Set Source
                   if (diag_read_trigger) begin
                       trigger_counter <= trigger_counter + 1;
                       if (is_psram_diag0) diag0_read_done <= 1;
                       if (is_psram_diag1) diag1_read_done <= 1;
                       
                       if (is_psram_diag2) begin
                           diag2_read_done <= 1;
                           active_req_source <= 3'd1; // P2 Request
                       end
                       
                       if (is_psram_diag3) begin
                           diag3_read_done <= 1;
                           active_req_source <= 3'd2; // P3 Request
                       end
                       
                       if (is_psram_diag4) begin 
                           diag4_read_done <= 1;
                           active_req_source <= 3'd4; // P4 Request
                       end
                       
                       if (is_psram_diag5) begin
                           diag5_read_done <= 1;
                           active_req_source <= 3'd5; // P5 Request
                       end
                       if (is_psram_diag6 && !p7_one_shot_fired) begin 
                           diag6_read_done <= 1;
                           p7_one_shot_fired <= 1; // Mark as fired permanently until reset
                           active_req_source <= 3'd3; 
                       end
                       
                       if (is_psram_diag7) diag7_read_done <= 1;
                   end
             end
             else if (psram_busy) begin 
                   // Safely clear request once acknowledged by the state machine
                   psram_rd_req <= 0; 
             end
             else if (!game_loaded && !in_any_diag) psram_rd_req <= 0; // Menu Mode safety (but allow diagnostics)
        end else begin
             p7_one_shot_fired <= 0;
        end
    end

    
    // Capture Read Data
    // Note: read_data from controller is stable until next read.
    // We can just update psram_latched_data when busy falls?
    // Or just use psram_dout_bus directly in data_out assignments?
    // Let's use `psram_dout_bus` directly, as it holds value.

    
    // TEST: Direct clock output to verify pin connection
    reg test_clk = 0;
    reg [3:0] test_div = 0;
    always @(posedge sys_clk) begin
        test_div <= test_div + 1;
        if (test_div == 0) test_clk <= ~test_clk;  // Much slower test clock (~1.6MHz)
    end
    
    // SD Controller signals

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
        .trigger_we(trigger_we),
        
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
        
        .fb0(first_bytes_0),
        .fb1(first_bytes_1),
        .fb2(first_bytes_2),
        .fb3(first_bytes_3),
        
        .busy(busy),
        .write_pending(write_pending_loader)
    );
    
    always @* write_pending = write_pending_loader;
        

    // ========================================================================
    // 6. DEBUG (Smart Visualizer - Atari Active Gated)
    // ========================================================================
    
    smart_blinkers blinkers_inst (
        .clk(sys_clk),
        .phi2_safe(phi2_safe),
        .a_stable(a_stable),
        .is_pokey(is_pokey),
        .is_2200(is_2200),
        .rw_safe(rw_safe),
        .buf_oe(buf_oe),
        .buf_dir(buf_dir),
        .psram_busy(psram_busy),
        .psram_rd_req(psram_rd_req),
        .pll_lock(pll_lock),
        .game_loaded(game_loaded),
        .write_pending(write_pending),
        .led(led)
    );
    
    // --- Oscilloscope Debug Pins ---
    // High-speed 1.8V outputs for accurate timing measurement
    assign debug_pin1 = psram_rd_req;     // Probe 1: Start of Read Request
    assign debug_pin2 = !psram_busy; // Probe 2: Data return from PSRAM IP
    
endmodule