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
    output [5:0] led       // Debug LEDs
);

    // ========================================================================
    // 0. CLOCK GENERATION (27MHz native for Atari, 60MHz PLL for PSRAM)
    // ========================================================================
    wire sys_clk = clk;     // 27MHz native

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
        if (!game_loaded && a_safe == 16'h0458 && rw_safe) begin
             // Status Read (POKEY Base + 8)
             data_out <= status_byte;
        end
        else if (game_loaded) begin
             data_out <= psram_read_latch; 
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
                    4'h4: begin // $x440: P0:XX (IP State + Init)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h30; // '0'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= (init_calib_synced ? 8'h49 : 8'h2D); // 'I' or '-'
                            4'h4: data_out <= (ip_state == IP_WAIT_INIT) ? 8'h57 :  // 'W'
                                              (ip_state == IP_IDLE) ? 8'h49 :        // 'I'
                                              (ip_state == IP_ACTIVE) ? 8'h41 : 8'h3F; // 'A' or '?'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h5: begin // $x450: P1:XX (Wait counter + sync status)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h31; // '1'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(ip_wait_count[7:4]); // High nibble (Timeout detection)
                            4'h4: data_out <= to_hex_ascii(ip_wait_count[3:0]); // Low nibble
                            4'h5: data_out <= (psram_busy ? 8'h42 : 8'h2D);       // 'B' if busy
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
                    4'h8: begin // $x480: P4:XX (address debug)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h34; // '4'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(a_safe[15:12]); // Address high nibble
                            4'h4: data_out <= to_hex_ascii(a_safe[11:8]);
                            4'h5: data_out <= to_hex_ascii(a_safe[7:4]);
                            4'h6: data_out <= to_hex_ascii(a_safe[3:0]);   // Address low nibble
                            4'h7: data_out <= (game_loaded ? 8'h47 : 8'h2D); // 'G' if game_loaded, '-' if not
                            4'h8: data_out <= (is_psram_diag4 ? 8'h44 : 8'h2D); // 'D' if diag4 detected
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'h9: begin // $x490: P5:XX (IP raw valid + init + busy)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h35; // '5'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= (ip_rd_data_valid ? 8'h52 : 8'h2D); // 'R' if raw valid, '-' if not
                            4'h4: data_out <= (ip_init_calib ? 8'h49 : 8'h2D);    // 'I' if init, '-' if not
                            4'h5: data_out <= (psram_busy ? 8'h42 : 8'h2D);       // 'B' if busy
                            default: data_out <= 8'h20;
                        endcase
                    end
                    4'hA: begin // $x4A0: P6:XX (ip_rd_data[7:0])
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h36; // '6'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(ip_rd_data[7:4]);
                            4'h4: data_out <= to_hex_ascii(ip_rd_data[3:0]);
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
    
    // Power-on reset for SD controller
    // Use PLL lock as reset - gives ~50ms initialization time
    wire sd_reset = !pll_lock;

    // ========================================================================
    // 7. PSRAM CONTROLLER (Gowin IP)
    // ========================================================================
    
    gowin_pll pll_inst (
        .clkin(sys_clk),
        .clkout(clk_81m),
        .clkoutp(clk_81m_shifted),
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
    reg [21:0] latched_ip_addr_reg;

    wire [21:0] psram_cmd_addr = {6'b0, psram_addr_mux};
    
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
    wire [21:0] psram_addr_mux = (game_loaded)   ? {6'b0, a_safe} - 22'h004000 : 
                                 (is_psram_diag0) ? 22'h000000 : 
                                 (is_psram_diag1) ? 22'h000001 : 
                                 (is_psram_diag2) ? 22'h000000 : // P2 Force Addr 0
                                 (is_psram_diag3) ? 22'h000000 : // P3 Force Addr 0
                                 (is_psram_diag6) ? 22'h000000 : // P7 Force Addr 0
                                 {psram_load_addr[21:0]};
    
    reg [7:0] psram_read_latch;
    reg [2:0] psram_busy_sync;
    always @(posedge sys_clk) begin
        psram_busy_sync <= {psram_busy_sync[1:0], psram_busy};
        // Capture on Fall of Busy (Stable Data)
        if (!psram_busy_sync[1] && psram_busy_sync[2]) begin
            psram_read_latch <= psram_dout;
        end
    end
    
    // Write Buffer for Reliable Data Transfer
    reg [7:0] write_buffer;
    reg write_pending;
    
    // V61: Removed forced data to see actual file content
    wire [7:0] psram_din_mux = write_buffer;
    
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
    
    // Write: replicate byte across all 4 bytes
    assign ip_wr_data = {4{psram_din_mux}};

    // [FIX 3] Simplified Masking
    // Use latched address for masking too
    reg [3:0] ip_data_mask_dyn;
    always @(*) begin
        case (latched_ip_addr_reg[1:0])
            2'b00: ip_data_mask_dyn = 4'b1011; // Atari Byte 0 -> PSRAM Lane 2
            2'b01: ip_data_mask_dyn = 4'b0111; // Atari Byte 1 -> PSRAM Lane 3
            2'b10: ip_data_mask_dyn = 4'b1110; // Atari Byte 2 -> PSRAM Lane 0
            2'b11: ip_data_mask_dyn = 4'b1101; // Atari Byte 3 -> PSRAM Lane 1
        endcase
    end
    
    // Assign the dynamic mask
    wire [3:0] ip_data_mask = ip_data_mask_dyn; 
    
    // Read: extract byte based on address[1:0]
    reg [7:0] extracted_byte;
    always @(*) begin
        case (latched_ip_addr_reg[1:0])
            2'd0: extracted_byte = ip_rd_data[23:16]; // Atari Byte 0 from PSRAM Lane 2
            2'd1: extracted_byte = ip_rd_data[31:24]; // Atari Byte 1 from PSRAM Lane 3
            2'd2: extracted_byte = ip_rd_data[7:0];   // Atari Byte 2 from PSRAM Lane 0
            2'd3: extracted_byte = ip_rd_data[15:8];  // Atari Byte 3 from PSRAM Lane 1
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
    
    always @(posedge sys_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            ip_state <= IP_WAIT_INIT;
            ip_cmd_en <= 1'b0;
            ip_data_buffer <= 8'h00;
            ip_wait_count <= 8'h0;
            ip_is_write <= 1'b0;
            latched_ip_addr_reg <= 0;
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
                        latched_ip_addr_reg <= psram_cmd_addr;
                        
                        ip_wait_count <= 8'h0;
                        ip_is_write <= psram_cmd_write;
                        ip_state <= IP_SETUP;
                    end else begin
                        ip_cmd_en <= 1'b0;
                    end
                end
                
                IP_SETUP: begin
                    // V51v: Latch byte offset for stable capture
                    latched_byte_offset <= latched_ip_addr_reg[1:0];
                    // V51u: One cycle setup, then assert cmd_en
                    ip_cmd_en <= 1'b1;
                    ip_state <= IP_ACTIVE;
                end
                
                IP_ACTIVE: begin
                    // V51v: Extend cmd_en to 2 cycles? No, keep 1 cycle pulse but use latched offset
                    ip_cmd_en <= 1'b0;
                    ip_wait_count <= ip_wait_count + 1'b1;
                    
                    if (ip_rd_data_valid) begin
                        // Read completed - capture from IP output
                        // V53: Route to dedicated latch based on source
                        case (active_req_source)
                            2'd1: latch_p2 <= ip_rd_data[7:0]; // Force Byte 0
                            2'd2: latch_p3 <= ip_rd_data[7:0]; // Force Byte 0
                            2'd3: latch_p7 <= ip_rd_data;
                            default: ip_data_buffer <= (latched_byte_offset == 0) ? ip_rd_data[7:0] :
                                                       (latched_byte_offset == 1) ? ip_rd_data[15:8] :
                                                       (latched_byte_offset == 2) ? ip_rd_data[23:16] : ip_rd_data[31:24];
                        endcase
                        // NOTE: active_req_source is cleared in the Request Block to avoid Multi-Driver!

                        ip_state <= IP_IDLE;
                    end else if (ip_is_write && ip_wait_count >= 8'd15) begin
                        // Write completed after minimum 15 cycles (more conservative)
                        ip_state <= IP_IDLE;
                    end else if (!ip_is_write && ip_wait_count >= 8'd50) begin
                        // Read timeout - something went wrong, recover
                        ip_data_buffer <= 8'hEE;  // Error marker
                        ip_state <= IP_IDLE;
                    end else if (ip_wait_count >= 8'd100) begin
                        // General timeout - force recovery
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
                             (is_psram_diag6 && !diag6_read_done) ||
                             (is_psram_diag7 && !diag7_read_done));
    
    reg [7:0] trigger_counter;
    reg [11:0] diag_exit_timer;
    
    // V52: Dedicated Diagnostic Latches
    reg [7:0] latch_p2;
    reg [7:0] latch_p3;
    reg [31:0] latch_p7;
    reg [1:0] active_req_source; // 0=None, 1=P2(Diag2), 2=P3(Diag3), 3=P7(Diag6)
    
    always @(posedge sys_clk) begin
        a_prev <= a_safe;
        rw_prev <= rw_safe;
        
        // Reset read-done flags when definitely OUT of diagnostic regions for a while
        if (!in_any_diag) begin
            if (diag_exit_timer < 12'hFFF) diag_exit_timer <= diag_exit_timer + 1;
            else begin
                diag0_read_done <= 0;
                diag1_read_done <= 0;
                diag2_read_done <= 0;
                diag3_read_done <= 0;
                diag4_read_done <= 0;
                diag5_read_done <= 0;
                diag6_read_done <= 0;
                diag7_read_done <= 0;
            end
        end else begin
            diag_exit_timer <= 0;
        end
        
        // [FIX 1] Clear Source in the SAME BLOCK to avoid Multi-Driver error
        if (ip_rd_data_valid) active_req_source <= 0;
        
        if (!sd_reset) begin
             // READ REQUEST (Trigger on Address or RW change, OR diag peak)
             if ((game_loaded && is_rom && rw_safe && !psram_busy && ((a_safe != a_prev) || (rw_safe != rw_prev))) || 
                 (diag_read_trigger && !psram_busy)) begin
                   psram_rd_req <= 1;
                   
                   // Mark diagnostic region as read & Set Source
                   if (diag_read_trigger) begin
                       trigger_counter <= trigger_counter + 1;
                       if (is_psram_diag0) diag0_read_done <= 1;
                       if (is_psram_diag1) diag1_read_done <= 1;
                       
                       if (is_psram_diag2) begin
                           diag2_read_done <= 1;
                           active_req_source <= 2'd1; // P2 Request
                       end
                       
                       if (is_psram_diag3) begin
                           diag3_read_done <= 1;
                           active_req_source <= 2'd2; // P3 Request
                       end
                       
                       if (is_psram_diag4) diag4_read_done <= 1;
                       if (is_psram_diag5) diag5_read_done <= 1;
                       
                       if (is_psram_diag6) begin // P7 maps here
                           diag6_read_done <= 1;
                           active_req_source <= 2'd3; // P7 Request
                       end
                       
                       if (is_psram_diag7) diag7_read_done <= 1;
                   end
             end
             else if (ip_state == IP_ACTIVE) begin 
                   // Safely clear request once acknowledged by the state machine
                   psram_rd_req <= 0; 
             end
             else if (!game_loaded && !in_any_diag) psram_rd_req <= 0; // Menu Mode safety (but allow diagnostics)
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
             write_buffer <= 0;
             write_pending <= 0;
              busy <= 1; // Start busy for initial load
              armed <= 0;
             
             current_sector <= 0;
             // V61: Exact 128-byte offset (byte 128 -> addr 0)
             psram_load_addr <= 23'h7FFF80; 
             sd_byte_available_d <= 0;
             pattern_buf <= 0;
             checksum <= 0;
             sd_dout_reg <= 0;
        end else begin
             sd_byte_available_d <= sd_byte_available;

              // --- INDEPENDENT PSRAM WRITE HANDSHAKE (V51c: Sequential) ---
              if (psram_wr_req) begin
                   psram_wr_req <= 0;
                   // V51r: Increment moved to SD_DATA to avoid race
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
                      if (sd_byte_available && !sd_byte_available_d) begin
                          sd_dout_reg <= sd_dout;
                          sd_state <= SD_DATA;
                      end else if (byte_index >= 512 && !write_pending) begin
                          sd_state <= SD_NEXT;
                      end else if (sd_ready && byte_index > 0 && !write_pending) begin
                          sd_state <= SD_NEXT;
                      end
                  end
                  
                  SD_DATA: begin
                         // 1. Capture Data
                         write_buffer <= sd_dout_reg;
                         
                         // Skip 128-byte Header in Sector 0
                         if (current_sector > 0 || byte_index >= 128) begin
                             write_pending <= 1;
                             checksum <= checksum + sd_dout_reg;
                             last_byte_captured <= sd_dout_reg;
                             
                             // Capture first 8 bytes for debugging
                             if (current_sector == 0 && byte_index == 128) first_bytes[0] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 129) first_bytes[1] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 130) first_bytes[2] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 131) first_bytes[3] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 132) first_bytes[4] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 133) first_bytes[5] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 134) first_bytes[6] <= sd_dout_reg;
                             if (current_sector == 0 && byte_index == 135) first_bytes[7] <= sd_dout_reg;
                         end
                         
                         byte_index <= byte_index + 1;
                         psram_load_addr <= psram_load_addr + 1; // V51r: Increment here
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
                     // Wait for Menu Trigger ($0458 Write - POKEY Base + 8)
                     // Using POKEY address avoids RAM initialization conflicts.
                     // Filter: Require Bit 7 High (Magic Value).
                     // Safety: Only trigger if NOT already loaded.
                     if (!game_loaded && a_safe == 16'h0458 && !rw_safe && phi2_safe) begin
                         if (d[7]) game_loaded <= 1;
                         else if (d[6]) begin
                             // RELOAD Trigger (for testing)
                             sd_state <= SD_START;
                             current_sector <= 0;
                             psram_load_addr <= 16'h4000;
                             checksum <= 0;
                             busy <= 1;
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
    
    reg [24:0] heartbeat;

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

    // LED Assignments (Full Loader Mode)
    // Active LOW LEDs. 
    assign led[0] = !pll_lock;      // ON when Locked
    assign led[1] = game_loaded;    // ON when Game Mode
    assign led[2] = !phi2_safe;     // ON when PHI2 activity
    assign led[3] = !sd_ready;      // ON when SD Ready
    assign led[4] = write_pending;  // ON when Write active
    assign led[5] = !busy;          // ON when busy
    
endmodule