// Package remote stores remote host metadata without storing SSH private keys or passwords.
package remote

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const storeVersion = 1

var (
	ErrNotFound = errors.New("host not found")
	ErrInvalid  = errors.New("invalid host configuration")
	hostAliasRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`)
)

// Host describes a remote agent-vm host reached over SSH (e.g. via EasyTier).
// Credentials (SSH keys, passphrases, passwords) are never persisted here.
type Host struct {
	Name      string `json:"name"`
	Address   string `json:"address"`
	User      string `json:"user,omitempty"`
	Port      int    `json:"port,omitempty"`
	SSHConfig string `json:"ssh_config,omitempty"`
}

type hostFile struct {
	Version int    `json:"version"`
	Hosts   []Host `json:"hosts"`
}

// ConfigPath returns the versioned host registry path under the state directory.
func ConfigPath(stateDir string) string {
	return filepath.Join(stateDir, "config", "hosts.json")
}

// Validate checks host metadata and rejects unsafe values or embedded credentials.
func Validate(h Host) error {
	if !hostAliasRe.MatchString(h.Name) || h.Name == "local" {
		return fmt.Errorf("%w: invalid host name", ErrInvalid)
	}
	addr := strings.TrimSpace(h.Address)
	if addr == "" || len(addr) > 255 || strings.ContainsAny(addr, " \t\r\n/@:\\") {
		return fmt.Errorf("%w: invalid host address", ErrInvalid)
	}
	if h.User != "" && (len(h.User) > 64 || strings.ContainsAny(h.User, " \t\r\n/@:\\")) {
		return fmt.Errorf("%w: invalid SSH user", ErrInvalid)
	}
	if h.Port < 0 || h.Port > 65535 {
		return fmt.Errorf("%w: invalid SSH port", ErrInvalid)
	}
	if h.SSHConfig != "" && !filepath.IsAbs(h.SSHConfig) {
		return fmt.Errorf("%w: ssh_config must be an absolute path", ErrInvalid)
	}
	return nil
}

// Load reads configured remote hosts. A missing file returns an empty slice.
func Load(stateDir string) ([]Host, error) {
	data, err := os.ReadFile(ConfigPath(stateDir))
	if os.IsNotExist(err) {
		return []Host{}, nil
	}
	if err != nil {
		return nil, err
	}
	var f hostFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, err
	}
	if f.Hosts == nil {
		return []Host{}, nil
	}
	sort.Slice(f.Hosts, func(i, j int) bool { return f.Hosts[i].Name < f.Hosts[j].Name })
	return f.Hosts, nil
}

func save(stateDir string, hosts []Host) error {
	path := ConfigPath(stateDir)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].Name < hosts[j].Name })
	data, err := json.MarshalIndent(hostFile{Version: storeVersion, Hosts: hosts}, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(dir, ".hosts-*")
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

// Upsert validates and stores a remote host entry atomically.
func Upsert(stateDir string, h Host) (Host, error) {
	h.Address = strings.TrimSpace(h.Address)
	h.User = strings.TrimSpace(h.User)
	if h.Port == 0 {
		h.Port = 22
	}
	if err := Validate(h); err != nil {
		return Host{}, err
	}
	hosts, err := Load(stateDir)
	if err != nil {
		return Host{}, err
	}
	updated := false
	for i := range hosts {
		if hosts[i].Name == h.Name {
			hosts[i] = h
			updated = true
			break
		}
	}
	if !updated {
		hosts = append(hosts, h)
	}
	if err := save(stateDir, hosts); err != nil {
		return Host{}, err
	}
	return h, nil
}

// Find looks up a configured remote host by alias name.
func Find(stateDir, name string) (Host, error) {
	if !hostAliasRe.MatchString(name) {
		return Host{}, fmt.Errorf("%w: invalid host name", ErrInvalid)
	}
	hosts, err := Load(stateDir)
	if err != nil {
		return Host{}, err
	}
	for _, h := range hosts {
		if h.Name == name {
			return h, nil
		}
	}
	return Host{}, ErrNotFound
}

// Remove deletes a named remote host entry.
func Remove(stateDir, name string) error {
	if !hostAliasRe.MatchString(name) {
		return fmt.Errorf("%w: invalid host name", ErrInvalid)
	}
	hosts, err := Load(stateDir)
	if err != nil {
		return err
	}
	kept := make([]Host, 0, len(hosts))
	found := false
	for _, h := range hosts {
		if h.Name == name {
			found = true
			continue
		}
		kept = append(kept, h)
	}
	if !found {
		return ErrNotFound
	}
	return save(stateDir, kept)
}
