//go:build darwin || linux

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	policyVersion  = 1
	vmStateVersion = 1

	PolicyManual      = "manual"
	PolicyAutoStart   = "auto_start"
	PolicyRestoreLast = "restore_last"
)

// DaemonPolicy configures unattended startup and bounded crash recovery.
// Note: macOS user LaunchAgent only starts after graphical user login (after FileVault unlock).
type DaemonPolicy struct {
	Version               int               `json:"version"`
	DefaultStartupPolicy  string            `json:"default_startup_policy"`
	VMStartupPolicies     map[string]string `json:"vm_startup_policies,omitempty"`
	MaxRetries            int               `json:"max_retries"`
	RetryWindowSeconds    int               `json:"retry_window_seconds"`
	InitialBackoffSeconds int               `json:"initial_backoff_seconds"`
}

// VMStateSnapshot persists the last observed running VMs for restore_last recovery.
type VMStateSnapshot struct {
	Version        int       `json:"version"`
	UpdatedAt      time.Time `json:"updated_at"`
	LastRunningVMs []string  `json:"last_running_vms"`
}

func DefaultDaemonPolicy() DaemonPolicy {
	return DaemonPolicy{
		Version:               policyVersion,
		DefaultStartupPolicy:  PolicyManual,
		VMStartupPolicies:     map[string]string{},
		MaxRetries:            3,
		RetryWindowSeconds:    900,
		InitialBackoffSeconds: 15,
	}
}

func validStartupPolicy(p string) bool {
	return p == PolicyManual || p == PolicyAutoStart || p == PolicyRestoreLast
}

func ValidateDaemonPolicy(p DaemonPolicy) error {
	if !validStartupPolicy(p.DefaultStartupPolicy) {
		return errors.New("default_startup_policy must be manual, auto_start, or restore_last")
	}
	if p.MaxRetries < 0 || p.MaxRetries > 5 {
		return errors.New("max_retries must be between 0 and 5")
	}
	if p.RetryWindowSeconds < 60 || p.RetryWindowSeconds > 86400 {
		return errors.New("retry_window_seconds must be between 60 and 86400")
	}
	if p.InitialBackoffSeconds < 1 || p.InitialBackoffSeconds > 600 {
		return errors.New("initial_backoff_seconds must be between 1 and 600")
	}
	for name, pol := range p.VMStartupPolicies {
		if !namePattern.MatchString(name) || name == "base" || name == "base-building" {
			return fmt.Errorf("invalid VM name in vm_startup_policies: %q", name)
		}
		if !validStartupPolicy(pol) {
			return fmt.Errorf("invalid policy %q for VM %q", pol, name)
		}
	}
	return nil
}

func (p DaemonPolicy) EffectiveFor(vmName string) string {
	if pol, ok := p.VMStartupPolicies[vmName]; ok && validStartupPolicy(pol) {
		return pol
	}
	if validStartupPolicy(p.DefaultStartupPolicy) {
		return p.DefaultStartupPolicy
	}
	return PolicyManual
}

func PolicyPath(stateDir string) string {
	return filepath.Join(stateDir, "config", "daemon.json")
}

func VMStatePath(stateDir string) string {
	return filepath.Join(stateDir, "state", "vms.json")
}

