# Atari 7800 AstroCart - Development Roadmap

This document outlines the planned features and development phases for the AstroCart project.

## Phase 1: Multi-Game Support & ROM Layouts
**Goal:** Support standard retail games with different file sizes (e.g., 32KB vs 48KB).

- [ ] **Target Game:** `Choplifter_NTSC.a78` (32KB Retail ROM).
- [ ] **Challenge:** Current loader assumes 48KB (mapped at `$4000`). 32KB games typically map at `$8000`.
- [ ] **Implementation:**
    - Update `a78_loader.v` to parse the ROM size from the header.
    - Adjust PSRAM write offsets or address decoding logic in `top.v` to handle 16KB, 32KB, and 48KB mappings correctly.
    - Ensure mirroring works (e.g., 16KB games often mirror to fill the space).

## Phase 2: Dynamic Menu System
**Goal:** Replace hardcoded game slots with a dynamic file browser.

- [ ] **Startup Sequence:**
    - Menu program stalls/waits upon boot.
    - FPGA scans the SD card root directory for `.a78` files.
    - FPGA parses headers (Name, Size, Mapper) and stores metadata in a buffer or PSRAM.
- [ ] **Menu Interface:**
    - Implement a communication protocol (shared memory or registers) for the 7800basic menu to request "Game Name at Index X".
    - Update `menu.bas` to populate the list dynamically.
- [ ] **Sorting:** Basic alphabetical sorting (optional, but nice).

## Phase 3: Advanced Mappers & Hardware
**Goal:** Support modern homebrew and complex bankswitched games.

- [ ] **Target Game:** `ARTI_Final_digital_edition_jan24_1.1.a78` (256KB + POKEY + RAM).
- [ ] **Bankswitching:**
    - Implement "SuperGame" mapper (standard for large homebrews).
    - Handle bank switching registers (usually at `$8000` or similar).
- [ ] **Cartridge RAM:**
    - Implement support for onboard RAM (SaveKey/High Score support).
    - Map PSRAM regions to `$4000` for RAM access if specified by header.

## Phase 4: Bonus Features / Future Expansion
**Goal:** Push the hardware limits.

### 4a. Hardware Acceleration
- [ ] **FastMath:** Implement hardware multiplier/divider registers to offload 6502 math.
- [ ] **Blitter/DMA:** Potential for fast memory moves or graphics manipulation helper functions.

### 4b. HDMI Output
- [ ] **Maria/TIA Mirroring:** Recreate the 7800 video generation logic (Maria/TIA) inside the FPGA.
- [ ] **Bus Snooping:** Listen to bus writes to update internal video state.
- [ ] **Output:** Generate digital video signals (HDMI/DVI) directly from the Tang Nano 9K.