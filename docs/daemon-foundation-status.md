# Daemon foundation: initial implementation

This is an incremental, opt-in foundation, not completion of Phase 0–3.

## Implemented

- Same agent-vm binary, foreground daemon serve/status/list commands.
- Unix socket under the existing AGENT_VM_STATE_DIR, private run directory (0700) and socket (0600).
- Kernel-backed single-instance lock, cautious stale socket cleanup, signal-driven shutdown.
- HTTP JSON client and versioned read-only VM inventory API, detail, configured resource sizes and mounts.
- Existing Lima backend reused; serialized read requests. Existing CLI paths are unchanged.
- Local transport only: no TCP listener, no browser CORS, no arbitrary command execution.

## Usage

Run agent-vm daemon serve in one terminal, then agent-vm daemon status or agent-vm daemon list in another. For an API request use curl --unix-socket ~/.agent-vm/run/agent-vm.sock http://agent-vm/api/v1/vms (adjust for AGENT_VM_STATE_DIR).

## Audit and migration boundary

Existing internal/cli/start.go performs policy, mount and boot checks; do not bypass it by exposing Backend.Start directly. Existing per-VM file locks and app-volumes lock must be shared by future writers. Proxy status includes custom proxy URL and must be sanitized before exposure. Swift browser, resource and remote ownership still require full audit.

## macOS service management

Use a stable installed CLI binary, then run agent-vm daemon install to register a user LaunchAgent. Commands start, stop, restart, uninstall and logs manage that service. Stop disables the job across login; start enables it. The service starts after graphical user login, not before FileVault unlock. It uses the configured state directory and preserves an absolute AGENT_VM_LIMA_HOME override. Linux remains foreground-only. Logs are private files under daemon-logs; logs displays at most 64 KiB per file, not automatic rotation. Existing foreground instances must be stopped before installing. The install is opt-in, not performed by building the App.

Graceful server shutdown now waits for the HTTP shutdown goroutine before releasing the instance lock.

## Async task foundation

The daemon now has a bounded single-worker queue (16 waiting tasks, 256 retained records), two-minute cooperative operation deadlines, task IDs and atomic JSON snapshots in its private run directory. Interrupted queued/running tasks are marked interrupted after restart, never replayed automatically. The first supported task is read-only VM inventory refresh. Submit with agent-vm daemon refresh, list with agent-vm daemon tasks. HTTP POST /api/v1/tasks/inventory returns 202 and a task ID; GET /api/v1/tasks and GET /api/v1/tasks/{id} expose records. GET /api/v1/events streams task snapshots on change and every 15 seconds, bounded to eight concurrent streams. Reconnecting clients receive a fresh snapshot rather than an event replay. Client disconnect does not cancel work. The first lifecycle endpoints are now exposed for existing project VMs. The deadline is cooperative; backend calls must honor context.

## Lifecycle migration (incremental)

- POST /api/v1/vms/{id}/start and /stop submit asynchronous operations with a ten-minute cooperative deadline. CLI: agent-vm daemon vm-start NAME or vm-stop NAME.
- Existing VM start verifies the original project via the first mount and derived VM name, reuses ensureRunningLocked and its existing security/mount checks, preserves all-read-only mode, and refuses unsafe environment overrides. No implicit migration or direct Backend.Start bypass. Base and scratch VMs are excluded. Operations verify final Lima state.
- Task records include target VM; a second pending/running lifecycle operation for that target is rejected with HTTP 409. Daemon operations share the existing file lock with legacy explicit stop/rm and startup paths. Other legacy writers (destroy-all, scratch cleanup, desktop direct operations) still need audit; this is not complete global coordination.
- A single worker and serialized backend access remain intentional until global Lima and policy interactions are audited; per-VM parallelism remains pending.
- Create/delete APIs are now exposed with the restrictions below. Noninteractive start may fail if security confirmation or manual repair is needed. A failed task does not automatically replay or imply rollback.

## Create/delete migration

- POST /api/v1/vms accepts an absolute host project path, CPU/memory/disk and read-only options. Resolves the derived VM name before enqueueing and again under the operation lock; refuses existing VMs, unsafe overrides and reserved names. Reuses the normal secure create-and-start pipeline (not a stopped-only create).
- DELETE /api/v1/vms/{id}?confirm={id} requires exact name confirmation and a stopped non-template, non-scratch VM. Reuses existing deletion and state cleanup. The client must explicitly stop a running VM before deletion.
- CLI: agent-vm daemon vm-create PROJECT [--cpus N --memory N --disk N --readonly]; agent-vm daemon vm-delete NAME --confirm.
- API operations disable terminal questions. Security confirmations that cannot be answered must fail rather than block. The existing base template must already be available.
- Legacy destroy-all now acquires the per-VM lock for each deletion; desktop direct calls and other legacy writers still require review. No claims of complete cross-process exclusion or parallel execution.
- No VM was created or deleted during development; compile and runtime tests remain pending.

