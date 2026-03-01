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
    
    // SD Card (SPI Mode)
    output       sd_cs,     // SPI Chip Select (active low)
    output       sd_mosi,   // SPI MOSI (Master Out, Slave In)
    input        sd_miso,   // SPI MISO (Master In, Slave Out)
    output       sd_clk,    // SPI Clock
    
    // PSRAM (Tang Nano 9K - Gowin IP Core)
    output wire [0:0] O_psram_ck,      // Clock
    output wire [0:0] O_psram_ck_n,    // Clock inverted
    output wire [0:0] O_psram_cs_n,    // CS#
    output wire [0:0] O_psram_reset_n, // Reset#
    inout [7:0]       IO_psram_dq,     // 8-bit Data
    inout [0:0]       IO_psram_rwds,   // RWDS
    
    output       audio,     // Audio PWM
    output [5:0] led,       // Debug LEDs
    
    // High-speed debug pins
    output       debug_pin1,
    output       debug_pin2
);

    // ========================================================================
    // 0. CLOCK GENERATION (27MHz native for Atari, 81MHz PSRAM, 81MHz Sys)
    // ========================================================================
    wire clk_81m;           // Declared here for sys_clk assignment
    wire sys_clk = clk_81m; // 81MHz System Clock
    wire clk_40m5;          // 40.5MHz for SD Card
    wire external_clk = clk;

    // ========================================================================
    // 1. INPUT SYNCHRONIZATION
    // ========================================================================
    reg [15:0] a_safe;
    reg phi2_safe;
    reg rw_safe;
    reg halt_safe;

    // NEW: Glitch Filter for Address Bus
    reg [15:0] a_delay;
    reg [15:0] a_stable;

    // Run synchronization on FAST clock
    always @(posedge sys_clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
        
        // Only accept the address if it hasn't changed for 2 clock ticks (~50ns)
        a_delay <= a_safe;
        if (a_safe == a_delay) a_stable <= a_safe;
    end

    // ========================================================================
    // 2. MEMORY & DECODING
    // ========================================================================
    reg [7:0] rom_memory [0:49151]; 
    reg [7:0] data_out;
    initial $readmemh("game.hex", rom_memory);

    wire [15:0] rom_index = a_stable - 16'h4000;
    
    // PSRAM / System status
    wire clk_81m_shifted;
    wire pll_lock;
    
    // Handover Registers
    reg busy;
    wire [3:0] sd_state;
    
    // Status Byte: 0x00=Busy (Loading), 0x80=Done/Ready
    wire [7:0] status_byte = busy ? 8'h00 : 8'h80;

    wire game_loaded;
    wire switch_pending;
    
    // BRAM Write Interface from Loader
    wire bram_we;
    wire [15:0] bram_addr;
    wire [7:0] bram_data;
    
    // Header Info from Loader
    wire [31:0] cart_rom_size;
    wire cart_has_pokey;
    wire [15:0] cart_pokey_addr;
    wire [3:0]  cart_mapper;        // 0=standard, 1=SuperGame
    wire        cart_ram_at_4000;   // 1=16KB RAM mapped at $4000-$7FFF

    // SuperGame (SGM) decode
    wire is_sgm = (cart_mapper == 4'd1);

    // -----------------------------------------------------------------------
    // SuperGame bank register
    // Any CPU write to $8000-$BFFF sets bank_reg to d[3:0].
    // The banked 16KB window at $8000-$BFFF maps to PSRAM bank*16KB.
    // -----------------------------------------------------------------------
    reg [3:0] bank_reg;
    wire sgm_bank_we = is_sgm && game_loaded && !rw_safe && phi2_safe
                       && (a_stable[15:14] == 2'b10); // $8000-$BFFF
    always @(posedge sys_clk) begin
        if (!pll_lock) bank_reg <= 4'd0;
        else if (sgm_bank_we) bank_reg <= d[3:0];
    end

    // -----------------------------------------------------------------------
    // SuperGame RAM write path
    // CPU writes to $4000-$7FFF (cart_ram_at_4000 set) → PSRAM 0x40000.
    // We latch the write on the rising edge of the CPU write strobe and
    // issue a byte-write to PSRAM when the bus is free.
    // Layout: ROM 0x00000-0x3FFFF (256KB), SGM RAM 0x40000-0x43FFF (16KB).
    // -----------------------------------------------------------------------
    reg       sgm_wr_pending;
    reg [21:0] sgm_wr_addr;
    reg [7:0]  sgm_wr_byte;
    reg        sgm_ram_we_prev;
    wire sgm_ram_we_wire = is_sgm && cart_ram_at_4000 && game_loaded
                           && !rw_safe && phi2_safe
                           && (a_stable[15:14] == 2'b01); // $4000-$7FFF
    always @(posedge sys_clk) begin
        sgm_ram_we_prev <= sgm_ram_we_wire;
        if (!pll_lock) begin
            sgm_wr_pending <= 0;
        end else if (sgm_ram_we_wire && !sgm_ram_we_prev) begin
            // Rising edge of CPU write: latch address and data
            sgm_wr_pending <= 1;
            sgm_wr_addr    <= {4'b0001, 4'b0000, a_stable[13:0]}; // PSRAM 0x40000+offset
            sgm_wr_byte    <= d;
        end else if (sgm_wr_pending && !psram_busy) begin
            sgm_wr_pending <= 0;
        end
    end
    


    // ROM Fetch / PSRAM Read / Status Read
    always @(posedge sys_clk) begin
        // Allow Loader to write to Menu RAM (BRAM) during header scan
        if (bram_we) begin
            // Map $6000-$6FFF to ROM index (Offset $2000)
            if (bram_addr >= 16'h4000) rom_memory[bram_addr - 16'h4000] <= bram_data;
        end
        
        if (!game_loaded) begin
            if (a_stable == 16'h7FF0) data_out <= status_byte;
            else if (rom_index < 49152) data_out <= rom_memory[rom_index];
            else data_out <= 8'hFF;
        end
    end
    // Decoders (Using STABLE address to prevent bus contention during transitions)
    wire is_rom   = (a_stable[15] | a_stable[14]);               // $4000-$FFFF
    wire is_pokey = cart_has_pokey && (a_stable[15:4] == cart_pokey_addr[15:4]);
    wire is_2200  = (a_stable == 16'h2200) && !game_loaded;    // $2200 (Menu Control disabled in game)

    // ========================================================================
    // 3. BUS ARBITRATION
    // ========================================================================
    
    // Drive Enable (Read from ROM)
    // Simplified logic: Drive whenever address is in ROM range and R/W is Read.
    wire should_drive = is_rom && rw_safe;

    // Write Enables
    wire pokey_we   = is_pokey && !rw_safe && phi2_safe;
    wire trigger_we = is_2200  && !rw_safe && phi2_safe;

    // ========================================================================
    // 4. OUTPUTS
    // ========================================================================

    // [FIX] Always-Enabled Transceiver Control
    // User Request: "buf_oe is controlled by FPGA alone. Keep buf_oe low all the time."
    // Direction (buf_dir) controlled by our drive logic + sticky hold.
    always @(posedge sys_clk) begin
        // Direction:
        // High (1) = Output (FPGA -> Atari) when we should drive.
        // Low (0)  = Input  (Atari -> FPGA) default.
        if (should_drive || pokey_we || trigger_we) begin 
            if (should_drive) buf_dir <= 1'b1; // Output
            else buf_dir <= 1'b0;              // Input
        end else begin
            buf_dir <= 1'b0; // Default to Input
        end

        // Output Enable: ALWAYS ON (Low)
        buf_oe <= 1'b0; 
    end


    // FPGA Tristate (Bypass data_out sync for game data to save 1 sys_clk latency)
    assign d = (should_drive) ? (game_loaded ? ip_data_buffer : data_out) : 8'bz;

    // ========================================================================
    // 5. POKEY AUDIO INSTANCE
    // ========================================================================
    
    // Clock Divider (81MHz -> 1.79MHz)
    // 81 / 1.79 ~= 45.25. Use 45.
    reg [5:0] clk_div;
    wire tick_179 = (clk_div == 44);
    
    always @(posedge sys_clk) begin
        if (clk_div >= 44) clk_div <= 0;
        else clk_div <= clk_div + 1;
    end

    // POKEY Pulse Stretcher
    // tick_179 fires every 45 sys_clk (~556ns). A CPU write pulse via phi2_safe is
    // ~22 sys_clk wide (~272ns) — a <50% window. Without stretching there's a >50%
    // chance tick_179 never fires while pokey_we is high, causing the write to be missed.
    // On the rising edge of pokey_we we latch the stable bus values, then hold
    // pokey_we_stretch high until tick_179 fires (guaranteeing POKEY consumes the write).
    reg       pokey_we_stretch;
    reg [7:0] pokey_din_latched;
    reg [3:0] pokey_addr_latched;
    reg       pokey_we_prev;

    always @(posedge sys_clk) begin
        pokey_we_prev <= pokey_we;
        if (!pll_lock) begin
            pokey_we_stretch <= 0;
        end else if (pokey_we && !pokey_we_prev) begin
            // Rising edge: latch stable bus values and start stretching
            pokey_din_latched  <= d;
            pokey_addr_latched <= a_stable[3:0];
            pokey_we_stretch   <= 1;
        end else if (pokey_we_stretch && tick_179) begin
            // POKEY's internal clock just ticked while we held write high — write consumed
            pokey_we_stretch <= 0;
        end
    end

    pokey_advanced my_pokey (
        .clk(sys_clk),
        .enable_179mhz(tick_179),
        .reset_n(pll_lock),
        .addr(pokey_addr_latched),
        .din(pokey_din_latched),
        .we(pokey_we_stretch),        // Pulse-stretched write enable
        .audio_pwm(audio)
    );

    // ========================================================================
    // 6. SD CARD - calint sd_controller (Tang 9K proven)
    // ========================================================================
    
    // Power-on reset for SD controller
    // Use PLL lock as reset - gives ~50ms initialization time
    wire sd_reset = !pll_lock;

    // ========================================================================
    // 7. PSRAM CONTROLLER (Gowin IP)
    // ========================================================================
    
    gowin_pll pll_inst (
        .clkin(external_clk),
        .clkout(clk_81m),
        .clkoutp(clk_81m_shifted),
        .clkoutd(clk_40m5),
        .lock(pll_lock)
    );
    
    // PSRAM Signals - original interface
    reg psram_rd_req;
    wire psram_wr_req;
    wire [15:0] psram_dout_16;
    
    // PSRAM Interface Signals
    // --- Clock Domain Crossing (CDC) ---
    // [OPTIMIZATION] Removed CDC logic as sys_clk is now 81MHz (same as PSRAM)
    wire psram_cmd_write = psram_wr_req;
    wire psram_cmd_read  = psram_rd_req;
    
    // Synchronize 81MHz Busy -> 27MHz Safe Level
    wire psram_busy_raw;
    wire psram_busy = psram_busy_raw;
    
    // PSRAM Address
    wire [22:0] psram_write_addr_latched;

    // SuperGame read-address calculation:
    //   $4000-$7FFF → PSRAM 0x40000 + offset  (SGM RAM)  bits: {4'b0001, 4'b0000, offset[13:0]}
    //   $8000-$BFFF → PSRAM bank*16K + offset  (banked)  bits: {4'b0000, bank_reg, offset[13:0]}
    //   $C000-$FFFF → PSRAM 0x3C000 + offset   (fixed)   bits: {4'b0000, 4'b1111, offset[13:0]}
    // All three regions have the same a_stable[13:0] offset within their 16KB bank.
    wire [21:0] psram_sgm_addr =
        (a_stable[15:14] == 2'b01) ? {4'b0001, 4'b0000, a_stable[13:0]} :
        (a_stable[15:14] == 2'b10) ? {4'b0000, bank_reg, a_stable[13:0]} :
                                     {4'b0000, 4'b1111,  a_stable[13:0]};

    // Drive addr from live a_stable — PsramController latches internally at start of op.
    wire [21:0] psram_addr_mux = game_loaded
        ? (is_sgm ? psram_sgm_addr : ({6'b0, a_stable} - 22'h004000))
        : psram_write_addr_latched[21:0];
    wire [22:0] psram_cmd_addr = {1'b0, psram_addr_mux};

    // SGM write arbitration: when a SGM RAM write is pending and bus is free, fire it.
    // Gate: do not overlap with ongoing PSRAM operations.
    wire sgm_doing_write = sgm_wr_pending && !psram_busy;

    // Final signals to PsramController — SGM writes take priority over reads.
    wire        psram_final_write = psram_wr_req || sgm_doing_write;
    wire [21:0] psram_final_addr  = sgm_doing_write ? sgm_wr_addr              : psram_cmd_addr[21:0];
    wire [15:0] psram_final_din   = sgm_doing_write ? {sgm_wr_byte, sgm_wr_byte}: acc_word0;
    wire        psram_final_bw    = sgm_doing_write; // byte_write=1 for SGM RAM

    wire [15:0] acc_word0;
    reg         write_pending;
    reg [7:0]   ip_data_buffer;

    // Instantiate Custom PSRAM Controller
    PsramController #(
        .FREQ(81_000_000),
        .LATENCY(3)
    ) psram_ctrl (
        .clk(clk_81m),
        .clk_p(clk_81m_shifted),
        .resetn(pll_lock),
        .read(psram_cmd_read),
        .write(psram_final_write),
        .addr(psram_final_addr),
        .din(psram_final_din),
        .byte_write(psram_final_bw),
        .dout(psram_dout_16),
        .busy(psram_busy_raw),    // Raw 81MHz output to be synchronized down to 27MHz
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );
    
    assign O_psram_reset_n = 1'b1;
    
    // Data Capture Logic
    always @* begin
        ip_data_buffer = psram_cmd_addr[0] ? psram_dout_16[15:8] : psram_dout_16[7:0];
    end

    // PSRAM Read/Write Logic
    reg [15:0] last_req_addr;
    reg game_loaded_d;
    
    always @(posedge sys_clk) begin
        game_loaded_d <= game_loaded;
        
        if (sd_reset) begin
            last_req_addr <= 16'hFFFF;
        end else begin
            // Prefetch: trigger PSRAM read on every address change.
            // Full 16-bit comparison (not word-boundary) is required because MARIA performs
            // non-sequential DMA — it jumps between distant ROM addresses. Using word-boundary
            // comparison allows psram_dout_16 to be silently overwritten by an intervening
            // read before the odd byte is served, returning stale data.
            // Every address change fires a fresh read; psram_cmd_addr[0] = a_stable[0]
            // always selects the correct byte from the returned 16-bit word.
            // Also fire on rising edge of game_loaded ($FFFC reset vector may already be stable).
            // Gate: don't trigger a read while an SGM RAM write is pending — both can't
            // use PSRAM simultaneously, and the write has priority.
            //
            // SGM BANK SWITCH CACHE INVALIDATION:
            // last_req_addr tracks only a_stable, not the effective PSRAM address.
            // After a SuperGame bank switch the same CPU address maps to a different
            // PSRAM location. Without invalidation the read trigger sees
            // a_stable == last_req_addr and silently serves stale data from the old
            // bank — corrupting MARIA tile DMA. Force a full re-fetch on every bank write.
            if (sgm_bank_we) last_req_addr <= 16'hFFFF;

            if (game_loaded && !sgm_doing_write && (a_stable[15] | a_stable[14]) && !psram_busy &&
                (a_stable != last_req_addr || (!game_loaded_d && game_loaded))) begin
                psram_rd_req <= 1;
                last_req_addr <= a_stable;
            end else if (psram_busy) begin
                psram_rd_req <= 0;
            end else if (!game_loaded) begin
                psram_rd_req <= 0;
                last_req_addr <= 16'hFFFF;
            end
        end
    end

    
    // Capture Read Data
    // Note: read_data from controller is stable until next read.
    // We can just update psram_latched_data when busy falls?
    // Or just use psram_dout_bus directly in data_out assignments?
    // Let's use `psram_dout_bus` directly, as it holds value.

    
    // SD Controller signals

    // ========================================================================
    // 5. CART LOADER (SD to PSRAM)
    // ========================================================================
    wire write_pending_loader;
    
    cart_loader loader_inst (
        .clk_sys(sys_clk),
        .clk_sd(clk_40m5),
        .reset(sd_reset),
        
        .a_stable(a_stable),
        .d(d),
        .rw_safe(rw_safe),
        .phi2_safe(phi2_safe),
        .trigger_we(trigger_we),
        
        .sd_cs(sd_cs),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_clk(sd_clk),
        
        .psram_busy(psram_busy),
        .psram_wr_req(psram_wr_req),
        .psram_write_addr_latched(psram_write_addr_latched),
        .acc_word0(acc_word0),
        
        .game_loaded(game_loaded),
        .switch_pending(switch_pending),
        .sd_state(sd_state),
        .busy(busy),
        .write_pending(write_pending_loader),
        
        .bram_we(bram_we),
        .bram_addr(bram_addr),
        .bram_data(bram_data),
        
        .cart_rom_size(cart_rom_size),
        .cart_has_pokey(cart_has_pokey),
        .cart_pokey_addr(cart_pokey_addr),
        .cart_mapper(cart_mapper),
        .cart_ram_at_4000(cart_ram_at_4000)
    );
    
    always @* write_pending = write_pending_loader;
        

    // ========================================================================
    // 6. DEBUG (Smart Visualizer - Atari Active Gated)
    // ========================================================================
    
    smart_blinkers blinkers_inst (
        .clk(sys_clk),
        .phi2_safe(phi2_safe),
        .a_stable(a_stable),
        .is_pokey(is_pokey),
        .is_2200(is_2200),
        .rw_safe(rw_safe),
        .buf_oe(buf_oe),
        .buf_dir(buf_dir),
        .psram_busy(psram_busy),
        .psram_rd_req(psram_rd_req),
        .pll_lock(pll_lock),
        .game_loaded(game_loaded),
        .write_pending(write_pending),
        .led(led)
    );
    
    // --- Oscilloscope Debug Pins ---
    // High-speed 1.8V outputs for accurate timing measurement
    assign debug_pin1 = psram_rd_req;     // Probe 1: Start of Read Request
    assign debug_pin2 = !psram_busy; // Probe 2: Data return from PSRAM IP
    
endmodule