# Atari 7800 AstroCart FPGA Cartridge

An FPGA-based cartridge implementation for the Atari 7800 that emulates a 48KB ROM cartridge. This project uses a Gowin FPGA to provide seamless game ROM storage and interface with the Atari 7800 console.

## Overview

This project implements a complete Atari 7800 cartridge interface using Verilog HDL. The FPGA acts as a ROM cartridge, storing game data in Block RAM and responding to the Atari's memory bus requests in the address range `$4000-$FFFF`.

### Key Features

- **48KB ROM Storage**: Uses FPGA Block RAM for fast, reliable game storage
- **Bus Arbitration**: Intelligent logic to drive the data bus only when needed
- **Level Shifting**: 74LVC245 buffer control for safe 5V/3.3V interfacing
- **Debug LEDs**: Visual indicators for bus activity, PHI2, and R/W signals
- **Hardware Audio Output**: PWM audio pin (ready for future expansion)

## Hardware Requirements

- Gowin FPGA development board (compatible with Apicula toolchain)
- 74LVC245 octal bus transceiver for level shifting
- Atari 7800 console
- Appropriate connectors and wiring for the cartridge interface

### Pin Connections

| Signal    | Direction | Description                           |
|-----------|-----------|---------------------------------------|
| `clk`     | Input     | 27MHz system clock                    |
| `a[15:0]` | Input     | Address bus from Atari                |
| `d[7:0]`  | I/O       | Bidirectional data bus                |
| `phi2`    | Input     | Phase 2 clock (~1.79MHz)              |
| `rw`      | Input     | Read/Write control (High = Read)      |
| `halt`    | Input     | Halt signal                           |
| `irq`     | Input     | Interrupt request                     |
| `buf_dir` | Output    | Buffer direction (High = FPGA→Atari)  |
| `buf_oe`  | Output    | Buffer enable (Low = Enabled)         |
| `audio`   | Output    | Audio PWM output                      |
| `led[5:0]`| Output    | Debug LEDs (active low)               |

## Building the Project

### Prerequisites

- [Apicula](https://github.com/YosysHQ/apicula) - Open-source Gowin FPGA toolchain
- Python 3.x
- Yosys and nextpnr (included with Apicula)

### Steps

1. **Prepare your ROM file**
   
   Convert your Atari 7800 ROM (48KB binary) to hex format:
   ```bash
   python rom_gen.py your_game.a78
   ```
   This generates `game.hex` which will be synthesized into the FPGA bitstream.

2. **Synthesize the design**
   
   Using Apicula toolchain:
   ```bash
   yosys -p "read_verilog top.v; synth_gowin -json Atari7800_AstroCart.json"
   nextpnr-gowin --json Atari7800_AstroCart.json --write Atari7800_AstroCart_pnr.json --device YOUR_DEVICE --cst atari.cst
   gowin_pack -d YOUR_DEVICE -o Atari7800_AstroCart.fs Atari7800_AstroCart_pnr.json
   ```

3. **Program the FPGA**
   
   Flash the `.fs` file to your FPGA board using the appropriate programmer.

## Usage

1. Convert your game ROM using the `rom_gen.py` script
2. Synthesize the FPGA bitstream with the embedded ROM
3. Program the FPGA
4. Connect the FPGA cartridge to your Atari 7800
5. Power on and enjoy!

## Memory Map

The FPGA responds to the Atari's address space as follows:

- `$4000 - $FFFF`: 48KB ROM (internal index 0 - 49151)
- `$0000 - $3FFF`: Not handled (TIA/RIOT/RAM regions)

The address decoder activates when `A15` or `A14` is high, ensuring the cartridge only drives the bus in its designated address range.

## Debug Features

The LED indicators provide real-time status:

- **LED 0**: Cartridge is driving the data bus (activity indicator)
- **LED 1**: PHI2 clock state
- **LED 2**: Read operation active
- **LEDs 3-5**: Reserved/Off

## File Structure

- `top.v` - Main Verilog HDL module
- `rom_gen.py` - ROM conversion utility
- `atari.cst` - Pin constraint file for FPGA
- `apicula.toml` - Apicula project configuration
- `game.hex` - Generated ROM data (created by rom_gen.py)

## Technical Details

### Bus Timing

The FPGA runs at 27MHz, significantly faster than the Atari's ~1.79MHz bus clock. This ensures ROM reads appear instantaneous to the Atari, behaving like standard ROM chips.

### Buffer Control

The 74LVC245 buffer is controlled by two signals:
- **DIR**: Always high (FPGA → Atari direction)
- **OE**: Active low when the FPGA should drive the bus, tri-stated otherwise

This prevents bus contention when the Atari accesses other memory-mapped devices (TIA, RIOT, RAM).

## License

See LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Acknowledgments

- Atari 7800 homebrew community
- Apicula and open-source FPGA toolchain developers
- Yosys Project and nextpnr team
