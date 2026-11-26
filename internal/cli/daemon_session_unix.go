//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "net/url"
 "regexp"

	"github.com/sylvinus/agent-vm/internal/daemon"
	"github.com/sylvinus/agent-vm/internal/paths"
	guestsess "github.com/sylvinus/agent-vm/internal/session"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

var sessionVMName = regexp.MustCompile("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$")

func (d *daemonInventory) Sessions(ctx context.Context, name string) ([]guestsess.Session, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	inst, err := d.instance(ctx, name)
	if err != nil {
		return nil, err
	}
	if inst.Status != vm.Running {
		return []guestsess.Session{}, nil
	}
	b, err := d.app.readOnlyBackend()
	if err != nil {
		return nil, err
	}
	return guestsess.List(ctx, b, name)
}

func (d *daemonInventory) ChangeSession(ctx context.Context, name, action string, in daemon.SessionRequest) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if name == vmname.Template || name == "base-building" || vmname.IsScratch(name) {
		return errors.New("not a project VM")
	}
	unlock, err := d.app.lockVM(ctx, name)
	if err != nil {
		return err
	}
	defer unlock()
	if err = ctx.Err(); err != nil {
		return err
	}
	inst, err := d.instance(ctx, name)
	if err != nil {
		return err
	}
	if inst.Status != vm.Running {
		return errors.New("VM not running")
	}
	b, err := d.app.readOnlyBackend()
	if err != nil {
		return err
	}
	switch action {
	case "install-tmux":
		return guestsess.InstallTmux(ctx, b, name)
	case "create":
		if len(inst.Mounts) == 0 {
			return errors.New("project mount unavailable")
		}
		dir, err := vmname.AbsDir(inst.Mounts[0].Location)
		if err != nil || vmname.Name(dir) != name {
			return errors.New("project cannot be verified")
		}
		return guestsess.Create(ctx, b, name, paths.Guest(dir), in.Name, in.Agent)
	case "stop":
		return guestsess.Stop(ctx, b, name, in.Name)
	default:
		return errors.New("unsupported session action")
	}
}

func daemonSessionCommand(args []string, streams IO) int {
	fail := func(err error) int { fmt.Fprintln(streams.Stderr, err); return 1 }
	usage := func() int {
		fmt.Fprintln(streams.Stderr, "Usage: agent-vm daemon session tools VM | install-tmux VM | list VM | create VM NAME [shell|codex|claude|opencode|vibe|pi|codex-resume|claude-resume] | attach VM NAME | stop VM NAME --confirm")
		return 2
	}
	if len(args) < 3 || !sessionVMName.MatchString(args[2]) {
		return usage()
	}
	name := args[2]
	if args[1] == "attach" {
		if len(args) != 4 || !guestsess.ValidName(args[3]) {
			return usage()
		}
		a, err := newApp(streams)
		if err != nil {
			return fail(err)
		}
		b, err := a.readOnlyBackend()
		if err != nil {
			return fail(err)
		}
		ctx, cancel := endedBySignal(context.Background())
		defer cancel()
		// Interactive PTY is a direct SSH data path, not an HTTP task.
		code, err := guestsess.Attach(ctx, b, name, args[3], streams.Stdin, streams.Stdout, streams.Stderr)
		if err != nil {
			return fail(err)
		}
		return code
	}
	st, err := state.Default()
	if err != nil {
		return fail(err)
	}
	c := daemon.NewClient(daemon.SocketPath(string(st)))
	defer c.Close()
	path := "/api/v1/vms/" + url.PathEscape(name) + "/sessions"
	var result any
	switch args[1] {
	case "tools":
		if len(args) != 3 {
			return usage()
		}
		err = c.Get(context.Background(), path+"/tools", &result)
	case "install-tmux":
		if len(args) != 3 {
			return usage()
		}
		err = c.SubmitEmpty(context.Background(), path+"/install-tmux", &result)
	case "list":
		if len(args) != 3 {
			return usage()
		}
		err = c.Get(context.Background(), path, &result)
	case "create":
		if len(args) < 4 || len(args) > 5 || !guestsess.ValidName(args[3]) {
			return usage()
		}
		agent := "shell"
		if len(args) == 5 {
			agent = args[4]
		}
		if !guestsess.ValidAgent(agent) {
			return usage()
		}
		err = c.SubmitManager(context.Background(), path+"/create", daemon.SessionRequest{Name: args[3], Agent: agent}, &result)
	case "stop":
		if len(args) != 5 || args[4] != "--confirm" || !guestsess.ValidName(args[3]) {
			return usage()
		}
		err = c.SubmitManager(context.Background(), path+"/stop", daemon.SessionRequest{Name: args[3]}, &result)
	default:
		return usage()
	}
	if err != nil {
		return fail(err)
	}
	enc := json.NewEncoder(streams.Stdout)
	enc.SetIndent("", "  ")
	if err = enc.Encode(result); err != nil {
		return fail(err)
	}
	return 0
}

func (d *daemonInventory) SessionTools(ctx context.Context, name string) (guestsess.Tools, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	inst, err := d.instance(ctx, name)
	if err != nil {
		return guestsess.Tools{}, err
	}
	if inst.Status != vm.Running {
		return guestsess.Tools{}, errors.New("VM not running")
	}
	b, err := d.app.readOnlyBackend()
	if err != nil {
		return guestsess.Tools{}, err
	}
	return guestsess.InspectTools(ctx, b, name)
}
