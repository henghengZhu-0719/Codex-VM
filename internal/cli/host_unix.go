//go:build darwin || linux

package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/sylvinus/agent-vm/internal/daemon"
	"github.com/sylvinus/agent-vm/internal/remote"
	"github.com/sylvinus/agent-vm/internal/state"
)

func remoteDaemonClient(h remote.Host) *daemon.Client {
	return daemon.NewClientWithDialer(func(ctx context.Context) (net.Conn, error) {
		return remote.DialDaemon(ctx, h)
	}, 20*time.Second)
}

func hostCommand(args []string, streams IO) int {
	usage := func() int {
		fmt.Fprintln(streams.Stderr, "Usage: agent-vm host <add NAME [USER@]ADDR[:PORT] [--user U --port P --ssh-config PATH] | list [--json] | remove NAME | check NAME>")
		return exitUsage
	}
	if len(args) == 0 {
		return usage()
	}
	st, err := state.Default()
	if err != nil {
		fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
		return 1
	}
	stateDir := string(st)

	switch args[0] {
	case "list":
		asJSON := len(args) == 2 && args[1] == "--json"
		if len(args) > 2 || (len(args) == 2 && !asJSON) {
			return usage()
		}
		hosts, err := remote.Load(stateDir)
		if err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		if asJSON {
			enc := json.NewEncoder(streams.Stdout)
			enc.SetIndent("", "  ")
			if err := enc.Encode(hosts); err != nil {
				return 1
			}
			return 0
		}
		if len(hosts) == 0 {
			fmt.Fprintln(streams.Stdout, "No remote hosts configured.")
			return 0
		}
		for _, h := range hosts {
			target := h.Address
			if h.User != "" {
				target = h.User + "@" + target
			}
			port := h.Port
			if port <= 0 {
				port = 22
			}
			fmt.Fprintf(streams.Stdout, "%-20s %s:%d\n", h.Name, target, port)
		}
		return 0

	case "add":
		if len(args) < 3 {
			return usage()
		}
		h, err := parseHostAddArgs(args[1:])
		if err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return exitUsage
		}
		saved, err := remote.Upsert(stateDir, h)
		if err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Fprintf(streams.Stdout, "Saved remote host '%s' (%s:%d)\n", saved.Name, saved.Address, saved.Port)
		return 0

	case "remove", "rm":
		if len(args) != 2 {
			return usage()
		}
		if err := remote.Remove(stateDir, args[1]); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Fprintf(streams.Stdout, "Removed remote host '%s'\n", args[1])
		return 0

	case "check":
		if len(args) != 2 {
			return usage()
		}
		h, err := remote.Find(stateDir, args[1])
		if err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := remote.CheckSSH(ctx, h); err != nil {
			fmt.Fprintf(streams.Stderr, "SSH check failed for '%s': %v\n", h.Name, err)
			return 1
		}
		fmt.Fprintf(streams.Stdout, "✓ SSH reachable: %s (%s:%d)\n", h.Name, h.Address, h.Port)
		c := remoteDaemonClient(h)
		defer c.Close()
		var health struct {
			Status     string `json:"status"`
			APIVersion int    `json:"api_version"`
		}
		if err := c.Get(ctx, "/health", &health); err != nil || health.Status != "ok" {
			fmt.Fprintf(streams.Stderr, "✗ Remote daemon unreachable on '%s': %v\n", h.Name, err)
			return 1
		}
		var vms []daemon.VM
		if err := c.Get(ctx, "/api/v1/vms", &vms); err != nil {
			fmt.Fprintf(streams.Stderr, "✗ Remote VM inventory error: %v\n", err)
			return 1
		}
		fmt.Fprintf(streams.Stdout, "✓ Remote daemon healthy (api v%d, %d VMs)\n", health.APIVersion, len(vms))
		return 0

	default:
		return usage()
	}
}

func parseHostAddArgs(args []string) (remote.Host, error) {
	if len(args) < 2 {
		return remote.Host{}, errors.New("host name and address required")
	}
	h := remote.Host{Name: args[0], Port: 22}
	rest := args[1:]
	// Support shorthand positional target: [user@]address[:port]
	if !strings.HasPrefix(rest[0], "--") {
		target := rest[0]
		rest = rest[1:]
		if u, after, ok := strings.Cut(target, "@"); ok {
			h.User = u
			target = after
		}
		if hostPart, portStr, ok := strings.Cut(target, ":"); ok {
			p, err := strconv.Atoi(portStr)
			if err != nil {
				return remote.Host{}, fmt.Errorf("invalid port %q", portStr)
			}
			h.Address = hostPart
			h.Port = p
		} else {
			h.Address = target
		}
	}
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case "--address", "--host":
			if i+1 >= len(rest) {
				return remote.Host{}, errors.New("--address requires a value")
			}
			i++
			h.Address = rest[i]
		case "--user":
			if i+1 >= len(rest) {
				return remote.Host{}, errors.New("--user requires a value")
			}
			i++
			h.User = rest[i]
		case "--port":
			if i+1 >= len(rest) {
				return remote.Host{}, errors.New("--port requires a value")
			}
			i++
			p, err := strconv.Atoi(rest[i])
			if err != nil {
				return remote.Host{}, fmt.Errorf("invalid port %q", rest[i])
			}
			h.Port = p
		case "--ssh-config":
			if i+1 >= len(rest) {
				return remote.Host{}, errors.New("--ssh-config requires a path")
			}
			i++
			h.SSHConfig = rest[i]
		default:
			return remote.Host{}, fmt.Errorf("unknown option %q", rest[i])
		}
	}
	if err := remote.Validate(h); err != nil {
		return remote.Host{}, err
	}
	return h, nil
}

