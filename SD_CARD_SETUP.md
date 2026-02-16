# SD Card Setup for Atari 7800 AstroCart

## SD Card Formatting

1. **Format**: FAT32
   - Most microSD cards come pre-formatted as FAT32
   - If needed, format using Disk Utility (macOS) or similar tool
   - Recommended: 4GB to 32GB card (SD or SDHC)

2. **File System Structure**: 
   - Place .a78 game files in the root directory
   - Use sequential naming: GAME0.A78, GAME1.A78, GAME2.A78, etc.
   - File names should be UPPERCASE (8.3 format)

## Game File Preparation

The menu system has 5 hardcoded game slots:

| Slot | Menu Display | File Name    | Description              |
|------|--------------|--------------|--------------------------|
| 0    | ASTRO CART   | GAME0.A78    | Use astrowing.a78        |
| 1    | DONKEY KONG  | GAME1.A78    | (placeholder)            |
| 2    | GALAGA       | GAME2.A78    | (placeholder)            |
| 3    | MS PAC-MAN   | GAME3.A78    | (placeholder)            |
| 4    | DEFENDER     | GAME4.A78    | (placeholder)            |

### Example Setup Commands

```bash
# Format SD card (macOS - replace diskX with your SD card identifier)
# WARNING: This will erase all data on the card!
diskutil eraseDisk FAT32 ATARI7800 MBRFormat /dev/diskX

# Mount the card and copy files
cd /path/to/your/games
cp astrowing.a78 /Volumes/ATARI7800/GAME0.A78
cp ARTI_Final_digital_edition_jan24_1.1.a78 /Volumes/ATARI7800/GAME1.A78

# Create placeholder files for remaining slots (optional)
# The system will show errors for missing games
touch /Volumes/ATARI7800/GAME2.A78
touch /Volumes/ATARI7800/GAME3.A78
touch /Volumes/ATARI7800/GAME4.A78

# Unmount safely
diskutil unmount /Volumes/ATARI7800
```

## File Format Requirements

- **File Extension**: .A78 (uppercase recommended)
- **Header**: Standard 128-byte .a78 header format
- **Content**: Compatible with Atari 7800 cartridge formats
  - 48K ROM (non-bank-switched)
  - SuperGame bank-switched (up to 256K)
  - POKEY audio chip support (@$440, $450, $800, $4000)

## Hardware Setup

1. Insert formatted microSD card into Tang Nano 9K SD card slot
2. Power on the FPGA
3. LEDs will indicate status:
   - LED[2]: SD card initialized (off=ready)
   - LED[3]: PSRAM ready (off=ready)
   - LED[4]: Game load complete (off=done)
   - LED[5]: Game loaded flag (off=game active)

## Usage

1. **Boot**: System starts with menu from BRAM
2. **Navigate**: Use joystick up/down to select game
3. **Load**: Press fire button to start loading
4. **Wait**: Background flashes, then game loads from SD to PSRAM
5. **Play**: System automatically jumps to game at $4000

## Control Registers

The menu uses these FPGA registers:

- **$5000 (write)**: Game select (0-4)
  - Write game number to trigger loading
- **$5001 (read)**: Status byte
  - Bit 0: Loading in progress
  - Bit 1: Load complete
  - Bit 2: Load error
  - Bit 7: PSRAM initialized

## Troubleshooting

### Game Won't Load
- Check SD card is properly formatted (FAT32)
- Verify file exists and is named correctly (GAMEX.A78)
- Check LED indicators for hardware status
- Ensure .a78 file has valid 128-byte header

### SD Card Not Detected
- Try different SD card (some brands have compatibility issues)
- Check card is <= 32GB (SDHC compatible)
- Verify all SD card pins in constraint file
- Reseat the SD card

### Game Loads But Won't Run
- Verify .a78 header is correct (use header inspector tool)
- Check game is compatible with hardware
- Try known-working game (astrowing.a78)
- Check POKEY address in header matches game requirements

## Supported Cartridge Types

Currently tested:
- ✅ 48K ROM with POKEY @$450 (astrowing.a78)
- ⏳ 256K SuperGame (ARTI_Final...)

Future support:
- [ ] Activision banking
- [ ] Absolute banking
- [ ] Banksets
- [ ] SuperGame with RAM

## Technical Details

### SD Card Interface
- SPI mode operation
- 13.5 MHz clock (27MHz ÷ 2)
- CMD0, CMD8, ACMD41, CMD17 initialization sequence
- 512-byte block reads

### PSRAM Interface
- HyperRAM protocol
- 4MB address space (22-bit addressing)
- DDR clock generation via ODDR primitive
- Byte-level access for CPU compatibility

### Loading Sequence
1. Menu writes game number to $5000
2. FPGA reads GAMEx.A78 header (128 bytes)
3. Header parser extracts ROM size and configuration
4. ROM data copied from SD card to PSRAM
5. Memory mux switches from BRAM (menu) to PSRAM (game)
6. CPU jumps to $4000 to start game execution
