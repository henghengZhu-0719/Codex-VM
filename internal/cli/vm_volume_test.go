package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
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
	if !strings.Contains(string(content), existing) || !strings.Contains(string(content), paths.Host(extra)+"::ro:"+paths.Host(se.proj)) {
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

func TestVolumePathFieldRejectsRuleSyntax(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	for _, tc := range []struct {
		path  string
		valid bool
	}{
		{"C:/Users/me/folder", true}, {"C:/Users/me:rw", false}, {"C:/Users/me#comment", false},
		{"C:/Users/*", false}, {"C:/Users/me\nother", false}, {"C:/Users/\"me\"", false},
	} {
		if got := volumePathFieldValid(tc.path); got != tc.valid {
			t.Errorf("%q: got %t", tc.path, got)
		}
	}
}
