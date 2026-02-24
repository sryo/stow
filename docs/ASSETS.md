# App Assets Guide

This document describes how to add icons and images to Arcmark.

## App Icon

### Icon Formats

Swift Bundler supports three icon formats:

1. **PNG (Recommended for simplicity)**: 1024x1024px PNG file
2. **ICNS (Recommended for production)**: Native macOS icon format with multiple resolutions
3. **Icon Composer (.icon)**: Apple's icon format (macOS only)

### Where to Place the Icon

Create a `Resources/` directory in the project root and place your icon there:

```
arcmark/
├── Resources/
│   └── AppIcon.png          # 1024x1024px PNG
│   └── AppIcon.icns         # Optional: Native macOS icon
│   └── dmg-background.png   # DMG background (see below)
├── Bundler.toml
└── ...
```

### Icon Specifications

**PNG Format:**
- **Size**: Exactly 1024x1024 pixels
- **Format**: PNG with transparency support
- **Color Space**: sRGB recommended
- **File size**: Keep under 1MB for best performance

**ICNS Format (Production):**
The ICNS format includes multiple resolutions for different display contexts:
- 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024
- Each at 1x and 2x (@2x for Retina displays)

### Creating an ICNS File

#### Method 1: Using Xcode (Recommended)

1. Create an App Icon set in Xcode:
   - Open Xcode
   - Create a new project or open an existing one
   - Go to Assets.xcassets
   - Right-click → New App Icon
   - Drag your 1024x1024px PNG into the "App Icon - macOS" slot

2. Export the iconset:
   - Right-click on the App Icon → Show in Finder
   - You'll see an `.appiconset` folder

3. Convert to ICNS:
   ```bash
   # Create iconset from your PNG
   mkdir AppIcon.iconset

   # Generate all required sizes (using sips - built into macOS)
   sips -z 16 16     AppIcon.png --out AppIcon.iconset/icon_16x16.png
   sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png
   sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_32x32.png
   sips -z 64 64     AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png
   sips -z 128 128   AppIcon.png --out AppIcon.iconset/icon_128x128.png
   sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png
   sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_256x256.png
   sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png
   sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_512x512.png
   sips -z 1024 1024 AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png

   # Convert iconset to ICNS
   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

   # Clean up
   rm -rf AppIcon.iconset
   ```

#### Method 2: Using Online Tools

1. Upload your 1024x1024px PNG to: https://cloudconvert.com/png-to-icns
2. Download the generated ICNS file
3. Place it in `Resources/AppIcon.icns`

#### Method 3: Using Icon Composer (Legacy)

Icon Composer is deprecated but still works. Create a `.icon` file using the legacy tool.

### Updating Bundler.toml

Add the icon path to your `Bundler.toml`:

```toml
[apps.Arcmark]
identifier = 'com.arcmark.app'
product = 'Arcmark'
version = '0.1.0'
icon = 'Resources/AppIcon.png'  # or 'Resources/AppIcon.icns'
# ... rest of config
```

**Using ICNS for macOS only (with PNG fallback):**

```toml
[apps.Arcmark]
identifier = 'com.arcmark.app'
product = 'Arcmark'
version = '0.1.0'
icon = 'Resources/AppIcon.png'  # Default icon
# ... rest of config

# Use ICNS on macOS for better quality
[[apps.Arcmark.overlays]]
condition = "platform(macOS)"
icon = "Resources/AppIcon.icns"
```

## DMG Background Image

### Background Specifications

The DMG background image provides a professional look to your installer.

**Specifications:**
- **Size**: 600x400 pixels (matches DMG window size)
- **Format**: PNG with transparency support
- **Color Space**: sRGB
- **Aspect Ratio**: 3:2 (width:height)
- **File name**: `dmg-background.png`
- **Location**: `Resources/dmg-background.png`

### Design Guidelines

**Layout Considerations:**
- The Arcmark.app icon will be positioned at approximately (125, 150)
- The Applications folder will be at approximately (375, 150)
- Leave space in these areas for the icons (roughly 128x128 + padding)

**Design Tips:**
1. **Keep it subtle**: The background should enhance, not distract
2. **Use transparency**: Consider a subtle gradient or transparent elements
3. **Add instructions**: "Drag Arcmark to Applications" text is helpful
4. **Brand colors**: Use your app's color scheme
5. **Test in Finder**: Mount the DMG to see how it looks in practice