## Volume and proxy migration

- POST /api/v1/vms/{id}/mounts accepts add/remove, absolute host path and ro/rw; reuses vmVolumeCmd and the existing volumes file, preserving user-written rules. A successful task saves settings; restart is still required to apply them. Legacy vm-volume now takes the existing per-VM lock before the global app-volumes lock and rechecks the original project.
- GET /api/v1/network/status exposes selection, source/node metadata and core/gate count without raw proxy URLs or probe/error bodies.
- POST /api/v1/network/actions queues config, import, manual, apply, refresh, delete, stop, gate-close and probe; reuses existing CLI handlers with isolated IO. JSON inputs use the existing CLI schema; inputs and raw outputs are not stored in task history. Legacy proxy CLI and daemon proxy actions share the app-proxy lock.
- CLI: agent-vm daemon volume add NAME PATH rw; agent-vm daemon volume remove NAME PATH rw; agent-vm daemon proxy status; agent-vm daemon proxy apply < selection.json; agent-vm daemon proxy refresh SOURCE.
- Single worker and serialized daemon backend operations remain; direct desktop/legacy writers not using shared locks are still outside complete coordination. No change to lower-level proxy forwarding, DNS or Fail-Closed rules. Existing proxy CLI output remains unchanged. Latency/connection queries, full gate status, browser and resource managers remain pending.
- No actual proxy or mount configuration was modified during development; compile and runtime tests pending.

## Remaining

- Verify launchd lifecycle on macOS; implement log rotation and stronger unattended recovery.
- Full Phase 0 audit, write-operation migration, global coordination with legacy CLI, network/volume/browser/session managers.
- Integrate lifecycle and manager operations into the task queue; add cancellation/idempotency, actual VM reconciliation, API error schema, security and compatibility tests. Verify task persistence and SSE at runtime.
- Desktop/CLI integration beyond opt-in daemon commands.

The inventory API is read-only; explicit lifecycle requests can change VM state. No claim of runtime verification or Phase 0–3 completion. Roll back by stopping the foreground daemon; legacy commands and data remain unchanged.

## Network queries and concurrency audit

- Added GET /api/v1/network/delay?node=ID and GET /api/v1/network/connections, CLI daemon proxy delay ID and daemon proxy connections. The latter reports totals and connection count, not destination history; controller failure is distinct from an empty connection list.
- Proxy read queries use the shared app-proxy lock but no longer take the daemon VM mutex. Query deadline is cooperative. Delay is per-node rather than unbounded all-node fanout.
- Background task panics are converted to failed task records rather than terminating the daemon.
- Audited internal/vm/lima.go: NewLima and prepare use process-wide environment, withLog changes the global logrus writer, and lifecycle operations call global network reconciliation. Simply increasing workers or removing the inventory mutex would not provide safe VM parallelism. Keep one mutation worker until process-isolated execution or a broader Lima refactor is implemented. No additional service is needed.
- Compile and runtime tests remain pending.

## Browser lifecycle migration

- Embedded existing Swift guest Python status, prepare and stop scripts in the Go browser package; uses the same Chromium profile, systemd transient service/detached fallback, X display and loopback viewer/CDP settings.
- GET /api/v1/vms/{id}/browser reports health and process-tree RSS; POST /api/v1/vms/{id}/browser/{start,stop,restart} queues explicit operations on running project VMs. CLI: agent-vm daemon browser status NAME, start NAME, stop NAME, restart NAME.
- Daemon shares VM operation lock and guest lifecycle flock with updated Swift prepare/stop scripts. Older installed Desktop builds do not have the guest lock. Viewer resize and other direct UI controls remain outside daemon migration.
- No public listener, MCP installation, automatic VM start, automatic browser shutdown or profile relocation. Browser restart preserves the profile. No dependency install API. Existing Chromium --no-sandbox compatibility flag remains unchanged.
- Script copies are intentionally retained for existing Desktop compatibility; future client migration should consolidate them. No build or guest runtime tests performed.

## Resource management foundation

