module top (
    input clk,              // 27MHz Crystal (Bus Clock)
    
    // Atari Interface
    input [15:0] a, inout [7:0] d,
    input phi2, input rw, input halt, input irq,
    
    // Outputs
    output reg buf_dir, output reg buf_oe,
    output audio, output [5:0] led
);

    // ========================================================================
    // 1. CLOCK GENERATION (Split Domain)
    // ========================================================================
    wire sys_clk, sys_clk_p, pll_lock;
    
    gowin_pll my_pll (
        .clkin(clk),
        .clkout(sys_clk),
        .clkoutp(sys_clk_p), // New Phase Shifted Clock
        .lock(pll_lock)
    );

    // ========================================================================
    // 2. BUS LOGIC (Running at STABLE 27MHz)
    // ========================================================================
    // We revert to the logic that worked perfectly before.
    
    reg [15:0] a_safe;
    reg phi2_safe, rw_safe, halt_safe;

    always @(posedge clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
    end

    // Memory (48KB BRAM)
    reg [7:0] rom_memory [0:49151]; 
    reg [7:0] data_out;
    initial $readmemh("game.hex", rom_memory);

    // Decoding
    reg [15:0] final_rom_addr;
    
    // Config
    reg [7:0] mapper_flags [0:0]; 
    initial $readmemh("mapper.hex", mapper_flags);
    wire has_pokey = mapper_flags[0][1];

    always @(*) begin
        if (a_safe >= 16'h4000) final_rom_addr = a_safe - 16'h4000;
        else final_rom_addr = 0;
    end

    // Access (27MHz)
    always @(posedge clk) begin
        if (final_rom_addr < 49152) data_out <= rom_memory[final_rom_addr];
        else data_out <= 8'hEA;
    end

    // Bus Control (The "Crash Proof" Logic)
    wire is_addr_valid = (a_safe >= 16'h4000); 
    wire is_pokey_addr = (a_safe[15:4] == 12'h045); 
    wire timing_ok = (phi2_safe && halt_safe) || (!halt_safe);
    wire should_drive = is_addr_valid && rw_safe && timing_ok && !is_pokey_addr;

    always @(posedge clk) begin
        buf_dir <= rw_safe;
        if (should_drive || (!rw_safe && is_pokey_addr)) buf_oe <= 0;
        else buf_oe <= 1;
    end
    assign d = (should_drive) ? data_out : 8'bz;

    // ========================================================================
    // 3. POKEY LOGIC (Running at HIGH RES 108MHz)
    // ========================================================================
    
    // We need to generate the 1.79MHz tick from the 108MHz clock.
    // 108 MHz / 1.79 MHz = ~60.33. 
    // We use a counter to 60.
    reg [5:0] tick_cnt;
    wire tick_179 = (tick_cnt == 44);
    
    always @(posedge sys_clk) begin
        if (tick_179) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
    end

    // Cross-Domain Write Enable
    // The 'pokey_we' signal comes from the 27MHz domain.
    // It will be High for ~20 sys_clk cycles. That is fine. 
    // POKEY registers are just latches; writing the same value 20 times is safe.
    wire pokey_we = is_pokey_addr && !rw_safe && phi2_safe;
    
    wire audio_raw;
    assign audio = audio_raw; 

    pokey_complete my_pokey (
        .clk(sys_clk),          // Fast Clock!
        .enable_179mhz(tick_179),
        .reset_n(pll_lock),     // Wait for PLL
        .addr(a_safe[3:0]),
        .din(d),                // Data from bus
        .we(pokey_we),          
        .audio_pwm(audio_raw)
    );

    assign led[0] = ~buf_oe;
    assign led[1] = ~pll_lock; 

endmodule