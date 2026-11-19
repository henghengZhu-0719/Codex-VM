# Linux browser as a persistent personal service

The browser runs inside each Linux guest. The macOS SwiftUI/React workbench is
only a viewer/controller: closing the browser tab must not be treated as a
request to stop the Chromium process. Stopping the VM still stops the browser.

## Lifecycle

- Chromium uses the existing guest profile at `~/.config/agent-vm-browser/profile`.
- The guest launch script first tries `systemd-run --user --unit=agent-vm-chromium`
  with `Restart=on-failure`. Minimal guests without a user systemd bus fall
  back to the existing detached Chromium process.
- Explicit Stop/Restart first stops the managed service to avoid restart loops.
- Existing Xvfb/TigerVNC, websockify/noVNC, SSH viewer, tab and clipboard
  controls are retained for compatibility.
- Chromium's default background throttling is enabled. Do not automatically
  suspend a VM while an agent task, download, or browser automation is active.
- Browser profiles contain credentials and are mode 0700. Never place them in
  the shared Downloads directory or synchronize them to another machine.

## CDP and MCP

Chromium's DevTools endpoint is bound to `127.0.0.1:9222` **inside the guest**.
The workbench already performs tab and navigation operations through this
endpoint over authenticated guest SSH. A Chrome DevTools MCP server can run
inside the same guest, connecting to `http://127.0.0.1:9222` (for example
`chrome-devtools-mcp --browserUrl http://127.0.0.1:9222`, when installed).

Do not expose CDP, noVNC, VNC, or the guest SSH port directly to the public
Internet. CDP has broad access to cookies and authenticated browser sessions.
Only install/run MCP from a trusted package and grant it to trusted agents.

## Personal server access

For remote use, first connect the remote device to an authenticated private
network (for example EasyTier with appropriately restricted membership).
Access the existing Mac-hosted workbench through an authenticated remote
desktop/session, or establish an authenticated SSH port-forward to a
loopback-only noVNC endpoint. Never bind noVNC to `0.0.0.0` without an
independent authentication/TLS gateway and authorization controls.

The VM's existing egress gateway, DNS policy and Fail-Closed rules remain
authoritative. Remote access must not add a second unfiltered network path.
Proxy failure should fail closed rather than silently switch to direct egress.

## Resource management

The status script reports the Chromium browser PID, resident memory (MiB),
accumulated CPU seconds and CDP reachability. These are **process-level**
figures, not the total memory/CPU of all Chromium child processes. Use
full process-tree accounting before making scheduling decisions.

The browser workbench can refresh its current session state without restarting
Chromium. A disconnected viewer is not evidence that an agent is idle.

## Operational notes

A user-level systemd service can restart while its user manager exists.
For reboot-time unattended startup, configure user lingering and the guest VM
boot policy separately, with explicit user consent. This change does not
enable lingering or automatically start VMs.
