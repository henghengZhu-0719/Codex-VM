//go:build darwin || linux

package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/remote"
)

func TestHostCommandLifecycle(t *testing.T) {
	t.Setenv("AGENT_VM_STATE_DIR", t.TempDir())

	runHost := func(args ...string) (int, string, string) {
		var out, errBuf bytes.Buffer
		code := Main(args, IO{Stdout: &out, Stderr: &errBuf})
		return code, out.String(), errBuf.String()
	}

	if code, out, errOut := runHost("host", "list"); code != 0 || !strings.Contains(out, "No remote hosts") {
		t.Fatalf("empty host list = %d, out=%q, err=%q", code, out, errOut)
	}

	if code, out, errOut := runHost("host", "add", "mac-pro", "alice@10.10.0.2:2222"); code != 0 || !strings.Contains(out, "mac-pro") {
		t.Fatalf("host add = %d, out=%q, err=%q", code, out, errOut)
	}

	if code, out, _ := runHost("host", "list"); code != 0 || !strings.Contains(out, "alice@10.10.0.2:2222") {
		t.Fatalf("host list = %d, out=%q", code, out)
	}

	if code, out, _ := runHost("host", "list", "--json"); code != 0 || !strings.Contains(out, `"mac-pro"`) {
		t.Fatalf("host list --json = %d, out=%q", code, out)
	}

	if code, _, _ := runHost("host", "remove", "mac-pro"); code != 0 {
		t.Fatalf("host remove = %d, want 0", code)
	}

	if code, _, _ := runHost("--host", "missing", "list"); code == 0 {
		t.Fatalf("expected non-zero for missing --host")
	}

	// Verify hardened SSH options: StrictHostKeyChecking=yes, ForwardAgent=no, ForwardX11=no.
	args := remote.SSHBaseArgs(remote.Host{Name: "mac-pro", Address: "10.10.0.2", User: "alice", Port: 22}, true)
	joined := strings.Join(args, " ")
	for _, want := range []string{"StrictHostKeyChecking=yes", "ForwardAgent=no", "ForwardX11=no", "BatchMode=yes", "alice@10.10.0.2"} {
		if !strings.Contains(joined, want) {
			t.Errorf("SSHBaseArgs missing %q: %s", want, joined)
		}
	}
}
