# SD Card Setup for Atari 7800 AstroCart

## Current Method: Raw Sector Loading (Phase 1)

While the ultimate goal is FAT32 file support, the current FPGA core uses **Raw Sector Loading**. This means game ROMs are written directly to specific sector offsets on the SD card, bypassing the filesystem.

### SD Card Layout Map

We use a **1MB Stride** (2048 sectors) for game slots. This supports games up to 1MB in size.

| Slot | Sector Offset | Byte Offset | Game |
|------|---------------|-------------|------|
| 0    | 0             | 0           | `astrowing.a78` |
| 1    | 2048          | 1MB         | `Choplifter_NTSC.a78` |
| 2    | 4096          | 2MB         | `ARTI_Final...a78` |
| 3    | 6144          | 3MB         | (Reserved) |
| 4    | 8192          | 4MB         | (Reserved) |

### Flashing Games (macOS/Linux)

Use the `dd` command to write games to the raw device.

**WARNING:** This will overwrite data on the SD card. Ensure you select the correct device (e.g., `/dev/rdisk4`).

#### 1. Identify your SD Card
```bash
diskutil list
# Look for your SD card (e.g., /dev/disk4)
# Use /dev/rdiskN for faster access on macOS
```

#### 2. Flash Games
```bash
# Slot 0: Astro Wing
sudo dd if=astrowing.a78 of=/dev/rdisk4 bs=512 conv=sync

# Slot 1: Choplifter (Seek 2048 blocks)
sudo dd if=Choplifter_NTSC.a78 of=/dev/rdisk4 bs=512 seek=2048 conv=sync

# Slot 2: ARTI (Seek 4096 blocks)
sudo dd if=ARTI_Final_digital_edition_jan24_1.1.a78 of=/dev/rdisk4 bs=512 seek=4096 conv=sync
```

### Automated Script
Use the provided `flash_games.sh` script to automate this process.

```bash
chmod +x flash_games.sh
./flash_games.sh /dev/rdisk4
```

## Troubleshooting

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
