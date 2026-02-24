# Build Process and Code Signing

This document explains how Stow is built, bundled, code-signed, and how to verify the build artifacts.

## Build System

Stow uses [Swift Bundler](https://github.com/stackotter/swift-bundler) to create macOS app bundles from Swift Package Manager projects without requiring Xcode.

### Build Configuration

The build is configured in `Bundler.toml`:

```toml
format_version = 2

[apps.Stow]
identifier = 'com.stow.app'
product = 'Stow'
version = '1.0.0'
category = 'public.app-category.productivity'

[apps.Stow.plist]
CFBundleIdentifier = 'com.stow.app'
```

**Note:** Swift Bundler v2.0.7 has a known issue where `[apps.*.plist]` values don't always merge into the final Info.plist. The build script includes a post-build patch to ensure `CFBundleIdentifier` is always present.

## Build Scripts

### `scripts/build.sh`

Builds a release version of Stow:

```bash
./scripts/build.sh
```

**What it does:**
1. Runs `mint run swift-bundler bundle -c release`
2. Patches `Info.plist` to ensure `CFBundleIdentifier` is set to `com.stow.app`
3. Code signs the app bundle with an ad-hoc signature
4. Verifies the bundle ID and code signature

**Output:** `.build/bundler/Stow.app`

### `scripts/run.sh`

Builds and runs the app in development mode:

```bash
./scripts/run.sh
```

Uses `mint run swift-bundler run` which builds and launches the app directly.

## Code Signing

### Why Code Signing Matters

macOS requires proper code signing for:
- **Accessibility Permissions:** Apps need a valid bundle identifier in their code signature to appear in System Settings > Privacy & Security > Accessibility
- **Gatekeeper:** Running apps from outside the App Store
- **TCC (Transparency, Consent, and Control):** Managing privacy permissions

### Ad-hoc Signing

For local development, Stow uses ad-hoc signing (no developer certificate):

```bash
codesign --force --deep --sign - Stow.app
```

**Flags explained:**
- `--force`: Replace existing signature
- `--deep`: Sign all nested code (frameworks, helper tools, etc.)
- `--sign -`: Use ad-hoc signature (no identity)

### Distribution Signing

For distribution, sign with a Developer ID:

```bash
codesign --force --deep --sign "Developer ID Application: Your Name (TEAM_ID)" Stow.app
```

## Info.plist Requirements

### Critical Keys for Permissions

The `Info.plist` must include:

```xml
<key>CFBundleIdentifier</key>
<string>com.stow.app</string>
```

**Why it's required:**
- macOS uses `CFBundleIdentifier` to track app permissions in the TCC database
- Without it, the app cannot request or be granted accessibility permissions
- The identifier must be present in both the Info.plist AND the code signature

### Complete Info.plist Structure

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Stow</string>
    <key>CFBundleIdentifier</key>
    <string>com.stow.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Stow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
```

## Verification Commands

### Check Info.plist Values

#### Read specific key:
```bash
defaults read /path/to/Stow.app/Contents/Info.plist CFBundleIdentifier
```

#### Read entire plist:
```bash
cat /path/to/Stow.app/Contents/Info.plist
```

#### Verify plist is valid:
```bash
plutil -lint /path/to/Stow.app/Contents/Info.plist
```

#### Using PlistBuddy for detailed inspection:
```bash
/usr/libexec/PlistBuddy -c "Print" /path/to/Stow.app/Contents/Info.plist
```

### Check Code Signature

#### Verbose signature details:
```bash
codesign -dvv /path/to/Stow.app
```

**Key fields to check:**
- `Identifier`: Should be `com.stow.app`
- `Format`: Should be `app bundle with Mach-O thin (arm64)`
- `Signature`: `adhoc` for development, or certificate details for distribution

#### Verify signature is valid:
```bash
codesign --verify --verbose=4 /path/to/Stow.app
```

No output means the signature is valid. Errors indicate signature problems.

#### Check if Info.plist is properly bound:
```bash
codesign -dvv /path/to/Stow.app 2>&1 | grep "Info.plist"
```

Should show: `Info.plist entries=XX` where XX is the number of keys.

### Check Accessibility Permissions

#### Check if app is trusted for accessibility:
```bash
# This returns nothing useful from command line, must check in Swift code
# Use WindowAttachmentService.shared.checkAccessibilityPermissions()
```

#### Reset TCC permissions for testing:
```bash
tccutil reset Accessibility com.stow.app
```

### Quick Verification Script

Run all checks at once:

```bash
APP_PATH=".build/bundler/Stow.app"

echo "=== Info.plist ==="
defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "ERROR: CFBundleIdentifier not found"
plutil -lint "$APP_PATH/Contents/Info.plist"

echo ""
echo "=== Code Signature ==="
codesign -dvv "$APP_PATH" 2>&1 | grep -E "^(Identifier|Format|Signature|Info.plist)"

echo ""
echo "=== Verification ==="
codesign --verify --verbose=4 "$APP_PATH" && echo "✅ Signature valid" || echo "❌ Signature invalid"
```

## Troubleshooting

### App doesn't appear in Accessibility permissions

**Symptoms:**
- Can't find Stow in System Settings > Privacy & Security > Accessibility
- Permission checks always return false

**Causes:**
1. Missing `CFBundleIdentifier` in Info.plist
2. Code signature doesn't match bundle identifier
3. TCC database has stale entries

**Solutions:**

1. Verify bundle ID in Info.plist:
   ```bash
   defaults read .build/bundler/Stow.app/Contents/Info.plist CFBundleIdentifier
   ```
   Should return: `com.stow.app`

2. Verify code signature identifier:
   ```bash
   codesign -dvv .build/bundler/Stow.app 2>&1 | grep "^Identifier="
   ```
   Should return: `Identifier=com.stow.app`

3. If they don't match, rebuild:
   ```bash
   ./scripts/build.sh
   ```

4. Reset TCC permissions:
   ```bash
   tccutil reset Accessibility com.stow.app
   ```

5. Fully quit and relaunch Stow

### Permission state doesn't update after granting

**Cause:** macOS caches TCC permission checks. The `AXIsProcessTrustedWithOptions` API may return stale results.

**Solutions:**
1. Fully quit and relaunch Stow (most reliable)
2. Switch to another app and back (triggers app activation observer)
3. Click "Refresh Status" button in Preferences
4. Close and reopen Preferences window

### Swift Bundler doesn't apply plist values

**Cause:** Swift Bundler v2.0.7 has a bug where `[apps.*.plist]` section doesn't always merge into Info.plist.

**Solution:** The build script now includes a post-build patch that ensures `CFBundleIdentifier` is always present.

If you need to manually patch:
```bash
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string 'com.stow.app'" \
    .build/bundler/Stow.app/Contents/Info.plist

codesign --force --deep --sign - .build/bundler/Stow.app
```

## References

- [Swift Bundler Documentation](https://swiftbundler.dev/documentation/swift-bundler/)
- [Swift Bundler Configuration](https://swiftbundler.dev/documentation/swift-bundler/configuration/)
- [Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Info.plist Keys Reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/)
- [TCC (Transparency, Consent, Control) Database](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)
