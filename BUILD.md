# Building and Programming

## Prerequisites

1. **Gowin IDE** (Educational Edition)
   - Installed at: `/Applications/GowinIDE.app/`
   - Download from: https://www.gowinsemi.com/en/support/download_eda/
   - Free Educational Edition supports GW1NR-9C (Tang Nano 9K)

2. **openFPGALoader**
   - Already installed via Homebrew
   - Used for programming the FPGA

3. **7800basic** (for menu compilation)
   - Compile `menu/menu.bas` to `menu/menu.bas.bin`
   - Script will convert this to `game.hex` automatically

## Build Process

### 1. Compile Menu (if changed)
```bash
cd menu
7800basic menu.bas
cd ..
```

### 2. Synthesize FPGA Design
```bash
./build_gowin.sh
```

This will:
- Generate `game.hex` from menu ROM
- Run Gowin IDE synthesis
- Create bitstream at `impl/pnr/Atari7800_AstroCart.fs`

### 3. Program FPGA
```bash
./program.sh
```

Choose:
- **Option 1 (SRAM)**: Fast, temporary - lost on power cycle (good for testing)
- **Option 2 (Flash)**: Permanent - survives power cycle (for final version)

## LED Indicators

After programming, the LEDs indicate status:

| LED | Signal | Meaning (active LOW) |
|-----|--------|---------------------|
| 0 | buf_oe | Bus driving (off = driving Atari bus) |
| 1 | pll_lock | PLL ready (off = clock locked) |
| 2 | sd_init_done | SD card ready (off = initialized) |
| 3 | psram_ready | PSRAM ready (off = ready) |
| 4 | load_complete | Game loaded (off = done loading) |
| 5 | game_loaded | Mode (off = menu, on = game) |

## Notes on PSRAM

The Tang Nano 9K has **internal PSRAM** that is automatically routed by Gowin IDE when it sees the special port names:
- `O_psram_ck`, `O_psram_cs_n`
- `IO_psram_rwds`, `IO_psram_dq[7:0]`

These ports **do not** need CST pin assignments - Gowin handles the internal routing automatically.

## Alternative: Manual Build in Gowin IDE GUI

If the command-line build doesn't work:
1. Open Gowin IDE
2. Create new project for GW1NR-9C device
3. Add all `.v` files
4. Add `atari.cst` constraint file
5. Set `top` as top module
6. Run synthesis and implementation
7. Use `program.sh` to flash the result

## Troubleshooting

**Board not detected:**
- Check USB cable (must support data, not just power)
- Try a different USB port
- Verify board has power LED on

**Build fails:**
- Check that all `.v` files are present
- Ensure `menu/menu.bas.bin` exists
- Try running synthesis manually in Gowin IDE GUI

**Game loading doesn't work:**
- Check SD card is formatted FAT32
- Verify `GAME0.A78` is on SD card root
- See `SD_CARD_SETUP.md` for details
