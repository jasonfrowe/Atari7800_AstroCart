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
    
    output       audio,     // Audio PWM
    output [5:0] led        // Debug LEDs
);

    // ========================================================================
    // 1. INPUT SYNCHRONIZATION
    // ========================================================================
    reg [15:0] a_safe;
    reg phi2_safe;
    reg rw_safe;
    reg halt_safe;

    always @(posedge clk) begin
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

    // ROM Fetch
    always @(posedge clk) begin
        if (rom_index < 49152) data_out <= rom_memory[rom_index];
        else data_out <= 8'hFF;
    end
    
    // Decoders (Using SAFE address)
    wire is_rom   = (a_safe[15] | a_safe[14]);          // $4000-$FFFF
    wire is_pokey = (a_safe[15:4] == 12'h045);          // $0450-$045F

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

    always @(posedge clk) begin
        // Direction follows RW (1=Out/Read, 0=In/Write)
        buf_dir <= rw_safe; 

        // Output Enable (Active Low)
        // Enable if Driving ROM OR if Atari is Writing (to us)
        // We must enable the buffer to receive the write data!
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
    reg [3:0] clk_div;
    wire tick_179 = (clk_div == 14);
    
    always @(posedge clk) begin
        if (tick_179) clk_div <= 0;
        else clk_div <= clk_div + 1;
    end

    pokey_complete my_pokey (
        .clk(clk),
        .enable_179mhz(tick_179),
        .reset_n(1'b1),
        .addr(a_safe[3:0]),  // Register 0-F
        .din(d),             // Input Data (from Atari)
        .we(pokey_we),       // Synchronized Write Enable
        .audio_pwm(audio)
    );

    // ========================================================================
    // 6. DEBUG
    // ========================================================================
    assign led[0] = ~buf_oe;     // Bus Activity
    assign led[1] = ~pokey_we;   // Flicker on Audio Write
    assign led[2] = ~halt_safe;  // DMA Activity
    assign led[5:3] = 3'b111;

endmodule
