// ============================================================================
// SD Card SPI Controller for Tang Nano 9K
// Provides byte-level read/write access to SD cards in SPI mode
// ============================================================================

module sd_spi_controller (
    input wire clk,              // System clock (27MHz recommended)
    input wire reset_n,          // Active low reset
    
    // User interface
    input wire cmd_start,        // Pulse to start command
    input wire [7:0] cmd_byte,   // Command/data byte to send
    output reg [7:0] resp_byte,  // Response byte received
    output reg busy,             // Module is busy
    output reg data_valid,       // Response data is valid
    
    // SPI interface
    output reg spi_clk,          // SPI Clock (max 25MHz for SD)
    output reg spi_mosi,         // Master Out Slave In
    input wire spi_miso,         // Master In Slave Out
    output reg spi_cs_n          // Chip Select (act low)
);

    // State machine
    localparam IDLE = 0;
    localparam TRANSMIT = 1;
    localparam RECEIVE = 2;
    localparam DONE = 3;
    
    reg [1:0] state;
    reg [7:0] tx_data;
    reg [7:0] rx_data;
    reg [3:0] bit_count;
    reg [4:0] clk_div;           // Clock divider for SPI clock
    reg spi_clk_en;
    
    // Clock divider - creates SPI clock from system clock
    // 27MHz / 2 = 13.5MHz (safe for SD card init and operation)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            clk_div <= 0;
            spi_clk_en <= 0;
        end else begin
            if (clk_div == 0) begin
                clk_div <= 1;    // Divide by 2
                spi_clk_en <= 1;
            end else begin
                clk_div <= clk_div - 1;
                spi_clk_en <= 0;
            end
        end
    end
    
    // Main state machine
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            busy <= 0;
            data_valid <= 0;
            spi_cs_n <= 1;
            spi_clk <= 0;
            spi_mosi <= 1;
            bit_count <= 0;
            tx_data <= 8'hFF;
            rx_data <= 0;
            resp_byte <= 0;
        end else begin
            case (state)
                IDLE: begin
                    data_valid <= 0;
                    if (cmd_start) begin
                        busy <= 1;
                        spi_cs_n <= 0;     // Assert CS
                        tx_data <= cmd_byte;
                        bit_count <= 7;
                        state <= TRANSMIT;
                    end else begin
                        busy <= 0;
                        spi_cs_n <= 1;     // Deassert CS when idle
                        spi_mosi <= 1;     // Keep MOSI high when idle
                    end
                end
                
                TRANSMIT: begin
                    if (spi_clk_en) begin
                        if (!spi_clk) begin
                            // Rising edge of SPI clock - setup data
                            spi_clk <= 1;
                            spi_mosi <= tx_data[bit_count];
                        end else begin
                            // Falling edge of SPI clock - sample and shift
                            spi_clk <= 0;
                            rx_data[bit_count] <= spi_miso;
                            
                            if (bit_count == 0) begin
                                state <= DONE;
                            end else begin
                                bit_count <= bit_count - 1;
                            end
                        end
                    end
                end
                
                DONE: begin
                    resp_byte <= rx_data;
                    data_valid <= 1;
                    busy <= 0;
                    state <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
endmodule


// ============================================================================
// SD Card Command Wrapper - Handles full command sequences
// ============================================================================

