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
    
    // PSRAM (Tang Nano 9K - Magic Ports - auto-routed by Gowin)
    output wire [1:0] O_psram_ck,      // 2-bit Clock (ck_n auto-inferred)
    output wire [1:0] O_psram_cs_n,    // 2-bit CS#
    output wire [1:0] O_psram_reset_n, // 2-bit Reset#
    inout [7:0]       IO_psram_dq,     // 8-bit Data
    inout [1:0]       IO_psram_rwds,    // 2-bit RWDS
    
    output       audio,     // Audio PWM
    output [5:0] led       // Debug LEDs
);

    // ========================================================================
    // 0. CLOCK GENERATION (No PLL - 27MHz native, Atari crashes with 81MHz)
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
            // Range 1: $7F00-$7F3F (CRC, SC, etc)
            // Range 2: $4440-$447F (P0-P4 Peaks)
            if ((a_safe >= 16'h7F00 && a_safe <= 16'h7F3F) || (a_safe >= 16'h4440 && a_safe <= 16'h447F)) begin
                // Use a_safe[6:4] to select the row
                case (a_safe[6:4])
                    3'b000: begin // $7F00-$7F0F: CRC
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h43; // 'C'
                            4'h1: data_out <= 8'h52; // 'R'
                            4'h2: data_out <= 8'h43; // 'C'
                            4'h3: data_out <= 8'h3A; // ':'
                            4'h4: data_out <= 8'h20; // ' '
                            4'h5: data_out <= to_hex_ascii(checksum[31:28]);
                            4'h6: data_out <= to_hex_ascii(checksum[27:24]);
                            4'h7: data_out <= to_hex_ascii(checksum[23:20]);
                            4'h8: data_out <= to_hex_ascii(checksum[19:16]);
                            4'h9: data_out <= to_hex_ascii(checksum[15:12]);
                            4'hA: data_out <= to_hex_ascii(checksum[11:8]);
                            4'hB: data_out <= to_hex_ascii(checksum[7:4]);
                            4'hC: data_out <= to_hex_ascii(checksum[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    3'b001: begin // $7F10-$7F1F: ST/BC
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
                    3'b010: begin // $7F20-$7F2F: SC/L
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
                    3'b011: begin // $7F30-$7F3F: First Bytes Peak
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
                    3'b100: begin // $4440: P0:EE (Static Test)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h30; // '0'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= 8'h45; // 'E'
                            4'h4: data_out <= 8'h45; // 'E'
                            default: data_out <= 8'h20;
                        endcase
                    end
                    3'b101: begin // $4450: P1:XX (Trigger Count)
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h31; // '1'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(trigger_counter[7:4]);
                            4'h4: data_out <= to_hex_ascii(trigger_counter[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    3'b110: begin // $7F60: P2:XX
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h32; // '2'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(psram_read_latch[7:4]);
                            4'h4: data_out <= to_hex_ascii(psram_read_latch[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
                    3'b111: begin // $7F70: P3:XX
                        case (a_safe[3:0])
                            4'h0: data_out <= 8'h50; // 'P'
                            4'h1: data_out <= 8'h33; // '3'
                            4'h2: data_out <= 8'h3A; // ':'
                            4'h3: data_out <= to_hex_ascii(psram_read_latch[7:4]);
                            4'h4: data_out <= to_hex_ascii(psram_read_latch[3:0]);
                            default: data_out <= 8'h20;
                        endcase
                    end
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
    // 7. PSRAM CONTROLLER (HyperRAM)
    // ========================================================================
    
    wire clk_81m;
    wire clk_81m_shifted;
    wire pll_lock;
    
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
    wire [21:0] psram_cmd_addr = {6'b0, psram_addr_mux};
    
    wire is_psram_diag0 = (!game_loaded && a_safe >= 16'h4440 && a_safe <= 16'h444F);
    wire is_psram_diag1 = (!game_loaded && a_safe >= 16'h4450 && a_safe <= 16'h445F);
    wire is_psram_diag2 = (!game_loaded && a_safe >= 16'h4460 && a_safe <= 16'h446F);
    wire is_psram_diag3 = (!game_loaded && a_safe >= 16'h4470 && a_safe <= 16'h447F);
    
    wire [21:0] psram_addr_mux = (game_loaded)   ? {6'b0, a_safe} - 22'h004000 : 
                                 (is_psram_diag0) ? 22'h000000 : 
                                 (is_psram_diag1) ? 22'h000001 : 
                                 (is_psram_diag2) ? 22'h000002 : 
                                 (is_psram_diag3) ? 22'h000003 : 
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
    
    // V51m: Force Write Pattern A5/5A/85/3C for addresses 0-3
    wire [7:0] psram_din_mux = (psram_load_addr[21:0] == 0) ? 8'hA5 : 
                                (psram_load_addr[21:0] == 1) ? 8'h5A : 
                                (psram_load_addr[21:0] == 2) ? 8'h85 : 
                                (psram_load_addr[21:0] == 3) ? 8'h3C : 
                                write_buffer;
    
    psram_controller psram_ctrl (
        .clk(clk_81m),
        .clk_shifted(clk_81m_shifted),
        .reset_n(pll_lock),
        
        .cmd_valid(psram_cmd_valid),
        .cmd_write(psram_cmd_write),
        .cmd_addr(psram_cmd_addr), 
        .write_data(psram_din_mux),
        .read_data(psram_dout),
        .data_ready(psram_data_ready),
        .busy(psram_busy),
        
        // Magic Ports
        .O_psram_ck(O_psram_ck),
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
    
    // V51j: Slow Trigger 
    wire slow_pulse = heartbeat[24]; 
    reg slow_pulse_prev;
    always @(posedge sys_clk) slow_pulse_prev <= slow_pulse;
    // Only fire when heartbeat is high (or transitions high) AND offset 0
    // V51m: Restore Fast Trigger (Remove slow_pulse gating)
    wire diag_read_trigger = (is_psram_diag0 || is_psram_diag1 || is_psram_diag2 || is_psram_diag3) && rw_safe && (a_safe != a_prev) && (a_safe[3:0] == 4'h0); // && slow_pulse;
    reg [7:0] trigger_counter;
    
    always @(posedge sys_clk) begin
        a_prev <= a_safe;
        rw_prev <= rw_safe;
        
        if (!sd_reset) begin
             // READ REQUEST (Trigger on Address or RW change, OR diag peak)
             if ((game_loaded && is_rom && rw_safe && ((a_safe != a_prev) || (rw_safe != rw_prev))) || diag_read_trigger) begin
                   psram_rd_req <= 1;
                   if (diag_read_trigger) trigger_counter <= trigger_counter + 1;
             end
             else if (psram_busy) begin 
                   // Acknowledged by 81MHz domain
                   psram_rd_req <= 0; 
             end
             else if (!game_loaded) psram_rd_req <= 0; // Menu Mode safety
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
              psram_load_addr <= 0; // V51e: Start at 0
             sd_byte_available_d <= 0;
             pattern_buf <= 0;
             checksum <= 0;
             sd_dout_reg <= 0;
        end else begin
             sd_byte_available_d <= sd_byte_available;

              // --- INDEPENDENT PSRAM WRITE HANDSHAKE (V51c: Sequential) ---
              if (psram_wr_req) begin
                   psram_wr_req <= 0;
                   psram_load_addr <= psram_load_addr + 1; // Increment ONLY after pulsed
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