func remoteHostCommand(hostName string, args []string, streams IO) int {
	usage := func() int {
		fmt.Fprintln(streams.Stderr, "Usage: agent-vm --host NAME <list [--json] | start VM [--async] | stop VM [--async] | rm VM --confirm [--async] | tasks | cancel TASK_ID | shell VM | codex VM [args] | claude VM [args] | opencode VM [args] | vibe VM [args] | pi VM [args]>")
		return exitUsage
	}
	if len(args) == 0 {
		return usage()
	}
	st, err := state.Default()
	if err != nil {
		fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
		return 1
	}
	h, err := remote.Find(string(st), hostName)
	if err != nil {
		fmt.Fprintf(streams.Stderr, "Error: remote host %q: %v\n", hostName, err)
		return 1
	}

	cmd, rest := args[0], args[1:]
	switch cmd {
	case "shell", "sh", "codex", "claude", "opencode", "vibe", "pi":
		if len(rest) < 1 {
			return usage()
		}
		vmName := rest[0]
		extra := rest[1:]
		ctx, cancel := endedBySignal(context.Background())
		defer cancel()
		code, err := remote.ExecVMPty(ctx, h, vmName, cmd, extra, streams.Stdin, streams.Stdout, streams.Stderr)
		if err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return code
		}
		return code

	case "list", "status":
		asJSON := len(rest) == 1 && rest[0] == "--json"
		if len(rest) > 1 || (len(rest) == 1 && !asJSON) {
			return usage()
		}
		c := remoteDaemonClient(h)
		defer c.Close()
		var vms []daemon.VM
		if err := c.Get(context.Background(), "/api/v1/vms", &vms); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		if asJSON {
			enc := json.NewEncoder(streams.Stdout)
			enc.SetIndent("", "  ")
			if err := enc.Encode(vms); err != nil {
				return 1
			}
			return 0
		}
		if len(vms) == 0 {
			fmt.Fprintf(streams.Stdout, "No VMs on host '%s'.\n", h.Name)
			return 0
		}
		for _, v := range vms {
			fmt.Fprintf(streams.Stdout, "%-32s %-10s %d CPU  %d GiB RAM  %d GiB Disk\n",
				v.Name, v.Status, v.CPUs, v.Memory>>30, v.Disk>>30)
		}
		return 0

	case "start", "stop":
		if len(rest) < 1 || len(rest) > 2 {
			return usage()
		}
		async := len(rest) == 2 && rest[1] == "--async"
		if len(rest) == 2 && !async {
			return usage()
		}
		c := remoteDaemonClient(h)
		defer c.Close()
		var task daemon.Task
		if err := c.ChangeVM(context.Background(), rest[0], cmd, &task); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		return waitOrPrintRemoteTask(c, task, async, streams)

	case "rm", "delete":
		if len(rest) < 2 || len(rest) > 3 || rest[1] != "--confirm" {
			return usage()
		}
		async := len(rest) == 3 && rest[2] == "--async"
		if len(rest) == 3 && !async {
			return usage()
		}
		c := remoteDaemonClient(h)
		defer c.Close()
		var task daemon.Task
		if err := c.DeleteVM(context.Background(), rest[0], &task); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		return waitOrPrintRemoteTask(c, task, async, streams)

	case "tasks":
		if len(rest) != 0 {
			return usage()
		}
		c := remoteDaemonClient(h)
		defer c.Close()
		var result any
		if err := c.Get(context.Background(), "/api/v1/tasks", &result); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		enc := json.NewEncoder(streams.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(result); err != nil {
			return 1
		}
		return 0

	case "cancel":
		if len(rest) != 1 {
			return usage()
		}
		c := remoteDaemonClient(h)
		defer c.Close()
		var result any
		if err := c.CancelTask(context.Background(), rest[0], &result); err != nil {
			fmt.Fprintf(streams.Stderr, "Error: %v\n", err)
			return 1
		}
		enc := json.NewEncoder(streams.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(result); err != nil {
			return 1
		}
		return 0

	default:
		return usage()
	}
}

func waitOrPrintRemoteTask(c *daemon.Client, task daemon.Task, async bool, streams IO) int {
	if async {
		enc := json.NewEncoder(streams.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(task)
		return 0
	}
	fmt.Fprintf(streams.Stdout, "Submitted task %s (%s %s)...\n", task.ID, task.Kind, task.Target)
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		var cur daemon.Task
		if err := c.Get(context.Background(), "/api/v1/tasks/"+task.ID, &cur); err != nil {
			fmt.Fprintf(streams.Stderr, "Error polling task %s: %v\n", task.ID, err)
			return 1
		}
		switch cur.Status {
		case "succeeded":
			fmt.Fprintf(streams.Stdout, "Task %s succeeded.\n", cur.ID)
			return 0
		case "failed", "interrupted", "cancelled":
			fmt.Fprintf(streams.Stderr, "Task %s %s: %s\n", cur.ID, cur.Status, cur.Error)
			return 1
		}
		time.Sleep(1 * time.Second)
	}
	fmt.Fprintf(streams.Stderr, "Timed out waiting for task %s (still running on remote host).\n", task.ID)
	return 1
}
