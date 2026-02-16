module psram (
    input         clk,        // 81MHz Logic Clock
    input         clk_p,      // 81MHz Phase Shifted Clock
    input         reset_n,
    
    // User Interface
    input         cmd_en,     // 1=Start Transaction
    input         cmd_write,  // 1=Write, 0=Read
    input  [21:0] addr,       // 0-4MB Address
    input  [15:0] wr_data,    // Data to Write
    output [15:0] rd_data,    // Data Read
    output        data_valid, // 1=Read Data Ready
    output        busy,       // 1=Busy
    
    // Hardware Pins
    output        O_psram_ck,
    output        O_psram_cs_n,
    inout  [7:0]  IO_psram_dq,
    inout         IO_psram_rwds
);

    // ========================================================================
    // 1. HARDWARE PRIMITIVES (The Magic)
    // ========================================================================
    // Drive the RAM Clock using the Phase-Shifted Signal
    ODDR oddr_ck (.D0(1'b1), .D1(1'b0), .CE(1'b1), .CLK(clk_p), .Q(O_psram_ck)); // Always Toggle

    // ========================================================================
    // 2. STATE MACHINE
    // ========================================================================
    localparam IDLE=0, CMD0=1, CMD1=2, CMD2=3, LATENCY=4, DATA_RW=5, DONE=6;
    reg [2:0] state;
    reg [3:0] latency_cnt;
    
    reg cs_n_reg;
    assign O_psram_cs_n = cs_n_reg;
    
    reg [47:0] cmd; // CA packet
    reg dq_oe;      // Output Enable
    reg [15:0] data_out_shift;
    
    // Output assignment (Tristate)
    assign IO_psram_dq = dq_oe ? data_out_shift[15:8] : 8'bz; // Simplified High Byte drive

    // Flags
    assign busy = (state != IDLE);
    reg valid_reg;
    assign data_valid = valid_reg;
    assign rd_data = 16'hFFFF; // Placeholder until Read Logic is perfect

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            cs_n_reg <= 1;
            dq_oe <= 0;
            valid_reg <= 0;
        end else begin
            case (state)
                IDLE: begin
                    valid_reg <= 0;
                    cs_n_reg <= 1;
                    dq_oe <= 0;
                    if (cmd_en) begin
                        state <= CMD0;
                        cs_n_reg <= 0; // Start
                        dq_oe <= 1;    // Drive Bus
                        
                        // Construct Command (Linear Burst, Memory Space)
                        // Bit 47: Read=1, Write=0
                        cmd <= { !cmd_write, 1'b0, 1'b1, 13'b0, addr, 10'b0 };
                    end
                end

                CMD0: begin 
                    // Send Byte 0 & 1
                    data_out_shift <= cmd[47:32];
                    state <= CMD1;
                end
                
                CMD1: begin
                    // Send Byte 2 & 3
                    data_out_shift <= cmd[31:16];
                    state <= CMD2;
                end
                
                CMD2: begin
                    // Send Byte 4 & 5
                    data_out_shift <= cmd[15:0];
                    state <= LATENCY;
                    latency_cnt <= 0;
                end
                
                LATENCY: begin
                    dq_oe <= 0; // Release Bus
                    if (latency_cnt == 6) begin // Fixed Latency
                        state <= DATA_RW;
                    end else latency_cnt <= latency_cnt + 1;
                end
                
                DATA_RW: begin
                    if (cmd_write) begin
                        // WRITE MODE
                        dq_oe <= 1;
                        data_out_shift <= wr_data;
                        // Single Word Write for now
                        state <= DONE; 
                    end else begin
                        // READ MODE
                        // (Requires IDDR Primitive to capture - Placeholder)
                        valid_reg <= 1; 
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    cs_n_reg <= 1;
                    dq_oe <= 0;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule