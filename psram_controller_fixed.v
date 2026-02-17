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
    output wire [1:0] O_psram_ck,      // PSRAM clock (2 bits)
    // output wire [1:0] O_psram_ck_n,    // PSRAM clock (inverted) (2 bits) - REMOVED (Inferred)
    output reg  [1:0] O_psram_cs_n,    // Chip select (2 bits)
    output reg  [1:0] O_psram_reset_n, // Reset (2 bits)
    inout [7:0]       IO_psram_dq,     // Data bus (8 bits)
    inout [1:0]       IO_psram_rwds    // Read/Write Data Strobe (2 bits)
);

    // ========================================================================
    // 1. DDR CLOCK GENERATION
    // ========================================================================
    // Use ODDR primitives to generate differential clock from phase-shifted clock
    // Use ODDR primitives to generate differential clock from phase-shifted clock
    ODDR ck_oddr_0 (
        .Q0(O_psram_ck[0]),
        .D0(1'b0),
        .D1(1'b1),
        .TX(1'b0),
        .CLK(clk_shifted)
    );
    /*
    ODDR ck_n_oddr_0 (
        .Q0(O_psram_ck_n[0]),
        .D0(1'b1),
        .D1(1'b0),
        .TX(1'b0),
        .CLK(clk_shifted)
    );
    */
    ODDR ck_oddr_1 (
        .Q0(O_psram_ck[1]),
        .D0(1'b0),
        .D1(1'b1),
        .TX(1'b0),
        .CLK(clk_shifted)
    );
    /*
    ODDR ck_n_oddr_1 (
        .Q0(O_psram_ck_n[1]),
        .D0(1'b1),
        .D1(1'b0),
        .TX(1'b0),
        .CLK(clk_shifted)
    );
    */

    // ========================================================================
    // 2. STATE MACHINE
    // ========================================================================
    localparam IDLE        = 4'd0;
    localparam RESET       = 4'd1;
    localparam CONFIG      = 4'd2;
    localparam CA_START    = 4'd3;
    localparam CA_BYTE0    = 4'd4;
    localparam CA_BYTE1    = 4'd5;
    localparam CA_BYTE2    = 4'd6;
    localparam CA_BYTE3    = 4'd7;
    localparam CA_BYTE4    = 4'd8;
    localparam CA_BYTE5    = 4'd9;
    localparam LATENCY     = 4'd10;
    localparam DATA_PHASE  = 4'd11;
    localparam DONE        = 4'd12;
    
    reg [3:0] state;
    reg [3:0] next_state;
    reg [3:0] latency_count;
    reg [14:0] init_count;  // 15-bit counter for 150us delay (12,150 cycles at 81MHz)
    
    // 150us initialization delay at 81MHz = 12,150 cycles
    localparam INIT_CYCLES = 15'd12150;
    
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
    
    // Drive BOTH channels identically for simplicity (Channel 0 and Channel 1)
    // We only actively use the lower 8 bits (Channel 0) based on address decoding inside the chip?
    // Actually, Tang Nano 9K connects two dies separately. 
    // For simplicity, let's drive everything to Channel 0 behavior and let Channel 1 mirror or idle.
    
    // We only use 8-bit data bus (Single Chip Mode)
    
    assign IO_psram_dq = dq_oe ? dq_out : 8'hzz;
    
    assign IO_psram_rwds[0] = rwds_oe ? 1'b0 : 1'bz;
    assign IO_psram_rwds[1] = 1'bz;   // Channel 1 Unused
    
    // ========================================================================
    // 3. MAIN CONTROLLER FSM
    // ========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= RESET;
            O_psram_cs_n <= 2'b11;   // Deassert both CS#
            O_psram_reset_n <= 2'b00; // Reset both
            dq_oe <= 1'b0;
            rwds_oe <= 1'b0;
            busy <= 1'b0;
            data_ready <= 1'b0;
            latency_count <= 4'd0;
            init_count <= 15'd0;
            read_data <= 8'h00;
        end else begin
            case (state)
                // --------------------------------------------------------
                // RESET: Initialize PSRAM (150us delay)
                // --------------------------------------------------------
                RESET: begin
                    busy <= 1'b1;
                    O_psram_cs_n <= 2'b11;   // Deassert CS#
                    O_psram_reset_n <= 2'b00; // Assert Reset
                    dq_oe <= 1'b0;
                    rwds_oe <= 1'b0;
                    
                    if (init_count < INIT_CYCLES) begin
                        init_count <= init_count + 1'b1;
                    end else begin
                        // Release Reset, move to CONFIG state
                        O_psram_reset_n <= 2'b11;
                        state <= CONFIG;
                    end
                end
                
                // --------------------------------------------------------
                // CONFIG: Write Configuration Register
                // HyperRAM requires CR0 = 0x8F (fixed latency, 2x latency)
                // Register address: 0x001000 (Register space)
                // --------------------------------------------------------
                CONFIG: begin
                    busy <= 1'b1;
                    O_psram_cs_n[0] <= 1'b0;  // Assert CS[0]
                    O_psram_cs_n[1] <= 1'b1;  // Disable Die 1
                    
                    // Build Configuration Register Write packet
                    // Write to CR0 at address 0x001000 in register space
                    ca_packet[47] <= 1'b0;           // Write
                    ca_packet[46] <= 1'b1;           // Register space
                    ca_packet[45] <= 1'b1;           // Linear burst
                    ca_packet[44:16] <= 29'd0;       // Upper address
                    ca_packet[15:3] <= 13'h1000;      // CR0 address
                    ca_packet[2:0] <= 3'd0;          // Reserved
                    
                    // Write CR0 value: 0x8F (fixed latency, initial latency=6)
                    data_buffer <= 8'h8F;
                    
                    state <= CA_START;
                    next_state <= IDLE;  // After config, go to IDLE
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
                        
                        // Capture write data
                        data_buffer <= write_data;
                        
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
                        dq_out <= data_buffer;  // Use captured write data
                        rwds_oe <= 1'b1;  // Drive RWDS low for write
                    end
                    state <= DONE;
                end
                
                // --------------------------------------------------------
                // DONE: Complete transaction
                // --------------------------------------------------------
                DONE: begin
                    O_psram_cs_n <= 2'b11;  // Deassert CS# for both
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
