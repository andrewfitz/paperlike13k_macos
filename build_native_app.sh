#!/bin/bash

cd "$(dirname "$0")"

APP_NAME="PaperlikeNative"
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CLI_NAME="paperlike"

echo "Creating App Bundle Directory Structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Writing Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.paperlike.native</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

SWIFT_FLAGS="-target arm64-apple-macosx15.0 -swift-version 6"

echo "Compiling GUI app..."
swiftc PaperlikeSerial.swift PaperlikeManager.swift PaperlikeNativeApp.swift CarbonHotkeyManager.swift \
    $SWIFT_FLAGS \
    -o "$MACOS_DIR/$APP_NAME"

if [ $? -ne 0 ]; then
    echo "ERROR: GUI app build failed!"
    exit 1
fi

echo "Compiling CLI tool..."
swiftc PaperlikeSerial.swift PaperlikeCLI.swift \
    $SWIFT_FLAGS \
    -o "$CLI_NAME"

if [ $? -ne 0 ]; then
    echo "ERROR: CLI build failed!"
    exit 1
fi

echo ""
echo "Done!"
echo "  GUI app: $APP_DIR"
echo "  CLI tool: ./$CLI_NAME"
echo ""
echo "Usage:"
echo "  open $APP_DIR                    # Launch menu bar app"
echo "  ./$CLI_NAME --daemon             # CLI daemon mode"
echo "  ./$CLI_NAME --help               # CLI help"
