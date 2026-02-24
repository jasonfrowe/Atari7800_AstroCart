# Atari 7800 AstroCart - FPGA Multi-Game Cartridge

## Overview

This project implements an advanced FPGA-based cartridge for the Atari 7800 using the Tang Nano 9K (Gowin GW1NR-9). Unlike traditional single-ROM cartridges, this system features a complete menu-driven loader that reads games from an SD card, loads them into onboard PSRAM, and configures the FPGA to emulate the specific hardware required for each game (Mapper, POKEY, etc.).

## Key Features

- **SD Card Loading**: Loads `.a78` game files from a FAT32 microSD card via SPI.
- **PSRAM Storage**: Utilizes 4MB of onboard PSRAM for game storage, supporting large homebrew games and bankswitching.
- **Menu System**: Integrated 7800basic menu for browsing and selecting games.
- **Automatic Configuration**: Parses `.a78` headers to automatically configure mappers (ROM size, banking) and audio hardware.
- **POKEY Audio**: Full POKEY chip emulation for high-fidelity audio.
- **Handover Mechanism**: Seamlessly transitions control from the menu system to the loaded game using a delayed handover logic.

## System Architecture

The system is built around a Tang Nano 9K FPGA and interacts with the Atari 7800 via level shifters.

1.  **Boot**: The FPGA initializes BRAM with the Menu ROM (`menu.bas`).
2.  **Menu**: The Atari boots into the menu. The FPGA acts as a standard 48KB cartridge.
3.  **Load**: User selects a game. The FPGA reads the file from SD card via SPI and writes it to PSRAM.
4.  **Handover**: Upon completion, the FPGA switches the memory mapping from BRAM (Menu) to PSRAM (Game) and triggers a reset/handover.

## Hardware Requirements

- **Tang Nano 9K** FPGA Board.
- **MicroSD Card** (FAT32 formatted).
- **Atari 7800** Console.
- **Interface Board**: Custom PCB or wiring to connect FPGA 3.3V logic to Atari 5V bus (requires level shifters like 74LVC245).

## Build Process

We use the **Gowin EDA** tools for synthesis and place-and-route.

### 1. Menu Firmware
The menu is written in `7800basic`.
```bash
cd menu
./build.sh
```
This generates the ROM image (`game.hex`) used to initialize the FPGA Block RAM.

### 2. FPGA Bitstream
You can build the project using the Gowin IDE:
1.  Open Gowin IDE and create a new project for the `GW1NR-LV9QN88PC6/I5`.
2.  Add all Verilog source files (`top.v`, `sd_controller.v.v`, `psram_controller.v`, `a78_loader.v`, `pokey_advanced.v`, `gowin_pll.v`).
3.  Add the constraint file `atari.cst`.
4.  Run Synthesis and Place & Route.
5.  Program the device using the Gowin Programmer or `openFPGALoader`.

See `BUILD.md` for more detailed instructions and script usage.

## SD Card Setup

1.  Format a microSD card to **FAT32**.
2.  Place `.a78` game files in the root directory.
3.  Ensure filenames follow the naming convention expected by the menu (e.g., `GAME0.A78`, `GAME1.A78`).

See `SD_CARD_SETUP.md` for detailed file preparation instructions.

## Memory Map

| Address Range | Description | Source |
| :--- | :--- | :--- |
| `$0000 - $3FFF` | System RAM/IO | Atari Console |
| `$4000 - $FFFF` | Cartridge ROM | FPGA (BRAM Menu or PSRAM Game) |
| `$5000` | Control Register | Write: Select Game / Trigger Load |
| `$5001` | Status Register | Read: Load Status |

## File Structure

- `top.v`: Main FPGA top-level module.
- `sd_controller.v`: SPI interface for SD card.
- `psram_controller.v`: HyperRAM/PSRAM controller.
- `a78_loader.v`: Game loader and header parser.
- `pokey_advanced.v`: POKEY audio emulation.
- `menu/`: Source code for the 7800basic menu system.

## License

See LICENSE file for details.
