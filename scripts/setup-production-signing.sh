#!/bin/bash
# Interactive setup script for production code signing
#
# This script helps you configure production signing for Stow
# See docs/PRODUCTION_SIGNING.md for detailed documentation

set -e

echo "🔐 Stow Production Signing Setup"
echo "======================================"
echo ""

# Check if config already exists
if [ -f ".notarization-config" ]; then
    echo "⚠️  .notarization-config already exists"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

echo "This script will help you set up production code signing and notarization."
echo "You'll need:"
echo "  1. Apple Developer Account (active membership)"
echo "  2. Developer ID Application certificate installed"
echo "  3. App-specific password for notarization"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."
echo ""

# Step 1: Check for Developer ID certificate
echo "Step 1: Checking for Developer ID certificate..."
echo "────────────────────────────────────────────────"

CERTS=$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)

if [ -z "$CERTS" ]; then
    echo "❌ No Developer ID Application certificate found"
    echo ""
    echo "You need to create and install a Developer ID certificate:"
    echo "  Option 1: Via Xcode → Settings → Accounts → Manage Certificates"
    echo "  Option 2: Via https://developer.apple.com/account/resources/certificates/list"
    echo ""
    echo "See docs/PRODUCTION_SIGNING.md for detailed instructions."
    exit 1
fi

echo "✅ Found Developer ID certificate(s):"
echo ""
echo "$CERTS"
echo ""

# If multiple certificates, ask user to choose
CERT_COUNT=$(echo "$CERTS" | wc -l | tr -d ' ')
if [ "$CERT_COUNT" -gt 1 ]; then
    echo "Multiple certificates found. Please copy the full certificate name you want to use."
    read -p "Certificate name (include quotes): " SIGNING_IDENTITY
else
    # Extract the certificate name
    SIGNING_IDENTITY=$(echo "$CERTS" | sed 's/^.*"\(.*\)"$/\1/')
fi

echo ""
echo "Using: $SIGNING_IDENTITY"
echo ""

# Step 2: Get Apple ID
echo "Step 2: Apple ID"
echo "────────────────"
read -p "Enter your Apple ID (email): " APPLE_ID
echo ""

# Step 3: Get Team ID
echo "Step 3: Team ID"
echo "───────────────"
echo "Your Team ID is a 10-character identifier from your Apple Developer account."
echo "Find it at: https://developer.apple.com/account → Membership"
echo ""
read -p "Enter your Team ID (10 characters): " TEAM_ID

# Validate Team ID format
if [[ ! $TEAM_ID =~ ^[A-Z0-9]{10}$ ]]; then
    echo "⚠️  Warning: Team ID should be 10 alphanumeric characters"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
echo ""

# Step 4: Get app-specific password
echo "Step 4: App-Specific Password"
echo "──────────────────────────────"
echo "Generate an app-specific password at:"
echo "  https://appleid.apple.com/account/manage → Security → App-Specific Passwords"
echo ""
echo "Format: xxxx-xxxx-xxxx-xxxx"
echo ""
read -p "Enter app-specific password: " APP_PASSWORD
echo ""

# Create the config file
echo "Creating .notarization-config..."

cat > .notarization-config <<EOF
# Notarization credentials for Stow
# This file is git-ignored - never commit it!

# Your Apple ID email
APPLE_ID="$APPLE_ID"

# Your Team ID (10 characters)
TEAM_ID="$TEAM_ID"

# Your app-specific password
# Format: xxxx-xxxx-xxxx-xxxx
APP_PASSWORD="$APP_PASSWORD"

# Your Developer ID certificate name
SIGNING_IDENTITY="$SIGNING_IDENTITY"
EOF

chmod 600 .notarization-config

echo "✅ Configuration saved to .notarization-config"
echo ""

# Step 5: Verify configuration
echo "Step 5: Verifying Configuration"
echo "────────────────────────────────"

echo "Testing certificate access..."
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"
echo "  ✓ Certificate found"

echo "Testing Apple ID credentials..."
source .notarization-config
if xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" > /dev/null 2>&1; then
    echo "  ✓ Credentials verified"
else
    echo "  ⚠️  Could not verify credentials"
    echo "     This might be okay - test with a build"
fi

echo ""
echo "════════════════════════════════════════"
echo "✅ Setup Complete!"
echo "════════════════════════════════════════"
echo ""
echo "You can now build with production signing:"
echo ""
echo "  # Build with Developer ID signing"
echo "  ./scripts/build.sh --production"
echo ""
echo "  # Build and create notarized DMG"
echo "  ./scripts/build.sh --production --dmg"
echo ""
echo "For detailed documentation, see: docs/PRODUCTION_SIGNING.md"
