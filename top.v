module top (
    input clk,              // 27MHz System Clock
    
    // Atari Interface (Raw Inputs)
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
    // 1. INPUT SYNCHRONIZATION (The Glitch Filter)
    // ========================================================================
    // We register the inputs to align them to our 27MHz clock.
    // This prevents "metastability" and filters out tiny noise spikes.
    
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
    // 2. ROM LOGIC (Block RAM)
    // ========================================================================
    reg [7:0] rom_memory [0:49151]; 
    reg [7:0] data_out;
    
    initial $readmemh("game.hex", rom_memory);

    // Calculate Index based on the SAFE address
    wire [15:0] rom_index = a_safe - 16'h4000;

    // Fetch Data
    always @(posedge clk) begin
        if (rom_index < 49152) 
            data_out <= rom_memory[rom_index];
        else 
            data_out <= 8'hFF;
    end

    // ========================================================================
    // 3. SAFETY LOGIC (The Crash Fix)
    // ========================================================================
    
    // Decode based on SAFE address
    wire is_rom_range = (a_safe[15] | a_safe[14]); // $4000-$FFFF

    // --- STATE MACHINE FOR DRIVING ---
    // We only want to drive when we are 100% sure we are in a valid cycle.
    
    // CPU Mode: Valid when PHI2 is High AND Halt is High.
    wire cpu_active = (phi2_safe && halt_safe);
    
    // DMA Mode: Valid when Halt is Low.
    wire dma_active = (!halt_safe);

    // Master Drive Enable
    // 1. Must be ROM Range
    // 2. Must be Read (rw=1)
    // 3. Must be in a Valid Timing Window (CPU or DMA)
    wire should_drive = is_rom_range && rw_safe && (cpu_active || dma_active);

    // ========================================================================
    // 4. OUTPUT CONTROL (Prevent Buffer Fighting)
    // ========================================================================

    // We use registers for outputs to ensure clean transitions.
    always @(posedge clk) begin
        
        // DIRECTION CONTROL
        // We follow RW, but we latch it to prevent mid-cycle flips.
        buf_dir <= rw_safe; 

        // OUTPUT ENABLE CONTROL
        // Active Low (0 = ON).
        if (should_drive) begin
            buf_oe <= 1'b0; // Enable Buffer
        end else begin
            buf_oe <= 1'b1; // Disable Buffer (High Z)
        end
    end

    // FPGA Tristate Driver
    // We use the same 'should_drive' logic logic to gate the internal bus.
    assign d = (should_drive) ? data_out : 8'bz;

    // ========================================================================
    // 5. DEBUG
    // ========================================================================
    assign audio = 1'b0; // Silence for now

    // LED 0: Solid ON means stuck. Flicker means healthy activity.
    assign led[0] = ~buf_oe; 
    assign led[1] = ~phi2_safe;
    assign led[2] = ~rw_safe;
    assign led[5:3] = 3'b111;

endmodule