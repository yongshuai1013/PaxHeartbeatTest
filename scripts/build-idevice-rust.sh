#!/bin/bash
# Build SideStore/idevice Rust for iOS (aarch64)
# Usage: ./build-idevice-rust.sh [version]
# Default version: v0.1.68-ss-3e55c84 (the one minimuxer uses)

set -e

VERSION=${1:-v0.1.68-ss-3e55c84}
REPO="https://github.com/SideStore/idevice.git"
WORKDIR="/tmp/idevice-build"
OUTPUT_DIR="$HOME/workspace/PaxHeartbeatTest/Libraries"

echo "=== Building SideStore/idevice $VERSION for iOS ==="

# 1. Install Rust if not present
if ! command -v cargo &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# 2. Add iOS target
echo "Adding aarch64-apple-ios target..."
rustup target add aarch64-apple-ios

# 3. Clone the repo
echo "Cloning $REPO..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
git clone --depth 1 --branch "$VERSION" "$REPO" idevice-src || git clone "$REPO" idevice-src
cd idevice-src

# 4. Build for iOS
echo "Building for aarch64-apple-ios (release)..."
cd idevice
cargo build --release --target aarch64-apple-ios

# 5. Find the static lib
LIB_PATH="target/aarch64-apple-ios/release/libidevice.a"
if [ ! -f "$LIB_PATH" ]; then
    # Try alternative name
    LIB_PATH=$(find target/aarch64-apple-ios/release -name "*.a" | head -1)
fi

if [ ! -f "$LIB_PATH" ]; then
    echo "ERROR: Could not find built .a file"
    exit 1
fi

echo "Built: $LIB_PATH"
ls -lh "$LIB_PATH"

# 6. Create xcframework structure
echo "Creating xcframework..."
XCFRAMEWORK_DIR="$OUTPUT_DIR/IDeviceFFI.xcframework"
rm -rf "$XCFRAMEWORK_DIR"
mkdir -p "$XCFRAMEWORK_DIR/ios-arm64/Headers"

# Copy the static lib
cp "$LIB_PATH" "$XCFRAMEWORK_DIR/ios-arm64/libidevice_ffi.a"

# Copy headers (from ffi directory)
if [ -d "../ffi" ]; then
    find ../ffi -name "*.h" -exec cp {} "$XCFRAMEWORK_DIR/ios-arm64/Headers/" \;
fi

# Copy our idevice.h if exists
if [ -f "$OUTPUT_DIR/IDeviceFFI-headers/idevice.h" ]; then
    cp "$OUTPUT_DIR/IDeviceFFI-headers/idevice.h" "$XCFRAMEWORK_DIR/ios-arm64/Headers/"
fi

# 7. Create Info.plist for xcframework
cat > "$XCFRAMEWORK_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>
            <string>libidevice_ffi.a</string>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>ios-arm64</string>
            <key>LibraryPath</key>
            <string>libidevice_ffi.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>ios</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

echo "=== Done ==="
echo "Xcframework at: $XCFRAMEWORK_DIR"
ls -lh "$XCFRAMEWORK_DIR/ios-arm64/"
