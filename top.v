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
    
    output       audio,     // Audio PWM
    output [5:0] led        // Debug LEDs
);

    // ========================================================================
    // 0. CLOCK GENERATION (No PLL - 27MHz native, Atari crashes with 81MHz)
    // ========================================================================
    wire sys_clk = clk;     // 27MHz native
    wire pll_lock = 1'b1;   // Always locked (no PLL)

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
    // 6. SD CARD - calint sd_controller (Tang 9K proven)
    // ========================================================================
    
    // SD Card - MIT sd_controller (Tang 9K compatible)
    // Direct rd/wr interface
    
    // Power-on reset for SD controller - simple counter approach
    // Counter will eventually overflow and stop, ending reset
    reg [7:0] reset_counter;
    
    always @(posedge sys_clk) begin
        if (reset_counter != 8'hFF) begin
            reset_counter <= reset_counter + 1;
        end
    end
    
    // Assert reset only during first ~50 cycles, then deassert forever
    wire sd_reset = (reset_counter < 8'd50);
    
    // Slow clock for SD controller (Internal to SD controller now)
    
    // TEST: Direct clock output to verify pin connection
    reg test_clk = 0;
    reg [3:0] test_div = 0;
    always @(posedge sys_clk) begin
        test_div <= test_div + 1;
        if (test_div == 0) test_clk <= ~test_clk;  // Much slower test clock (~1.6MHz)
    end
    
    // SD Controller signals
    wire sd_ready;
    wire [7:0] sd_dout;
    wire sd_byte_available;
    wire [4:0] sd_status;
    wire [7:0] sd_recv_data;
    
    reg sd_rd;
    reg [31:0] sd_address;
    wire sd_sclk_internal;

    // SD Controller
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
        .reset(sd_reset),
        .ready(sd_ready),
        .address(sd_address),
        .clk(sys_clk),
        .status(sd_status),
        .recv_data(sd_recv_data)
    );

    assign sd_clk = sd_sclk_internal;

    // PSRAM Interface Stubs (Until PSRAM ports are added to top)
    // reg  psram_ready = 1; // Fake ready
    wire psram_ready = 0; // Not ready
    
    // File detection storage
    reg [5:0] files_found;          // Bitmask for GAME0-GAME5
    reg [2:0] file_count;           // Count of files detected
    reg sd_init_done;
    
    // State machine to scan for game files
    // (Localparams defined below)
    
    reg [3:0] sd_state;
    reg [31:0] sector_num;          // 32-bit sector number
    reg [9:0] byte_index;
    reg [87:0] pattern_buf;         // 11-byte sliding window for "GAMEx   A78"
    reg sd_byte_available_d;        // Delayed signal for edge detection
    reg [15:0] sector_count;        // Number of sectors scanned
    
    // Capture/Playback Registers
    reg capture_active;
    reg [4:0] capture_count;
    reg [25:0] playback_timer;
    reg [4:0] playback_index;
    reg [7:0] led_debug_byte;
    reg led_0_toggle;
    
    // Cluster Parsing
    reg [5:0] post_match_cnt;
    reg [31:0] file_cluster;
    reg [31:0] debug_data_trap;

    // Game Loader Registers
    reg [8:0] loading_sector_cnt;
    reg [22:0] psram_load_addr;
    reg header_found;
    reg game_loaded;
        
    // State Machine Definitions (Localparams)
    localparam SD_WAIT_INIT       = 0;
    localparam SD_START_READ      = 1;
    localparam SD_READ_SECTOR     = 2;
    localparam SD_SCAN_DATA       = 3;
    localparam SD_NEXT_SECTOR     = 4;
    localparam SD_DONE            = 5;
    localparam SD_PLAYBACK_PATTERN = 6;
    localparam SD_CALC_LOC        = 7;
    localparam SD_LOAD_SEEK       = 8;
    localparam SD_LOAD_READ_WAIT  = 9;
    localparam SD_LOAD_DATA       = 10;
    localparam SD_LOAD_NEXT       = 11;
    localparam SD_GAME_START      = 12;

    always @(posedge sys_clk) begin
        if (sd_reset) begin
            sd_byte_available_d <= 0;
            sd_state <= SD_WAIT_INIT;
            sd_rd <= 0;
            sector_num <= 32270;    // Target Sector 32274 (Offset 16524480 / 512)
            byte_index <= 0;
            files_found <= 0;
            file_count <= 0;
            sd_init_done <= 0;
            pattern_buf <= 0;
            sd_address <= 0;
            sector_count <= 0;
            
            // Playback Init
            capture_active <= 0;
            capture_count <= 0;
            playback_timer <= 0;
            playback_index <= 0;
            led_debug_byte <= 0;
            led_0_toggle <= 0;
            
            // Loader Init
            game_loaded <= 0;
        end else begin
            sd_byte_available_d <= sd_byte_available; // Update delayed signal
            
            case (sd_state)
                SD_WAIT_INIT: begin
                    // Wait for card initialization (status == IDLE)
                    if (sd_ready && sd_status == 6) begin  // 6 = IDLE state
                        sd_state <= SD_START_READ;
                    end
                end
                
                SD_START_READ: begin
                    // Start reading a sector (SDHC: direct sector addressing)
                    sd_address <= sector_num;
                    sd_rd <= 1;
                    byte_index <= 0;
                    pattern_buf <= 0;
                    sd_state <= SD_READ_SECTOR;
                end
                
                SD_READ_SECTOR: begin
                    // Wait one cycle for sd_rd to be sampled, then check if read started
                    if (!sd_ready) begin  // Controller has started reading
                        sd_rd <= 0;
                        sd_state <= SD_SCAN_DATA;
                    end
                end
                
                SD_SCAN_DATA: begin
                    // Check for Abort/Timeout
                    if (sd_ready && byte_index < 512) begin
                       // Controller aborted (Timeout)
                       sd_state <= SD_NEXT_SECTOR;
                    end
                    
                    // Detect rising edge of sd_byte_available
                    else if (sd_byte_available && !sd_byte_available_d) begin
                        // Shift new byte into pattern buffer
                        pattern_buf <= {pattern_buf[79:0], sd_dout};
                        byte_index <= byte_index + 1;
                        
                        // STATE MACHINE: HUNT -> CAPTURE -> PLAYBACK
                        if (!capture_active) begin
                            // DIAGNOSTIC SCOPE: Capture FIRST 4 BYTES of SECTOR 0 (of scan)
                            // To see if we catch MBR (often starts with FA, 33, C0, 8E...)
                            // or FAT32 Volume ID (EB 58 90...)
                            if (sector_count == 0 && byte_index < 4) begin
                                // Using playback_timer to store bytes temporarily? 
                                // No, use pattern_buf. 
                                // pattern_buf shifts left. 
                                // After 4 bytes, pattern_buf[31:0] has the data.
                                // We can use a separate register for scope? 
                                // Let's just FORCE capture active after 4 bytes IF we haven't found G?
                                // No, user wants to see G if it exists.
                                // But if G not found, show S0 bytes.
                                case (byte_index)
                                    0: playback_timer[7:0]   <= sd_dout;
                                    1: playback_timer[15:8]  <= sd_dout;
                                    2: playback_timer[23:16] <= sd_dout;
                                    3: playback_timer[25:24] <= sd_dout[1:0]; // Partial
                                endcase
                            end

                            // HUNTING for 'G'
                            if (sd_dout == "G") begin
                                capture_active <= 1;
                                capture_count <= 0;
                                led_0_toggle <= 1; // Solid ON to indicate trigger
                            end
                            // FALLBACK: If we finish Sector 0 and haven't found G...
                            // Actually, let's just capture the first 4 bytes into a debug register
                            if (sector_count == 0 && byte_index < 4) begin
                                case (byte_index)
                                    0: playback_timer[7:0]   <= sd_dout;
                                    1: playback_timer[15:8]  <= sd_dout;
                                    2: playback_timer[23:16] <= sd_dout;
                                    3: playback_timer[25:24] <= sd_dout[1:0]; // Partial
                                endcase
                            end
                        end else begin
                            // CAPTURING subsequent chars (A, M, E...)
                            capture_count <= capture_count + 1;
                            if (capture_count >= 10) begin
                                // Captured enough! 
                                // Do NOT go to Playback Trap. Continue to next sector/done.
                                // sd_state <= SD_PLAYBACK_PATTERN; // REMOVED
                                capture_active <= 0; // Stop capturing pattern
                            end
                        end

                        // Check for "GAMEx   A78" pattern after receiving 11 bytes
                        if (byte_index >= 10 && !post_match_cnt) begin // Only check if not already found
                            if (pattern_buf[87:80] == 8'h47 &&  // 'G'
                                pattern_buf[79:72] == 8'h41 &&  // 'A'
                                pattern_buf[71:64] == 8'h4D &&  // 'M'
                                pattern_buf[63:56] == 8'h45 &&  // 'E'
                               (pattern_buf[55:48] >= 8'h30 && pattern_buf[55:48] <= 8'h35) &&  // '0'-'5'
                                pattern_buf[47:40] == 8'h20 &&  // ' '
                                pattern_buf[39:32] == 8'h20 &&  // ' '
                                pattern_buf[31:24] == 8'h20 &&  // ' '
                                pattern_buf[23:16] == 8'h41 &&  // 'A'
                                pattern_buf[15:8]  == 8'h37 &&  // '7'
                                pattern_buf[7:0]   == 8'h38) begin  // '8'
                                // Found a game file!
                                files_found[pattern_buf[55:48] - 8'h30] <= 1;
                                if (!files_found[pattern_buf[55:48] - 8'h30])
                                    file_count <= file_count + 1;
                                
                                // Start Cluster Parsing
                                post_match_cnt <= 1; 
                                file_cluster <= 0;
                            end
                        end
                        
                        // Parse Cluster Number (FAT32)
                        // "GAME..." match ends at Offset 10 relative to Entry Start.
                        // post_match_cnt counts bytes AFTER match.
                        // Entry Structure:
                        // 00-10: Name (Matched)
                        // 20-21: FstClusHI (High Word) -> Match+10, Match+11
                        // 26-27: FstClusLO (Low Word)  -> Match+16, Match+17
                        if (post_match_cnt > 0) begin
                            post_match_cnt <= post_match_cnt + 1;
                            // Correct Offsets:
                            // We start `post_match_cnt` at Offset 11 (Attr).
                            // High Word is Offset 20, 21. Delta = 9, 10. (Wait. 20-11=9).
                            // Low Word is Offset 26, 27. Delta = 15, 16.
                            // My previous map was 10, 11 (High) and 16, 17 (Low).
                            // Let's stick to the ones that worked!
                            // Offset 20 is `post_match_cnt == 10`.
                            // Offset 21 is `post_match_cnt == 11`.
                            // Offset 26 is `post_match_cnt == 16`.
                            // Offset 27 is `post_match_cnt == 17`.
                            
                            if (post_match_cnt == 10) file_cluster[23:16] <= sd_dout;
                            if (post_match_cnt == 11) file_cluster[31:24] <= sd_dout;
                            if (post_match_cnt == 16) file_cluster[7:0]   <= sd_dout;
                            if (post_match_cnt == 17) file_cluster[15:8]  <= sd_dout;
                            
                            if (post_match_cnt >= 32) begin // Done with entry
                                post_match_cnt <= 0; // Reset for next entry
                            end
                        end
                    end
                    
                    if (sd_ready) begin  // Read complete
                        sector_count <= sector_count + 1;
                        if (sd_state != SD_PLAYBACK_PATTERN) sd_state <= SD_NEXT_SECTOR;
                    end
                end
                
                SD_PLAYBACK_PATTERN: begin
                    // Cycle through the buffer to show what we found
                    if (playback_timer < 26'h2000000) begin // ~1s
                        playback_timer <= playback_timer + 1;
                    end else begin
                        playback_timer <= 0;
                        playback_index <= playback_index + 1;
                        if (playback_index >= 10) playback_index <= 0; // Loop
                        
                        case (playback_index)
                            0: led_debug_byte <= pattern_buf[87:80]; // G
                            1: led_debug_byte <= pattern_buf[79:72]; // A
                            2: led_debug_byte <= pattern_buf[71:64]; // M
                            3: led_debug_byte <= pattern_buf[63:56]; // E
                            4: led_debug_byte <= pattern_buf[55:48]; // 0
                            5: led_debug_byte <= pattern_buf[47:40]; // .
                            6: led_debug_byte <= pattern_buf[39:32]; // A
                            7: led_debug_byte <= pattern_buf[31:24]; // 7
                            8: led_debug_byte <= pattern_buf[23:16]; // 8
                            9: led_debug_byte <= pattern_buf[15:8];  // space
                            10: led_debug_byte <= pattern_buf[7:0];  // space
                        endcase
                    end
                end

                SD_NEXT_SECTOR: begin
                    // Scan LIMIT (reduced for targeted scan)
                    if (file_count >= 1 || sector_count >= 2000) begin
                        if (file_count > 0) begin
                            // File Found! Proceed to Load.
                            sd_state <= SD_CALC_LOC;
                        end else begin
                            // Not found
                            sd_state <= SD_DONE;
                            sd_init_done <= 1; // Done (Failed)
                            led_0_toggle <= 0;
                        end
                    end else begin
                        sector_num <= sector_num + 1;
                        sd_state <= SD_START_READ;
                    end
                end

                SD_CALC_LOC: begin
                    // HEADER SEARCH MODE
                    // Instead of calculating, we START at Root (32274) and SCAN for "ATARI7800".
                    sector_num <= 32274; 
                    
                    sd_state <= SD_LOAD_SEEK;
                    loading_sector_cnt <= 0;
                    psram_load_addr <= 0;
                    led_0_toggle <= 1;    
                    
                    // Reset Logic for Header Check
                    pattern_buf <= 0;
                    header_found <= 0;
                end

                SD_LOAD_SEEK: begin
                    // Start reading the sector
                    sd_address <= sector_num;
                    sd_rd <= 1;
                    byte_index <= 0;
                    pattern_buf <= 0;
                    sd_state <= SD_LOAD_READ_WAIT;
                end

                SD_LOAD_READ_WAIT: begin
                    if (!sd_ready) begin
                        sd_rd <= 0;
                        sd_state <= SD_LOAD_DATA;
                    end
                end

                SD_LOAD_DATA: begin
                    if (sd_ready && byte_index < 512) begin
                        sd_state <= SD_LOAD_NEXT; 
                    end
                    else if (sd_byte_available && !sd_byte_available_d) begin
                         // Shift into pattern buffer for Header verification
                        pattern_buf <= {pattern_buf[79:0], sd_dout};
                        byte_index <= byte_index + 1;
                        
                        // Check for "ATARI7800" at start of file (Bytes 0-8)
                        if (byte_index >= 9) begin
                             if (pattern_buf[71:64] == 8'h41 && // A
                                 pattern_buf[63:56] == 8'h54 && // T
                                 pattern_buf[55:48] == 8'h41 && // A
                                 pattern_buf[47:40] == 8'h52 && // R
                                 pattern_buf[39:32] == 8'h49 && // I
                                 pattern_buf[31:24] == 8'h37 && // 7
                                 pattern_buf[23:16] == 8'h38 && // 8
                                 pattern_buf[15:8]  == 8'h30 && // 0
                                 pattern_buf[7:0]   == 8'h30)   // 0
                             begin
                                 header_found <= 1;
                                 sd_state <= SD_GAME_START; // Found it! Stop immediately.
                             end
                        end
                    end
                    
                    if (sd_ready) begin
                       sd_state <= SD_LOAD_NEXT;
                    end
                end

                SD_LOAD_NEXT: begin
                     // If we are here, we finished a sector.
                     // Did we find the header?
                     if (header_found) begin
                        // This logic is actually skipped because SD_LOAD_DATA jumps to GAME_START on success.
                        // But if we wanted to continue loading...
                        // For now, we only want to FIND it.
                        sd_state <= SD_GAME_START;
                     end else begin
                        // Header NOT found in this sector.
                        // Increment Sector and Search Next.
                        sector_num <= sector_num + 1;
                        // Reset everything for next sector
                        byte_index <= 0;
                        pattern_buf <= 0;
                        loading_sector_cnt <= 0; // Not loading yet
                        
                        // Search Limit (e.g. 5000 sectors -> ~2.5MB)
                        if (sector_num > (32274 + 5000)) begin
                            sd_state <= SD_DONE; // Give up
                        end else begin
                            sd_state <= SD_LOAD_SEEK;
                        end
                     end
                end

                SD_GAME_START: begin
                     game_loaded <= 1; // Success!
                     led_debug_byte <= 8'hAA; 
                     sd_init_done <= 1;
                     led_0_toggle <= 1;
                     sd_state <= SD_DONE; 
                end
                
                SD_DONE: begin
                    // Done State
                    if (game_loaded) begin
                         // SUCCESS:
                         // Display Low Byte of Sector Number where file was found.
                         // This helps us know WHERE it is.
                         led_debug_byte <= sector_num[7:0]; 
                         led_0_toggle <= 1;
                    end else if (file_count > 0) begin
                        // File found in Dir, but Header text NOT found in data scan.
                         if (sector_num[26] == 0) begin
                             sector_num <= sector_num + 1; 
                         end else begin
                              sector_num <= 0;
                              playback_index <= playback_index + 1;
                              if (playback_index >= 4) playback_index <= 0;
                              case (playback_index)
                                  0: led_debug_byte <= debug_data_trap[7:0]; // Last Trap
                                  1: led_debug_byte <= debug_data_trap[15:8];
                                  2: led_debug_byte <= debug_data_trap[23:16];
                                  3: led_debug_byte <= debug_data_trap[31:24]; 
                              endcase
                         end
                         led_0_toggle <= 1; 
                    end else begin
                         // Fail
                         led_0_toggle <= 0; 
                    end
                    sd_init_done <= 1;
                end
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

    // File count indicator - count LED blinks
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
    
    // LED[4] blinks <file_count> times, then pauses
    wire led4_pattern = (blink_phase > 0 && blink_phase <= file_count) ? blink_counter[23] : 1'b0;
    
    // LED Assignments (DIAGNOSTIC MODE)
    // Active LOW LEDs. 
    assign led[0] = ~(capture_active | led_0_toggle); // ON if Found OR Done
    assign led[1] = ~led_debug_byte[0];         // Data Bit 0
    assign led[2] = ~led_debug_byte[1];         // Data Bit 1
    assign led[3] = ~led_debug_byte[2];         // Data Bit 2
    assign led[4] = ~led_debug_byte[3];         // Data Bit 3
    assign led[5] = ~game_loaded;               // ON if Header Verified (Game Loaded)
    
endmodule