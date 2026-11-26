package remote

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	vmNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$`)
	sshBin   = "ssh"
)

// ValidVMName reports whether name is safe to pass to remote Lima/SSH commands.
func ValidVMName(name string) bool {
	return vmNameRe.MatchString(name) && name != "base" && name != "base-building"
}

// SSHBaseArgs builds hardened OpenSSH arguments for connecting to host.
// Enforces StrictHostKeyChecking=yes, disables agent and X11 forwarding.
func SSHBaseArgs(h Host, batch bool) []string {
	port := h.Port
	if port <= 0 {
		port = 22
	}
	args := []string{
		"-o", "StrictHostKeyChecking=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "ForwardAgent=no",
		"-o", "ForwardX11=no",
	}
	if batch {
		args = append(args, "-o", "BatchMode=yes")
	}
	if h.SSHConfig != "" {
		args = append(args, "-F", h.SSHConfig)
	}
	args = append(args, "-p", strconv.Itoa(port), "--")
	target := h.Address
	if h.User != "" {
		target = h.User + "@" + h.Address
	}
	args = append(args, target)
	return args
}

// remoteSocketBridge relays stdin/stdout to the remote user's private daemon Unix socket.
// Never exposes a TCP port and respects remote AGENT_VM_STATE_DIR or ~/.agent-vm.
const remoteSocketBridge = `python3 -u -c '
import os, select, socket, sys
state = os.environ.get("AGENT_VM_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".agent-vm")
sock_path = os.path.join(state, "run", "agent-vm.sock")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
inp = sys.stdin.buffer.fileno()
out = sys.stdout.buffer.fileno()
sfd = s.fileno()
rlist = [inp, sfd]
while rlist:
    ready, _, _ = select.select(rlist, [], [])
    if inp in ready:
        data = os.read(inp, 65536)
        if not data:
            try: s.shutdown(socket.SHUT_WR)
            except OSError: pass
            rlist.remove(inp)
        else:
            s.sendall(data)
    if sfd in ready:
        data = s.recv(65536)
        if not data:
            break
        os.write(out, data)
s.close()
'`

// DialDaemon opens a single HTTP-capable net.Conn to the remote host's private Unix socket
// over an authenticated OpenSSH stdio channel (no listening ports on either side).
func DialDaemon(ctx context.Context, h Host) (net.Conn, error) {
	if err := Validate(h); err != nil {
		return nil, err
	}
	args := append([]string{"-T"}, SSHBaseArgs(h, true)...)
	args = append(args, remoteSocketBridge)
	cmd := exec.CommandContext(ctx, sshBin, args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		stdin.Close()
		stdout.Close()
		return nil, fmt.Errorf("ssh start: %w", err)
	}
	return &stdioConn{cmd: cmd, r: stdout, w: stdin, remote: h.Name}, nil
}

// CheckSSH verifies key-based SSH reachability to host without prompting.
func CheckSSH(ctx context.Context, h Host) error {
	if err := Validate(h); err != nil {
		return err
	}
	checkCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	args := append([]string{"-T"}, SSHBaseArgs(h, true)...)
	args = append(args, "true")
	cmd := exec.CommandContext(checkCtx, sshBin, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg != "" {
			return fmt.Errorf("ssh check failed: %s", msg)
		}
		return fmt.Errorf("ssh check failed: %w", err)
	}
	return nil
}

// ExecVMPty opens a direct interactive SSH PTY to a VM on a remote host.
// tool may be "shell" (or "") for an interactive login shell, or one of codex/claude/opencode/vibe/pi.
func ExecVMPty(ctx context.Context, h Host, vmName, tool string, extraArgs []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	if err := Validate(h); err != nil {
		return 1, err
	}
	if !ValidVMName(vmName) {
		return 2, fmt.Errorf("invalid VM name: %q", vmName)
	}
	remoteVMSSH := fmt.Sprintf("cd && exec /usr/bin/ssh -F .agent-vm/lima/%s/ssh.config -o ForwardAgent=no -o ForwardX11=no -tt lima-%s", vmName, vmName)
	if tool != "" && tool != "shell" && tool != "sh" {
		switch tool {
		case "codex", "claude", "opencode", "vibe", "pi":
		default:
			return 2, fmt.Errorf("unsupported remote VM tool: %q", tool)
		}
		quoted := []string{shellQuote(tool)}
		for _, a := range extraArgs {
			quoted = append(quoted, shellQuote(a))
		}
		inner := "exec zsh -l -c " + shellQuote("exec "+strings.Join(quoted, " "))
		remoteVMSSH += " " + shellQuote(inner)
	}
	args := append([]string{"-tt"}, SSHBaseArgs(h, false)...)
	args = append(args, remoteVMSSH)
	cmd := exec.CommandContext(ctx, sshBin, args...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), nil
	}
	return 1, err
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

type stdioConn struct {
	cmd    *exec.Cmd
	r      io.ReadCloser
	w      io.WriteCloser
	remote string
	once   sync.Once
}

func (c *stdioConn) Read(p []byte) (int, error)  { return c.r.Read(p) }
func (c *stdioConn) Write(p []byte) (int, error) { return c.w.Write(p) }
func (c *stdioConn) Close() error {
	var err error
	c.once.Do(func() {
		err = errors.Join(c.w.Close(), c.r.Close())
		if c.cmd.Process != nil {
			_ = c.cmd.Process.Signal(os.Interrupt)
		}
		_ = c.cmd.Wait()
	})
	return err
}
func (c *stdioConn) LocalAddr() net.Addr                { return stdioAddr("local") }
func (c *stdioConn) RemoteAddr() net.Addr               { return stdioAddr(c.remote) }
func (c *stdioConn) SetDeadline(t time.Time) error      { return nil }
func (c *stdioConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *stdioConn) SetWriteDeadline(t time.Time) error { return nil }

type stdioAddr string

func (a stdioAddr) Network() string { return "ssh-stdio" }
func (a stdioAddr) String() string  { return string(a) }
