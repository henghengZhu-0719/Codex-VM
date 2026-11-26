package cli

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// vmVolumeCmd manages only app-created extra shares; existing user rules remain intact.
func (e *app) vmVolumeCmd(ctx context.Context, args []string) int {
	fail := func(err error) int { fmt.Fprintln(e.io.Stderr, err); return 1 }
	if len(args) != 4 || (args[0] != "add" && args[0] != "remove") {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm vm-volume {add|remove} NAME PATH {ro|rw}")
		return exitUsage
	}
	action, name, src, mode := args[0], args[1], args[2], args[3]
	if mode != "ro" && mode != "rw" {
		return fail(fmt.Errorf("invalid mode"))
	}
	b, err := e.readOnlyBackend()
	if err != nil {
		return fail(err)
	}
	inst, err := b.Get(ctx, name)
	if err != nil {
		return fail(err)
	}
	if len(inst.Mounts) == 0 {
		return fail(fmt.Errorf("VM has no project folder"))
	}
	project := inst.Mounts[0].Location
	project, err = vmname.AbsDir(project)
	if err != nil || vmname.Name(project) != name {
		return fail(fmt.Errorf("cannot verify the VM's original project directory"))
	}
	vmUnlock, err := e.lockVM(ctx, name)
	if err != nil { return fail(err) }
	defer vmUnlock()
	// Recheck after taking the same lock used by start/stop/delete.
	inst, err = b.Get(ctx, name)
	if err != nil { return fail(err) }
	if len(inst.Mounts) == 0 { return fail(fmt.Errorf("VM has no project folder")) }
	current, err := vmname.AbsDir(inst.Mounts[0].Location)
	if err != nil || current != project { return fail(fmt.Errorf("VM project changed")) }
	if !filepath.IsAbs(src) {
		return fail(fmt.Errorf("folder path contains unsupported characters"))
	}
	src, project = paths.Host(src), paths.Host(project)
	if !volumePathFieldValid(src) || !volumePathFieldValid(project) {
		return fail(fmt.Errorf("folder path contains unsupported characters"))
	}
	if why, bad := mounts.Unmountable(src); bad {
		return fail(fmt.Errorf("folder %s", why))
	}
	lock, err := e.lockVM(ctx, "app-volumes")
	if err != nil {
		return fail(err)
	}
	defer lock()
	file := e.state.Path("volumes")
	old, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return fail(err)
	}
	marker := " # Agent VM " + name
	rule := src + "::" + mode + ":" + project + marker
	lines := strings.Split(strings.TrimSuffix(string(old), "\n"), "\n")
	out := make([]string, 0, len(lines)+1)
	found := false
	for _, line := range lines {
		if line == rule {
			found = true
			continue
		}
		out = append(out, line)
	}
	if action == "remove" && !found {
		return fail(fmt.Errorf("only folders added in this app can be removed here"))
	}
	if action == "add" {
		info, err := os.Stat(src)
		if err != nil || !info.IsDir() {
			return fail(fmt.Errorf("folder does not exist"))
		}
		tmp, err := os.CreateTemp("", "agent-vm-volume-*")
		if err != nil {
			return fail(err)
		}
		defer os.Remove(tmp.Name())
		if _, err := tmp.WriteString(strings.Join(out, "\n") + "\n" + rule + "\n"); err != nil {
			tmp.Close()
			return fail(err)
		}
		tmp.Close()
		var warnings bytes.Buffer
		entries := mounts.Entries(tmp.Name(), project, paths.Home(), e.refs(), &warnings)
		accepted := false
		for _, entry := range entries {
			if entry.Line == src+"::"+mode {
				accepted = true
			}
		}
		if !accepted {
			return fail(fmt.Errorf("cannot add folder: %s", strings.TrimSpace(warnings.String())))
		}
		out = append(out, rule)
	}
	content := strings.Join(out, "\n")
	if content != "" {
		content += "\n"
	}
	if err := e.state.Write("volumes", []byte(content)); err != nil {
		return fail(err)
	}
	fmt.Fprintln(e.io.Stdout, "Folder settings saved. Restart the VM to apply them.")
	return 0
}

// volumePathFieldValid keeps volume separators and project glob syntax out of
// literal paths, allowing only the drive colon in Windows absolute paths.
func volumePathFieldValid(path string) bool {
	if paths.Windows() && len(path) >= 3 && ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')) && path[1] == ':' && path[2] == '/' {
		path = path[2:]
	}
	return !strings.ContainsAny(path, ":#*?[]\"\\|\r\n") && strings.IndexFunc(path, unicode.IsControl) < 0
}
