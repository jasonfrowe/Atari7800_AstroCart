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
    
    // Slow clock for SD controller
    reg [1:0] clk_div_counter;  // Divide by 4 -> ~6.75MHz SPI
    reg clk_pulse_slow;
    
    always @(posedge sys_clk) begin
        clk_div_counter <= clk_div_counter + 1;
        clk_pulse_slow <= (clk_div_counter == 0);
    end
    
    // SD Controller signals
    wire sd_ready;
    wire [7:0] sd_dout;
    wire sd_byte_available;
    wire [4:0] sd_status;
    wire [7:0] sd_recv_data;
    reg sd_rd;
    reg [31:0] sd_address;
    
    sd_controller sd_ctrl (
        .cs(sd_cs),
        .mosi(sd_mosi),
        .miso(sd_miso),
        .sclk(sd_clk),
        .rd(sd_rd),
        .dout(sd_dout),
        .byte_available(sd_byte_available),
        .wr(1'b0),                    // No writes for now
        .din(8'h00),
        .ready_for_next_byte(),       // Unused
        .reset(~pll_lock),
        .ready(sd_ready),
        .address(sd_address),          // SDHC: sector number directly
        .clk(sys_clk),
        .clk_pulse_slow(clk_pulse_slow),
        .status(sd_status),
        .recv_data(sd_recv_data)
    );
    
    // File detection storage
    reg [5:0] files_found;          // Bitmask for GAME0-GAME5
    reg [2:0] file_count;           // Count of files detected
    reg sd_init_done;
    
    // State machine to scan for game files
    localparam SD_WAIT_INIT = 0;
    localparam SD_START_READ = 1;
    localparam SD_READ_SECTOR = 2;
    localparam SD_SCAN_DATA = 3;
    localparam SD_NEXT_SECTOR = 4;
    localparam SD_DONE = 5;
    
    reg [2:0] sd_state;
    reg [31:0] sector_num;          // 32-bit sector number
    reg [8:0] byte_index;
    reg [87:0] pattern_buf;         // 11-byte sliding window for "GAMEx   A78"
    reg sd_byte_available_d;        // Delayed signal for edge detection
    
    always @(posedge sys_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            sd_byte_available_d <= 0;
            sd_state <= SD_WAIT_INIT;
            sd_rd <= 0;
            sector_num <= 2050;     // Files at sector ~2055 per grep
            byte_index <= 0;
            files_found <= 0;
            file_count <= 0;
            sd_init_done <= 0;
            pattern_buf <= 0;
            sd_address <= 0;
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
                    if (!sd_ready) begin  // Wait for controller to start (sd_ready drops)
                        sd_rd <= 0;
                        sd_state <= SD_SCAN_DATA;
                    end
                end
                
                SD_READ_SECTOR: begin
                    sd_rd <= 0;  // Clear read request after one cycle
                    if (!sd_ready) begin  // Controller is now reading
                        sd_state <= SD_SCAN_DATA;
                    end
                end
                
                SD_SCAN_DATA: begin
                    // Detect rising edge of sd_byte_available
                    if (sd_byte_available && !sd_byte_available_d) begin
                        // Shift new byte into pattern buffer
                        pattern_buf <= {pattern_buf[79:0], sd_dout};
                        byte_index <= byte_index + 1;
                        
                        // Check for "GAMEx   A78" pattern after receiving 11 bytes
                        if (byte_index >= 10) begin
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
                                // Found a game file!
                                files_found[pattern_buf[55:48] - "0"] <= 1;
                                if (!files_found[pattern_buf[55:48] - "0"])
                                    file_count <= file_count + 1;
                            end
                        end
                    end
                    
                    if (sd_ready) begin  // Read complete
                        sd_state <= SD_NEXT_SECTOR;
                    end
                end
                
                SD_NEXT_SECTOR: begin
                    // Scan 100 sectors (files at ~2055 per grep)
                    if (file_count >= 6 || sector_num >= (2050 + 100)) begin
                        sd_state <= SD_DONE;
                        sd_init_done <= 1;
                    end else begin
                        sector_num <= sector_num + 1;
                        sd_state <= SD_START_READ;
                    end
                end
                
                SD_DONE: begin
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
    
    // LED Assignments (FILE COUNT MODE)
    // Active LOW LEDs - Show our SD state machine status
    assign led[0] = ~sd_state[0];                         // Our state bit 0
    assign led[1] = ~sd_state[1];                         // Our state bit 1  
    assign led[2] = ~sd_state[2];                         // Our state bit 2
    assign led[3] = ~sd_ready;                            // SD controller ready (ON when ready)
    assign led[4] = ~sd_rd;                               // Read request active
    assign led[5] = ~sd_byte_available;                   // Byte available pulse

endmodule