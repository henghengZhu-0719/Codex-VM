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

## Built-in MCP adapter (guest/browser/agent_vm_browser_mcp.py)

A dependency-free MCP stdio adapter is included in the repository. It supports
`browser_tabs`, `browser_new_tab`, `browser_activate_tab` and
`browser_close_tab` over the guest-local CDP HTTP endpoint. The MCP process
runs **inside the guest**, under the same Linux user as Chromium. It does not
listen on any TCP port.

Copy the script into the guest (for example via the existing authenticated
`limactl shell <vm>` workflow), then register it as a stdio MCP server:

```json
{
  "mcpServers": {
    "agent-vm-browser": {
      "command": "python3",
      "args": ["/home/ubuntu/agent_vm_browser_mcp.py"]
    }
  }
}
```

Replace the script path with its actual location in your guest. MCP uses
newline-delimited JSON-RPC on stdin/stdout. The adapter intentionally exposes
only a limited tab-management API and does not provide arbitrary JavaScript
execution, filesystem access or remote CDP forwarding.

The adapter is not yet automatically installed into every VM. Installing it
must not bypass guest network isolation, and access should be limited to
trusted local agent processes.

## One-click MCP installation

The browser workbench now includes **安装 MCP**. It copies the bundled adapter
over the existing authenticated guest SSH connection into:

`~/.config/agent-vm-browser/agent_vm_browser_mcp.py`

The guest directory and script are private to its user. Register the server
with the agent's MCP configuration using that path and `python3` as the
command. This installation does not modify arbitrary agent configuration files
or grant new privileges. Registration remains a separate user-controlled step.

Do not run the adapter outside the guest: its loopback CDP address resolves
relative to the process running the adapter.
