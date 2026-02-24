# Quick Reference: Build Verification Commands

## Common Verification Commands

### Check Bundle Identifier in Info.plist
```bash
defaults read .build/bundler/Arcmark.app/Contents/Info.plist CFBundleIdentifier
# Expected: com.arcmark.app
```

### Check Code Signature Identifier
```bash
codesign -dvv .build/bundler/Arcmark.app 2>&1 | grep "^Identifier="
# Expected: Identifier=com.arcmark.app
```

### Verify Info.plist is Valid
```bash
plutil -lint .build/bundler/Arcmark.app/Contents/Info.plist
# Expected: .build/bundler/Arcmark.app/Contents/Info.plist: OK
```

### Verify Code Signature is Valid
```bash
codesign --verify --verbose=4 .build/bundler/Arcmark.app
# Expected: (no output means valid)
```

### View Complete Info.plist
```bash
cat .build/bundler/Arcmark.app/Contents/Info.plist
```

### View Complete Code Signature Details
```bash
codesign -dvv .build/bundler/Arcmark.app
```

### Run All Verifications at Once
```bash
./scripts/verify-build.sh
```

## Build Commands

### Build Release App
```bash
./scripts/build.sh
```

### Build and Run in Development Mode
```bash
./scripts/run.sh
```

### Manual Build Steps (if needed)
```bash
# 1. Build with Swift Bundler
mint run swift-bundler bundle -c release

# 2. Add CFBundleIdentifier to Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string 'com.arcmark.app'" \
    .build/bundler/Arcmark.app/Contents/Info.plist

# 3. Code sign
codesign --force --deep --sign - .build/bundler/Arcmark.app

# 4. Verify
./scripts/verify-build.sh
```

## Installation

### Install to Applications Folder
```bash
cp -R .build/bundler/Arcmark.app /Applications/
```

### Remove Old Version First (recommended)
```bash
rm -rf /Applications/Arcmark.app
cp -R .build/bundler/Arcmark.app /Applications/
```

## Permissions Management

### Reset Accessibility Permissions
```bash
tccutil reset Accessibility com.arcmark.app
```

### Open System Settings to Accessibility
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

## Troubleshooting

### App Not in Accessibility List

1. Check bundle identifier exists:
   ```bash
   defaults read .build/bundler/Arcmark.app/Contents/Info.plist CFBundleIdentifier
   ```

2. Check signature matches:
   ```bash
   codesign -dvv .build/bundler/Arcmark.app 2>&1 | grep "^Identifier="
   ```

3. Rebuild if needed:
   ```bash
   ./scripts/build.sh
   ```

4. Reinstall:
   ```bash
   rm -rf /Applications/Arcmark.app
   cp -R .build/bundler/Arcmark.app /Applications/
   ```

5. Reset TCC permissions:
   ```bash
   tccutil reset Accessibility com.arcmark.app
   ```

6. Restart Arcmark

### Permission State Not Updating

1. Fully quit Arcmark (⌘Q)
2. Relaunch from Applications
3. Grant permission in System Settings
4. Switch back to Arcmark (triggers app activation observer)
5. Click "Refresh Status" button in Preferences if needed

### Swift Bundler Not Found

```bash
mint install stackotter/swift-bundler
```

## Key Files

- **Build config:** `Bundler.toml`
- **Build script:** `scripts/build.sh`
- **Run script:** `scripts/run.sh`
- **Verification script:** `scripts/verify-build.sh`
- **Full documentation:** `docs/BUILD_AND_CODESIGN.md`
