---
name: agent-vm
description: >-
  Operate and orchestrate AI agents (Codex, Claude Code, OpenCode, Mistral Vibe, Pi)
  and commands inside agent-vm Linux VMs from either the Mac host or an external
  computer over SSH. Use when an agent needs to inspect VMs, run tasks inside a VM,
  delegate work to an in-VM agent, or connect to VM services via SSH.
---

# agent-vm Skill

`agent-vm` runs isolated Linux VMs (via Lima) on a macOS host, one persistent VM per project directory. Each VM can run coding agents (`codex`, `claude`, `opencode`, `vibe`, `pi`) and arbitrary Linux commands with host-enforced `.git` protection and network isolation.

## 1. Prerequisites & Discovery

Run commands in the target project directory (or pass a path to `info` / `name`):

```sh
# Machine-readable VM state (version, vm_name, vm_exists, vm_running, ssh_host, ssh_config, security_questions)
agent-vm info [dir]

# List all VMs and their status (returns internal Lima instance names)
agent-vm list

# Optional (macOS desktop app): read custom VM display-name aliases (vm_name -> display_name)
defaults read org.agentvm.desktop vmAliases 2>/dev/null || true

# Read-only environment/health check
agent-vm doctor
```

If calling from an **external computer**, first connect to the Mac host over SSH (`ssh <mac-user>@<mac-host>`) and run `agent-vm` there.

## 2. Running Agents Inside a VM

Always prefer non-interactive flags when an orchestrating agent invokes an in-VM agent:

```sh
# Claude Code (non-interactive prompt)
agent-vm claude -p "fix lint errors and run tests"

# Codex CLI (non-interactive exec)
agent-vm codex exec "summarize the failing tests"

# OpenCode / Mistral Vibe / Pi
agent-vm opencode -p "..."
agent-vm vibe -p "..."
agent-vm pi -p "..."
```

### Non-Interactive / Headless Scripts
When running without a TTY (for example from another agent or CI), `agent-vm` refuses to boot a VM if there are unresolved `security_questions` unless explicitly bypassed:
- Check `security_questions=` in `agent-vm info` first.
- If safe to proceed in automation, pass `--unsafe-disable-security-prompts` (right after `agent-vm` or right after the subcommand name) or set `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1`.

## 3. Running Commands & Shells Inside a VM

```sh
# Run a single command directly (no shell expansion)
agent-vm run pytest -q

# Run a command with shell pipes / redirects via login zsh
agent-vm sh -c "ls -la | grep config"

# Allocate a PTY for TUI programs
agent-vm run --tty htop
```

## 4. Direct SSH / Port Forwarding (For External Agents)

VM SSH and forwarded ports bind to `127.0.0.1` on the Mac host only:
- Use `agent-vm info` to read `ssh_host` and `ssh_config`.
- Connect directly from the Mac host:
  ```sh
  ssh -F "<ssh_config>" "<ssh_host>" "<command>"
  ```
- From an external computer, tunnel through the Mac host using SSH jump/port-forwarding (`ssh -J <mac-user>@<mac-host> ...` or `ssh -L ...`) rather than binding VM services to `0.0.0.0`.

## 5. Lifecycle & Isolation Options

Options must appear **before** the subcommand (or immediately after it):

- `--readonly`: Mount all host shares read-only (host-enforced).
- `--scratch`: Ephemeral VM with no host project or volumes mounted; destroyed on exit.
- `--rm`: Destroy the project VM after the command exits.
- `--reset`: Destroy and re-clone the VM from the base template.
- `--cpus N --memory GB --disk GB`: Resource limits when creating a new VM.
- `--ssh-port N`: Pin a fixed host loopback SSH port.
- `agent-vm stop [vm-name]`: Stop a VM.
- `agent-vm rm [vm-name]`: Delete a VM (does not delete the host project directory).

## 6. Guardrails

- `.git`, `.hg`, and git hook directories in shared folders are read-only inside VMs by default (`--unsafe-writable-git` disables this if commits from inside the VM are explicitly required).
- By default, VMs can reach the internet but not the host or LAN (`~/.agent-vm/network` controls allowlists/domains).
- Never expose unauthenticated in-VM agent servers or debugging ports to `0.0.0.0`.
