package resource

import (
	"os"
	"testing"
	"time"
)

func TestResourcePolicyPersistenceAndValidation(t *testing.T) {
	dir := t.TempDir()
	def := LoadPolicy(dir)
	if def.IdleMinutes != 10 || def.MemoryWarnPercent != 85 || !def.ProtectActiveAgents || !def.ProtectBrowser {
		t.Fatalf("unexpected default policy: %+v", def)
	}

	custom := Policy{
		IdleMinutes:                15,
		MemoryWarnPercent:          80,
		ReclaimStrategy:            StrategyBalloonThenIdleStop,
		ProtectActiveAgents:        true,
		ProtectBrowser:             true,
		BlockNewStartUnderPressure: true,
	}
	if err := SavePolicy(dir, custom); err != nil {
		t.Fatalf("SavePolicy failed: %v", err)
	}
	info, err := os.Stat(PolicyPath(dir))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("policy file perm = %v, want 0600", info.Mode().Perm())
	}
	loaded := LoadPolicy(dir)
	if loaded.IdleMinutes != 15 || loaded.ReclaimStrategy != StrategyBalloonThenIdleStop {
		t.Fatalf("loaded = %+v", loaded)
	}

	bad := custom
	bad.MemoryWarnPercent = 30
	if err := ValidatePolicy(bad); err == nil {
		t.Fatalf("expected error for low MemoryWarnPercent")
	}
}

func TestEvaluateProtectsActiveAgentAndBrowser(t *testing.T) {
	pol := DefaultPolicy()
	pol.ReclaimStrategy = StrategyBalloonThenIdleStop
	idleMetrics := &Metrics{IdleCandidate: true, ActiveSessions: 0, ProtectedProcesses: 0}

	// Active agent session is protected even under high pressure and long idle time.
	d1 := Evaluate(pol, idleMetrics, true, false, 90, 20*time.Minute)
	if !d1.Protected || d1.ProtectedReason != "active_agent_session" || d1.IdleEligible || d1.AllowNewStart {
		t.Fatalf("active agent decision = %+v", d1)
	}
	if d1.Action != "reclaim_memory" {
		t.Fatalf("expected reclaim_memory under pressure without idle stop, got %+v", d1)
	}

	// Persistent browser is protected.
	d2 := Evaluate(pol, idleMetrics, false, true, 50, 20*time.Minute)
	if !d2.Protected || d2.ProtectedReason != "persistent_browser" || d2.Action != "none" {
		t.Fatalf("persistent browser decision = %+v", d2)
	}

	// Truly idle VM beyond IdleMinutes becomes idle_stop_candidate.
	d3 := Evaluate(pol, idleMetrics, false, false, 50, 15*time.Minute)
	if d3.Protected || !d3.IdleEligible || d3.Action != "idle_stop_candidate" || !d3.AllowNewStart {
		t.Fatalf("idle VM decision = %+v", d3)
	}

	// Missing metrics are conservatively protected.
	d4 := Evaluate(pol, nil, false, false, 50, 30*time.Minute)
	if !d4.Protected || d4.ProtectedReason != "metrics_unavailable" {
		t.Fatalf("missing metrics decision = %+v", d4)
	}
}

func TestDetectHostCapabilities(t *testing.T) {
	cap := DetectHostCapabilities()
	if cap.OS == "" || cap.Arch == "" || cap.CPUs < 1 {
		t.Fatalf("unexpected capabilities: %+v", cap)
	}
}
