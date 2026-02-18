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
    
    // SD Card (SPI Mode) - WIRED OFF
    output       sd_cs,     
    output       sd_mosi,   
    input        sd_miso,   
    output       sd_clk,    
    
    // PSRAM (Tang Nano 9K - Gowin IP Core)
    output wire [0:0] O_psram_ck,      
    output wire [0:0] O_psram_ck_n,    
    output wire [0:0] O_psram_cs_n,    
    output wire [0:0] O_psram_reset_n, 
    inout [7:0]       IO_psram_dq,     
    inout [0:0]       IO_psram_rwds,   
    
    output       audio,     
    output [5:0] led       
);

    // 1. CLOCK
    wire sys_clk = clk; 

    // 2. SYNCHRONIZATION
    reg [15:0] a_safe;
    reg phi2_safe;
    reg rw_safe;
    reg halt_safe;

    always @(posedge sys_clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
    end

    // 3. PSRAM LOGIC
    wire clk_81m, clk_81m_shifted, pll_lock;
    
    gowin_pll pll_inst (
        .clkin(sys_clk),
        .clkout(clk_81m),
        .clkoutp(clk_81m_shifted),
        .lock(pll_lock)
    );

    // IP SIGNALS
    reg         ip_cmd;       // 1=Write, 0=Read
    reg         ip_cmd_en;
    reg [20:0]  ip_addr;
    reg [31:0]  ip_wr_data;
    reg [3:0]   ip_data_mask;
    wire [31:0] ip_rd_data;
    wire        ip_rd_data_valid;
    wire        ip_init_calib;
    
    PSRAM_Memory_Interface_HS_Top psram_ip (
        .clk(sys_clk),              
        .memory_clk(clk_81m),       
        .pll_lock(pll_lock),        
        .rst_n(pll_lock),           
        .cmd(ip_cmd),           
        .cmd_en(ip_cmd_en),
        .addr(ip_addr),
        .wr_data(ip_wr_data),
        .data_mask(ip_data_mask),    
        .rd_data(ip_rd_data),
        .rd_data_valid(ip_rd_data_valid),
        .init_calib(ip_init_calib),
        .clk_out(),
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );

    // 4. TEST STATE MACHINE
    reg [3:0] state;
    reg [7:0] timer;
    reg [31:0] latch_data;
    
    // CDC Sync
    reg [2:0] calib_sync;
    wire calib_done = calib_sync[2];
    always @(posedge sys_clk) calib_sync <= {calib_sync[1:0], ip_init_calib};

    always @(posedge sys_clk) begin
        if (!pll_lock) begin
            state <= 0;
            ip_cmd_en <= 0;
            latch_data <= 32'hFFFFFFFF; // Default to F's
        end else begin
            case (state)
                0: if (calib_done) state <= 1; // Wait Init
                
                1: begin // WRITE ONCE
                    ip_cmd <= 1; // Write
                    ip_addr <= 0;
                    ip_wr_data <= 32'h3C855AA5; // THE PATTERN
                    ip_data_mask <= 4'b0000;    // All Bytes
                    ip_cmd_en <= 1;
                    state <= 2;
                end
                
                2: begin // Stop Write
                    ip_cmd_en <= 0;
                    timer <= 0;
                    state <= 3;
                end
                
                3: begin // Wait for Write Recovery
                    timer <= timer + 1;
                    if (timer == 255) state <= 4;
                end
                
                4: begin // READ CONTINUOUSLY
                    ip_cmd <= 0; // Read
                    ip_addr <= 0;
                    ip_data_mask <= 4'b0000;
                    ip_cmd_en <= 1; // Trigger Read
                    state <= 5;
                end
                
                5: begin
                    ip_cmd_en <= 0;
                    if (ip_rd_data_valid) begin
                        latch_data <= ip_rd_data; // Capture
                        timer <= 0;
                        state <= 6; // Wait before next read
                    end
                end
                
                6: begin
                    timer <= timer + 1;
                    if (timer == 200) state <= 4; // Read again
                end
            endcase
        end
    end

    // 5. ATARI OUTPUT LOGIC
    reg [7:0] data_out;
    reg [7:0] rom_memory [0:49151]; 
    initial $readmemh("game.hex", rom_memory);
    
    function [7:0] to_hex (input [3:0] n);
        to_hex = (n < 10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    always @(posedge sys_clk) begin
        // Diagnostic range $7F00 - $7FBF
        if (a_safe >= 16'h7F00 && a_safe <= 16'h7FBF) begin
            case (a_safe[7:4])
                4'h6: begin // P2: Byte 0 (Should be A5)
                    if (a_safe[0]) data_out <= to_hex(latch_data[3:0]);
                    else           data_out <= to_hex(latch_data[7:4]);
                end
                4'h7: begin // P3: Byte 1 (Should be 5A)
                    if (a_safe[0]) data_out <= to_hex(latch_data[11:8]);
                    else           data_out <= to_hex(latch_data[15:12]);
                end
                4'hB: begin // P7: Full 32-bit (Should be 3C855AA5)
                    case (a_safe[3:0])
                        3: data_out <= to_hex(latch_data[31:28]);
                        4: data_out <= to_hex(latch_data[27:24]);
                        5: data_out <= to_hex(latch_data[23:20]);
                        6: data_out <= to_hex(latch_data[19:16]);
                        7: data_out <= to_hex(latch_data[15:12]);
                        8: data_out <= to_hex(latch_data[11:8]);
                        9: data_out <= to_hex(latch_data[7:4]);
                        10: data_out <= to_hex(latch_data[3:0]);
                        default: data_out <= 8'h2D; // '-'
                    endcase
                end
                default: data_out <= 8'h20;
            endcase
        end
        else if (a_safe >= 16'h4000) data_out <= rom_memory[a_safe - 16'h4000];
        else data_out <= 8'hEA;
    end

    // 6. BUS CONTROL
    wire is_rom = (a_safe >= 16'h4000);
    wire drv = is_rom && rw_safe && (phi2_safe || !halt_safe);
    
    always @(posedge sys_clk) begin
        buf_dir <= rw_safe;
        buf_oe  <= !drv;
    end
    assign d = drv ? data_out : 8'bz;
    
    // SD Signals (Disabled)
    assign sd_cs = 1; assign sd_clk = 0; assign sd_mosi = 0;
    
    // LEDs
    assign led = ~{latch_data[0], latch_data[1], latch_data[2], latch_data[3], latch_data[4], latch_data[5]};

endmodule