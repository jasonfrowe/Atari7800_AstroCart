// ============================================================================
// PSRAM/HyperRAM Controller for Tang Nano 9K 
// Based on zf3/psram-tang-nano-9k reference design
// This controller provides byte-level access to the on-board PSRAM
// Optimized for low latency single-byte access
// ============================================================================

module psram_controller (
    input wire        clk,           // 81MHz system clock
    input wire        clk_shifted,   // 81MHz phase-shifted clock for DDR
    input wire        reset_n,
    
    // User Interface (Simplified)
    input wire        cmd_valid,     // Command valid strobe
    input wire        cmd_write,     // 1=Write, 0=Read
    input wire [21:0] cmd_addr,      // Address (4MB range) 
    input wire [7:0]  write_data,    // Data to write
    output reg [7:0]  read_data,     // Data read
    output reg        data_ready,    // Data ready flag
    output reg        busy,          // Controller busy
    
    // PSRAM Hardware Interface
    output wire       O_psram_ck,      // PSRAM clock
    output wire       O_psram_ck_n,    // PSRAM clock (inverted)
    output reg        O_psram_cs_n,    // Chip select
    output reg        O_psram_reset_n, // Reset
    inout [7:0]       IO_psram_dq,     // Data bus
    inout wire        IO_psram_rwds    // Read/Write Data Strobe
);

    // ========================================================================
    // 1. DDR CLOCK GENERATION
    // ========================================================================
    // Use ODDR primitives to generate differential clock from phase-shifted clock
    ODDR ck_oddr (
        .Q0(O_psram_ck),
        .Q1(O_psram_ck_n),
        .D0(1'b0),
        .D1(1'b1),
        .TX(1'b0),
        .CLK(clk_shifted)
    );

    // ========================================================================
    // 2. STATE MACHINE
    // ========================================================================
    localparam IDLE        = 4'd0;
    localparam RESET       = 4'd1;
    localparam CA_START    = 4'd2;
    localparam CA_BYTE0    = 4'd3;
    localparam CA_BYTE1    = 4'd4;
    localparam CA_BYTE2    = 4'd5;
    localparam CA_BYTE3    = 4'd6;
    localparam CA_BYTE4    = 4'd7;
    localparam CA_BYTE5    = 4'd8;
    localparam LATENCY     = 4'd9;
    localparam DATA_PHASE  = 4'd10;
    localparam DONE        = 4'd11;
    
    reg [3:0] state;
    reg [3:0] next_state;
    reg [3:0] latency_count;
    reg [3:0] init_count;
    
    // Command/Address packet (48 bits for HyperRAM)
    // [47]    = R/W# (1=Read, 0=Write)
    // [46]    = Address Space (0=Memory, 1=Register) 
    // [45]    = Burst Type (1=Linear, 0=Wrapped)
    // [44:16] = Reserved/Row Address
    // [15:3]  = Column Address  
    // [2:0]   = Reserved
    reg [47:0] ca_packet;
    reg [7:0] ca_byte;
    reg [7:0] data_buffer;
    
    // Tristate control
    reg dq_oe;           // Output enable for data bus
    reg rwds_oe;         // Output enable for RWDS
    reg [7:0] dq_out;    // Output data
    
    assign IO_psram_dq = dq_oe ? dq_out : 8'hzz;
    assign IO_psram_rwds = rwds_oe ? 1'b0 : 1'bz;
    
    // ========================================================================
    // 3. MAIN CONTROLLER FSM
    // ========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= RESET;
            O_psram_cs_n <= 1'b1;
            O_psram_reset_n <= 1'b0;
            dq_oe <= 1'b0;
            rwds_oe <= 1'b0;
            busy <= 1'b0;
            data_ready <= 1'b0;
            latency_count <= 4'd0;
            init_count <= 4'd0;
            read_data <= 8'h00;
        end else begin
            case (state)
                // --------------------------------------------------------
                // RESET: Initialize PSRAM
                // --------------------------------------------------------
                RESET: begin
                    busy <= 1'b1;
                    if (init_count < 4'd15) begin
                        init_count <= init_count + 1'b1;
                        O_psram_reset_n <= 1'b0;
                    end else begin
                        O_psram_reset_n <= 1'b1;
                        state <= IDLE;
                        busy <= 1'b0;
                    end
                end
                
                // --------------------------------------------------------
                // IDLE: Wait for command
                // --------------------------------------------------------
                IDLE: begin
                    data_ready <= 1'b0;
                    O_psram_cs_n <= 1'b1;
                    dq_oe <= 1'b0;
                    rwds_oe <= 1'b0;
                    
                    if (cmd_valid) begin
                        busy <= 1'b1;
                        O_psram_cs_n <= 1'b0;  // Assert CS#
                        
                        // Build Command/Address packet
                        // Format: [R/W#][AS][BT][Addr][Reserved]
                        ca_packet[47] <= ~cmd_write;     // Read=1, Write=0
                        ca_packet[46] <= 1'b0;           // Memory space
                        ca_packet[45] <= 1'b1;           // Linear burst
                        ca_packet[44:32] <= 13'd0;       // Upper address bits
                        ca_packet[31:19] <= cmd_addr[21:9];  // Row address
                        ca_packet[18:16] <= cmd_addr[8:6];   // Column high
                        ca_packet[15:3] <= {cmd_addr[5:0], 7'd0};  // Column
                        ca_packet[2:0] <= 3'd0;          // Reserved
                        
                        state <= CA_START;
                    end else begin
                        busy <= 1'b0;
                    end
                end
                
                // --------------------------------------------------------
                // CA_START: Begin sending CA packet
                // --------------------------------------------------------
                CA_START: begin
                    dq_oe <= 1'b1;
                    ca_byte <= ca_packet[47:40];
                    dq_out <= ca_packet[47:40];
                    state <= CA_BYTE1;
                end
                
                // --------------------------------------------------------
                // CA_BYTE1-5: Send remaining CA bytes
                // --------------------------------------------------------
                CA_BYTE1: begin
                    dq_out <= ca_packet[39:32];
                    state <= CA_BYTE2;
                end
                
                CA_BYTE2: begin
                    dq_out <= ca_packet[31:24];
                    state <= CA_BYTE3;
                end
                
                CA_BYTE3: begin
                    dq_out <= ca_packet[23:16];
                    state <= CA_BYTE4;
                end
                
                CA_BYTE4: begin
                    dq_out <= ca_packet[15:8];
                    state <= CA_BYTE5;
                end
                
                CA_BYTE5: begin
                    dq_out <= ca_packet[7:0];
                    latency_count <= 4'd0;
                    state <= LATENCY;
                end
                
                // --------------------------------------------------------
                // LATENCY: Fixed latency period (typ. 6 cycles)
                // --------------------------------------------------------
                LATENCY: begin
                    dq_oe <= 1'b0;  // Release bus
                    rwds_oe <= 1'b0;
                    
                    if (latency_count < 4'd6) begin
                        latency_count <= latency_count + 1'b1;
                    end else begin
                        state <= DATA_PHASE;
                    end
                end
                
                // --------------------------------------------------------
                // DATA_PHASE: Read or Write data
                // --------------------------------------------------------
                DATA_PHASE: begin
                    if (ca_packet[47]) begin
                        // READ operation
                        dq_oe <= 1'b0;
                        read_data <= IO_psram_dq;  // Capture data
                        data_ready <= 1'b1;
                    end else begin
                        // WRITE operation
                        dq_oe <= 1'b1;
                        dq_out <= write_data;
                        rwds_oe <= 1'b1;  // Drive RWDS low for write
                    end
                    state <= DONE;
                end
                
                // --------------------------------------------------------
                // DONE: Complete transaction
                // --------------------------------------------------------
                DONE: begin
                    O_psram_cs_n <= 1'b1;  // Deassert CS#
                    dq_oe <= 1'b0;
                    rwds_oe <= 1'b0;
                    busy <= 1'b0;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
endmodule


// ============================================================================
// PSRAM Byte-Access Wrapper
// Simpler interface for byte-level reads/writes
// ============================================================================

module psram_byte_controller (
    input wire clk,
    input wire clk_shifted,
    input wire reset_n,
    
    // Simple byte interface
    input wire read_req,
    input wire write_req,
    input wire [21:0] address,
    input wire [7:0] write_data,
    output wire [7:0] read_data,
    output wire data_valid,
    output wire busy,
    
    // PSRAM hardware
    output wire O_psram_ck,
    output wire O_psram_ck_n,
    output wire O_psram_cs_n,
    output wire O_psram_reset_n,
    inout [7:0] IO_psram_dq,
    inout wire IO_psram_rwds
);

    reg cmd_valid;
    reg cmd_write;
    reg [21:0] cmd_addr;
    reg [7:0] wr_data;
    wire [7:0] rd_data;
    wire data_ready;
    wire ctrl_busy;
    
    assign read_data = rd_data;
    assign data_valid = data_ready;
    assign busy = ctrl_busy;
    
    // Control logic
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cmd_valid <= 1'b0;
            cmd_write <= 1'b0;
            cmd_addr <= 22'd0;
            wr_data <= 8'd0;
        end else begin
            cmd_valid <= 1'b0;  // Default
            
            if (!ctrl_busy) begin
                if (read_req) begin
                    cmd_valid <= 1'b1;
                    cmd_write <= 1'b0;
                    cmd_addr <= address;
                end else if (write_req) begin
                    cmd_valid <= 1'b1;
                    cmd_write <= 1'b1;
                    cmd_addr <= address;
                    wr_data <= write_data;
                end
            end
        end
    end
    
    // Instantiate main controller
    psram_controller psram_ctrl (
        .clk(clk),
        .clk_shifted(clk_shifted),
        .reset_n(reset_n),
        .cmd_valid(cmd_valid),
        .cmd_write(cmd_write),
        .cmd_addr(cmd_addr),
        .write_data(wr_data),
        .read_data(rd_data),
        .data_ready(data_ready),
        .busy(ctrl_busy),
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );
    
endmodule
