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
    // 0. CLOCK GENERATION (27MHz native for Atari, 81MHz PSRAM, 40.5MHz Sys)
    // ========================================================================
    wire sys_clk; // 40.5MHz native from PLL
    wire external_clk = clk;

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
    
    // PSRAM / System status
    wire clk_81m;
    wire clk_81m_shifted;
    wire pll_lock;
    
    // Handover Registers
    reg busy;
    reg armed;
    
    // Status Byte: 0x00=Busy (Loading), 0x80=Done/Ready
    wire [7:0] status_byte = busy ? 8'h00 : 8'h80;

    // Checksum Logic
    reg [31:0] checksum;
    
    // Hex-to-ASCII converter helper
    function [7:0] to_hex_ascii (input [3:0] nibble);
        to_hex_ascii = (nibble < 10) ? (8'h30 + nibble) : (8'h37 + nibble);
    endfunction

    // ROM Fetch / PSRAM Read / Status Read
    always @(posedge sys_clk) begin
        if (game_loaded) begin
             // [OPTIMIZATION] Fast Data Capture: Bypass synced latch entirely
             // Data connects directly combinationally to the FPGA pins from ip_data_buffer
             // data_out <= ip_data_buffer; 
        end else begin
            // --- DIAGNOSTIC ROM OVERRIDE ---
            // Use $7F00-$7FBF range (all zeros in menu.bin - safe)
            // Use a_safe[7:4] for nibble-based addressing (0-B = 12 outputs)
            if (a_safe >= 16'h7F00 && a_safe <= 16'h7FBF) begin
                // Use a_safe[7:4] to select the diagnostic output (0-B = 12 outputs)
                case (a_safe[7:4])
                    4'h0: begin // $x400: SD Word 0 (A9 50 85 3C)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h53; // 'S'
                            4'h1: data_out <= 8'h44; // 'D'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(first_bytes[0][7:4]);
                            4'h4: data_out <= to_hex_ascii(first_bytes[0][3:0]);
                            4'h5: data_out <= 8'h20;
                            4'h6: data_out <= to_hex_ascii(first_bytes[1][7:4]);
                            4'h7: data_out <= to_hex_ascii(first_bytes[1][3:0]);
                            4'h8: data_out <= 8'h20;
                            4'h9: data_out <= to_hex_ascii(first_bytes[2][7:4]);
                            4'hA: data_out <= to_hex_ascii(first_bytes[2][3:0]);
                            4'hB: data_out <= 8'h20;
                            4'hC: data_out <= to_hex_ascii(first_bytes[3][7:4]);
                            4'hD: data_out <= to_hex_ascii(first_bytes[3][3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h1: begin // $x410: ST/BC
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h53; // 'S'
                            4'h1: data_out <= 8'h54; // 'T'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii({1'b0, sd_state});
                            4'h4: data_out <= 8'h20; 
                            4'h5: data_out <= 8'h42; // 'B'
                            4'h6: data_out <= 8'h43; // 'C'
                            4'h7: data_out <= 8'h3A;
                            4'h8: data_out <= to_hex_ascii({2'b0, byte_index[9:8]});
                            4'h9: data_out <= to_hex_ascii(byte_index[7:4]);
                            4'hA: data_out <= to_hex_ascii(byte_index[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h2: begin // $x420: SC/L
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h53; // 'S'
                            4'h1: data_out <= 8'h43; // 'C'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii({1'b0, current_sector[6:4]});
                            4'h4: data_out <= to_hex_ascii(current_sector[3:0]);
                            4'h5: data_out <= 8'h20;
                            4'h6: data_out <= 8'h4C; // 'L' (Last Byte)
                            4'h7: data_out <= 8'h3A;
                            4'h8: data_out <= to_hex_ascii(last_byte_captured[7:4]);
                            4'h9: data_out <= to_hex_ascii(last_byte_captured[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h3: begin // $x430: First Bytes Peak
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h48; // 'H'
                            4'h1: data_out <= 8'h3A; // ':'
                            4'h2: data_out <= to_hex_ascii(first_bytes[0][7:4]);
                            4'h3: data_out <= to_hex_ascii(first_bytes[0][3:0]);
                            4'h4: data_out <= 8'h20;
                            4'h5: data_out <= to_hex_ascii(first_bytes[1][7:4]);
                            4'h6: data_out <= to_hex_ascii(first_bytes[1][3:0]);
                            4'h7: data_out <= 8'h20;
                            4'h8: data_out <= to_hex_ascii(first_bytes[2][7:4]);
                            4'h9: data_out <= to_hex_ascii(first_bytes[2][3:0]);
                            4'hA: data_out <= 8'h20;
                            4'hB: data_out <= to_hex_ascii(first_bytes[3][7:4]);
                            4'hC: data_out <= to_hex_ascii(first_bytes[3][3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h4: begin // $x440: Checksum (C:XXXXXXXX) - WAS P0
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h43; // 'C'
                            4'h1: data_out <= 8'h3A; // ':'
                            4'h2: data_out <= to_hex_ascii(checksum[31:28]);
                            4'h3: data_out <= to_hex_ascii(checksum[27:24]);
                            4'h4: data_out <= to_hex_ascii(checksum[23:20]);
                            4'h5: data_out <= to_hex_ascii(checksum[19:16]); 
                            4'h6: data_out <= to_hex_ascii(checksum[15:12]);
                            4'h7: data_out <= to_hex_ascii(checksum[11:8]);
                            4'h8: data_out <= to_hex_ascii(checksum[7:4]);
                            4'h9: data_out <= to_hex_ascii(checksum[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h5: begin // $x450: P1:XX (Max Wait Counter / Timeout flag)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h31; // '1'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_max_wait[7:4]); // High nibble
                            4'h4: data_out <= to_hex_ascii(latch_max_wait[3:0]); // Low nibble
                            4'h5: data_out <= (ip_state == 2'd3 ? 8'h41 : 8'h20); // 'A' if stuck in ACTIVE
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h6: begin // $x460: P2:XX (Addr 0 - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h32; // '2'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p2[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p2[3:0]);
                            // Note: Labels A0/A1 are hardcoded below, they don't reflect actual address
                            4'h5: data_out <= 8'h41; // 'A'
                            4'h6: data_out <= 8'h30; // '0'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h7: begin // $x470: P3:XX (Addr 1 - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h33; // '3'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p3[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p3[3:0]);
                            4'h5: data_out <= 8'h41; // 'A'
                            4'h6: data_out <= 8'h31; // '1'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h8: begin // $x480: P4:XX (Addr Mid - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h34; // '4'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p4[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p4[3:0]);
                            4'h5: data_out <= 8'h41; // 'A'
                            4'h6: data_out <= 8'h32; // '2'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h9: begin // $x490: P5:XX (Burst LSB - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h35; // '5'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p5[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p5[3:0]);
                            4'h5: data_out <= 8'h42; // 'B'
                            4'h6: data_out <= 8'h30; // '0'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'hA: begin // $x4A0: P6:XX (Load Addr LSB - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h36; // '6'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p6[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p6[3:0]);
                            4'h5: data_out <= 8'h4C; // 'L' (Load)
                            4'h6: data_out <= 8'h44; // 'D'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    
                    4'hB: begin // $x4B0: P7:XX (32-bit Raw Peak - Dedicated Latch)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h37; // '7'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p7[31:28]);
                            4'h4: data_out <= to_hex_ascii(latch_p7[27:24]);
                            4'h5: data_out <= to_hex_ascii(latch_p7[23:20]);
                            4'h6: data_out <= to_hex_ascii(latch_p7[19:16]);
                            4'h7: data_out <= to_hex_ascii(latch_p7[15:12]);
                            4'h8: data_out <= to_hex_ascii(latch_p7[11:8]);
                            4'h9: data_out <= to_hex_ascii(latch_p7[7:4]);
                            4'hA: data_out <= to_hex_ascii(latch_p7[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    default: data_out <= 8'h20;
                endcase
            end
            else if (rom_index < 49152) data_out <= rom_memory[rom_index];
            else data_out <= 8'hFF;
        end
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
    
    // Clock Divider (67.5MHz -> 1.79MHz)
    // 67.5 / 1.79 ~= 37.7. Use 38.
    reg [5:0] clk_div;
    wire tick_179 = (clk_div == 37);
    
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
        .clkoutd(sys_clk),
        .lock(pll_lock)
    );
    
    // PSRAM Signals - original interface
    reg psram_rd_req;
    reg psram_wr_req;
    
    // PSRAM Interface Signals
    wire [7:0] psram_dout;
    wire psram_data_ready;
    wire psram_busy;
    
    // Bridge logic to controller interface
    wire psram_cmd_valid = psram_rd_req || psram_wr_req;
    wire psram_cmd_write = psram_wr_req;
    
    // [FIX 4] Latch Address for IP Stability
    // We cannot drive IP address directly from 'a_safe' via MUX because 'a_safe' changes
    // while IP is busy. We must latch it.
    reg [22:0] latched_ip_addr_reg; // V68: Fixed width to 23 bits

    wire [22:0] psram_cmd_addr = {7'b0, psram_addr_mux}; // V68: 23 bits
    
    wire is_psram_diag0 = (!game_loaded && a_safe >= 16'h7F40 && a_safe <= 16'h7F4F);
    wire is_psram_diag1 = (!game_loaded && a_safe >= 16'h7F50 && a_safe <= 16'h7F5F);
    wire is_psram_diag2 = (!game_loaded && a_safe >= 16'h7F60 && a_safe <= 16'h7F6F);
    wire is_psram_diag3 = (!game_loaded && a_safe >= 16'h7F70 && a_safe <= 16'h7F7F);
    wire is_psram_diag4 = (!game_loaded && a_safe >= 16'h7F80 && a_safe <= 16'h7F8F);
    wire is_psram_diag5 = (!game_loaded && a_safe >= 16'h7F90 && a_safe <= 16'h7F9F);
    wire is_psram_diag6 = (!game_loaded && a_safe >= 16'h7FA0 && a_safe <= 16'h7FAF);
    wire is_psram_diag7 = (!game_loaded && a_safe >= 16'h7FB0 && a_safe <= 16'h7FBF);
    
    // [FIX 2] Simplified Address Mux
    // P2(Diag2), P3(Diag3), P7(Diag6) ALL READ ADDRESS 0
    // V62: Use LATCHED write address for IP to avoid race with loop increment
    reg [22:0] psram_write_addr_latched;
    
    wire [21:0] psram_addr_mux = (game_loaded)   ? {6'b0, a_safe} - 22'h004000 : 
                                 (is_psram_diag0) ? 22'h000000 : 
                                 (is_psram_diag1) ? 22'h000001 : 
                                 (is_psram_diag2) ? 22'h000000 : // P2 Force Addr 0
                                 (is_psram_diag3) ? 22'h000000 : // P3 Force Addr 0
                                 (is_psram_diag6) ? 22'h000000 : // P7 Force Addr 0
                                 {psram_write_addr_latched[21:0]};
    
    reg [7:0] psram_read_latch;
    reg [2:0] psram_busy_sync;
    // [OPTIMIZATION] Old Latch Logic - Removed for Low Latency
    // always @(posedge sys_clk) begin
    //    psram_busy_sync <= {psram_busy_sync[1:0], psram_busy};
    //    // Capture on Fall of Busy (Stable Data)
    //    if (!psram_busy_sync[1] && psram_busy_sync[2]) begin
    //        psram_read_latch <= psram_dout;
    //    end
    // end
    // reg [2:0] psram_busy_sync; // Removed duplicate
    
    // Write Buffer for Reliable Data Transfer
    // V66: 128-bit Accumulator (16 Bytes)
    
    // --- PSRAM Read Blinker Declarations ---
    reg state_read;
    reg [22:0] timer_read;
    reg [31:0] acc_word0;
    reg [31:0] acc_word1;
    reg [31:0] acc_word2;
    reg [31:0] acc_word3;
    reg [22:0] burst_start_addr; 
    
    // --- Direction / Drive Blinker Declarations ---
    reg state_dir;
    reg [22:0] timer_dir;
 
    
    reg write_pending;
    
    // V65: Use 32-bit mux for IP input (captured from accumulator)
    // Removed unused mux logic
    
    // Gowin PSRAM IP signals (32-bit interface)
    reg         ip_cmd_en;
    wire [20:0] ip_addr;
    wire [31:0] ip_wr_data;
    wire [31:0] ip_rd_data;
    wire        ip_rd_data_valid;
    wire        ip_init_calib;
    wire        ip_clk_out;
    
    // CDC synchronizers for signals crossing from 54MHz to 27MHz domain
    reg [2:0] rd_valid_sync;
    reg [2:0] init_calib_sync;
    wire rd_valid_sync_pulse;
    wire init_calib_synced;
    
    always @(posedge sys_clk) begin
        rd_valid_sync <= {rd_valid_sync[1:0], ip_rd_data_valid};
        init_calib_sync <= {init_calib_sync[1:0], ip_init_calib};
    end
    
    // Detect rising edge of rd_data_valid
    assign rd_valid_sync_pulse = rd_valid_sync[1] && !rd_valid_sync[2];
    assign init_calib_synced = init_calib_sync[2];
    
    // Byte-level conversion logic
    // [FIX 4] Drive IP Address from LATCHED register, NOT direct Mux
    assign ip_addr = latched_ip_addr_reg[21:2];
    
    // [FIX 5] Latch Write Data inside IP Controller to avoid Race Condition
    // V65: 32-bit Latch
    reg [31:0] ip_wr_data_latch;
    assign ip_wr_data = ip_wr_data_latch;

    // [FIX 3] Simplified Masking
    // V65: ALWAYS ENABLE ALL LANES (Mask 0000) for 32-bit writes
    reg [3:0] ip_data_mask;  
    // Read: extract byte based on address[1:0]
    reg [7:0] extracted_byte;
    always @(*) begin
        case (latched_ip_addr_reg[1:0])
            2'd0: extracted_byte = ip_rd_data[7:0];   // Atari Byte 0 from PSRAM Lane 0
            2'd1: extracted_byte = ip_rd_data[15:8];  // Atari Byte 1 from PSRAM Lane 1
            2'd2: extracted_byte = ip_rd_data[23:16]; // Atari Byte 2 from PSRAM Lane 2
            2'd3: extracted_byte = ip_rd_data[31:24]; // Atari Byte 3 from PSRAM Lane 3
        endcase
    end
    
    // State machine for IP control
    // State machine for IP control
    localparam IP_WAIT_INIT = 2'd0;
    localparam IP_IDLE = 2'd1;
    localparam IP_SETUP = 2'd2;
    localparam IP_ACTIVE = 2'd3;
    
    reg [1:0] ip_state;
    reg [7:0] ip_data_buffer;
    reg [7:0] ip_wait_count;  // Extended to 8-bit for longer timeout
    reg       ip_is_write;    // Remember if current operation is write
    reg [1:0] latched_byte_offset; // V51v: Latch byte offset
    
    assign psram_dout = ip_data_buffer;
    assign psram_data_ready = (ip_state == IP_IDLE) && init_calib_synced;
    assign psram_busy = !init_calib_synced || (ip_state != IP_IDLE) || ip_cmd_en;
    
    reg [7:0] latch_max_wait;
    
    always @(posedge sys_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            ip_state <= IP_WAIT_INIT;
            ip_cmd_en <= 1'b0;
            ip_data_buffer <= 8'h00;
            ip_wait_count <= 8'h0;
            ip_is_write <= 1'b0;
            latched_ip_addr_reg <= 0;
            ip_wr_data_latch <= 0;
            latch_max_wait <= 0;
        end else begin
            case (ip_state)
                IP_WAIT_INIT: begin
                    if (init_calib_synced) begin
                        ip_state <= IP_IDLE;
                    end
                end
                
                IP_IDLE: begin
                    if (psram_cmd_valid && init_calib_synced) begin
                        // [FIX 4] LATCH ADDRESS HERE
                        if (psram_cmd_write) latched_ip_addr_reg <= psram_write_addr_latched; 
                        else latched_ip_addr_reg <= psram_cmd_addr; // Reads use Mux
                        
                        // [FIX 5] Latch Write Data here to ensure stability
                        if (psram_cmd_write) begin
                            ip_wr_data_latch <= acc_word0; // First word
                            
                            // [FIX 6] MASKING SETUP: Enable the FIRST word
                            ip_data_mask <= 4'b0000;
                            
                            ip_wait_count <= 8'h0;
                            ip_is_write <= 1'b1;
                            ip_state <= IP_SETUP; // Writers go to SETUP
                        end else begin
                            // [OPTIMIZATION] READS SKIP SETUP!
                            // Issue command immediately
                            ip_cmd_en <= 1'b1;
                            
                            // Latch byte offset immediately for read routing
                            latched_byte_offset <= psram_cmd_addr[1:0];
                            
                            ip_wait_count <= 8'h0;
                            ip_is_write <= 1'b0;
                            ip_state <= IP_ACTIVE; // Readers go directly to ACTIVE
                        end

                    end else begin
                        ip_cmd_en <= 1'b0;
                        // Default mask state (optional, but good safety)
                        ip_data_mask <= 4'b0000; 
                    end
                end
                
                IP_SETUP: begin
                    // ONLY WRITES COME HERE NOW
                    
                    // V51u: One cycle setup, then assert cmd_en
                    ip_cmd_en <= 1'b1;
                    
                    // CRITICAL FIX: DO NOT set mask to 1111 yet!
                    // We need the mask to be 0000 during the NEXT cycle (when cmd_en is seen)
                    // so that the FIRST word is written.
                    // Keep mask 0000 (set in IDLE).
                    
                    ip_state <= IP_ACTIVE;
                end
                
                IP_ACTIVE: begin
                    // Pulse cmd_en for 1 cycle
                    ip_cmd_en <= 1'b0;
                    
                    // CRITICAL FIX: Mask the TAIL of the burst.
                    // Now that the command is issued, we must block writes for the
                    // remaining 3 words of the burst (Cycles 2, 3, 4).
                    if (ip_is_write) ip_data_mask <= 4'b1111; 
                    
                    // Note: We don't need to reset to 0000 here. 
                    // IP_IDLE handles the reset to 0000 for the next transaction.

                    ip_wait_count <= ip_wait_count + 1'b1;
                    if (ip_wait_count > latch_max_wait) latch_max_wait <= ip_wait_count;
                    
                    if (ip_rd_data_valid) begin
                         // READ LOGIC (Unchanged - this part is correct)
                         // It captures the first word and exits immediately, 
                         // effectively masking the read burst.
                        case (active_req_source)
                            3'd1: latch_p2 <= ip_rd_data[7:0]; 
                            3'd2: latch_p3 <= psram_write_addr_latched[7:0];   
                            3'd3: latch_p7 <= ip_rd_data; 
                            3'd4: latch_p4 <= psram_write_addr_latched[15:8];  
                            default: begin
                                ip_data_buffer <= (latched_byte_offset == 0) ? ip_rd_data[7:0] :
                                                  (latched_byte_offset == 1) ? ip_rd_data[15:8] :
                                                  (latched_byte_offset == 2) ? ip_rd_data[23:16] : ip_rd_data[31:24];
                            end
                        endcase
                        ip_state <= IP_IDLE;

                    end else if (ip_is_write && ip_wait_count >= 8'd15) begin
                        ip_state <= IP_IDLE;
                    end else if (!ip_is_write && ip_wait_count >= 8'd250) begin // Increased to 250 (max 8-bit)
                        ip_data_buffer <= 8'hEE;
                        ip_state <= IP_IDLE;
                    end else if (ip_wait_count >= 8'd255) begin
                        ip_state <= IP_IDLE;
                    end
                end
                
                default: ip_state <= IP_WAIT_INIT;
            endcase
        end
    end
    
    // Instantiate Gowin PSRAM IP (at top level for auto-routing)
    PSRAM_Memory_Interface_HS_Top psram_ip (
        .clk(sys_clk),              // 27MHz system clock
        .memory_clk(clk_81m),       // 54MHz PSRAM clock
        .pll_lock(pll_lock),        // PLL lock signal
        .rst_n(pll_lock),           // Active-high reset
        
        // [FIX 1] Use ip_is_write (latched) instead of psram_cmd_write (transient)
        // psram_cmd_write drops to 0 before cmd_en goes high!
        .cmd(ip_is_write),      // 0=read, 1=write
        .cmd_en(ip_cmd_en),
        .addr(ip_addr),
        .wr_data(ip_wr_data),
        .data_mask(ip_data_mask),    // Use byte mask to prevent neighbor overwrites
        .rd_data(ip_rd_data),
        .rd_data_valid(ip_rd_data_valid),
        .init_calib(ip_init_calib),
        .clk_out(ip_clk_out),
        
        // PSRAM Hardware Interface
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );
    
    // PSRAM Read/Write Logic (CDC Handshake)
    
    // 1. Read Logic (Game Mode)
    // Trigger read on Address Change (Prefetch) to gain timing margin.
    reg should_drive_d;
    always @(posedge sys_clk) should_drive_d <= should_drive;
    
    reg [15:0] a_prev;
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
    
    // Only trigger read once per entry to diagnostic region
    wire diag_read_trigger = !game_loaded && rw_safe && 
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
    reg [7:0] latch_p2;
    reg [7:0] latch_p3;
    reg [7:0] latch_p4; // V71: Added
    reg [7:0] latch_p5; // V71: Added
    reg [7:0] latch_p6; // V75: Added for Load Addr Debug
    reg [31:0] latch_p7;
    reg [2:0] active_req_source; // V71: Extended to 3 bits (support up to 7)
    
    reg [15:0] last_req_addr;
    reg last_req_rw;
    
    always @(posedge sys_clk) begin
        a_prev <= a_safe;
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
        if (ip_rd_data_valid) active_req_source <= 0;
        
        if (!sd_reset) begin
             // READ REQUEST (Trigger on Address change, OR diag peak)
             // CRITICAL FIX: PREFETCH ENABLED
             // We trigger the read the moment `a_safe` changes, regardless of `phi2` state.
             // The 6502 asserts the address during PHI1 (or late PHI2 of prev cycle). 
             // We want the 750ns PSRAM IP to start working IMMEDIATELY.
             if ((game_loaded && is_rom && !psram_busy && (a_safe != last_req_addr)) || 
                 (diag_read_trigger && !psram_busy)) begin
                   psram_rd_req <= 1;
                   last_req_addr <= a_safe; // Immediately record that we are requesting this address
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
             else if (ip_state == IP_ACTIVE) begin 
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
    reg [7:0] sd_dout_reg;          // Registered SD data
    
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

    reg [7:0] first_bytes [0:7];
    reg [7:0] last_byte_captured;
    reg [22:0] psram_load_addr;
    reg game_loaded;
        
    // Simplified Sequential Loader (Full Implementation)
    localparam SD_IDLE       = 0;
    localparam SD_START      = 1;
    localparam SD_WAIT       = 2;
    localparam SD_DATA       = 3;
    localparam SD_NEXT       = 4;
    localparam SD_COMPLETE   = 5;

    // Game constants (astrowing.a78 = 48KB + 128b Header = 97 Sectors)
    localparam GAME_SIZE_SECTORS = 97;
    
    reg [6:0] current_sector;
    
    reg byte_arrived_latched;

    always @(posedge sys_clk) begin
        if (sd_reset) begin
             sd_state <= SD_IDLE;
             sd_rd <= 0;
             sd_address <= 0;
             byte_index <= 0;
             led_debug_byte <= 0;
             led_0_toggle <= 0;
             game_loaded <= 0;
             psram_wr_req <= 0;
             // V66: 128-bit Accumulator (16 Bytes)
             acc_word0 <= 0;
             acc_word1 <= 0;
             acc_word2 <= 0;
             acc_word3 <= 0;
             // Latch trigger address
             burst_start_addr <= 0;
             
             write_pending <= 0;
              busy <= 1; // Start busy for initial load
              armed <= 0;
             
             current_sector <= 0;
             // V61: Exact 128-byte offset (byte 128 -> addr 0)
             psram_load_addr <= 23'h000000; // V70: Simplified, start at 0
             sd_byte_available_d <= 0;
             pattern_buf <= 0;
             checksum <= 0;
             sd_dout_reg <= 0;
             byte_arrived_latched <= 0;
        end else begin
             sd_byte_available_d <= sd_byte_available;

             // Edge Detection for Latch (V63)
             if (sd_byte_available && !sd_byte_available_d) 
                 byte_arrived_latched <= 1;
             
             // --- INDEPENDENT PSRAM WRITE HANDSHAKE (V51c: Sequential) ---
             if (psram_wr_req) begin
                  psram_wr_req <= 0;
                  // V51r: Increment REMOVED (V62)
                  // psram_load_addr <= psram_load_addr + 1; 
             end else if (write_pending && !psram_busy) begin
                  psram_wr_req <= 1;
                  write_pending <= 0;
             end
            
            case (sd_state)
                SD_IDLE: begin
                    if (sd_ready && sd_status == 6) begin
                        sd_state <= SD_START;
                        busy <= 1;
                    end
                end
                
                SD_START: begin
                    sd_address <= current_sector;
                    sd_rd <= 1;
                    byte_index <= 0;
                    sd_state <= SD_WAIT;
                end
                
                SD_WAIT: begin
                     // Flow Control: Pause SD (sd_rd=0) if we are busy writing
                     sd_rd <= !write_pending;
                     
                     // V63: Use Latch instead of Edge
                     if (byte_arrived_latched && !write_pending) begin
                         sd_dout_reg <= sd_dout;
                         byte_arrived_latched <= 0; // Clear Latch
                         sd_state <= SD_DATA;
                     end else if (byte_index >= 512 && !write_pending) begin
                         sd_state <= SD_NEXT;
                     end else if (sd_ready && byte_index > 0 && !write_pending) begin
                         sd_state <= SD_NEXT;
                     end
                 end
                  
                  SD_DATA: begin
                         // Accumulate 32-bit words (Little Endian: Byte 0 -> [7:0])
                         // V72: Switch to Little Endian to match PSRAM byte lane order
                         // Byte Index 0 -> [7:0], Byte Index 3 -> [31:24]
                         
                         case (byte_index[3:2]) // Select Word
                             2'b00: begin // Word 0
                                 case (byte_index[1:0])
                                     2'b00: acc_word0[7:0]   <= sd_dout_reg;
                                     2'b01: acc_word0[15:8]  <= sd_dout_reg;
                                     2'b10: acc_word0[23:16] <= sd_dout_reg;
                                     2'b11: acc_word0[31:24] <= sd_dout_reg;
                                 endcase
                             end
                             2'b01: begin // Word 1
                                 case (byte_index[1:0])
                                     2'b00: acc_word1[7:0]   <= sd_dout_reg;
                                     2'b01: acc_word1[15:8]  <= sd_dout_reg;
                                     2'b10: acc_word1[23:16] <= sd_dout_reg;
                                     2'b11: acc_word1[31:24] <= sd_dout_reg;
                                 endcase
                             end
                             2'b10: begin // Word 2
                                 case (byte_index[1:0])
                                     2'b00: acc_word2[7:0]   <= sd_dout_reg;
                                     2'b01: acc_word2[15:8]  <= sd_dout_reg;
                                     2'b10: acc_word2[23:16] <= sd_dout_reg;
                                     2'b11: acc_word2[31:24] <= sd_dout_reg;
                                 endcase
                             end
                             2'b11: begin // Word 3
                                 case (byte_index[1:0])
                                     2'b00: acc_word3[7:0]   <= sd_dout_reg;
                                     2'b01: acc_word3[15:8]  <= sd_dout_reg;
                                     2'b10: acc_word3[23:16] <= sd_dout_reg;
                                     2'b11: acc_word3[31:24] <= sd_dout_reg;
                                 endcase
                             end
                         endcase
                         
                         // Skip 128-byte Header
                         if (current_sector > 0 || byte_index >= 128) begin
                              // Trigger Write on 16th byte
                              // Trigger Write on 16th byte
                              if (byte_index[3:0] == 4'hF) begin
                                  write_pending <= 1;
                                  // V73: Calculate Base Address directly from current load address (Robust)
                                  // current load addr is 15, 31, etc. Masking low 4 bits gives 0, 16, etc.
                                  psram_write_addr_latched <= {psram_load_addr[22:4], 4'b0000};
                                  
                                  if (current_sector == 0) begin if (byte_index == 143) latch_p5 <= psram_load_addr[7:0]; if (byte_index == 159) latch_p6 <= psram_load_addr[7:0]; end                             end
                             
                             checksum <= checksum + sd_dout_reg;
                             last_byte_captured <= sd_dout_reg;
                             
                             // RESTORED Debug Capture
                             if (current_sector == 0) begin
                                 if (byte_index == 128) first_bytes[0] <= sd_dout_reg;
                                 else if (byte_index == 129) first_bytes[1] <= sd_dout_reg;
                                 else if (byte_index == 130) first_bytes[2] <= sd_dout_reg;
                                 else if (byte_index == 131) first_bytes[3] <= sd_dout_reg;
                                 else if (byte_index == 132) first_bytes[4] <= sd_dout_reg;
                                 else if (byte_index == 133) first_bytes[5] <= sd_dout_reg;
                                 else if (byte_index == 134) first_bytes[6] <= sd_dout_reg;
                                 else if (byte_index == 135) first_bytes[7] <= sd_dout_reg;
                             end
                             
                             // V69: Only increment target address in valid data region
                             psram_load_addr <= psram_load_addr + 1; 
                         end
                         
                         byte_index <= byte_index + 1;
                         sd_state <= SD_WAIT;
                  end

                 
                 SD_NEXT: begin
                     psram_wr_req <= 0;
                     if (current_sector < 96) begin // 0 to 96 = 97 sectors
                          current_sector <= current_sector + 1;
                          sd_state <= SD_START;
                      end else begin
                          sd_state <= SD_COMPLETE;
                          busy <= 0;
                      end
                  end
                 
                 SD_COMPLETE: begin
                     // Load Done. 
                     // Wait for Menu Trigger.
                     // TRIGGER: Write 0xA5 to Address $8000
                     // WHY $8000? 
                     // 1. It is ROM space. The Atari OS RAM test NEVER writes here.
                     // 2. It avoids all POKEY/TIA/RIOT hardware mirrors.
                     // 3. It works even if the FPGA is emulating ROM at that address 
                     //    (because FPGA tristates data bus on Writes).
                     
                     if (a_safe == 16'h2200 && !rw_safe && phi2_safe) begin
                         if (!game_loaded && d == 8'hA5) begin
                             // LOCK: Switch to Game Mode
                             game_loaded <= 1;
                         end
                         else if (d == 8'h5A) begin
                             // RELOAD: Magic Key 0x5A
                             // Only allow reload for testing/debugging
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 23'h000000;
                             checksum <= 0;
                             busy <= 1;
                             game_loaded <= 0; // Force unload
                         end
                     end
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
    
    localparam ACTIVITY_TIMEOUT = 23'h330000; // ~50ms at 67.5MHz
    
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
    
    reg [24:0] heartbeat;

    localparam BLINK_DUR = 23'h4D0000; // ~75ms at 67.5MHz

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
    
    // --- Direction / Drive Blinker Logic ---
    // Blink when we switch to Output Mode (DIR=1)
    always @(posedge sys_clk) begin
        if (state_dir) begin
             if (timer_dir == 0) begin
                 state_dir <= 0;
                 timer_dir <= BLINK_DUR;
             end else timer_dir <= timer_dir - 1;
        end else begin
             if (timer_dir > 0) timer_dir <= timer_dir - 1;
             else if (buf_dir == 1'b1) begin // Trigger on OUTPUT direction
                 state_dir <= 1;
                 timer_dir <= BLINK_DUR;
             end
        end
    end

    // --- PSRAM Read Blinker Logic ---
    // Blink when Data is Valid (Read Complete)
    always @(posedge sys_clk) begin
        if (state_read) begin
             if (timer_read == 0) begin
                 state_read <= 0;
                 timer_read <= BLINK_DUR;
             end else timer_read <= timer_read - 1;
        end else begin
             if (timer_read > 0) timer_read <= timer_read - 1;
             else if (ip_rd_data_valid) begin // Trigger on Read Data Valid
                 state_read <= 1;
                 timer_read <= BLINK_DUR;
             end
        end
    end


    // LED Assignments (Full Loader Mode)
    // Active LOW LEDs. 
    assign led[0] = !pll_lock;      // ON when Locked
    assign led[1] = game_loaded;    // ON when Game Mode
    assign led[2] = !phi2_safe;     // ON when PHI2 activity
    assign led[3] = !state_dir;      // ON when Driving Bus (Output Mode)

    assign led[4] = write_pending;  // ON when Write active
    assign led[5] = !state_read;    // ON when Reading (Active Low)
    
    // --- Oscilloscope Debug Pins ---
    // High-speed 1.8V outputs for accurate timing measurement
    assign debug_pin1 = psram_rd_req;     // Probe 1: Start of Read Request
    assign debug_pin2 = ip_rd_data_valid; // Probe 2: Data return from PSRAM IP
    
endmodule