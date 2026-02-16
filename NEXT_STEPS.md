# Next Steps for Atari 7800 Multi-Game Cartridge

## Immediate Tasks (Ready to Work On)

### 1. Create Menu Font Graphic
**Priority: HIGH**

The menu program needs a font graphic before it can be compiled.

```bash
cd menu/gfx
# Option A: Copy from 7800basic samples
cp /Users/rowe/Software/Atari7800/7800basic/samples/samplegfx/atascii.png menufont.png

# Option B: Create a simple 4-color PNG (32×8 pixels)
# Use any pixel art editor (Piskel, Aseprite, GIMP, etc.)
```

See `menu/gfx/README.md` for detailed instructions.

### 2. Test Menu Program
**Priority: HIGH**

Once the font is created:

```bash
cd menu
./build.sh
# Test the .a78 file in an emulator (A7800, MAME, etc.)
```

### 3. Fix PSRAM Implementation
**Priority: HIGH**

The current `psram.v` has issues. Use the new `psram_controller_fixed.v` instead:

**Migration steps:**
1. Update `top.v` to use the new PSRAM controller
2. Verify ODDR primitive syntax for your specific FPGA
3. Adjust clock frequencies (currently set for 81MHz)
4. Test with hardware if available

**Key changes needed in top.v:**
```verilog
// Replace old psram instantiation with:
psram_byte_controller psram (
    .clk(sys_clk),              // 81MHz or adjust as needed
    .clk_shifted(sys_clk_p),    // Phase-shifted clock
    .reset_n(pll_lock),
    // ... rest of signals
);
```

### 4. Integrate SD Card Controller  
**Priority: MEDIUM**

Add SD card initialization and reading:

**In top.v:**
```verilog
// Add SD card signals to module ports
output wire sd_clk,
output wire sd_mosi, 
input wire sd_miso,
output wire sd_cs_n,

// Instantiate the controller
sd_card_manager sdcard (
    .clk(clk),
    .reset_n(pll_lock),
    .spi_clk(sd_clk),
    .spi_mosi(sd_mosi),
    .spi_miso(sd_miso),
    .spi_cs_n(sd_cs_n),
    // Control signals...
);
```

### 5. Integrate Game Loader
**Priority: MEDIUM**

Connect the game loader module:

```verilog
game_loader loader (
    .clk(clk),
    .reset_n(pll_lock),
    .game_select(game_select_reg),  // From Atari write to $5000
    .load_game(load_trigger),
    .load_complete(load_done),
    // Connect to PSRAM and SD card controllers
);
```

### 6. Add Control Registers
**Priority: MEDIUM**

Implement memory-mapped registers for menu communication:

```verilog
// At address $5000: Game select register (write only)
// At address $5001: Status register (read only)
//   Bit 0: Load in progress
//   Bit 1: Load complete
//   Bit 2: Error flag

reg [3:0] game_select_reg;
reg load_trigger;

always @(posedge clk) begin
    if (a_safe == 16'h5000 && !rw_safe && phi2_safe) begin
        game_select_reg <= d[3:0];
        load_trigger <= 1'b1;
    end else begin
        load_trigger <= 1'b0;
    end
end
```

## Testing Plan

### Phase 1: Menu Only (No Hardware)
- [x] Create menu program
- [ ] Create menu font
- [ ] Build and test menu in emulator
- [ ] Verify joystick controls work

### Phase 2: PSRAM Testing
- [ ] Build bitstream with PSRAM controller
- [ ] Program FPGA
- [ ] Test PSRAM read/write on real hardware
- [ ] Use LEDs to display status

### Phase 3: SD Card Testing  
- [ ] Add SD card controller to build
- [ ] Test SD card initialization
- [ ] Read test file from SD card
- [ ] Display data on LEDs

### Phase 4: Integration
- [ ] Load menu program from internal ROM
- [ ] Detect Atari writes to control register
- [ ] Load game from SD to PSRAM
- [ ] Parse .a78 header
- [ ] Configure mapper dynamically

### Phase 5: Full System
- [ ] Test with multiple games
- [ ] Implement reset control
- [ ] Add bankswitching support
- [ ] Optimize loading speed

## Hardware Requirements

### Essential
- Tang Nano 9K FPGA board
- MicroSD card (formatted FAT32)
- Atari 7800 console
- Custom PCB or breadboard for interfacing
- Level shifters (for 5V ↔ 3.3V conversion)

### Recommended
- Logic analyzer (for debugging)
- Oscilloscope
- JTAG programmer
- Multiple test games in .a78 format

## Files Overview

### Verilog Modules
```
top.v                    - Main integration (already exists, needs updates)
sd_spi_controller.v      - SD card interface (NEW - completed)
psram_controller_fixed.v - PSRAM interface (NEW - completed)
a78_loader.v            - Game loader & parser (NEW - completed)
gowin_pll.v             - Clock generation (already exists)
pokey_advanced.v        - POKEY emulation (already exists)
```

### 7800basic Code
```
menu/menu.bas           - Menu program (NEW - completed)
menu/gfx/menufont.png   - Font graphic (needs creation)
menu/build.sh           - Build script (NEW - completed)
```

### Documentation
```
README_NEW.md           - System overview (NEW - completed)
NEXT_STEPS.md           - This file (NEW - completed)
menu/gfx/README.md      - Font creation guide (NEW - completed)
```

## Common Issues and Solutions

### PSRAM Not Working
- Check voltage levels (should be 1.8V)
- Verify clock phase relationship
- Increase latency cycles if timing is marginal
- Check ODDR primitive syntax for your FPGA

### SD Card Not Detected
- Verify 3.3V levels
- Check pull-up resistors on MISO
- Try slower SPI clock (divide by 4 or 8)
- Ensure proper initialization sequence

### Menu Not Displaying
- Verify font PNG format (indexed color, 4 colors max)
- Check character alignment (4 pixels per char in 320A)
- Ensure plotchars X/Y coordinates are on screen
- Test with simpler text first

### Game Won't Load
- Verify .a78 header format
- Check PSRAM address mapping
- Ensure sufficient latency for read operations
- Test with known-good ROM first

## Resource Allocation

Current FPGA usage estimate:
- **Logic Cells**: ~3000 / 8640 (35%)
- **Block RAM**: 48KB menu + POKEY buffers
- **I/O Pins**: 45 / 86 (52%)

Plenty of room for expansion!

## Questions to Resolve

1. **PSRAM Clock**: Stick with 81MHz or adjust to 108MHz?
2. **Menu Storage**: Keep in BRAM or load from SD?
3. **File System**: Implement FAT32 or simple sequential storage?
4. **Reset Method**: Hardware reset pin or soft reset via register?

## Support Resources

- **7800basic Forum**: https://atariage.com/forums/forum/65-atari-7800-programming/
- **Tang Nano Docs**: https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html
- **Atari 7800 Hardware**: http://7800.8bitdev.org

---

**Current Status**: Foundation complete, ready for hardware testing!

Good luck with the build! 🎮
