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
    
    // SD Card (SPI)
    output       sd_clk,    // SPI Clock
    output       sd_mosi,   // SPI MOSI
    input        sd_miso,   // SPI MISO
    output       sd_cs_n,   // SPI Chip Select (active low)
    
    output       audio,     // Audio PWM
    output [5:0] led        // Debug LEDs
);

    // ========================================================================
    // 0. CLOCK GENERATION (PLL REMOVED - RUNNING NATIVE 27MHz)
    // ========================================================================
    wire sys_clk = clk;     // 27MHz
    wire pll_lock = 1'b1;   // Always Ready
    
    // gowin_pll my_pll (
    //     .clkin(clk),
    //     .clkout(sys_clk),
    //     .lock(pll_lock)
    // );

    // ========================================================================
    // 1. INPUT SYNCHRONIZATION
    // ========================================================================
    reg [15:0] a_safe;
    reg phi2_safe;
    reg rw_safe;
    reg halt_safe;

    // Run synchronization on FAST clock
    always @(posedge sys_clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
    end

    // ========================================================================
    // 2. MEMORY & DECODING
    // ========================================================================
    reg [7:0] rom_memory [0:49151]; 
    reg [7:0] data_out;
    initial $readmemh("game.hex", rom_memory);

    wire [15:0] rom_index = a_safe - 16'h4000;

    // ROM Fetch (High Speed)
    always @(posedge sys_clk) begin
        if (rom_index < 49152) data_out <= rom_memory[rom_index];
        else data_out <= 8'hFF;
    end
    
    // Decoders (Using SAFE address)
    wire is_rom   = (a_safe[15] | a_safe[14]);          // $4000-$FFFF
    wire is_pokey = (a_safe[15:4] == 12'h045);          // $0450-$045F
    wire is_2200  = (a_safe == 16'h2200);               // $2200 (Menu Control)

    // ========================================================================
    // 3. BUS ARBITRATION
    // ========================================================================
    
    // Valid Timing Windows
    wire cpu_active = (phi2_safe && halt_safe);
    wire dma_active = (!halt_safe);

    // Drive Enable (Read from ROM)
    wire should_drive = is_rom && rw_safe && (cpu_active || dma_active);

    // Write Enable (Write to POKEY)
    // STRICT RULE: Only write when PHI2 is High (Data is valid).
    wire pokey_we = is_pokey && !rw_safe && phi2_safe;

    // ========================================================================
    // 4. OUTPUTS
    // ========================================================================

    always @(posedge sys_clk) begin
        // Direction follows RW (1=Out/Read, 0=In/Write)
        buf_dir <= rw_safe; 

        // Output Enable (Active Low)
        // Enable if Driving ROM OR if Atari is Writing (to us)
        // We must enable the buffer to receive the write data!
        // Decoupled from PLL: Bus Logic must run always!
        if (should_drive || pokey_we) begin
            buf_oe <= 1'b0; 
        end else begin
            buf_oe <= 1'b1; 
        end
    end

    // FPGA Tristate
    assign d = (should_drive) ? data_out : 8'bz;

    // ========================================================================
    // 5. POKEY AUDIO INSTANCE
    // ========================================================================
    
    // Clock Divider (27MHz -> 1.79MHz)
    // 27 / 1.79 ~= 15.08. Use 15.
    reg [3:0] clk_div;
    wire tick_179 = (clk_div == 14);
    
    always @(posedge sys_clk) begin
        if (tick_179) clk_div <= 0;
        else clk_div <= clk_div + 1;
    end

    pokey_advanced my_pokey (
        .clk(sys_clk),
        .enable_179mhz(tick_179),
        .reset_n(pll_lock),
        .addr(a_safe[3:0]),  // Register 0-F
        .din(d),             // Input Data (from Atari)
        .we(pokey_we),       // Synchronized Write Enable
        .audio_pwm(audio)
    );

    // ========================================================================
    // 6. SD CARD - FAT32-Lite File Detection
    // ========================================================================
    // Strategy: Skip boot sector, scan sector 8192+ for root directory
    // Look for "GAME0   A78" through "GAME5   A78" patterns
    
    // SD Control Signals
    reg sd_cmd_start;
    reg [7:0] sd_cmd_byte;
    wire [7:0] sd_resp_byte;
    wire sd_busy;
    wire sd_data_valid;
    
    sd_spi_controller sd_ctrl (
        .clk(sys_clk),
        .reset_n(pll_lock),
        .cmd_start(sd_cmd_start),
        .cmd_byte(sd_cmd_byte),
        .resp_byte(sd_resp_byte),
        .busy(sd_busy),
        .data_valid(sd_data_valid),
        .spi_clk(sd_clk),
        .spi_mosi(sd_mosi),
        .spi_miso(sd_miso),
        .spi_cs_n(sd_cs_n)
    );
    
    // File detection storage
    reg [5:0] files_found;          // Bitmask for GAME0-GAME5
    reg [2:0] file_count;           // Count of files detected
    
    // SD State Machine - with proper initialization
    localparam SD_IDLE = 0;
    localparam SD_SEND_DUMMY = 1;
    localparam SD_CMD0 = 2;
    localparam SD_CMD0_RESP = 3;
    localparam SD_INIT_DONE = 4;
    localparam SD_SEND_CMD17 = 5;
    localparam SD_WAIT_TOKEN = 6;
    localparam SD_READ_DATA = 7;
    localparam SD_SCAN_COMPLETE = 8;
    
    reg [3:0] sd_state;
    reg [15:0] sector_num;          // Current sector being read (start at 8192)
    reg [8:0] byte_index;           // Index within 512-byte sector
    reg [7:0] cmd17_index;          // Index for sending CMD17 (0-5)
    reg [31:0] read_addr;           // Sector address for CMD17
    reg [87:0] pattern_buf;         // 11-byte sliding window for "GAMEx   A78"
    reg [4:0] entry_offset;         // Offset within 32-byte directory entry
    reg sd_init_done;
    
    // CMD17 command bytes (will be populated dynamically)
    reg [7:0] cmd17 [0:5];
    
    always @(posedge sys_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            sd_state <= SD_IDLE;
            sd_cmd_start <= 0;
            sector_num <= 8192;         // Start at typical FAT32 root location
            byte_index <= 0;
            files_found <= 0;
            file_count <= 0;
            sd_init_done <= 0;
            cmd17_index <= 0;
        end else begin
            // Default: don't start commands
            if (!sd_busy && sd_cmd_start) begin
                sd_cmd_start <= 0;  // Clear start after one cycle
            end
            
            case (sd_state)
                SD_IDLE: begin
                    // Initial power-up delay
                    if (byte_index < 100) begin
                        byte_index <= byte_index + 1;
                    end else begin
                        sd_state <= SD_SEND_DUMMY;
                        byte_index <= 0;
                    end
                end
                
                SD_SEND_DUMMY: begin
                    // Send dummy clocks (80+ clocks = 10 bytes minimum)
                    if (sd_data_valid) begin
                        // Previous byte completed
                        if (byte_index < 20) begin
                            byte_index <= byte_index + 1;
                        end else begin
                            sd_state <= SD_CMD0;
                            byte_index <= 0;
                            cmd17_index <= 0;
                        end
                    end else if (!sd_busy && !sd_cmd_start) begin
                        // Send next dummy byte
                        sd_cmd_byte <= 8'hFF;
                        sd_cmd_start <= 1;
                    end
                end
                
                SD_CMD0: begin
                    // Send CMD0: 0x40 0x00 0x00 0x00 0x00 0x95 (GO_IDLE_STATE)
                    if (!sd_busy && !sd_cmd_start && cmd17_index < 6) begin
                        case (cmd17_index)
                            0: sd_cmd_byte <= 8'h40;  // CMD0
                            1: sd_cmd_byte <= 8'h00;
                            2: sd_cmd_byte <= 8'h00;
                            3: sd_cmd_byte <= 8'h00;
                            4: sd_cmd_byte <= 8'h00;
                            5: sd_cmd_byte <= 8'h95;  // Valid CRC for CMD0
                        endcase
                        sd_cmd_start <= 1;
                        cmd17_index <= cmd17_index + 1;
                    end else if (cmd17_index >= 6) begin
                        sd_state <= SD_CMD0_RESP;
                        byte_index <= 0;
                    end
                end
                
                SD_CMD0_RESP: begin
                    // Wait for R1 response (should be 0x01 for idle state)
                    if (!sd_busy && !sd_cmd_start && byte_index < 10) begin
                        sd_cmd_byte <= 8'hFF;
                        sd_cmd_start <= 1;
                        byte_index <= byte_index + 1;
                    end else if (byte_index >= 10) begin
                        // Skip full init for now, assume card is ready
                        sd_state <= SD_INIT_DONE;
                        byte_index <= 0;
                    end
                end
                
                SD_INIT_DONE: begin
                    // Card initialized, prepare to read
                    sd_state <= SD_SEND_CMD17;
                    byte_index <= 0;
                    
                    // Prepare CMD17 to read sector_num
                    // CMD17 format: 0x51 [A31-A24] [A23-A16] [A15-A8] [A7-A0] 0xFF
                    read_addr <= {16'h0000, sector_num};  // Sector to byte address
                    cmd17[0] <= 8'h51;                     // CMD17
                    cmd17[1] <= read_addr[31:24];
                    cmd17[2] <= read_addr[23:16];
                    cmd17[3] <= read_addr[15:8];
                    cmd17[4] <= read_addr[7:0];
                    cmd17[5] <= 8'hFF;                     // Dummy CRC
                    cmd17_index <= 0;
                end
                
                SD_SEND_CMD17: begin
                    // Send CMD17 bytes
                    if (!sd_busy && !sd_cmd_start) begin
                        if (cmd17_index < 6) begin
                            sd_cmd_byte <= cmd17[cmd17_index];
                            sd_cmd_start <= 1;
                            cmd17_index <= cmd17_index + 1;
                        end else begin
                            sd_state <= SD_WAIT_TOKEN;
                            byte_index <= 0;
                        end
                    end
                end
                
                SD_WAIT_TOKEN: begin
                    // Wait for 0xFE data token
                    if (!sd_busy && !sd_cmd_start) begin
                        sd_cmd_byte <= 8'hFF;  // Send dummy byte
                        sd_cmd_start <= 1;
                    end else if (sd_data_valid) begin
                        if (sd_resp_byte == 8'hFE) begin
                            // Got data token, start reading
                            sd_state <= SD_READ_DATA;
                            byte_index <= 0;
                            pattern_buf <= 0;
                            entry_offset <= 0;
                        end else if (byte_index > 100) begin
                            // Timeout - skip to next sector or finish
                            if (sector_num < 8200 && file_count < 6) begin
                                sector_num <= sector_num + 1;
                                sd_state <= SD_IDLE;
                            end else begin
                                sd_state <= SD_SCAN_COMPLETE;
                            end
                        end else begin
                            byte_index <= byte_index + 1;
                        end
                    end
                end
                
                SD_READ_DATA: begin
                    // Read 512 bytes + 2 CRC, scanning for patterns
                    if (!sd_busy && !sd_cmd_start && byte_index < 514) begin
                        sd_cmd_byte <= 8'hFF;
                        sd_cmd_start <= 1;
                    end else if (sd_data_valid && byte_index < 512) begin
                        // Shift pattern buffer
                        pattern_buf <= {pattern_buf[79:0], sd_resp_byte};
                        entry_offset <= entry_offset + 1;
                        
                        // Check if we've accumulated 11 bytes for pattern match
                        if (entry_offset >= 10) begin
                            // Check for "GAME0   A78" through "GAME5   A78"
                            if (pattern_buf[87:80] == "G" && 
                                pattern_buf[79:72] == "A" &&
                                pattern_buf[71:64] == "M" &&
                                pattern_buf[63:56] == "E" &&
                                (pattern_buf[55:48] >= "0" && pattern_buf[55:48] <= "5") &&
                                pattern_buf[47:40] == " " &&
                                pattern_buf[39:32] == " " &&
                                pattern_buf[31:24] == " " &&
                                pattern_buf[23:16] == "A" &&
                                pattern_buf[15:8] == "7" &&
                                pattern_buf[7:0] == "8") begin
                                // Found a match! Mark the file
                                // Extract file number: pattern_buf[55:48] is '0'-'5' (48-53)
                                files_found[pattern_buf[50:48]] <= 1;  // Subtract 48 to get 0-5
                                file_count <= file_count + 1;
                            end
                        end
                        
                        byte_index <= byte_index + 1;
                    end else if (byte_index >= 514) begin
                        // Finished reading this sector
                        if (file_count >= 6 || sector_num >= 8200) begin
                            sd_state <= SD_SCAN_COMPLETE;
                            sd_init_done <= 1;
                        end else begin
                            // Try next sector
                            sector_num <= sector_num + 1;
                            sd_state <= SD_IDLE;
                            byte_index <= 0;
                        end
                    end
                end
                
                SD_SCAN_COMPLETE: begin
                    sd_init_done <= 1;
                    // Stay here, file detection complete
                end
                
                default: sd_state <= SD_IDLE;
            endcase
        end
    end

    // ========================================================================
    // 6. DEBUG (Smart Visualizer - Atari Active Gated)
    // ========================================================================
    // PHI2 Activity Detector: Only enable LED triggers when Atari is running.
    
    reg phi2_prev;
    reg atari_active;
    reg [22:0] activity_timer;
    
    localparam ACTIVITY_TIMEOUT = 23'h100000; // ~50ms
    
    always @(posedge sys_clk) begin
        phi2_prev <= phi2_safe;
        
        // Detect PHI2 edge (rising or falling)
        if (phi2_safe != phi2_prev) begin
            atari_active <= 1;
            activity_timer <= ACTIVITY_TIMEOUT;
        end else if (activity_timer > 0) begin
            activity_timer <= activity_timer - 1;
        end else begin
            atari_active <= 0;
        end
    end
    
    // Smart Blinker Logic (Gated by atari_active)
    reg [22:0] timer_a15;   reg state_a15;
    reg [22:0] timer_pokey; reg state_pokey;
    reg [22:0] timer_rw;    reg state_rw;
    reg [22:0] timer_oe;    reg state_oe;
    reg [22:0] timer_2200;  reg state_2200;  // $2200 detector
    
    reg [23:0] heartbeat;

    localparam BLINK_DUR = 23'h200000; // ~75ms

    always @(posedge sys_clk) begin
        heartbeat <= heartbeat + 1;

        // --- A15 Smart Blinker ---
        if (state_a15) begin
            if (timer_a15 == 0) begin
                state_a15 <= 0;
                timer_a15 <= BLINK_DUR;
            end else timer_a15 <= timer_a15 - 1;
        end else begin
            if (timer_a15 > 0) timer_a15 <= timer_a15 - 1;
            else if (atari_active && !a_safe[15]) begin // GATED
                state_a15 <= 1;
                timer_a15 <= BLINK_DUR;
            end
        end

        // --- POKEY Smart Blinker ---
        if (state_pokey) begin
            if (timer_pokey == 0) begin
                state_pokey <= 0;
                timer_pokey <= BLINK_DUR;
            end else timer_pokey <= timer_pokey - 1;
        end else begin
            if (timer_pokey > 0) timer_pokey <= timer_pokey - 1;
            else if (atari_active && is_pokey) begin // GATED
                state_pokey <= 1;
                timer_pokey <= BLINK_DUR;
            end
        end

        // --- RW Smart Blinker ---
        if (state_rw) begin
            if (timer_rw == 0) begin
                state_rw <= 0;
                timer_rw <= BLINK_DUR;
            end else timer_rw <= timer_rw - 1;
        end else begin
            if (timer_rw > 0) timer_rw <= timer_rw - 1;
            else if (atari_active && !rw_safe) begin // GATED
                state_rw <= 1;
                timer_rw <= BLINK_DUR;
            end
        end

        // --- OE Smart Blinker ---
        if (state_oe) begin
            if (timer_oe == 0) begin
                state_oe <= 0;
                timer_oe <= BLINK_DUR;
            end else timer_oe <= timer_oe - 1;
        end else begin
            if (timer_oe > 0) timer_oe <= timer_oe - 1;
            else if (atari_active && !buf_oe) begin // GATED
                state_oe <= 1;
                timer_oe <= BLINK_DUR;
            end
        end
        
        // --- $2200 Smart Blinker (Menu Control) ---
        if (state_2200) begin
            if (timer_2200 == 0) begin
                state_2200 <= 0;
                timer_2200 <= BLINK_DUR;
            end else timer_2200 <= timer_2200 - 1;
        end else begin
            if (timer_2200 > 0) timer_2200 <= timer_2200 - 1;
            else if (atari_active && is_2200 && !rw_safe) begin // GATED - Write to $2200
                state_2200 <= 1;
                timer_2200 <= BLINK_DUR;
            end
        end
    end

    // File count blinker - blink LED[4] <file_count> times
    reg [24:0] blink_counter;
    reg [2:0] blink_phase;  // Which blink in the sequence (0-file_count)
    
    always @(posedge sys_clk) begin
        blink_counter <= blink_counter + 1;
        if (blink_counter[24]) begin  // ~0.3s at 27MHz
            if (blink_phase < file_count) begin
                blink_phase <= blink_phase + 1;
            end else begin
                blink_phase <= 0;
            end
        end
    end
    
    wire led4_blink = (blink_phase > 0 && blink_phase <= file_count) ? blink_counter[23] : 1'b1;
    
    // LED Assignments (DEBUG MODE - showing SD state)
    assign led[0] = ~state_a15;                           // A15 (RAM/TIA access)
    assign led[1] = ~state_pokey;                         // POKEY activity
    assign led[2] = ~sd_state[0];                         // SD State bit 0 (DEBUG)
    assign led[3] = ~sd_state[1];                         // SD State bit 1 (DEBUG)
    assign led[4] = ~sd_state[2];                         // SD State bit 2 (DEBUG)
    assign led[5] = ~state_oe;                            // Bus Drive activity

endmodule