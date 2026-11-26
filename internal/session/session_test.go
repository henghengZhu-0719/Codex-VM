package session

import (
	"context"
	"io"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/vm"
)

type stubBackend struct {
	vm.Backend
	out  string
	code int
}

func (s *stubBackend) Shell(ctx context.Context, name string, opts vm.ShellOpts) (int, error) {
	if opts.Stdout != nil && s.out != "" {
		_, _ = io.WriteString(opts.Stdout, s.out)
	}
	return s.code, nil
}

func TestValidation(t *testing.T) {
	if !ValidName("work_1-a") || ValidName("../bad") || ValidName("") {
		t.Fatalf("ValidName unexpected result")
	}
	for _, a := range []string{"shell", "codex", "claude", "opencode", "vibe", "pi", "codex-resume", "claude-resume"} {
		if !ValidAgent(a) {
			t.Errorf("ValidAgent(%q) = false, want true", a)
		}
	}
	if ValidAgent("rm -rf /") {
		t.Errorf("ValidAgent accepted invalid agent")
	}
}

func TestListAndInspectTools(t *testing.T) {
	b := &stubBackend{out: "dev|1|1700000000|codex|1700000100\n"}
	sessions, err := List(context.Background(), b, "vm-1")
	if err != nil || len(sessions) != 1 || sessions[0].Name != "dev" || sessions[0].Agent != "codex" || sessions[0].Attached != 1 {
		t.Fatalf("List = %+v, err=%v", sessions, err)
	}

	b2 := &stubBackend{out: `{"tmux":true,"agents":{"codex":{"installed":true,"login_hint":"credential_file_present"}}}`}
	tools, err := InspectTools(context.Background(), b2, "vm-1")
	if err != nil || !tools.Tmux || !tools.Agents["codex"].Installed {
		t.Fatalf("InspectTools = %+v, err=%v", tools, err)
	}

	if err := Create(context.Background(), &stubBackend{}, "vm-1", "/work", "s1", "codex"); err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if err := Stop(context.Background(), &stubBackend{}, "vm-1", "s1"); err != nil {
		t.Fatalf("Stop failed: %v", err)
	}
	if err := Create(context.Background(), &stubBackend{}, "vm-1", "/work", "bad name!", "codex"); err == nil || !strings.Contains(err.Error(), "invalid") {
		t.Fatalf("Create should reject bad name, got %v", err)
	}
}