### Example Background Layout

```
┌────────────────────────────────────────────────┐
│                                                │
│         Drag Arcmark to Applications          │
│                                                │
│      ╔═══════╗                ╔═══════╗      │
│      ║       ║                ║       ║      │
│      ║   🎯   ║       →        ║   📁   ║      │
│      ║       ║                ║       ║      │
│      ╚═══════╝                ╚═══════╝      │
│     Arcmark.app            Applications       │
│                                                │
└────────────────────────────────────────────────┘
```

### Creating the Background

You can create the background using:
- **Figma/Sketch**: Export at 600x400px
- **Photoshop**: Create new image at 600x400px, 72 DPI
- **Pixelmator/Acorn**: Native Mac design tools
- **GIMP**: Free alternative

**Simple approach:** Create a subtle gradient or use your brand color with low opacity.

## Icon Design Guidelines

### Visual Style

**macOS Icons Guidelines:**
1. **Use a rounded square shape**: Most Mac icons use rounded rectangles
2. **Add depth**: Use subtle shadows and highlights
3. **Keep it simple**: Icons should be recognizable at small sizes
4. **Use vibrant colors**: Mac icons typically use bold, saturated colors
5. **Consider dark mode**: Test how your icon looks on both light and dark backgrounds

### Color Palette

Arcmark uses these workspace colors:
- Blush: `#FF8BA0`
- Apricot: `#FFBD9A`
- Butter: `#FFE48E`
- Leaf: `#B5E48C`
- Mint: `#92E3D0`
- Sky: `#8FC8E8`
- Periwinkle: `#B39FF3`
- Lavender: `#E0BBE4`

Consider incorporating one or more of these colors in your app icon.

### Icon Inspiration

Look at similar productivity apps for inspiration:
- Safari (bookmarks/web)
- Notes (organization)
- Reminders (task management)
- Things (structured lists)

## Testing Your Assets

### Test the App Icon

After adding your icon to Bundler.toml:

```bash
# Clean and rebuild
./scripts/clean.sh
./scripts/build.sh

# Check the icon in Finder
open .build/bundler/

# Verify in Get Info panel
# Right-click Arcmark.app → Get Info
```

### Test the DMG Background

After adding the background image:

```bash
# Build with DMG
./scripts/build.sh --dmg

# Open the DMG
open .build/dmg/Arcmark-0.1.0.dmg

# The background should appear in the Finder window
```

## Troubleshooting

### Icon Not Showing

**Problem**: Icon doesn't appear in the built app
**Solutions**:
1. Verify the icon path in Bundler.toml is correct
2. Check file permissions: `chmod 644 Resources/AppIcon.png`
3. Ensure the PNG is exactly 1024x1024px: `sips -g pixelWidth -g pixelHeight Resources/AppIcon.png`
4. Clean build: `./scripts/clean.sh && ./scripts/build.sh`
5. Clear icon cache: `sudo rm -rf /Library/Caches/com.apple.iconservices.store && killall Finder`

### DMG Background Not Showing

**Problem**: Background doesn't appear in DMG
**Solutions**:
1. Verify the file exists at `Resources/dmg-background.png`
2. Check dimensions: `sips -g pixelWidth -g pixelHeight Resources/dmg-background.png`
3. The script will skip background if file is missing (this is intentional)

### Icon Looks Blurry

**Problem**: Icon appears blurry or pixelated
**Solutions**:
1. Use an ICNS file instead of PNG for production builds
2. Ensure your source artwork is vector-based or high resolution
3. Check that PNG is exactly 1024x1024px (not scaled)

## Asset Checklist

Before distributing your app, verify:

- [ ] App icon is 1024x1024px PNG or ICNS format
- [ ] Icon is placed in `Resources/` directory
- [ ] Icon path is added to `Bundler.toml`
- [ ] Icon looks good at multiple sizes (16px to 512px)
- [ ] Icon works on both light and dark backgrounds
- [ ] DMG background is 600x400px PNG
- [ ] DMG background is placed in `Resources/`
- [ ] DMG mounts and displays correctly
- [ ] Both icons and text are readable in DMG

## Future Improvements

- [ ] Add app icon to repository with license info
- [ ] Create animated icon for loading states
- [ ] Design alternate icons for user customization
- [ ] Create promotional graphics (Mac App Store)
- [ ] Design app screenshots for distribution
