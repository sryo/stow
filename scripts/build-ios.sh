#!/bin/bash
# Build the iOS app for the simulator and emit the .app path on stdout.
#
# Usage:
#   ./scripts/build-ios.sh                    # iPhone 16, iOS latest
#   ./scripts/build-ios.sh "iPhone 15 Pro"    # specific sim
#
# The script is idempotent — repeated calls reuse derived data so subsequent
# builds are incremental.

set -e

cd "$(dirname "$0")/.."

DESTINATION_NAME="${1:-iPhone 16}"
DERIVED="$(pwd)/.build/ios"
SCHEME="StowIOS"
PROJECT="StowIOS/StowIOS.xcodeproj"

mkdir -p "$DERIVED"

echo "🔨 Building $SCHEME for simulator '$DESTINATION_NAME'..." 1>&2

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$DESTINATION_NAME" \
    -derivedDataPath "$DERIVED" \
    -configuration Debug \
    build 1>&2 | tail -20

APP_PATH=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 2 -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ No .app product found under $DERIVED" 1>&2
    exit 1
fi

echo "✅ Built: $APP_PATH" 1>&2
echo "$APP_PATH"
