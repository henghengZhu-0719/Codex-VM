package remote

import (
	"errors"
	"os"
	"testing"
)

func TestHostsCRUDAndValidation(t *testing.T) {
	dir := t.TempDir()

	list, err := Load(dir)
	if err != nil || len(list) != 0 {
		t.Fatalf("initial Load = %v, %v", list, err)
	}

	saved, err := Upsert(dir, Host{Name: "mac-pro", Address: "10.10.0.1", User: "alice"})
	if err != nil {
		t.Fatalf("Upsert failed: %v", err)
	}
	if saved.Port != 22 {
		t.Fatalf("default port = %d, want 22", saved.Port)
	}

	info, err := os.Stat(ConfigPath(dir))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("hosts.json perm = %v, want 0600", info.Mode().Perm())
	}

	list, err = Load(dir)
	if err != nil || len(list) != 1 || list[0].Name != "mac-pro" {
		t.Fatalf("Load after Upsert = %+v, %v", list, err)
	}

	if err := Remove(dir, "mac-pro"); err != nil {
		t.Fatalf("Remove failed: %v", err)
	}
	if err := Remove(dir, "mac-pro"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second Remove err = %v, want ErrNotFound", err)
	}

	badCases := []Host{
		{Name: "local", Address: "127.0.0.1"},
		{Name: "../bad", Address: "10.0.0.1"},
		{Name: "h1", Address: "user@10.0.0.1"},
		{Name: "h1", Address: "10.0.0.1", Port: 70000},
		{Name: "h1", Address: "10.0.0.1", SSHConfig: "relative/config"},
	}
	for _, tc := range badCases {
		if err := Validate(tc); !errors.Is(err, ErrInvalid) {
			t.Errorf("Validate(%+v) = %v, want ErrInvalid", tc, err)
		}
	}
}
