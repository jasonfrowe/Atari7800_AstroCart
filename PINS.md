# Pin Assignment Notes

## Tang Nano 9K Pin Constraints

### SSPI Pins Used as GPIO

Pins 54-56 are normally dedicated to SSPI (SPI flash configuration interface), but the build script configures them to be released as general GPIO after configuration using:
```tcl
set_option -use_sspi_as_gpio 1
```

This allows these pins to be used for the address bus:
- **a[3] → Pin 54** (SSPI_MISO)
- **a[4] → Pin 56** (SSPI_SCK)
- **a[9] → Pin 55** (SSPI_MOSI)

### Bank Voltage Configuration

The Tang Nano 9K's **PSRAM requires Bank 1 to operate at 1.8V**. Therefore, all pins in Bank 1 (approximately pins 48-86) must use `LVCMOS18` instead of `LVCMOS33`.

**Pins using LVCMOS18 (Bank 1)**:
- Address lines: a[2], a[3], a[4], a[7], a[8], a[9], a[11], a[13], a[14], a[15]
- Control signals: phi2, rw, halt, irq, buf_dir, buf_oe (pins 81-86)
- Audio output: audio (pin 76)
- Status LEDs: led[0-5] (pins 10-16)

**Pins using LVCMOS33 (Other banks)**:
- Data bus: d[0-7]
- Address lines: a[0], a[1], a[5], a[6], a[10], a[12]
- SD card: sd_clk, sd_mosi, sd_cs_n, sd_miso

### PSRAM Pins

PSRAM pins are **NOT defined** in the CST file. The Gowin IDE automatically routes them when it detects the "magic" port names in the Verilog:
- `O_psram_ck` - Clock
- `O_psram_cs_n` - Chip Select (active low)
- `IO_psram_rwds` - Read/Write Data Strobe
- `IO_psram_dq[7:0]` - 8-bit data bus

These ports connect to the onboard PSRAM and are handled internally by Gowin IDE.

## Reference

See [atari.cst](atari.cst) for the complete pin assignment file.
