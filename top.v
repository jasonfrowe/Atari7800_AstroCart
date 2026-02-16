module top (
    input clk,              // 27MHz Crystal (Bus Clock)
    
    // Atari Interface
    input [15:0] a, inout [7:0] d,
    input phi2, input rw, input halt, input irq,
    
    // Outputs
    output reg buf_dir, output reg buf_oe,
    output audio, output [5:0] led,
    
    // SD Card Interface (SPI)
    output sd_clk,
    output sd_mosi,
    output sd_cs_n,
    input sd_miso,
    
    // PSRAM Interface (HyperRAM)
    // These "magic" port names are recognized by Gowin IDE
    // No CST pins needed - automatically routed to internal PSRAM
    output O_psram_ck,
    output O_psram_cs_n,
    inout IO_psram_rwds,
    inout [7:0] IO_psram_dq
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
    
    reg [15:0] a_safe;
    reg phi2_safe, rw_safe, halt_safe;

    always @(posedge clk) begin
        a_safe    <= a;
        phi2_safe <= phi2;
        rw_safe   <= rw;
        halt_safe <= halt;
    end

    // ========================================================================
    // 3. MEMORY SYSTEMS
    // ========================================================================
    
    // Menu ROM in BRAM (48KB)
    reg [7:0] menu_rom [0:49151]; 
    initial $readmemh("game.hex", menu_rom);
    
    // Game loaded flag (0=menu from BRAM, 1=game from PSRAM)
    reg game_loaded;
    
    // ========================================================================
    // 4. SD CARD CONTROLLER
    // ========================================================================
    
    wire sd_init_done;
    wire sd_read_done;
    wire [7:0] sd_data_out;
    wire sd_data_valid;
    wire sd_error;
    reg sd_start_init;
    reg sd_start_read;
    reg [31:0] sd_block_addr;
    
    sd_card_manager sd_mgr (
        .clk(clk),
        .reset_n(pll_lock),
        .start_init(sd_start_init),
        .start_read(sd_start_read),
        .block_addr(sd_block_addr),
        .init_done(sd_init_done),
        .read_done(sd_read_done),
        .read_data(sd_data_out),
        .read_data_valid(sd_data_valid),
        .error(sd_error),
        .spi_clk(sd_clk),
        .spi_mosi(sd_mosi),
        .spi_miso(sd_miso),
        .spi_cs_n(sd_cs_n)
    );
    
    // Initialize SD card on reset
    reg init_done_reg;
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin
            sd_start_init <= 1;
            init_done_reg <= 0;
        end else if (sd_init_done && !init_done_reg) begin
            init_done_reg <= 1;
            sd_start_init <= 0;
        end
    end
    
    // ========================================================================
    // 5. PSRAM CONTROLLER
    // ========================================================================
    
    wire [7:0] psram_read_data;
    wire psram_data_valid;
    wire psram_busy;
    wire psram_ck_n_unused;
    wire psram_reset_n_unused;
    reg psram_write_req;
    reg psram_read_req;
    reg [21:0] psram_addr_reg;
    reg [7:0] psram_write_data;
    
    psram_byte_controller psram_ctrl (
        .clk(clk),
        .clk_shifted(sys_clk_p),
        .reset_n(pll_lock),
        .read_req(psram_read_req),
        .write_req(psram_write_req),
        .address(psram_addr_reg),
        .write_data(psram_write_data),
        .read_data(psram_read_data),
        .data_valid(psram_data_valid),
        .busy(psram_busy),
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(psram_ck_n_unused),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(psram_reset_n_unused),
        .IO_psram_dq(IO_psram_dq),
        .IO_psram_rwds(IO_psram_rwds)
    );
    
    wire psram_ready = init_done_reg;
    
    // ========================================================================
    // 6. GAME LOADER
    // ========================================================================
    
    reg [3:0] game_select_reg;
    reg load_game_trigger;
    wire load_complete;
    wire load_error;
    wire [255:0] game_name;
    wire [31:0] game_size;
    wire [15:0] cart_type;
    wire loaded_game_has_pokey;
    wire [15:0] loaded_pokey_addr;
    wire [7:0] controller_1_unused;
    wire [7:0] controller_2_unused;
    wire tv_type_unused;
    wire loader_psram_write_req;
    wire [21:0] loader_psram_addr;
    wire [7:0] loader_psram_data;
    wire loader_sd_read_req;
    wire [31:0] loader_sd_block_addr;
    
    game_loader loader (
        .clk(clk),
        .reset_n(pll_lock),
        .game_select(game_select_reg),
        .load_game(load_game_trigger),
        .load_complete(load_complete),
        .load_error(load_error),
        .game_name(game_name),
        .game_size(game_size),
        .cart_type(cart_type),
        .has_pokey(loaded_game_has_pokey),
        .pokey_addr(loaded_pokey_addr),
        .controller_1(controller_1_unused),
        .controller_2(controller_2_unused),
        .tv_type(tv_type_unused),
        .psram_write_req(loader_psram_write_req),
        .psram_addr(loader_psram_addr),
        .psram_data(loader_psram_data),
        .psram_busy(psram_busy),
        .sd_read_req(loader_sd_read_req),
        .sd_block_addr(loader_sd_block_addr),
        .sd_data(sd_data_out),
        .sd_data_valid(sd_data_valid),
        .sd_busy(!sd_read_done)
    );
    
    // Multiplex PSRAM and SD card access between loader and CPU
    reg cpu_psram_read_req;
    reg [21:0] cpu_psram_addr;
    
    always @(*) begin
        if (game_loaded) begin
            // CPU has access (game is loaded and running)
            psram_write_req = 0;
            psram_read_req = cpu_psram_read_req;
            psram_addr_reg = cpu_psram_addr;
            psram_write_data = 8'h00;
            sd_start_read = 0;
            sd_block_addr = 32'h0;
        end else begin
            // Loader has access (menu or loading game)
            psram_write_req = loader_psram_write_req;
            psram_read_req = 0;
            psram_addr_reg = loader_psram_addr;
            psram_write_data = loader_psram_data;
            sd_start_read = loader_sd_read_req;
            sd_block_addr = loader_sd_block_addr;
        end
    end
    
    // Track when a game has been loaded
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin
            game_loaded <= 0;
        end else if (load_complete) begin
            game_loaded <= 1;
        end
    end
    
    // ========================================================================
    // 7. CONTROL REGISTERS  
    // ========================================================================
    // Address detection (bus snooping - we don't respond, just detect)
    // $2200-$220F: Menu options 0-15 (in 7800basic user RAM space)
    
    wire menu_trigger = (a_safe == 16'h2200) && !rw_safe && phi2_safe; // Detect write to $2200
    
    // Debug: LED that toggles on each detection
    reg debug_write_detected;
    reg prev_menu_trigger;
    
    reg load_trigger_pending;
    
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin
            game_select_reg <= 0;
            load_trigger_pending <= 0;
            load_game_trigger <= 0;
            debug_write_detected <= 0;
            prev_menu_trigger <= 0;
        end else begin
            prev_menu_trigger <= menu_trigger;
            
            // Detect rising edge of $2200 write (toggle LED once per write)
            if (menu_trigger && !prev_menu_trigger) begin
                game_select_reg <= d[3:0];
                load_trigger_pending <= 1;
                debug_write_detected <= ~debug_write_detected; // Toggle LED on each write
            end
            
            // Generate single-cycle load trigger pulse
            if (load_trigger_pending && !load_game_trigger) begin
                load_game_trigger <= 1;
                load_trigger_pending <= 0;
            end else begin
                load_game_trigger <= 0;
            end
        end
    end
    
    wire [7:0] status_byte = {
        psram_ready,           // bit 7: PSRAM initialized
        4'b0,                  // bits 6:3: reserved
        load_error,            // bit 2: error
        load_complete,         // bit 1: complete
        load_trigger_pending   // bit 0: loading
    };
    
    // ========================================================================
    // 8. MEMORY ACCESS & BUS OUTPUT
    // ========================================================================
    
    reg [7:0] data_out;
    reg [15:0] final_rom_addr;
    
    // Determine active POKEY configuration
    wire has_pokey = game_loaded ? loaded_game_has_pokey : 0;
    wire [15:0] pokey_base = game_loaded ? loaded_pokey_addr : 16'h0450;
    wire is_pokey_addr = has_pokey && (a_safe[15:4] == pokey_base[15:4]);
    
    // Address decoding
    always @(*) begin
        if (a_safe >= 16'h4000) final_rom_addr = a_safe - 16'h4000;
        else final_rom_addr = 0;
    end
    
    // Memory read logic
    always @(posedge clk) begin
        cpu_psram_read_req <= 0;
        
        if (game_loaded && final_rom_addr < game_size[15:0]) begin
            // Read from PSRAM (loaded game)
            cpu_psram_addr <= {6'b0, final_rom_addr};
            cpu_psram_read_req <= 1;
            if (psram_data_valid) begin
                data_out <= psram_read_data;
            end
        end else if (!game_loaded && final_rom_addr < 49152) begin
            // Read from BRAM (menu)
            data_out <= menu_rom[final_rom_addr];
        end else begin
            // Invalid address
            data_out <= 8'hEA;
        end
    end

    // Bus Control
    wire is_addr_valid = (a_safe >= 16'h4000); 
    wire timing_ok = (phi2_safe && halt_safe) || (!halt_safe);
    wire should_drive = is_addr_valid && rw_safe && timing_ok && !is_pokey_addr;

    always @(posedge clk) begin
        buf_dir <= rw_safe;
        if (should_drive || (!rw_safe && is_pokey_addr)) buf_oe <= 0;
        else buf_oe <= 1;
    end
    assign d = (should_drive) ? data_out : 8'bz;

    // ========================================================================
    // 9. POKEY LOGIC (Running at HIGH RES 108MHz)
    // ========================================================================
    
    // Generate 1.79MHz tick from 108MHz clock
    // 108 MHz / 1.79 MHz = ~60.33, use counter to 60
    reg [5:0] tick_cnt;
    wire tick_179 = (tick_cnt == 44);
    
    always @(posedge sys_clk) begin
        if (tick_179) tick_cnt <= 0; else tick_cnt <= tick_cnt + 1;
    end

    // Cross-Domain Write Enable
    wire pokey_we = is_pokey_addr && !rw_safe && phi2_safe;
    
    wire audio_raw;
    assign audio = audio_raw; 

    pokey_complete my_pokey (
        .clk(sys_clk),
        .enable_179mhz(tick_179),
        .reset_n(pll_lock),
        .addr(a_safe[3:0]),
        .din(d),
        .we(pokey_we),          
        .audio_pwm(audio_raw)
    );

    // ========================================================================
    // 10. DEBUG LEDS
    // ========================================================================
    
    assign led[0] = ~buf_oe;
    assign led[1] = ~pll_lock;
    assign led[2] = ~sd_init_done;
    assign led[3] = ~psram_ready;
    assign led[4] = ~debug_write_detected;  // Debug: toggles on each $2200 write (inverted = starts OFF, turns ON when detected)
    assign led[5] = ~game_loaded;

endmodule
