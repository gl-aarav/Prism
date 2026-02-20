#!/bin/bash

APP_NAME="Prism"
BUILD_PATH=".build/release/$APP_NAME"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 1. Create Directory Structure
echo "Creating $APP_BUNDLE structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 2. Copy Executable
echo "Copying executable..."
if [ -f "$BUILD_PATH" ]; then
    cp "$BUILD_PATH" "$MACOS_DIR/"
else
    # Fallback to check for arch-specific build if universal/release alias fails
    ARCH_BUILD_PATH=".build/arm64-apple-macosx/release/$APP_NAME"
    if [ -f "$ARCH_BUILD_PATH" ]; then
        cp "$ARCH_BUILD_PATH" "$MACOS_DIR/"
    else
        echo "Error: Build artifact not found at $BUILD_PATH or $ARCH_BUILD_PATH"
        exit 1
    fi
fi

# 3. Create Info.plist
echo "Creating Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.aaravgoyal.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>7.0.0</string>
    <key>CFBundleVersion</key>
    <string>7</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Copy light/dark PNG app icons for runtime switching
for ICON in "AppIcon.png" "AppIconLight.png" "AppIconDark.png"; do
    if [ -f "$ICON" ]; then
        echo "Copying $ICON to Resources..."
        cp "$ICON" "$RESOURCES_DIR/"
    fi
done

# Copy Swift Package Resources (Bundles)
echo "Copying resource bundles..."
# Find bundles in release folder (handling potential symlinks or arch folders)
find .build/release -maxdepth 1 -name "*.bundle" -exec cp -r {} "$RESOURCES_DIR/" \; 2>/dev/null
find .build/arm64-apple-macosx/release -maxdepth 1 -name "*.bundle" -exec cp -r {} "$RESOURCES_DIR/" \; 2>/dev/null

# Fix for SPM generated Bundle.module accessor which looks in bundle root for executables
echo "Copying resource bundles to App root for SPM compatibility..."
find .build/release -maxdepth 1 -name "*.bundle" -exec cp -r {} "$APP_BUNDLE/" \; 2>/dev/null
find .build/arm64-apple-macosx/release -maxdepth 1 -name "*.bundle" -exec cp -r {} "$APP_BUNDLE/" \; 2>/dev/null

# 5. Sign App
echo "Signing app with entitlements..."
SIGNING_IDENTITY="Aarav Goyal"

# Sign nested bundles first
find "$RESOURCES_DIR" -name "*.bundle" -exec codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=identifier,entitlements,flags {} \;
find "$APP_BUNDLE" -maxdepth 1 -name "*.bundle" -exec codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=identifier,entitlements,flags {} \;

if [ -f "Entitlements.plist" ]; then
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" --entitlements Entitlements.plist "$APP_BUNDLE"
else
    echo "Warning: Entitlements.plist not found, signing without specific entitlements."
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi

echo "App bundle created at $PWD/$APP_BUNDLE"
echo "You can move this to your Applications folder."
