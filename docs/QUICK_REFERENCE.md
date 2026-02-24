# Quick Reference: Build Verification Commands

## Common Verification Commands

### Check Bundle Identifier in Info.plist
```bash
defaults read .build/bundler/Stow.app/Contents/Info.plist CFBundleIdentifier
# Expected: com.stow.app
```

### Check Code Signature Identifier
```bash
codesign -dvv .build/bundler/Stow.app 2>&1 | grep "^Identifier="
# Expected: Identifier=com.stow.app
```

### Verify Info.plist is Valid
```bash
plutil -lint .build/bundler/Stow.app/Contents/Info.plist
# Expected: .build/bundler/Stow.app/Contents/Info.plist: OK
```

### Verify Code Signature is Valid
```bash
codesign --verify --verbose=4 .build/bundler/Stow.app
# Expected: (no output means valid)
```

### View Complete Info.plist
```bash
cat .build/bundler/Stow.app/Contents/Info.plist
```

### View Complete Code Signature Details
```bash
codesign -dvv .build/bundler/Stow.app
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
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string 'com.stow.app'" \
    .build/bundler/Stow.app/Contents/Info.plist

# 3. Code sign
codesign --force --deep --sign - .build/bundler/Stow.app

# 4. Verify
./scripts/verify-build.sh
```

## Installation

### Install to Applications Folder
```bash
cp -R .build/bundler/Stow.app /Applications/
```

### Remove Old Version First (recommended)
```bash
rm -rf /Applications/Stow.app
cp -R .build/bundler/Stow.app /Applications/
```

## Permissions Management

### Reset Accessibility Permissions
```bash
tccutil reset Accessibility com.stow.app
```

### Open System Settings to Accessibility
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

## Troubleshooting

### App Not in Accessibility List

1. Check bundle identifier exists:
   ```bash
   defaults read .build/bundler/Stow.app/Contents/Info.plist CFBundleIdentifier
   ```

2. Check signature matches:
   ```bash
   codesign -dvv .build/bundler/Stow.app 2>&1 | grep "^Identifier="
   ```

3. Rebuild if needed:
   ```bash
   ./scripts/build.sh
   ```

4. Reinstall:
   ```bash
   rm -rf /Applications/Stow.app
   cp -R .build/bundler/Stow.app /Applications/
   ```

5. Reset TCC permissions:
   ```bash
   tccutil reset Accessibility com.stow.app
   ```

6. Restart Stow

### Permission State Not Updating

1. Fully quit Stow (⌘Q)
2. Relaunch from Applications
3. Grant permission in System Settings
4. Switch back to Stow (triggers app activation observer)
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
