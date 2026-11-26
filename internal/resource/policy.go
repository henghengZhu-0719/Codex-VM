package resource

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const (
	resourcePolicyVersion = 1

	StrategyObserveOnly         = "observe_only"
	StrategyBalloonFirst        = "balloon_first"
	StrategyBalloonThenIdleStop = "balloon_then_idle_stop"
)

// Policy controls configurable idle detection, memory pressure thresholds, and protection rules.
type Policy struct {
	Version                    int    `json:"version"`
	IdleMinutes                int    `json:"idle_minutes"`
	MemoryWarnPercent          int    `json:"memory_warn_percent"`
	ReclaimStrategy            string `json:"reclaim_strategy"`
	ProtectActiveAgents        bool   `json:"protect_active_agents"`
	ProtectBrowser             bool   `json:"protect_browser"`
	BlockNewStartUnderPressure bool   `json:"block_new_start_under_pressure"`
}

// Decision is the non-destructive scheduling evaluation for a VM under Policy.
type Decision struct {
	Action          string `json:"action"` // none | reclaim_memory | idle_stop_candidate
	Protected       bool   `json:"protected"`
	ProtectedReason string `json:"protected_reason,omitempty"`
	MemoryPressure  bool   `json:"memory_pressure"`
	AllowNewStart   bool   `json:"allow_new_start"`
	IdleEligible    bool   `json:"idle_eligible"`
}

func DefaultPolicy() Policy {
	return Policy{
		Version:                    resourcePolicyVersion,
		IdleMinutes:                10,
		MemoryWarnPercent:          85,
		ReclaimStrategy:            StrategyBalloonFirst,
		ProtectActiveAgents:        true,
		ProtectBrowser:             true,
		BlockNewStartUnderPressure: true,
	}
}

func ValidatePolicy(p Policy) error {
	if p.IdleMinutes < 0 || p.IdleMinutes > 1440 {
		return errors.New("idle_minutes must be between 0 and 1440")
	}
	if p.MemoryWarnPercent < 50 || p.MemoryWarnPercent > 98 {
		return errors.New("memory_warn_percent must be between 50 and 98")
	}
	switch p.ReclaimStrategy {
	case StrategyObserveOnly, StrategyBalloonFirst, StrategyBalloonThenIdleStop:
	default:
		return errors.New("reclaim_strategy must be observe_only, balloon_first, or balloon_then_idle_stop")
	}
	return nil
}

func PolicyPath(stateDir string) string {
	return filepath.Join(stateDir, "config", "resource-policy.json")
}

func LoadPolicy(stateDir string) Policy {
	p := DefaultPolicy()
	if stateDir == "" {
		return p
	}
	data, err := os.ReadFile(PolicyPath(stateDir))
	if err != nil {
		return p
	}
	if err := json.Unmarshal(data, &p); err != nil || ValidatePolicy(p) != nil {
		return DefaultPolicy()
	}
	return p
}

func SavePolicy(stateDir string, p Policy) error {
	p.Version = resourcePolicyVersion
	if err := ValidatePolicy(p); err != nil {
		return err
	}
	if stateDir == "" {
		return nil
	}
	path := PolicyPath(stateDir)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(dir, ".respolicy-*")
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

// Evaluate assesses a VM conservatively:
// - Never recommends terminating active agents or persistent Chromium when protected.
// - Prioritizes reclaimable memory before considering idle VM stop.
// - Restricts new VM starts under high host memory pressure without killing running tasks.
func Evaluate(pol Policy, m *Metrics, hasActiveSession, browserRunning bool, hostMemUsedPct float64, idleDuration time.Duration) Decision {
	pressure := hostMemUsedPct >= float64(pol.MemoryWarnPercent)
	d := Decision{
		Action:         "none",
		MemoryPressure: pressure,
		AllowNewStart:  !(pressure && pol.BlockNewStartUnderPressure),
	}

	if pol.ProtectActiveAgents && hasActiveSession {
		d.Protected = true
		d.ProtectedReason = "active_agent_session"
	} else if pol.ProtectBrowser && browserRunning {
		d.Protected = true
		d.ProtectedReason = "persistent_browser"
	} else if m == nil {
		// Missing metrics are conservatively treated as active/protected.
		d.Protected = true
		d.ProtectedReason = "metrics_unavailable"
	} else if m.ActiveSessions > 0 || m.ProtectedProcesses > 0 {
		d.Protected = true
		d.ProtectedReason = "active_guest_process"
	}

	idleThreshold := time.Duration(pol.IdleMinutes) * time.Minute
	if !d.Protected && m != nil && m.IdleCandidate && pol.IdleMinutes > 0 && idleDuration >= idleThreshold {
		d.IdleEligible = true
	}

	switch pol.ReclaimStrategy {
	case StrategyObserveOnly:
		d.Action = "none"
	case StrategyBalloonFirst:
		if pressure {
			d.Action = "reclaim_memory"
		}
	case StrategyBalloonThenIdleStop:
		if pressure {
			d.Action = "reclaim_memory"
		}
		if d.IdleEligible {
			d.Action = "idle_stop_candidate"
		}
	}
	return d
}
