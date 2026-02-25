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
    reg [3:0] sd_state; // Moved up for visibility
    
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
            if (a_stable >= 16'h7F00 && a_stable <= 16'h7FBF) begin
                // Use a_stable[7:4] to select the diagnostic output (0-B = 12 outputs)
                case (a_stable[7:4])
                    4'h0: begin // $x400: SD Word 0 (A9 50 85 3C)
                        case (a_stable[3:0])
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
                        case (a_stable[3:0])
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
                        case (a_stable[3:0])
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
                        case (a_stable[3:0])
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
                        case (a_stable[3:0])
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
                    4'h5: begin // $x450: P0:XXXXXXXX (PSRAM Checksum)
                        case (a_stable[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h30; // '0'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(psram_checksum[31:28]);
                            4'h4: data_out <= to_hex_ascii(psram_checksum[27:24]);
                            4'h5: data_out <= to_hex_ascii(psram_checksum[23:20]);
                            4'h6: data_out <= to_hex_ascii(psram_checksum[19:16]);
                            4'h7: data_out <= to_hex_ascii(psram_checksum[15:12]);
                            4'h8: data_out <= to_hex_ascii(psram_checksum[11:8]);
                            4'h9: data_out <= to_hex_ascii(psram_checksum[7:4]);
                            4'hA: data_out <= to_hex_ascii(psram_checksum[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h6: begin // $x460: P2:XX (crc_burst word 1)
                        case (a_stable[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h32; // '2'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p2[31:28]);
                            4'h4: data_out <= to_hex_ascii(latch_p2[27:24]);
                            4'h5: data_out <= to_hex_ascii(latch_p2[23:20]);
                            4'h6: data_out <= to_hex_ascii(latch_p2[19:16]);
                            4'h7: data_out <= to_hex_ascii(latch_p2[15:12]);
                            4'h8: data_out <= to_hex_ascii(latch_p2[11:8]);
                            4'h9: data_out <= to_hex_ascii(latch_p2[7:4]);
                            4'hA: data_out <= to_hex_ascii(latch_p2[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h7: begin // $x470: P3:XX (crc_burst word 2)
                        case (a_stable[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h33; // '3'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p3[31:28]);
                            4'h4: data_out <= to_hex_ascii(latch_p3[27:24]);
                            4'h5: data_out <= to_hex_ascii(latch_p3[23:20]);
                            4'h6: data_out <= to_hex_ascii(latch_p3[19:16]);
                            4'h7: data_out <= to_hex_ascii(latch_p3[15:12]);
                            4'h8: data_out <= to_hex_ascii(latch_p3[11:8]);
                            4'h9: data_out <= to_hex_ascii(latch_p3[7:4]);
                            4'hA: data_out <= to_hex_ascii(latch_p3[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h8: begin // $x480: P4:XX (Addr Mid - Dedicated Latch)
                        case (a_stable[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h34; // '4'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(latch_p4[7:4]);
                            4'h4: data_out <= to_hex_ascii(latch_p4[3:0]);
                            4'h5: data_out <= 8'h41; // 'A'
