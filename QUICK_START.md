# Atari 7800 AstroCart - Quick Start Guide

## System Overview

This FPGA cartridge system implements a multi-game loader for Atari 7800, with:
- Menu system in BRAM (48KB)
- Game loading from SD card to PSRAM (4MB)
- Dynamic cartridge configuration based on .a78 headers
- POKEY audio chip support
- Multiple cartridge mapper types

## Current Status

✅ **Completed:**
- Menu system with joystick navigation
- SD card SPI interface
- PSRAM byte controller
- Game loader with .a78 header parser
- Control register interface ($5000/$5001)
- Memory multiplexing (BRAM menu ↔ PSRAM game)
- POKEY audio at configurable addresses

⏳ **Testing Required:**
- SD card initialization and block reads
- PSRAM writes during game loading
- Game execution from PSRAM
- POKEY @ $450 with astrowing.a78

## Build Process

### 1. Compile Menu ROM
```bash
cd menu
# Compile with 7800basic (already done - menu.bas.bin and menu.bas.a78 exist)
```

### 2. Generate FPGA Memory Image
```bash
python3 rom_gen.py menu/menu.bas.bin
# Creates game.hex for BRAM initialization
```

### 3. Build FPGA Bitstream
Open Lushay Code IDE:
1. Load project: Atari7800_AstroCart
2. Click "Build" 
3. Wait for synthesis to complete
4. Output: `Atari7800_AstroCart.fs`

### 4. Program FPGA
```bash
# Use openFPGALoader or Lushay Code programmer
openFPGALoader -b tangnano9k Atari7800_AstroCart.fs
```

## SD Card Setup

### Quick Method
```bash
# Format SD card as FAT32
diskutil eraseDisk FAT32 ATARI7800 MBRFormat /dev/diskX

# Copy game files
cp astrowing.a78 /Volumes/ATARI7800/GAME0.A78
cp ARTI_Final_digital_edition_jan24_1.1.a78 /Volumes/ATARI7800/GAME1.A78

# Unmount safely
diskutil unmount /Volumes/ATARI7800
```

See [SD_CARD_SETUP.md](SD_CARD_SETUP.md) for detailed instructions.

## Hardware Connections

### Tang Nano 9K to Atari 7800 Cartridge Slot

**Data Bus (8-bit):**
- d[0:7] ↔ Cartridge data pins

**Address Bus (16-bit):**
- a[0:15] ↔ Cartridge address pins

**Control Signals:**
- phi2 ← 7800 clock (1.79MHz)
- rw ← Read/Write signal
- halt ← DMA halt signal
- buf_dir → 74LVC245 direction control
- buf_oe → 74LVC245 output enable

**Audio:**
- audio → POKEY audio output (PWM)

**Storage:**
- SD card slot on Tang Nano 9K
- PSRAM on-board (no external connections)

## LED Debug Indicators

| LED | Signal | Meaning |
|-----|--------|---------|
| 0 | ~buf_oe | Bus output enabled (off=driving) |
| 1 | ~pll_lock | PLL locked (off=ready) |
| 2 | ~sd_init_done | SD card initialized (off=ready) |
| 3 | ~psram_ready | PSRAM ready (off=ready) |
| 4 | ~load_complete | Game load done (off=done) |
| 5 | ~game_loaded | Game active (off=playing game) |

## Usage Flow

1. **Power On**: Menu appears on screen
2. **Navigate**: Use joystick up/down to select game
3. **Select**: Press fire button
4. **Loading**: Background flashes, LEDs show status
5. **Play**: Game starts automatically at completion

## Control Register Map

| Address | Access | Function |
|---------|--------|----------|
| $5000 | Write | Game select (0-4) - triggers loading |
| $5001 | Read | Status: [PSRAM ready][reserved×4][error][complete][loading] |

## Memory Map (Atari View)

