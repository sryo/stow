#!/bin/bash
# Create a DMG installer for Stow with drag-and-drop to Applications folder
#
# Usage:
#   ./scripts/create-dmg.sh              # Create DMG without notarization
#   ./scripts/create-dmg.sh --notarize   # Create and notarize DMG (requires .notarization-config)

set -e  # Exit on error

# Parse arguments
NOTARIZE=false
if [ "$1" = "--notarize" ]; then
    NOTARIZE=true
fi

echo "📦 Creating DMG installer..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Read version from VERSION file
if [ ! -f "VERSION" ]; then
    echo "❌ Error: VERSION file not found"
    exit 1
fi
VERSION=$(cat VERSION | tr -d '[:space:]')

# Verify the app bundle exists
APP_BUNDLE=".build/bundler/Stow.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Error: App bundle not found at $APP_BUNDLE"
    echo "   Run ./scripts/build.sh first"
    exit 1
fi

# Create output directory
OUTPUT_DIR=".build/dmg"
mkdir -p "$OUTPUT_DIR"

# DMG configuration
DMG_NAME="Stow-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
VOLUME_NAME="Stow ${VERSION}"
TEMP_DMG="$OUTPUT_DIR/temp.dmg"

# Clean up any existing DMG files
rm -f "$DMG_PATH" "$TEMP_DMG"

# Unmount any previously mounted volumes with this name
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    echo "  → Cleaning up previously mounted volume..."
    hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true
fi

# Create a temporary directory for DMG contents
DMG_STAGING="$OUTPUT_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

echo "  → Copying app bundle..."
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

echo "  → Creating Applications folder symlink..."
ln -s /Applications "$DMG_STAGING/Applications"

# Create a .DS_Store file for nice window layout (optional but recommended)
# This creates a hidden file that sets the Finder window appearance
echo "  → Setting up DMG layout..."

# Calculate DMG size (app size + 50MB buffer)
APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

echo "  → Creating temporary DMG (${DMG_SIZE}MB)..."
hdiutil create -srcfolder "$DMG_STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE}m \
    "$TEMP_DMG" > /dev/null

# Mount the temporary DMG
echo "  → Mounting temporary DMG..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep -E '^/dev/')
DEVICE=$(echo "$MOUNT_OUTPUT" | awk '{print $1}')
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk '{print $3}')

echo "  → Customizing Finder window..."

# Check if background image exists and copy it if present
BACKGROUND_IMAGE="Resources/dmg-background.png"
USE_BACKGROUND=false

if [ -f "$BACKGROUND_IMAGE" ]; then
    echo "  → Adding custom background image..."
    mkdir -p "$MOUNT_POINT/.background"
    cp "$BACKGROUND_IMAGE" "$MOUNT_POINT/.background/background.png"
    USE_BACKGROUND=true
else
    echo "  ℹ️  No background image found at $BACKGROUND_IMAGE (optional)"
fi

# Use AppleScript to customize the DMG window
echo "  → Applying Finder customizations..."

# First, set up basic window properties
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 500}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 180
        set text size of viewOptions to 14

        -- Position icons (adjusted for larger icons)
        set position of item "Stow.app" of container window to {160, 200}
        set position of item "Applications" of container window to {460, 200}

        -- Update view
        update without registering applications
        delay 1
    end tell
end tell
EOF

# Set background image if available (done separately to avoid path issues)
if [ "$USE_BACKGROUND" = true ]; then
    echo "  → Setting background image..."

    # Try to set the background image using multiple approaches
    # Method 1: Try using POSIX file with alias
    if osascript -e "tell application \"Finder\" to tell disk \"$VOLUME_NAME\" to set background picture of icon view options of container window to alias ((POSIX file \"$MOUNT_POINT/.background/background.png\") as text)" 2>/dev/null; then
        echo "     ✓ Background image set successfully"
    # Method 2: Try using file reference directly
    elif osascript <<EOF 2>/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        set viewOptions to icon view options of container window
        set theFile to POSIX file "$MOUNT_POINT/.background/background.png" as alias
        set background picture of viewOptions to theFile
        update without registering applications
    end tell