- GET /api/v1/vms/{id}/usage and agent-vm daemon usage NAME report configured resources, guest CPU sample, MemAvailable-based memory, swap, terminal/process activity and existing hostagent balloon target/min/max when available.
- Missing metrics are explicitly unavailable, not zero. Stopped VMs return configuration only. Idle candidate is a conservative instantaneous observation, not a sustained idle timer or permission to stop. Process-name checks are heuristic, not comprehensive.
- Audited Desktop SmartMemoryManager and AgentVMApp: existing autoSleepVM calls stop, not a resumable hypervisor pause. Existing balloon controller writes from Desktop; daemon only reads to avoid competing controllers. No new automatic sleep, stop, cache drop, balloon write or resume action. Actual suspend/resume backend capability and unified ownership must be implemented separately.
- Compile/runtime tests pending.

## Detached AI/terminal sessions

- Added guest tmux session manager using a separate agent-vm socket name. List/create/stop via local daemon API, attach via direct existing guest SSH/PTY path. No arbitrary command HTTP endpoint and no additional daemon.
- CLI: agent-vm daemon session create VM NAME codex; agent-vm daemon session list VM; agent-vm daemon session attach VM NAME; agent-vm daemon session stop VM NAME --confirm. Shell, Codex, Claude, OpenCode, Vibe and Pi supported; guest tmux and chosen tool must already be installed. No automatic install.
- Sessions are independent of Desktop and management client connection while the guest and tmux server remain running. Detach using Ctrl-b d. Stop kills the selected session; VM shutdown/reboot destroys live processes. Native AI history resume remains separate.
- Create uses the verified existing project mount and fixed agent commands without adding approval bypass flags. Duplicate names rejected by tmux. API lifecycle operations serialized by existing VM lock. Direct attach does not hold the VM lock for the duration of the terminal.
- Desktop legacy auto-sleep still needs unified activity ownership; turn off auto-sleep when relying on long-running sessions. Quota reporting and remote host CLI routing remain pending. No runtime or compile verification.

## Quota migration

- Reused the existing guest quota query for Codex, Antigravity and Claude. Credentials stay in the guest; typed output excludes raw errors and account email. Existing provider endpoints are unchanged and may change independently.
- Explicit refresh is an asynchronous task; GET returns in-memory snapshot with timestamp and stale flag after 20 minutes. No automatic polling or persistent credential cache. Desktop continues its legacy quota path until client migration. CLI: daemon quota refresh VM; daemon quota status VM.
- Compile and runtime tests pending.

## AI session and quota follow-up

- Daemon polls at most one eligible running VM per minute when no pending/running task was observed; quota refresh attempts are throttled per VM for 20 minutes, including failures. Manual refresh remains available.
- Session creation accepts codex-resume and claude-resume for native interactive history pickers, distinct from attaching a live tmux session.
- Desktop defaults auto-sleep to disabled for new preferences, treats missing metrics as active, counts managed tmux sessions even when detached, and respects disabled auto-sleep under critical memory pressure. Existing explicit auto-sleep preferences remain. This is best-effort protection, not a race-free lease; stale samples and direct stop can still interrupt sessions.
- Guest metrics recognize tmux server process names. No automatic VM stop or second memory controller added. Compile/runtime tests pending.

## Session tools and idle-stop guard

- Added guest tool inventory and credential-file presence hints (not verified login), explicit noninteractive tmux installation via existing guest apt/network path, and tmux session tool/last-activity metadata. CLI: daemon session tools VM; daemon session install-tmux VM.
- Desktop automatic stop now invokes daemon idle-stop VM, a local guarded command taking the existing VM lock and requiring two fresh idle samples. A failed check does not stop the VM proxy. Explicit manual stop remains unchanged. This is best-effort; arbitrary guest process launches outside the lock can race, and idle checks are conservative heuristics. No actual hypervisor pause.
- No compilation or runtime verification performed.


## Batch 1 completion and verification (Phase 0–3)

