package session

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const snapshotVersion = 1

// SnapshotFile records sanitized active session metadata per VM (no credentials or terminal output).
type SnapshotFile struct {
	Version   int                  `json:"version"`
	UpdatedAt time.Time            `json:"updated_at"`
	VMs       map[string][]Session `json:"vms"`
}

func SnapshotPath(stateDir string) string {
	return filepath.Join(stateDir, "state", "sessions.json")
}

// LoadSnapshot reads the last persisted session metadata snapshot.
func LoadSnapshot(stateDir string) (SnapshotFile, error) {
	empty := SnapshotFile{Version: snapshotVersion, VMs: map[string][]Session{}}
	data, err := os.ReadFile(SnapshotPath(stateDir))
	if os.IsNotExist(err) {
		return empty, nil
	}
	if err != nil {
		return empty, err
	}
	var snap SnapshotFile
	if err := json.Unmarshal(data, &snap); err != nil {
		return empty, err
	}
	if snap.VMs == nil {
		snap.VMs = map[string][]Session{}
	}
	return snap, nil
}

// SaveVMSessions atomically updates the persisted session metadata for vmName.
func SaveVMSessions(stateDir, vmName string, sessions []Session) error {
	if stateDir == "" || vmName == "" {
		return nil
	}
	snap, _ := LoadSnapshot(stateDir)
	snap.Version = snapshotVersion
	snap.UpdatedAt = time.Now().UTC()
	if len(sessions) == 0 {
		delete(snap.VMs, vmName)
	} else {
		cp := make([]Session, len(sessions))
		copy(cp, sessions)
		snap.VMs[vmName] = cp
	}
	path := SnapshotPath(stateDir)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(dir, ".sessions-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	_, werr := tmp.Write(data)
	if err := errors.Join(werr, tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
