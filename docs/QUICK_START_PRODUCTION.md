# Quick Start: Production Signing

Get production-ready code signing and notarization set up in 10 minutes.

## Prerequisites

- ✅ Apple Developer Account (paid membership)
- ✅ macOS 10.15 or later
- ✅ Xcode Command Line Tools

## Option 1: Interactive Setup (Recommended)

Run the interactive setup script:

```bash
./scripts/setup-production-signing.sh
```

This will:
1. Check for your Developer ID certificate
2. Ask for your Apple ID
3. Ask for your Team ID
4. Ask for your app-specific password
5. Create `.notarization-config` with your credentials
6. Verify everything works

Then build:
```bash
./scripts/build.sh --production --dmg
```

## Option 2: Manual Setup

### 1. Get Developer ID Certificate

**Via Xcode** (easiest):
1. Xcode → Settings → Accounts
2. Select your Apple ID → Manage Certificates
3. Click + → Developer ID Application

**Verify it's installed**:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Get Your Team ID

Go to https://developer.apple.com/account → Membership

Your Team ID is shown there (10 characters).

### 3. Create App-Specific Password

1. Go to https://appleid.apple.com/account/manage
2. Security → App-Specific Passwords
3. Generate password with label "Stow Notarization"
4. Copy the password (format: `xxxx-xxxx-xxxx-xxxx`)

### 4. Create Configuration File

```bash
cp .notarization-config.template .notarization-config
```

Edit `.notarization-config` and fill in:
- `APPLE_ID`: Your Apple ID email
- `TEAM_ID`: Your 10-character Team ID
- `APP_PASSWORD`: Your app-specific password
- `SIGNING_IDENTITY`: Your certificate name from step 1

### 5. Build

```bash
./scripts/build.sh --production --dmg
```

## What You'll See

```
🔨 Building Stow...
📌 Version: 0.1.0
...
🔏 Code signing app...
  → Using Developer ID: Developer ID Application: Your Name (ABC123)
  ✓ Signed with Developer ID (hardened runtime enabled)
...
────────────────────────────────────────
📦 Creating DMG installer...
...
────────────────────────────────────────
📝 Starting notarization...
  → Submitting to Apple for notarization...
  → This typically takes 2-5 minutes

  Conducting pre-submission checks for Stow-0.1.0.dmg...
  Submission ID received
    id: 12345678-1234-1234-1234-123456789012
  Successfully uploaded file
    id: 12345678-1234-1234-1234-123456789012
    path: /path/to/Stow-0.1.0.dmg
  Waiting for processing to complete...
  Current status: In Progress.......
  Current status: Accepted

  ✓ Notarization successful!
  → Stapling notarization ticket to DMG...
  ✓ Notarization ticket stapled

✅ DMG is fully notarized and ready for distribution!
```

## Testing

### Verify Notarization

```bash
spctl -a -vvv -t install .build/dmg/Stow-0.1.0.dmg
```

Should output:
```
.build/dmg/Stow-0.1.0.dmg: accepted
source=Notarized Developer ID
```

### Test User Experience

1. Copy DMG to another Mac (or different user account)
2. Open the DMG
3. Drag Stow to Applications
4. Launch the app
5. **Expected**: No security warnings! ✨

## Troubleshooting

### "No identity found"

Your Developer ID certificate isn't installed. Follow step 1 above.

### "Invalid Credentials"

Check your `.notarization-config`:
- Apple ID email is correct
- Team ID is exactly 10 characters
- App-specific password is correct (regenerate if needed)

### Notarization Fails

Get the detailed error log:

```bash
source .notarization-config
xcrun notarytool log <submission-id> \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD"
```

Common issues:
- Unsigned frameworks/libraries
- Missing hardened runtime entitlements
- Invalid Info.plist values

## Security Notes

**IMPORTANT**:
- `.notarization-config` is git-ignored (never commit it!)
- Use app-specific passwords (not your Apple ID password)
- Keep credentials secure (use a password manager)

## Next Steps

1. ✅ Test the notarized DMG on a fresh Mac
2. ✅ Verify no security warnings
3. ✅ Distribute to beta testers
4. 🎉 Public release!

## Resources

For detailed documentation:
- [PRODUCTION_SIGNING.md](PRODUCTION_SIGNING.md) - Complete guide with all details
- [DISTRIBUTION.md](DISTRIBUTION.md) - Distribution workflow
- [Apple: Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
