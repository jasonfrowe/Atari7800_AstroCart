#!/bin/bash
# Usage: ./flash_games.sh /dev/rdiskX

DISK=$1
GAME0="astrowing.a78"
GAME1="Choplifter_NTSC.a78"
GAME2="ARTI_Final_digital_edition_jan24_1.1.a78"

if [ -z "$DISK" ]; then
    echo "Usage: $0 /dev/rdiskX"
    exit 1
fi

echo "Flashing games to $DISK..."

# Slot 0
echo "Writing Slot 0: $GAME0..."
sudo dd if="$GAME0" of="$DISK" bs=512 conv=sync

# Slot 1
echo "Writing Slot 1: $GAME1..."
sudo dd if="$GAME1" of="$DISK" bs=512 seek=2048 conv=sync

# Slot 2
echo "Writing Slot 2: $GAME2..."
sudo dd if="$GAME2" of="$DISK" bs=512 seek=4096 conv=sync

echo "Done."