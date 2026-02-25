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
if [ -f "VERSION" ]; then
    VERSION=$(cat VERSION | tr -d '[:space:]')
    echo "📌 Version: $VERSION"

    # Update version in Bundler.toml if it differs
    if grep -q "^version = " Bundler.toml; then
        CURRENT_VERSION=$(grep "^version = " Bundler.toml | head -1 | sed "s/version = '\(.*\)'/\1/" | tr -d "'")
        if [ "$CURRENT_VERSION" != "$VERSION" ]; then
            echo "  → Updating Bundler.toml version to $VERSION"
            sed -i '' "s/^version = .*/version = '$VERSION'/" Bundler.toml
        fi
    fi
fi

# Build the app bundle using swift-bundler
mint run swift-bundler bundle -c release

# Post-build: Patch Info.plist with CFBundleIdentifier
# Swift Bundler v2.0.7 has an issue where [apps.*.plist] values don't always merge
echo "🔧 Patching Info.plist..."
INFO_PLIST=".build/bundler/Stow.app/Contents/Info.plist"

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
    # Development signing with ad-hoc signature and entitlements
    codesign --force --deep --sign - --entitlements "Stow.entitlements" ".build/bundler/Stow.app" 2>&1 | grep -v "replacing existing signature" || true
    echo "  ✓ Signed with ad-hoc signature (development only)"
fi

# Verify the build
echo ""
echo "✅ Build complete!"
echo "📦 App bundle: .build/bundler/Stow.app"
echo ""
echo "🔍 Verification:"
echo "  Bundle ID: $(defaults read "$(pwd)/$INFO_PLIST" CFBundleIdentifier 2>/dev/null || echo 'ERROR: Not found')"
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
