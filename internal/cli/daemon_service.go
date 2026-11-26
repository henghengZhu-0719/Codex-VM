//go:build darwin || linux

package cli

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// DaemonServiceManager abstracts platform service managers (macOS launchd, Linux systemd).
type DaemonServiceManager interface {
	Install() error
	Uninstall() error
	Start() error
	Stop() error
	Restart() error
	Logs(out io.Writer) error
}

// SystemdUnit renders a user-level systemd service unit for Linux compatibility (Phase 10).
func SystemdUnit(exe, state, limaHome string) (string, error) {
	if !filepath.IsAbs(exe) {
		return "", fmt.Errorf("daemon executable path must be absolute")
	}
	if !filepath.IsAbs(state) {
		return "", fmt.Errorf("state directory must be absolute")
	}
	var b strings.Builder
	b.WriteString("[Unit]\n")
	b.WriteString("Description=Agent-VM Background Daemon\n")
	b.WriteString("After=network.target\n\n")
	b.WriteString("[Service]\n")
	b.WriteString("Type=simple\n")
	fmt.Fprintf(&b, "ExecStart=%q daemon serve\n", exe)
	fmt.Fprintf(&b, "WorkingDirectory=%q\n", state)
	fmt.Fprintf(&b, "Environment=AGENT_VM_STATE_DIR=%q\n", state)
	if limaHome != "" {
		if !filepath.IsAbs(limaHome) {
			return "", fmt.Errorf("AGENT_VM_LIMA_HOME must be absolute for systemd")
		}
		fmt.Fprintf(&b, "Environment=AGENT_VM_LIMA_HOME=%q\n", limaHome)
	}
	b.WriteString("Restart=on-failure\n")
	b.WriteString("RestartSec=10\n\n")
	b.WriteString("[Install]\n")
	b.WriteString("WantedBy=default.target\n")
	return b.String(), nil
}

// copyTail writes at most maxBytes from the end of path to out.
func copyTail(out io.Writer, label, path string, maxBytes int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	offset := max(int64(0), info.Size()-maxBytes)
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	fmt.Fprintln(out, "---", label, "---")
	_, err = io.CopyN(out, f, info.Size()-offset)
	if err != nil && err != io.EOF {
		return err
	}
	return nil
}
