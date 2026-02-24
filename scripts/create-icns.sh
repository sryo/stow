#!/bin/bash
# Convert a 1024x1024 PNG to ICNS format for macOS app icon
#
# Usage:
#   ./scripts/create-icns.sh Resources/AppIcon.png
#   ./scripts/create-icns.sh path/to/icon.png Resources/AppIcon.icns

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🎨 Creating ICNS icon from PNG..."

# Parse arguments
if [ $# -eq 0 ]; then
    echo -e "${RED}❌ Error: No input file specified${NC}"
    echo ""
    echo "Usage:"
    echo "  ./scripts/create-icns.sh INPUT.png"
    echo "  ./scripts/create-icns.sh INPUT.png OUTPUT.icns"
    echo ""
    echo "Example:"
    echo "  ./scripts/create-icns.sh Resources/AppIcon.png"
    exit 1
fi

INPUT_PNG="$1"
OUTPUT_ICNS="${2:-${INPUT_PNG%.png}.icns}"

# Verify input file exists
if [ ! -f "$INPUT_PNG" ]; then
    echo -e "${RED}❌ Error: Input file not found: $INPUT_PNG${NC}"
    exit 1
fi

# Verify it's a PNG
if [[ ! "$INPUT_PNG" =~ \.png$ ]]; then
    echo -e "${YELLOW}⚠️  Warning: Input file doesn't have .png extension${NC}"
fi

# Check image dimensions
echo "  → Checking image dimensions..."
DIMENSIONS=$(sips -g pixelWidth -g pixelHeight "$INPUT_PNG" 2>/dev/null | grep -E "pixelWidth|pixelHeight" | awk '{print $2}')
WIDTH=$(echo "$DIMENSIONS" | head -1)
HEIGHT=$(echo "$DIMENSIONS" | tail -1)

if [ "$WIDTH" != "1024" ] || [ "$HEIGHT" != "1024" ]; then
    echo -e "${YELLOW}⚠️  Warning: Image is ${WIDTH}x${HEIGHT}px (expected 1024x1024)${NC}"
    echo "  The icon will be scaled, which may affect quality."
fi

# Create temporary iconset directory
ICONSET_DIR="${OUTPUT_ICNS%.icns}.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

echo "  → Generating icon sizes..."

# Generate all required sizes for macOS
# Format: size_name:pixel_size
SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

for size_spec in "${SIZES[@]}"; do
    IFS=':' read -r filename pixels <<< "$size_spec"
    echo "    • ${filename} (${pixels}x${pixels})"
    sips -z "$pixels" "$pixels" "$INPUT_PNG" --out "$ICONSET_DIR/$filename" > /dev/null 2>&1
done

echo "  → Converting to ICNS format..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# Clean up
rm -rf "$ICONSET_DIR"

# Verify the output
if [ -f "$OUTPUT_ICNS" ]; then
    FILE_SIZE=$(du -h "$OUTPUT_ICNS" | cut -f1)
    echo ""
    echo -e "${GREEN}✅ ICNS icon created successfully!${NC}"
    echo "📦 Output: $OUTPUT_ICNS"
    echo "📏 Size: $FILE_SIZE"
    echo ""
    echo "Next steps:"
    echo "  1. Update Bundler.toml to reference this icon:"
    echo "     icon = '$OUTPUT_ICNS'"
    echo ""
    echo "  2. Rebuild the app:"
    echo "     ./scripts/build.sh"
else
    echo -e "${RED}❌ Error: Failed to create ICNS file${NC}"
    exit 1
fi
