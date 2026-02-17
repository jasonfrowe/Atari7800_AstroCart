// ============================================================================
// Byte-Level Wrapper for Gowin PSRAM IP
// ============================================================================
// The Gowin IP works with 32-bit words. This wrapper provides byte-level
// access for compatibility with the Atari 7800 interface.

module psram_byte_wrapper (
    input wire        clk,           // 27MHz system clock
    input wire        memory_clk,    // 81MHz PSRAM clock
    input wire        pll_lock,      // PLL lock signal
    input wire        reset_n,
    
    // Simple byte interface
    input wire        cmd_valid,
    input wire        cmd_write,
    input wire [21:0] cmd_addr,      // Byte address
    input wire [7:0]  write_data,
    output reg [7:0]  read_data,
    output reg        data_ready,
    output wire       busy,
    
    // PSRAM hardware interface (8-bit DQ, single CS for Tang Nano 9K)
    output wire [0:0] O_psram_ck,
    output wire [0:0] O_psram_ck_n,
    output wire [0:0] O_psram_cs_n,
    output wire [0:0] O_psram_reset_n,
    inout  [7:0]      IO_psram_dq,
    inout  [0:0]      IO_psram_rwds
);

    // Gowin IP signals (32-bit data interface)
    wire        ip_cmd;           // 0=read, 1=write
    reg         ip_cmd_en;
    wire [20:0] ip_addr;
    wire [31:0] ip_wr_data;
    wire [31:0] ip_rd_data;
    wire        ip_rd_data_valid;
    wire        ip_init_calib;
    wire        ip_clk_out;
    wire [3:0]  ip_data_mask;     // Mask for 4 bytes
    
    // State machine
    localparam IDLE = 2'd0;
    localparam WAIT_INIT = 2'd1;
    localparam ACTIVE = 2'd2;
    
    reg [1:0] state;
    reg [7:0] data_buffer;
    
    // Gowin IP expects bursts, but we only use 1 byte
    // Map byte address to IP address (32-bit = 4 bytes per word)
    assign ip_addr = cmd_addr[21:2];  // Divide by 4 for 32-bit word addressing
    assign ip_cmd = cmd_write;
    
    // For writes, replicate byte across all 4 bytes of 32-bit word
    assign ip_wr_data = {4{write_data}};
    
    // Data mask: enable all bytes (active low)
    assign ip_data_mask = 4'b0000;
    
    // Extract correct byte from 32-bit read data based on address[1:0]
    wire [1:0] byte_sel = cmd_addr[1:0];
    reg [7:0] selected_byte;
    
    always @(*) begin
        case (byte_sel)
            2'd0: selected_byte = ip_rd_data[7:0];
            2'd1: selected_byte = ip_rd_data[15:8];
            2'd2: selected_byte = ip_rd_data[23:16];
            2'd3: selected_byte = ip_rd_data[31:24];
        endcase
    end
    
    // Busy when not initialized or actively processing
    assign busy = !ip_init_calib || (state != IDLE) || ip_cmd_en;
    
    // State machine
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= WAIT_INIT;
            ip_cmd_en <= 1'b0;
            data_ready <= 1'b0;
            read_data <= 8'h00;
            data_buffer <= 8'h00;
        end else begin
            case (state)
                WAIT_INIT: begin
                    if (ip_init_calib) begin
                        state <= IDLE;
                    end
                end
                
                IDLE: begin
                    data_ready <= 1'b0;
                    if (cmd_valid && ip_init_calib) begin
                        ip_cmd_en <= 1'b1;
                        if (!cmd_write) begin
                            // Read operation
                            state <= ACTIVE;
                        end else begin
                            // Write operation - IP handles it
                            state <= ACTIVE;
                        end
                    end else begin
                        ip_cmd_en <= 1'b0;
                    end
                end
                
                ACTIVE: begin
                    ip_cmd_en <= 1'b0;
                    
                    if (ip_rd_data_valid) begin
                        // Read data arrived
                        read_data <= selected_byte;
                        data_ready <= 1'b1;
                        state <= IDLE;
                    end else if (!ip_cmd_en && cmd_write) begin
                        // Write completed (no valid signal for writes)
                        data_ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= WAIT_INIT;
            endcase
        end
    end
    
    // Instantiate Gowin PSRAM IP
    PSRAM_Memory_Interface_HS_Top psram_ip (
        .clk(clk),                  // 27MHz system clock
        .memory_clk(memory_clk),    // 81MHz PSRAM clock
        .pll_lock(pll_lock),        // PLL lock signal
        .rst_n(reset_n),
        
        .cmd(ip_cmd),
        .cmd_en(ip_cmd_en),
        .addr(ip_addr),
        .wr_data(ip_wr_data),
        .data_mask(ip_data_mask),  // 4-bit mask for 32-bit data
        .rd_data(ip_rd_data),
        .rd_data_valid(ip_rd_data_valid),
        .init_calib(ip_init_calib),
        .clk_out(ip_clk_out),
        
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .IO_psram_rwds(IO_psram_rwds),
        .IO_psram_dq(IO_psram_dq),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n)
    );

endmodule