end tell
EOF
    then
        echo "     ✓ Background image set successfully (alternate method)"
    else
        echo "  ⚠️  Warning: Could not set background image"
        echo "     The DMG will be created without a custom background"
    fi

    # Brief delay to ensure settings are applied
    sleep 1
fi

# Close the Finder window before unmounting
osascript <<EOF > /dev/null 2>&1
tell application "Finder"
    if exists disk "$VOLUME_NAME" then
        close window of disk "$VOLUME_NAME"
    end if
end tell
EOF

# Ensure changes are written to disk
sync
sleep 2

echo "  → Unmounting temporary DMG..."
# Try multiple unmount approaches
if ! hdiutil detach "$DEVICE" 2>/dev/null; then
    if ! hdiutil detach "$MOUNT_POINT" 2>/dev/null; then
        hdiutil detach "$MOUNT_POINT" -force || true
    fi
fi

# Verify unmount succeeded
if mount | grep -q "$VOLUME_NAME"; then
    echo "  ⚠️  Warning: Volume still mounted, forcing unmount..."
    hdiutil detach "/Volumes/$VOLUME_NAME" -force || true
    sleep 1
fi

echo "  → Converting to compressed DMG..."
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" > /dev/null

# Clean up
rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"

# Remove any stray Volumes folders created in project root
# This includes both "Volumes" and folders with unusual names like "\n/"
if [ -d "Volumes" ]; then
    rm -rf "Volumes"
fi
if [ -d $'\n/' ]; then
    rm -rf $'\n/'
fi

echo ""
echo "✅ DMG created successfully!"
echo "📦 Output: $DMG_PATH"
echo "📏 Size: $(du -h "$DMG_PATH" | cut -f1)"

# Notarize if requested
if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "────────────────────────────────────────"
    echo "📝 Starting notarization..."

    # Check for config file
    if [ ! -f ".notarization-config" ]; then
        echo "❌ Error: .notarization-config not found"
        echo "   See docs/PRODUCTION_SIGNING.md for setup instructions"
        exit 1
    fi

    # Load credentials
    source .notarization-config

    if [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$APP_PASSWORD" ]; then
        echo "❌ Error: Missing credentials in .notarization-config"
        echo "   Required: APPLE_ID, TEAM_ID, APP_PASSWORD"
        exit 1
    fi

    echo "  → Submitting to Apple for notarization..."
    echo "  → This typically takes 2-5 minutes"

    # Submit for notarization and wait
    SUBMISSION_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait 2>&1)

    echo "$SUBMISSION_OUTPUT"

    # Check if notarization succeeded
    if echo "$SUBMISSION_OUTPUT" | grep -q "status: Accepted"; then
        echo ""
        echo "  ✓ Notarization successful!"

        # Staple the notarization ticket
        echo "  → Stapling notarization ticket to DMG..."
        xcrun stapler staple "$DMG_PATH"

        echo "  ✓ Notarization ticket stapled"
        echo ""
        echo "✅ DMG is fully notarized and ready for distribution!"
    else
        echo ""
        echo "❌ Notarization failed!"
        echo ""
        echo "To see detailed error log:"
        SUBMISSION_ID=$(echo "$SUBMISSION_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
        if [ -n "$SUBMISSION_ID" ]; then
            echo "  xcrun notarytool log $SUBMISSION_ID \\"
            echo "    --apple-id \"$APPLE_ID\" \\"
            echo "    --team-id \"$TEAM_ID\" \\"
            echo "    --password \"$APP_PASSWORD\""
        fi
        exit 1
    fi
fi

echo ""
echo "🧪 To test the DMG:"
echo "   open $DMG_PATH"

if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "🔍 To verify notarization:"
    echo "   spctl -a -vvv -t install $DMG_PATH"
    echo "   (Should show: source=Notarized Developer ID)"
fi
