//go:build linux

package cli

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/sylvinus/agent-vm/internal/daemon"
)

func daemonService(command, state string, streams IO) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(state))
	unitName := fmt.Sprintf("agent-vm-daemon-%x.service", digest[:8])
	unitDir := filepath.Join(home, ".config", "systemd", "user")
	unitPath := filepath.Join(unitDir, unitName)

	runSystemctl := func(args ...string) error {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "systemctl", append([]string{"--user"}, args...)...)
		cmd.Stdout, cmd.Stderr = streams.Stdout, streams.Stderr
		return cmd.Run()
	}

	healthy := func() bool {
		c := daemon.NewClient(daemon.SocketPath(state))
		defer c.Close()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		var result struct {
			Status string `json:"status"`
		}
		return c.Get(ctx, "/health", &result) == nil && result.Status == "ok"
	}

	wait := func(want bool) error {
		for i := 0; i < 40; i++ {
			if healthy() == want {
				return nil
			}
			time.Sleep(250 * time.Millisecond)
		}
		return errors.New("daemon health did not reach expected state; inspect daemon logs")
	}

	switch command {
	case "install":
		if healthy() {
			return errors.New("stop the existing daemon before installing")
		}
		if _, err := os.Lstat(unitPath); err == nil {
			return errors.New("systemd unit already installed; uninstall first")
		} else if !os.IsNotExist(err) {
			return err
		}
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		exe, err = filepath.EvalSymlinks(exe)
		if err != nil {
			return err
		}
		unit, err := SystemdUnit(exe, state, os.Getenv("AGENT_VM_LIMA_HOME"))
		if err != nil {
			return err
		}
		if err := os.MkdirAll(unitDir, 0700); err != nil {
			return err
		}
		if err := os.WriteFile(unitPath, []byte(unit), 0600); err != nil {
			return err
		}
		if err := runSystemctl("daemon-reload"); err != nil {
			return err
		}
		if err := runSystemctl("enable", "--now", unitName); err != nil {
			return err
		}
		return wait(true)

	case "start":
		if healthy() {
			return nil
		}
		if _, err := os.Lstat(unitPath); err != nil {
			return err
		}
		if err := runSystemctl("start", unitName); err != nil {
			return err
		}
		return wait(true)

	case "stop", "uninstall":
		if _, err := os.Lstat(unitPath); err != nil {
			return err
		}
		_ = runSystemctl("disable", "--now", unitName)
		if err := wait(false); err != nil {
			return err
		}
		if command == "uninstall" {
			if err := os.Remove(unitPath); err != nil {
				return err
			}
			_ = runSystemctl("daemon-reload")
		}
		return nil

	case "restart":
		if _, err := os.Lstat(unitPath); err != nil {
			return err
		}
		if err := runSystemctl("restart", unitName); err != nil {
			return err
		}
		return wait(true)

	case "logs":
		return copyTail(streams.Stdout, "daemon.log", daemon.LogPath(state), 65536)

	default:
		return fmt.Errorf("unknown daemon service command: %s", command)
	}
}
