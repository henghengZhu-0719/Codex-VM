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
# Build a static, offline frontend: the running app never starts a Vite server.
web="$root/native-macos/web"
if [ ! -d "$web/node_modules" ]; then
  (cd "$web" && npm install --no-audit --no-fund)
fi
(cd "$web" && npm run build)
test -f "$web/dist/index.html"
xcrun swiftc -target arm64-apple-macos13 -module-cache-path "${AGENT_VM_SWIFT_MODULE_CACHE:-$cache/modules}" -vfsoverlay "$cache/overlay.yaml" -parse-as-library "$root/native-macos/AgentVMApp.swift" "$root/native-macos/ProxyGatewayView.swift" "$root/native-macos/ReactWorkbenchView.swift" "$root/native-macos/CodeEditor.swift" -o "$app/Contents/MacOS/AgentVM" -framework SwiftUI -framework AppKit -framework WebKit -framework Combine
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>AgentVM</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleIdentifier</key><string>org.agentvm.desktop</string><key>CFBundleName</key><string>Agent VM</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string></dict></plist>
PLIST

test -x "$root/_output/bin/agent-vm"
cp "$root/_output/bin/agent-vm" "$app/Contents/MacOS/agent-vm"
codesign --force --sign - --entitlements "$root/third_party/lima/vz.entitlements" "$app/Contents/MacOS/agent-vm"
for mihomo_src in "$root/_output/bin/mihomo" "$root/_output/proxy-core/mihomo"; do
  if [ -x "$mihomo_src" ]; then
    cp "$mihomo_src" "$app/Contents/MacOS/mihomo"
    chmod 755 "$app/Contents/MacOS/mihomo"
    codesign --force --sign - "$app/Contents/MacOS/mihomo"
    break
  fi
done
mkdir -p "$app/Contents/Resources"
rm -rf "$app/Contents/Resources/web"
cp -R "$web/dist" "$app/Contents/Resources/web"
if [ -f "$root/native-macos/AppIcon.icns" ]; then
  cp "$root/native-macos/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$app"
codesign --verify --verbose "$app"
