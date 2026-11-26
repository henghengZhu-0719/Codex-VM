//go:build darwin || linux

package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSystemdUnitAndCopyTail(t *testing.T) {
	unit, err := SystemdUnit("/usr/local/bin/agent-vm", "/home/u/.agent-vm", "/home/u/.lima")
	if err != nil {
		t.Fatalf("SystemdUnit failed: %v", err)
	}
	for _, want := range []string{"daemon serve", "AGENT_VM_STATE_DIR", "AGENT_VM_LIMA_HOME", "Restart=on-failure"} {
		if !strings.Contains(unit, want) {
			t.Errorf("unit missing %q:\n%s", want, unit)
		}
	}
	if _, err := SystemdUnit("relative/bin", "/home/u/.agent-vm", ""); err == nil {
		t.Error("expected error for relative exe path")
	}

	p := filepath.Join(t.TempDir(), "test.log")
	content := strings.Repeat("A", 100) + "TAIL_END"
	if err := os.WriteFile(p, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := copyTail(&buf, "test.log", p, 16); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "TAIL_END") || strings.Contains(buf.String(), strings.Repeat("A", 50)) {
		t.Fatalf("unexpected tail output: %q", buf.String())
	}
}
