# 🎮 Quick Reference Card

## Project Files at a Glance

```
Atari7800_AstroCart/
├── 📄 Verilog Modules
│   ├── top.v                      ← Main (needs integration updates)
│   ├── sd_spi_controller.v        ← NEW: SD card SPI interface
│   ├── psram_controller_fixed.v   ← NEW: Fixed PSRAM controller
│   ├── a78_loader.v               ← NEW: Game loader + .a78 parser
│   ├── gowin_pll.v                ← Clock generation
│   └── pokey_advanced.v           ← POKEY emulation
│
├── 🎯 Menu System
│   └── menu/
│       ├── menu.bas               ← NEW: Menu program (7800basic)
│       ├── build.sh               ← NEW: Build script
│       └── gfx/
│           ├── README.md          ← Font creation guide
│           └── menufont.png       ← ⚠️ NEEDS CREATION
│
├── 📚 Documentation
│   ├── README_NEW.md              ← System overview
│   ├── NEXT_STEPS.md              ← Detailed guide
│   ├── IMPLEMENTATION_SUMMARY.md  ← This document's big brother
│   └── QUICKREF.md                ← You are here!
│
└── 🛠️ Tools
    └── status.sh                   ← Project status checker
```

---

## ⚡️ Essential Commands

### Check Project Status
```bash
./status.sh
```

### Build Menu
```bash
cd menu
./build.sh
```

### Test Menu in Emulator
```bash
open menu/menu.bas.a78  # macOS
# or
a7800 menu/menu.bas.a78  # If A7800 emulator installed
```

### Build FPGA (when ready)
```bash
# Using Apicula
yosys -p "read_verilog top.v sd_spi_controller.v psram_controller_fixed.v a78_loader.v gowin_pll.v pokey_advanced.v; synth_gowin -json Atari7800_AstroCart.json"

nextpnr-gowin --json Atari7800_AstroCart.json \
  --write Atari7800_AstroCart_pnr.json \
  --device GW1NR-LV9QN88PC6/I5 --cst atari.cst

gowin_pack -d GW1N-9C -o Atari7800_AstroCart.fs Atari7800_AstroCart_pnr.json
```

---

## 🔑 Key Addresses

### Atari Memory Map
| Address       | Purpose                    |
|---------------|----------------------------|
| `$4000-$FFFF` | Cartridge ROM (from PSRAM) |
| `$5000`       | Game select register (W)   |
| `$5001`       | Load status register (R)   |

### PSRAM Memory Map
| Address         | Content              | Size  |
|-----------------|----------------------|-------|
| `$000000-$00BFFF` | Menu program       | 48KB  |
| `$010000-$3FFFFF` | Loaded games       | ~4MB  |

### Status Register (`$5001`)
| Bit | Meaning          |
|-----|------------------|
| 0   | Load in progress |
| 1   | Load complete    |
| 2   | Error flag       |

---

## 🎨 Creating Menu Font

### Quick Method (Copy Sample)
```bash
cd menu/gfx
cp /Users/rowe/Software/Atari7800/7800basic/samples/samplegfx/atascii.png menufont.png
```

### Manual Method
1. Create 32×8 pixel PNG
2. Use indexed color mode (4 colors max)
3. Draw characters: ` ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-`
4. Each character: 4 pixels wide × 8 pixels tall
5. Save as `menufont.png`

See `menu/gfx/README.md` for details.

---

## 🐛 Debugging Tips

### LEDs
```verilog
assign led[0] = ~psram_busy;        // PSRAM active
assign led[1] = ~sd_busy;           // SD card active
assign led[2] = ~load_complete;     // Load done
assign led[3] = ~load_error;        // Error occurred
assign led[4] = ~game_select[0];    // Game select bit 0
assign led[5] = ~pll_lock;          // PLL locked
```

### Common Issues
| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| No display | Font missing | Create menufont.png |
| Menu won't build | Path wrong | Check 7800basic path in build.sh |
| PSRAM not working | Clock phase | Adjust phase shift in PLL |
| SD card timeout | Speed too fast | Slow down SPI clock |

---

## 📊 Resource Budget

| Resource      | Used    | Available | Usage |
|---------------|---------|-----------|-------|
| Logic Cells   | ~3,000  | 8,640     | 35%   |
| Block RAM     | ~50KB   | 468KB     | 11%   |
| I/O Pins      | 45      | 86        | 52%   |

**Status**: Plenty of room! 🎉

---

## 🚀 3-Step Quick Start

### 1. Create Font (5 minutes)
```bash
cd menu/gfx
cp /path/to/font.png menufont.png
```

### 2. Build Menu (2 minutes)  
```bash
cd menu
./build.sh
```

### 3. Test in Emulator (1 minute)
```bash
open menu/menu.bas.a78
```

---

## 🔗 Important Links

- **7800basic Home**: https://www.randomterrain.com/7800basic.html
- **Tang Nano 9K Wiki**: https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/
- **PSRAM Reference**: https://github.com/zf3/psram-tang-nano-9k
- **AtariAge Forums**: https://atariage.com/forums/forum/65-atari-7800-programming/

---

## 📋 Checklist

**Foundation** (Complete! ✅)
- [x] SD card controller
- [x] PSRAM controller  
- [x] Game loader
- [x] Menu program
- [x] Documentation

**Next Up** (Your Tasks 📝)
- [ ] Create menu font
- [ ] Build menu
- [ ] Test in emulator
- [ ] Integrate into top.v
- [ ] Test on hardware

**Future** (Nice to Have 🌟)
- [ ] Multiple mapper support
- [ ] Game directory scanning
- [ ] Save state support
- [ ] Cheat code menu
- [ ] High score saves

---

## 🎯 Priority Matrix

```
  High Priority ↑
  ┌─────────────────────┬─────────────────────┐
  │ 🔥 DO NOW           │ 📅 SCHEDULE         │
  │                     │                     │
  │ • Create font       │ • Test PSRAM        │
  │ • Build menu        │ • Hardware debug    │
  │ • Integrate top.v   │ • Optimize timing   │
  └─────────────────────┼─────────────────────┤
  │ 💤 LATER            │ 🚫 DON'T DO        │
  │                     │                     │
  │ • Add mappers       │ • Rewrite from      │
  │ • Save states       │   scratch           │
  │ • Cheats            │ • Support all carts │
  └─────────────────────┴─────────────────────┘
  Low Priority ↓        Low Value →  High Value
```

---

## 💾 Backup Command

```bash
git add -A
git commit -m "Added SD card loader and menu system"
git push
```

---

## 🆘 Getting Help

1. Read `NEXT_STEPS.md` troubleshooting section
2. Check `status.sh` output
3. Review build logs
4. Test modules independently
5. Use LEDs for debugging
6. Ask on AtariAge forums

---

## 🎊 You're Ready!

All the pieces are in place. Just create that font and you're off to the races! 🏁

**Good luck and have fun! 🎮👾**

---

*Keep this file handy for quick reference during development!*
