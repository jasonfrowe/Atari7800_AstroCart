#!/bin/bash
# Project status checker

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Atari 7800 Multi-Game Cartridge Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check Verilog modules
echo "📦 Core Verilog Modules:"
check_file() {
    if [ -f "$1" ]; then
        echo "  ✅ $1"
        return 0
    else
        echo "  ❌ $1"
        return 1
    fi
}

check_file "sd_spi_controller.v"
check_file "psram_controller_fixed.v"
check_file "a78_loader.v"
check_file "top.v"
check_file "gowin_pll.v"
check_file "pokey_advanced.v"
echo ""

# Check menu system
echo "🎮 Menu System:"
check_file "menu/menu.bas"
check_file "menu/build.sh"
if [ -f "menu/gfx/menufont.png" ]; then
    echo "  ✅ menu/gfx/menufont.png"
else
    echo "  ⚠️  menu/gfx/menufont.png (NEEDS CREATION)"
fi
echo ""

# Check documentation
echo "📚 Documentation:"
check_file "README_NEW.md"
check_file "NEXT_STEPS.md"
check_file "IMPLEMENTATION_SUMMARY.md"
check_file "menu/gfx/README.md"
echo ""

# Check build outputs
echo "🔨 Build Outputs:"
if [ -f "menu/menu.bas.a78" ]; then
    echo "  ✅ menu/menu.bas.a78"
    ls -lh menu/menu.bas.a78 | awk '{print "     Size:", $5}'
else
    echo "  ❌ menu/menu.bas.a78 (not built yet)"
fi

if [ -f "Atari7800_AstroCart.fs" ]; then
    echo "  ✅ Atari7800_AstroCart.fs"
    ls -lh Atari7800_AstroCart.fs | awk '{print "     Size:", $5}'
else
    echo "  ❌ Atari7800_AstroCart.fs (not built yet)"
fi
echo ""

# Check test ROMs
echo "🎯 Test ROMs:"
check_file "astrowing.a78"
check_file "ARTI_Final_digital_edition_jan24_1.1.a78"
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Project Status: FOUNDATION COMPLETE"
echo ""
echo "🚀 Next Steps:"
echo "  1. Create menu font: cd menu/gfx && [create menufont.png]"
echo "  2. Build menu: cd menu && ./build.sh"
echo "  3. Integrate modules into top.v"
echo "  4. Synthesize and test FPGA bitstream"
echo ""
echo "📖 See NEXT_STEPS.md for detailed instructions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