func writeJSONAtomicWithBackup(path string, v any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if prev, err := os.ReadFile(path); err == nil && json.Valid(prev) {
		_ = os.WriteFile(path+".bak", prev, 0600)
	}
	tmp, err := os.CreateTemp(dir, ".state-*")
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

func readJSONWithBackup(path string, out any) (loaded bool, err error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if json.Unmarshal(data, out) == nil {
		return true, nil
	}
	corruptPath := fmt.Sprintf("%s.corrupt.%d", path, time.Now().UTC().Unix())
	_ = os.Rename(path, corruptPath)
	slog.Warn("corrupt state file archived", "path", corruptPath)
	if bak, berr := os.ReadFile(path + ".bak"); berr == nil && json.Unmarshal(bak, out) == nil {
		slog.Warn("recovered state file from backup", "path", path)
		return true, nil
	}
	return false, nil
}

func LoadDaemonPolicy(stateDir string) DaemonPolicy {
	p := DefaultDaemonPolicy()
	if stateDir == "" {
		return p
	}
	loaded, err := readJSONWithBackup(PolicyPath(stateDir), &p)
	if err != nil || !loaded || ValidateDaemonPolicy(p) != nil {
		return DefaultDaemonPolicy()
	}
	if p.VMStartupPolicies == nil {
		p.VMStartupPolicies = map[string]string{}
	}
	return p
}

func SaveDaemonPolicy(stateDir string, p DaemonPolicy) error {
	p.Version = policyVersion
	if p.VMStartupPolicies == nil {
		p.VMStartupPolicies = map[string]string{}
	}
	if err := ValidateDaemonPolicy(p); err != nil {
		return err
	}
	if stateDir == "" {
		return nil
	}
	return writeJSONAtomicWithBackup(PolicyPath(stateDir), p)
}

func LoadVMState(stateDir string) VMStateSnapshot {
	snap := VMStateSnapshot{Version: vmStateVersion, LastRunningVMs: []string{}}
	if stateDir == "" {
		return snap
	}
	_, _ = readJSONWithBackup(VMStatePath(stateDir), &snap)
	if snap.LastRunningVMs == nil {
		snap.LastRunningVMs = []string{}
	}
	return snap
}

func SaveVMState(stateDir string, vms []VM) error {
	if stateDir == "" {
		return nil
	}
	running := make([]string, 0)
	for _, v := range vms {
		if v.Status == "Running" && v.Name != "base" && v.Name != "base-building" && namePattern.MatchString(v.Name) {
			running = append(running, v.Name)
		}
	}
	return writeJSONAtomicWithBackup(VMStatePath(stateDir), VMStateSnapshot{
		Version:        vmStateVersion,
		UpdatedAt:      time.Now().UTC(),
		LastRunningVMs: running,
	})
}

// RetryTracker enforces bounded retries with exponential backoff within a sliding window.
type RetryTracker struct {
	mu       sync.Mutex
	attempts map[string][]time.Time
}

func NewRetryTracker() *RetryTracker {
	return &RetryTracker{attempts: map[string][]time.Time{}}
}

// RecordFailure records a failure for target and reports whether another retry is allowed
// along with the exponential backoff delay before the next attempt.
func (r *RetryTracker) RecordFailure(target string, policy DaemonPolicy, now time.Time) (allowed bool, backoff time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if policy.MaxRetries <= 0 {
		return false, 0
	}
	window := time.Duration(policy.RetryWindowSeconds) * time.Second
	prev := r.attempts[target]
	kept := prev[:0]
	for _, ts := range prev {
		if now.Sub(ts) <= window {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	r.attempts[target] = kept
	if len(kept) > policy.MaxRetries {
		return false, 0
	}
	shift := len(kept) - 1
	backoff = time.Duration(policy.InitialBackoffSeconds) * time.Second * (1 << shift)
	return true, backoff
}

func (r *RetryTracker) Reset(target string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.attempts, target)
}

// ReconcileStartup scans actual Lima VMs, records authoritative state, and enqueues
// start tasks for stopped VMs matching auto_start or restore_last policies.
func ReconcileStartup(ctx context.Context, stateDir string, inventory Inventory, tasks *TaskManager) {
	prevSnap := LoadVMState(stateDir)
	policy := LoadDaemonPolicy(stateDir)

	reconcileCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	vms, err := inventory.List(reconcileCtx)
	cancel()
	if err != nil {
		slog.Warn("initial VM reconciliation failed", "error", err)
		return
	}

	running := 0
	for _, v := range vms {
		if v.Status == "Running" {
			running++
		}
	}
	slog.Info("initial VM reconciliation complete", "total_vms", len(vms), "running_vms", running)

	wasRunning := map[string]bool{}
	for _, name := range prevSnap.LastRunningVMs {
		wasRunning[name] = true
	}

	if lifecycle, ok := inventory.(Lifecycle); ok && tasks != nil {
		for _, v := range vms {
			if v.Status != "Stopped" || v.Name == "base" || v.Name == "base-building" || !namePattern.MatchString(v.Name) {
				continue
			}
			eff := policy.EffectiveFor(v.Name)
			shouldStart := eff == PolicyAutoStart || (eff == PolicyRestoreLast && wasRunning[v.Name])
			if !shouldStart {
				continue
			}
			name := v.Name
			if _, err := tasks.SubmitTarget("vm-auto-start", name, 10*time.Minute, func(tctx context.Context) ([]VM, error) {
				res, cerr := lifecycle.Change(tctx, name, "start")
				if cerr != nil {
					return nil, cerr
				}
				return []VM{res}, nil
			}); err != nil {
				slog.Warn("failed to schedule startup policy VM", "vm", name, "policy", eff, "error", err)
			} else {
				slog.Info("scheduled VM startup from daemon policy", "vm", name, "policy", eff)
			}
		}
	}
	_ = SaveVMState(stateDir, vms)
}

func registerPolicyRoutes(mux *http.ServeMux, stateDir string) {
	if stateDir == "" {
		return
	}
	mux.HandleFunc("GET /api/v1/daemon/policy", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, LoadDaemonPolicy(stateDir))
	})
	mux.HandleFunc("PUT /api/v1/daemon/policy", func(w http.ResponseWriter, r *http.Request) {
		var in DaemonPolicy
		if !decodeStrictJSON(w, r, 16384, &in) {
			writeError(w, http.StatusBadRequest, "invalid_request", "invalid daemon policy payload")
			return
		}
		if err := SaveDaemonPolicy(stateDir, in); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_policy", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, LoadDaemonPolicy(stateDir))
	})
}
