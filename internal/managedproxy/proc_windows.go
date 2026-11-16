//go:build windows

package managedproxy

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

func configureDetachedCmd(cmd *exec.Cmd) {
	const (
		createNewProcessGroup = 0x00000200
		detachedProcess       = 0x00000008
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: createNewProcessGroup | detachedProcess,
	}
}

func coreProcessEnv(dir string) []string {
	env := []string{"USERPROFILE=" + dir}
	for _, key := range []string{"SystemRoot", "COMSPEC", "PATH", "TEMP", "TMP"} {
		if v := os.Getenv(key); v != "" {
			env = append(env, key+"="+v)
		}
	}
	return env
}

func stopPID(pid int) error {
	if pid <= 0 {
		return nil
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return nil
	}
	if err := p.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	return nil
}
