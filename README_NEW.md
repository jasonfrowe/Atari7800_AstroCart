# Atari 7800 Multi-Game Cartridge with SD Card Loader

## Overview

This project creates an advanced FPGA-based cartridge for the Atari 7800 that can load multiple games from an SD card. The system includes:

- **SD Card Interface**: SPI-based SD card reader
- **PSRAM Storage**: 4MB of PSRAM for storing loaded games
- **Game Loader**: Automatic .a78 header parsing and game loading
- **Menu System**: 7800basic-based menu for game selection
- **Dynamic Configuration**: Automatic mapper and POKEY configuration based on game headers

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Atari 7800 Console                      │
└────────────────────┬────────────────────────────────────────┘
                     │ Cartridge Bus
┌────────────────────┴────────────────────────────────────────┐
│                    FPGA (Tang Nano 9K)                      │
│                                                             │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐  │
│  │ Game Loader  │──→│   PSRAM      │←──│  SD Card     │  │
│  │  & Parser    │   │  Controller  │   │  SPI Ctrl    │  │
│  └──────┬───────┘   └──────────────┘   └──────────────┘  │
│         │                                                  │
│         ↓                                                  │
│  ┌──────────────────────────────────────┐                 │
│  │   Atari Bus Interface & Mapper       │                 │
│  └──────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. SD Card Controller (`sd_spi_controller.v`)

Implements SPI protocol for SD card communication:
- Byte-level read/write operations
- Automatic initialization sequence
- Block read support for efficient data transfer
- Configurable SPI clock (runs at 13.5MHz from 27MHz system clock)

### 2. PSRAM Controller (`psram_controller_fixed.v`)

Based on the Tang Nano 9K reference design:
- HyperRAM/PSRAM protocol implementation
- 4MB address space (22-bit addressing)
- Byte-level access for flexibility
- DDR clock generation using ODDR primitives
- Low latency (12 cycles typical for read)

### 3. A78 Header Parser (`a78_loader.v`)

Automatically extracts game configuration:
- Cartridge type and mapper
- ROM size
- POKEY chip presence and address ($450, $800, or $4000)
- Controller requirements
- Cartridge RAM configuration

### 4. Menu System (`menu/menu.bas`)

7800basic program for game selection:
- Displays list of available games
- Joystick-controlled cursor
- Communicates with FPGA via memory-mapped register
- Triggers game loading and system reset

## How It Works

### Boot Sequence

1. **Power On**: FPGA loads menu program from internal ROM
2. **Menu Display**: 7800 boots and displays game selection menu
3. **SD Scan**: FPGA scans SD card for .a78 game files
4. **Game List**: Menu displays available games

### Game Loading Sequence

1. **Selection**: User selects game with joystick and presses fire button
2. **Request**: Menu writes game number to FPGA control register ($5000)
3. **SD Read**: FPGA reads .a78 header from SD card
4. **Parse**: Header parser extracts game configuration
5. **Transfer**: FPGA loads ROM data from SD card to PSRAM
6. **Configure**: FPGA configures mapper and POKEY based on header
7. **Reset**: FPGA triggers 7800 reset, game starts from PSRAM

## Memory Map

### Atari 7800 Address Space

```
$0000-$3FFF : TIA, RIOT, RAM (not handled by cartridge)
$4000-$FFFF : Cartridge ROM space (loaded from PSRAM)
$5000       : Game select register (write to trigger load)
$5001       : Load status register (read for completion)
```

### PSRAM Address Space

```
$000000-$00BFFF : Menu program (48KB)
$010000-$3FFFFF : Loaded game space (remaining ~4MB)
```

### SD Card Organization

```
Block 0      : Directory (game list)
Block 1+     : Game files (.a78 format)
               Each game allocated 50KB max
```

## FPGA Pin Assignments

See `atari.cst` for complete pin mapping:
- **Atari Bus**: Address[15:0], Data[7:0], Control signals
- **SD Card**: CLK, MOSI, MISO, CS#
- **PSRAM**: CK, CS#, DQ[7:0], RWDS
- **Debug**: 6 LEDs

## Building the Project

### Menu Program

```bash
cd menu
# Create menu font graphic first (see gfx/README.md)
/Users/rowe/Software/Atari7800/7800basic/7800basic.sh menu.bas
cp menu.bas.bin ../menu_rom.bin
```

### FPGA Bitstream

```bash
# Assuming Apicula toolchain is installed
yosys -p "read_verilog top.v sd_spi_controller.v psram_controller_fixed.v a78_loader.v gowin_pll.v pokey_advanced.v; synth_gowin -json Atari7800_AstroCart.json"

nextpnr-gowin --json Atari7800_AstroCart.json \
    --write Atari7800_AstroCart_pnr.json \
    --device GW1NR-LV9QN88PC6/I5 \
    --cst atari.cst

gowin_pack -d GW1N-9C \
    -o Atari7800_AstroCart.fs \
    Atari7800_AstroCart_pnr.json
```

### Preparing SD Card

1. Format SD card as FAT32
2. Copy .a78 game files to root directory
3. Games will be auto-detected on boot

## Cartridge Types Supported

- **Standard**: 16K, 32K, 48K non-bankswitched
- **Bankswitched**: SuperGame (128K), Activision (64K)
- **With POKEY**: Automatic detection and routing
- **With SaveRAM**: Future enhancement

## Current Status

✅ **Completed:**
- SD card SPI controller
- PSRAM controller (based on Tang Nano 9K reference)
- .a78 header parser
- Basic menu program structure
- Pin constraints file

🚧 **In Progress:**
- Menu font graphics
- Full game loader integration
- Reset control logic

📋 **TODO:**
- Test PSRAM with actual hardware
- Implement bankswitching logic
- Add game directory scanning
- Test with multiple games
- Create SD card formatter tool

## References

- [7800basic Guide](https://www.randomterrain.com/7800basic.html)
- [Tang Nano 9K PSRAM Controller](https://github.com/zf3/psram-tang-nano-9k)
- [Atari 7800 Hardware Manual](https://atarihq.com/danb/a7800.shtml)
- [.a78 File Format](https://atariage.com/forums/topic/245238-a78-file-format/)

## License

See individual file headers for licensing information.

## Contributing

This is an active development project. Contributions welcome!

Key areas needing work:
- PSRAM testing and optimization
- SD card file system implementation
- Menu graphics and UI improvements
- Mapper support expansion
