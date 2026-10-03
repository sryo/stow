#!/bin/bash
# Build Stow as a proper macOS app bundle
#
# Usage:
#   ./scripts/build.sh                  # Build with ad-hoc signing (development)
#   ./scripts/build.sh --dmg            # Build with ad-hoc signing and create DMG
#   ./scripts/build.sh --production     # Build with Developer ID signing (production)
#   ./scripts/build.sh --production --dmg  # Build and create notarized DMG

set -e  # Exit on error

# Parse arguments
CREATE_DMG=false
PRODUCTION=false

for arg in "$@"; do
    case $arg in
        --dmg)
            CREATE_DMG=true
            ;;
        --production)
            PRODUCTION=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--production] [--dmg]"
            exit 1
            ;;
    esac
done

echo "🔨 Building Stow..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Read version from VERSION file and update Bundler.toml
if [ ! -f "VERSION" ]; then
    echo "❌ Error: VERSION file not found in project root"
    exit 1
fi
VERSION=$(cat VERSION | tr -d '[:space:]')
if [ -z "$VERSION" ]; then
    echo "❌ Error: VERSION file is empty"
    exit 1
fi
echo "📌 Version: $VERSION"

# Update version in Bundler.toml if it differs
if grep -q "^version = " Bundler.toml; then
    CURRENT_VERSION=$(grep "^version = " Bundler.toml | head -1 | sed "s/version = '\(.*\)'/\1/" | tr -d "'")
    if [ "$CURRENT_VERSION" != "$VERSION" ]; then
        echo "  → Updating Bundler.toml version to $VERSION"
        sed -i '' "s/^version = .*/version = '$VERSION'/" Bundler.toml
    fi
fi

# Build the app bundle using swift-bundler
# Swift 6.4's default build system writes products to .build/out/Products, not the
# .build/<triple>/release that swift-bundler assumes, so build with SwiftPM and point
# swift-bundler at wherever the products landed.
swift build -c release --product Stow
PRODUCTS_DIR=$(swift build -c release --show-bin-path)
mint run swift-bundler bundle -c release --skip-build --products-directory "$PRODUCTS_DIR"

# Post-build: Patch Info.plist with CFBundleIdentifier
# Swift Bundler v2.0.7 has an issue where [apps.*.plist] values don't always merge
echo "🔧 Patching Info.plist..."
INFO_PLIST=".build/bundler/Stow.app/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "❌ Error: $INFO_PLIST not found — did swift-bundler change its output layout?"
    exit 1
fi

# Add CFBundleIdentifier if missing (using PlistBuddy)
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string 'com.stow.app'" "$INFO_PLIST"
    echo "  ✓ Added CFBundleIdentifier"
else
    # Update if already exists but has wrong value
    CURRENT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
    if [ "$CURRENT_ID" != "com.stow.app" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier 'com.stow.app'" "$INFO_PLIST"
        echo "  ✓ Updated CFBundleIdentifier"
    else
        echo "  ✓ CFBundleIdentifier already correct"
    fi
fi

# Compile the Icon Composer document into Assets.car (Liquid Glass icon) plus a
# flattened AppIcon.icns fallback; CFBundleIconName points the system at the .car.
echo "🎨 Compiling AppIcon.icon..."
APP_RESOURCES=".build/bundler/Stow.app/Contents/Resources"
mkdir -p "$APP_RESOURCES"
xcrun actool Resources/AppIcon.icon \
    --compile "$APP_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist .build/bundler/AppIcon-partial.plist \
    --errors --warnings > /dev/null
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$INFO_PLIST" &>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST"
echo "  ✓ Assets.car + AppIcon.icns"

# Add NSAppleEventsUsageDescription (needed to focus existing browser tabs via AppleScript)
USAGE_DESC='Stow uses Apple Events to focus the existing browser tab when you click a bookmark whose URL is already open. Without this, every click opens a duplicate tab.'
if ! /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$INFO_PLIST" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string '$USAGE_DESC'" "$INFO_PLIST"
    echo "  ✓ Added NSAppleEventsUsageDescription"
fi

# Register stow:// URL scheme
echo "🔗 Registering stow:// URL scheme..."
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$INFO_PLIST" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'com.stow.app'" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string 'stow'" "$INFO_PLIST"
    echo "  ✓ Added stow:// URL scheme"
else
    echo "  ✓ CFBundleURLTypes already exists"
fi

# Code sign the app
echo "🔏 Code signing app..."

if [ "$PRODUCTION" = true ]; then
    # Production signing with Developer ID
    if [ ! -f ".notarization-config" ]; then
        echo "❌ Error: .notarization-config not found"
        echo "   See docs/PRODUCTION_SIGNING.md for setup instructions"
        exit 1
    fi

    # Load signing identity from config
    source .notarization-config

    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "❌ Error: SIGNING_IDENTITY not set in .notarization-config"
        exit 1
    fi

    echo "  → Using Developer ID: $SIGNING_IDENTITY"

    # Sign with hardened runtime for notarization
    codesign --force --deep \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements "Stow.entitlements" \
        --timestamp \
        ".build/bundler/Stow.app" 2>&1 | grep -v "replacing existing signature" || true

    echo "  ✓ Signed with Developer ID (hardened runtime enabled)"
else
    # Development signing — use Apple Development identity if available (required for CloudKit),
    # fall back to ad-hoc if none found. Uses SHA-1 hash to avoid ambiguity with duplicate names.
    DEV_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
    if [ -n "$DEV_IDENTITY" ]; then
        codesign --force --deep \
            --sign "$DEV_IDENTITY" \
            --entitlements "Stow.entitlements" \
            ".build/bundler/Stow.app" 2>&1 | grep -v "replacing existing signature" || true
        echo "  ✓ Signed with $DEV_IDENTITY"
    else
        codesign --force --deep --sign - --entitlements "Stow.entitlements" ".build/bundler/Stow.app" 2>&1 | grep -v "replacing existing signature" || true
        echo "  ✓ Signed with ad-hoc signature (CloudKit sync requires Apple Development identity)"
    fi
fi

# Verify the build
echo ""
echo "✅ Build complete!"
echo "📦 App bundle: .build/bundler/Stow.app"
echo ""
echo "🔍 Verification:"
BUNDLE_ID=$(defaults read "$(pwd)/$INFO_PLIST" CFBundleIdentifier 2>/dev/null || true)
if [ -z "$BUNDLE_ID" ]; then
    echo "❌ Error: CFBundleIdentifier missing from Info.plist after patching"
    exit 1
fi
echo "  Bundle ID: $BUNDLE_ID"
echo "  Version: $(defaults read "$(pwd)/$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || echo 'Not set')"
echo "  Code Sign: $(codesign -dvv ".build/bundler/Stow.app" 2>&1 | grep "^Identifier=" | cut -d= -f2)"

# Create DMG if requested
if [ "$CREATE_DMG" = true ]; then
    echo ""
    echo "────────────────────────────────────────"
    if [ "$PRODUCTION" = true ]; then
        ./scripts/create-dmg.sh --notarize
    else
        ./scripts/create-dmg.sh
    fi
fi
