# React desktop migration (feat/zhu)

## Architecture

The native desktop shell stays SwiftUI. The main window hosts an offline React build in `WKWebView`; the menu bar remains native. The existing Go CLI, Lima instances, shared workspaces and managed-proxy engine are unchanged.

- `native-macos/web/src/main.jsx`: React screens, card grid, quota management, proxy management and create confirmation.
- `native-macos/web/src/style.css`: Apple / Linear-inspired utility design tokens.
- `native-macos/ReactWorkbenchView.swift`: `NSViewRepresentable` WKWebView and whitelisted JavaScript-to-Swift actions.
- `native-macos/AgentVMApp.swift`: model, live VM usage, quota polling, VM commands, native menu bar.
- `native-macos/ProxyGatewayView.swift`: legacy UI retained for verification and parity comparisons.
- `native-macos/build.sh`: builds React with Vite and bundles its static output under the signed app's Resources/web directory.

## Build

On Apple Silicon macOS with Xcode command-line tools, Go and Node.js 22:

```bash
make
sh native-macos/build.sh
open "_output/Agent VM.app"
```

The build automatically installs frontend dependencies if `node_modules` is missing. No Vite server and no remote JavaScript is needed at runtime.

For React-only development:

```bash
cd native-macos/web
npm install
npm run dev
```

The dev preview has no privileged bridge and deliberately does not simulate successful VM commands.

## Security boundaries

- The bridge accepts only explicit actions such as start/stop, quota refresh, proxy management and folder selection.
- VM names and proxy IDs are checked against native model data.
- The WebView rejects navigation outside the bundled React resources.
- WebKit messages from subframes are ignored.
- No generic shell execution, arbitrary filesystem access or credential read is exposed to React.
- Unsafe network-mode conditions are not represented as verified isolation. Consult `docs/managed-network-development.md`.
- VM stop and destructive actions require a React confirmation, and the host checks status again.

## Migration caveats

- Native macOS compilation must be verified on a Mac; GitHub Actions attempts this using `native-macos/build.sh`.
- The React UI is the default shell; the legacy SwiftUI screen remains in source for comparison, not as a selectable production mode.
- Frontend usage and quota information reflects current guest observations. It is not a measurement of actual host memory pressure or an automatic memory-reclaim system.
- Proxy import and safety checks continue to depend on existing CLI capabilities and their real-world network configuration.
