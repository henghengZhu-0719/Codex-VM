package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

func TestManagedVMVolume(t *testing.T) {
	se := newStartEnv(t)
	name := vmname.Name(se.proj)
	se.fake.VMs[name] = &vm.Instance{Name: name, Status: vm.Stopped, Mounts: []vm.Mount{{Location: se.proj}}}
	extra := filepath.Join(se.home, "extra")
	if err := os.Mkdir(extra, 0755); err != nil {
		t.Fatal(err)
	}
	existing := "# keep this configuration\n"
	if err := os.WriteFile(se.state.Path("volumes"), []byte(existing), 0644); err != nil {
		t.Fatal(err)
	}
	if code := se.run("vm-volume", "add", name, extra, "ro"); code != 0 {
		t.Fatalf("add: %d %s", code, se.out())
	}
	content, _ := os.ReadFile(se.state.Path("volumes"))
	if !strings.Contains(string(content), existing) || !strings.Contains(string(content), extra+"::ro:"+se.proj) {
		t.Fatalf("unexpected rules: %s", content)
	}
	if code := se.run("vm-volume", "remove", name, extra, "ro"); code != 0 {
		t.Fatalf("remove: %d %s", code, se.out())
	}
	content, _ = os.ReadFile(se.state.Path("volumes"))
	if string(content) != existing {
		t.Fatalf("other rules changed: %q", content)
	}
	if code := se.run("vm-volume", "add", name, se.home, "rw"); code == 0 {
		t.Fatal("allowed sharing protected home")
	}
}
