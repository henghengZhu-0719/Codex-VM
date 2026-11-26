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

## Remaining

- Verify launchd lifecycle on macOS; implement log rotation and stronger unattended recovery.
- Full Phase 0 audit, write-operation migration, global coordination with legacy CLI, network/volume/browser/session managers.
- Integrate lifecycle and manager operations into the task queue; add cancellation/idempotency, actual VM reconciliation, API error schema, security and compatibility tests. Verify task persistence and SSE at runtime.
- Desktop/CLI integration beyond opt-in daemon commands.

The inventory API is read-only; explicit lifecycle requests can change VM state. No claim of runtime verification or Phase 0–3 completion. Roll back by stopping the foreground daemon; legacy commands and data remain unchanged.