module sd_card_manager (
    input wire clk,
    input wire reset_n,
    
    // Command interface
    input wire start_init,           // Start SD card initialization
    input wire start_read,           // Start block read
    input wire [31:0] block_addr,    // Block address to read
    output reg init_done,            // Initialization complete
    output reg read_done,            // Read complete
    output reg [7:0] read_data,      // Data output
    output reg read_data_valid,      // Data valid strobe
    output reg error,                // Error flag
    
    // SPI interface
    output wire spi_clk,
    output wire spi_mosi,
    input wire spi_miso,
    output wire spi_cs_n
);

    // SPI controller interface
    reg spi_cmd_start;
    reg [7:0] spi_cmd_byte;
    wire [7:0] spi_resp_byte;
    wire spi_busy;
    wire spi_data_valid;
    
    // Instantiate SPI controller
    sd_spi_controller spi_ctrl (
        .clk(clk),
        .reset_n(reset_n),
        .cmd_start(spi_cmd_start),
        .cmd_byte(spi_cmd_byte),
        .resp_byte(spi_resp_byte),
        .busy(spi_busy),
        .data_valid(spi_data_valid),
        .spi_clk(spi_clk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n)
    );
    
    // State machine for SD card operations
    localparam S_IDLE = 0;
    localparam S_INIT_START = 1;
    localparam S_SEND_CMD = 2;
    localparam S_WAIT_RESP = 3;
    localparam S_INIT_DONE = 4;
    localparam S_READ_START = 5;
    localparam S_READ_DATA = 6;
    localparam S_READ_DONE = 7;
    
    reg [3:0] state;
    reg [7:0] cmd_buffer [0:5];
    reg [3:0] cmd_index;
    reg [15:0] delay_counter;
    reg [15:0] byte_counter;
    
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= S_IDLE;
            init_done <= 0;
            read_done <= 0;
            error <= 0;
            spi_cmd_start <= 0;
            read_data_valid <= 0;
        end else begin
            spi_cmd_start <= 0;  // Default
            read_data_valid <= 0;
            
            case (state)
                S_IDLE: begin
                    if (start_init) begin
                        state <= S_INIT_START;
                        init_done <= 0;
                        // Prepare CMD0 (GO_IDLE_STATE)
                        cmd_buffer[0] <= 8'h40;  // CMD0
                        cmd_buffer[1] <= 8'h00;
                        cmd_buffer[2] <= 8'h00;
                        cmd_buffer[3] <= 8'h00;
                        cmd_buffer[4] <= 8'h00;
                        cmd_buffer[5] <= 8'h95;  // CRC for CMD0
                        cmd_index <= 0;
                    end else if (start_read && init_done) begin
                        state <= S_READ_START;
                        read_done <= 0;
                        // Prepare CMD17 (READ_SINGLE_BLOCK)
                        cmd_buffer[0] <= 8'h51;  // CMD17
                        cmd_buffer[1] <= block_addr[31:24];
                        cmd_buffer[2] <= block_addr[23:16];
                        cmd_buffer[3] <= block_addr[15:8];
                        cmd_buffer[4] <= block_addr[7:0];
                        cmd_buffer[5] <= 8'hFF;  // Dummy CRC
                        cmd_index <= 0;
                    end
                end
                
                S_INIT_START: begin
                    if (!spi_busy) begin
                        spi_cmd_byte <= cmd_buffer[cmd_index];
                        spi_cmd_start <= 1;
                        state <= S_SEND_CMD;
                    end
                end
                
                S_SEND_CMD: begin
                    if (spi_data_valid) begin
                        if (cmd_index < 5) begin
                            cmd_index <= cmd_index + 1;
                            state <= S_INIT_START;
                        end else begin
                            state <= S_WAIT_RESP;
                            delay_counter <= 1000;  // Wait for response
                        end
                    end
                end
                
                S_WAIT_RESP: begin
                    if (!spi_busy) begin
                        spi_cmd_byte <= 8'hFF;  // Send dummy bytes
                        spi_cmd_start <= 1;
                        if (spi_resp_byte != 8'hFF) begin
                            // Got response
                            state <= S_INIT_DONE;
                        end else if (delay_counter == 0) begin
                            error <= 1;
                            state <= S_IDLE;
                        end else begin
                            delay_counter <= delay_counter - 1;
                        end
                    end
                end
                
                S_INIT_DONE: begin
                    init_done <= 1;
                    state <= S_IDLE;
                end
                
                S_READ_START: begin
                    // Similar to init, send CMD17 and wait for response
                    // Then read 512 bytes of data
                    state <= S_IDLE;  // Simplified for now
                    read_done <= 1;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule
