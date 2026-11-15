#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
app="$root/_output/Agent VM.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p /private/tmp/agent-vm-swift-cache
# Some Command Line Tools releases include two copies of SwiftBridging.
# Mask only the duplicate for this build; leave the system installation alone.
cache="${TMPDIR:-/tmp}/agent-vm-swift-build"
mkdir -p "$cache"
printf '// duplicate module map masked for this build\n' > "$cache/empty.modulemap"
cat > "$cache/overlay.yaml" <<OVERLAY
{ 'version': 0, 'roots': [ { 'type': 'file', 'name': '/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap', 'external-contents': '$cache/empty.modulemap' } ] }
OVERLAY
xcrun swiftc -target arm64-apple-macos13 -module-cache-path "${AGENT_VM_SWIFT_MODULE_CACHE:-$cache/modules}" -vfsoverlay "$cache/overlay.yaml" -parse-as-library "$root/native-macos/AgentVMApp.swift" -o "$app/Contents/MacOS/AgentVM" -framework SwiftUI -framework AppKit
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>AgentVM</string><key>CFBundleIdentifier</key><string>org.agentvm.desktop</string><key>CFBundleName</key><string>Agent VM</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string></dict></plist>
PLIST

test -x "$root/_output/bin/agent-vm"
cp "$root/_output/bin/agent-vm" "$app/Contents/MacOS/agent-vm"
codesign --force --sign - --entitlements "$root/third_party/lima/vz.entitlements" "$app/Contents/MacOS/agent-vm"
mkdir -p "$app/Contents/Resources"
codesign --force --sign - "$app"
codesign --verify --verbose "$app"