- Fixed `internal/cli` build collision between `type session` in `commands.go` and the `internal/session` import in `daemon_session_unix.go`, and updated `TestHelp` to account for the `daemon` help section.
- Added structured JSON `slog` logging with size-based rotation (`internal/daemon/log_unix.go`, 10 MiB / 5 backups, `0700` dir, `0600` files) and integrated `daemon.log` into `daemon logs`.
- Added cross-platform `DaemonServiceManager` abstraction and Linux `SystemdUnit` generator (`internal/cli/daemon_service.go`) for Phase 10 readiness.
- Completed legacy CLI lock audit: wrapped `scratch` cleanup deletions in `commands.go` with per-VM `lockVM`.
- Added versioned, atomic remote host metadata store (`internal/remote/hosts.go`, `~/.agent-vm/config/hosts.json`, `0600`, no SSH credentials) and `/api/v1/hosts` endpoints.
- Added unified API error payload (`{"code", "error"}`), `X-Agent-VM-API-Version: 1` header, `POST /api/v1/tasks/{id}/cancel` (`agent-vm daemon cancel ID`), `Idempotency-Key` deduplication on mutation endpoints, explicit `501` `/pause` & `/resume` contract endpoints, `.bak` corrupt task journal recovery, and startup VM reconciliation scan.
- Verified `go build ./...`, `go vet ./...`, and `go test -race -v ./internal/daemon ./internal/remote ./internal/session ./internal/cli` all pass.


## Batch 2 completion and verification (Phase 4–5)

- Added custom transport dialer support to `daemon.Client` (`NewClientWithDialer`) and implemented hardened OpenSSH stdio daemon tunneling (`internal/remote/ssh.go`, `DialDaemon`, `CheckSSH`, `ExecVMPty`) enforcing `StrictHostKeyChecking=yes`, `ForwardAgent=no`, and `ForwardX11=no` with zero listening ports.
- Added CLI remote host management (`agent-vm host add/list/remove/check`) and `--host NAME <list|start|stop|rm|tasks|cancel|shell|codex|claude|opencode|vibe|pi>` (`internal/cli/host_unix.go`, `internal/cli/host_test.go`).
- Added native Swift Unix-socket `DaemonClient` and auto-reconnecting `DaemonEventStream` (`native-macos/DaemonClient.swift`) wired into `AgentVMApp.swift` and `ReactWorkbenchView.swift`; VM start/stop routes through the background Daemon when connected, and closing Desktop only closes the SSE socket without stopping the Daemon or active tasks.
- Upgraded `RemoteHostConnection.swift` and React UI (`native-macos/web/src/main.jsx`) to display all remote VM states (including Stopped), support remote start/stop via SSH daemon commands, and display live Daemon SSE status and cancellable task queue.
- Verified Go (`-race`), React (`vite build`), and macOS SwiftUI build (`native-macos/build.sh`).


## Batch 3 completion and verification (Phase 6, 8, 9)

- Added cross-device remote tmux session attach (`remote.AttachVMSession`) and `agent-vm --host NAME session <list|tools|install-tmux|create|attach|stop>` routing in `internal/cli/host_unix.go`.
- Added sanitized session metadata snapshot store (`internal/session/store.go`, `~/.agent-vm/state/sessions.json`, `0600`, no credentials or terminal contents).
- Added daemon startup policy (`~/.agent-vm/config/daemon.json`, `GET/PUT /api/v1/daemon/policy`: `manual`, `auto_start`, `restore_last`), last-running VM snapshot (`~/.agent-vm/state/vms.json`) with `.bak` corrupt recovery, `ReconcileStartup`, and bounded exponential-backoff `RetryTracker` (`internal/daemon/recovery_unix.go`, `internal/daemon/recovery_test.go`).
- Integrated Fail-Closed egress verification (`VerifyEgress`) on daemon VM start and browser start/restart; verified daemon shutdown never stops managed proxy core or EgressGate.
- Verified `go build ./...`, `go vet ./...`, and `go test -race -v ./internal/daemon ./internal/remote ./internal/session ./internal/cli` all pass.


## Batch 4 & Batch 5 completion and verification (Phase 7 & Phase 10)

- Added configurable resource scheduling policy (`internal/resource/policy.go`, `~/.agent-vm/config/resource-policy.json`, `GET/PUT /api/v1/resource/policy`) and conservative evaluator (`resource.Evaluate`, `GET /api/v1/resource/evaluate/{id}`) that protects active Agent sessions and persistent Chromium, prioritizes balloon memory reclaim before idle stop, and blocks new VM starts under high host memory pressure without killing running workloads.
- Added cross-platform host capability detection (`internal/resource/capabilities*.go`, `GET /api/v1/host/capabilities`) reporting CPU, RAM, VZ/KVM/QEMU availability, and VM/browser suitability without assuming nested virtualization on small VPS hosts.
- Implemented Linux `systemd --user` service lifecycle in `internal/cli/daemon_service_linux.go` (`install`, `uninstall`, `start`, `stop`, `restart`, `logs`).
- Verified `-race` tests across `internal/resource`, `internal/daemon`, `internal/remote`, `internal/session`, and `internal/cli`, plus Linux `amd64`/`arm64` cross-compilation of core packages.
