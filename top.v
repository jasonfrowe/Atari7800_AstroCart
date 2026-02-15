module top (
    input clk,              // 27MHz System Clock
    
    // Atari Interface
    input [15:0] a,         // Address Bus
    inout [7:0]  d,         // Data Bus
    input        phi2,      // Phase 2 Clock
    input        rw,        // Read/Write (High = Read)
    input        halt,      // Halt Line
    input        irq,       // IRQ Line
    
    // Buffer Control
    output       buf_dir,   // Buffer Direction (High = FPGA->Atari)
    output       buf_oe,    // Buffer Enable (Low = Enabled)
    
    output       audio,     // Audio PWM
    output [5:0] led        // Debug LEDs
);

    // ========================================================================
    // 1. ROM STORAGE (Block RAM)
    // ========================================================================
    // We infer a 48KB ROM. The compiler will map this to Block RAM automatically.
    reg [7:0] rom_memory [0:49151]; // 48K Bytes

    // Load the hex file at synthesis time
    initial begin
        $readmemh("game.hex", rom_memory);
    end

    // ========================================================================
    // 2. ADDRESS DECODING & LOGIC
    // ========================================================================
    
    // Calculate internal ROM address
    // Atari $4000 maps to ROM index 0.
    wire [15:0] rom_index = a - 16'h4000;
    
    // Fetch Data
    // We use the 27MHz clock to sync the Block RAM reads.
    // This is vastly faster than the Atari 1.79MHz bus, so it acts like "Instant RAM".
    reg [7:0] data_out;
    always @(posedge clk) begin
        // Safety: Prevent out-of-bounds reads wrapping around
        if (rom_index < 49152) begin
            data_out <= rom_memory[rom_index];
        end else begin
            data_out <= 8'hFF; // Default/Open Bus
        end
    end

    // ========================================================================
    // 3. BUS ARBITRATION
    // ========================================================================
    
    // Is the Atari asking for our ROM range? ($4000 - $FFFF)
    // Logic: Active if A15 is High OR A14 is High
    wire is_rom_range = (a[15] | a[14]);

    // Should we drive the bus?
    // YES if: ROM Range selected AND Atari is Reading (RW=1)
    wire drive_enable = is_rom_range && rw;

    // --- DATA BUS DRIVER ---
    // If driving, output 'data_out'. If not, High-Z ('z').
    assign d = (drive_enable) ? data_out : 8'bz;

    // --- BUFFER CONTROL PINS ---
    // Matches your Teensy Setup:
    // DIR is always HIGH (FPGA -> Atari direction)
    assign buf_dir = 1'b1; 
    
    // OE is LOW (Enabled) when we want to drive. HIGH (Disabled) otherwise.
    // This releases the 74LVC245 when the Atari is accessing other chips (TIA/RAM).
    assign buf_oe = ~drive_enable; 

    // ========================================================================
    // 4. DEBUG & EXTRAS
    // ========================================================================
    
    // Simple Audio (Just tie Low for now to avoid noise)
    assign audio = 1'b0;

    // LEDs (Active Low)
    // LED 0: ON if we are driving the bus (Activity Indicator)
    // LED 1: ON if PHI2 is High
    // LED 2: ON if RW is Read
    assign led[0] = ~drive_enable;
    assign led[1] = ~phi2;
    assign led[2] = ~rw;
    assign led[5:3] = 3'b111; // Off

endmodule