| Address Range | Content | Source |
|---------------|---------|--------|
| $0000-$3FFF | Reserved | N/A |
| $4000-$FFFF | Game ROM | BRAM (menu) or PSRAM (loaded game) |
| $0450 | POKEY (if enabled) | pokey_complete module @ 108MHz |
| $5000 | Game Select Register | Write-only control |
| $5001 | Status Register | Read-only status |

## Test Plan for astrowing.a78

### Phase 1: SD Card Test
1. Insert SD with GAME0.A78 (astrowing.a78)
2. Power on - check LED[2] goes off (SD ready)
3. Check LED[3] goes off (PSRAM ready)

### Phase 2: Menu Test
4. Verify menu displays with 5 games
5. Test joystick up/down navigation
6. Cursor should move smoothly without jumping

### Phase 3: Load Test
7. Select "ASTRO CART" (game 0)
8. Press fire button
9. Background should flash briefly
10. Check LED[4] goes off (load complete)
11. Check LED[5] goes off (game loaded)

### Phase 4: Game Test
12. Astro Wing should start playing
13. POKEY audio should work @$450
14. Game should play normally

## Troubleshooting

### Menu Won't Display
- Check BRAM initialization (game.hex)
- Verify bus signals with logic analyzer
- Check PLL lock (LED[1] should be off)

### SD Card Not Detected
- Try different SD card
- Check SPI pins in constraint file
- Verify FAT32 format

### Game Won't Load
- Check GAME0.A78 exists on SD card
- Watch LED indicators for error
- Check .a78 header with hex editor

### Game Loads But Won't Run
- Verify PSRAM reads work
- Check game size matches header
- Test with known-working game

## File Structure

```
Atari7800_AstroCart/
├── top.v                      # Main FPGA module
├── sd_spi_controller.v        # SD card SPI interface
├── psram_controller_fixed.v   # PSRAM DDR controller
├── a78_loader.v               # Game loader + header parser
├── gowin_pll.v                # Clock generation (27→108MHz)
├── pokey_advanced.v           # POKEY sound chip
├── atari.cst                  # Pin constraints
├── game.hex                   # Menu ROM (BRAM init)
├── mapper.hex                 # Mapper config (deprecated)
├── menu/
│   ├── menu.bas               # 7800basic menu source
│   ├── menu.bas.bin           # Compiled ROM (no header)
│   └── menu.bas.a78           # Compiled ROM (with .a78 header)
├── rom_gen.py                 # Converts .bin → .hex
├── SD_CARD_SETUP.md           # Detailed SD card instructions
└── QUICK_START.md             # This file
```

## Next Steps

### Immediate:
1. Build FPGA bitstream with updated code
2. Program Tang Nano 9K
3. Prepare SD card with GAME0.A78
4. Test menu and game loading

### Short Term:
5. Test ARTI (256K SuperGame)
6. Implement SuperGame banking
7. Add more cartridge mapper types

### Long Term:
8. FAT32 file system for directory scanning
9. On-screen game list (auto-detect from SD)
10. Save RAM support for battery-backed games
11. HSC (High Score Cart) emulation

## Technical Specifications

- **FPGA**: Gowin GW1NR-LV9 (Tang Nano 9K)
- **System Clock**: 27MHz (crystal)
- **PLL Output**: 108MHz (for POKEY and PSRAM DDR)
- **Menu ROM**: 48KB BRAM
- **Game Storage**: 4MB PSRAM (expandable)
- **SD Interface**: SPI mode, 13.5MHz
- **PSRAM**: HyperRAM DDR protocol
- **Audio**: POKEY PWM output
- **Display**: Via original Atari 7800 MARIA

## References

- [A78 Header Specification](http://7800.8bitdev.org/index.php/A78_Header_Specification)
- [7800basic Compiler](https://github.com/7800-devtools/7800basic)
- [Tang Nano 9K Documentation](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
- [Atari 7800 Hardware Manual](http://www.atarimuseum.com/videogames/consoles/7800/games/a7800.html)
