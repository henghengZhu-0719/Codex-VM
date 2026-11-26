//go:build darwin || linux

package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"testing"
	"time"
)

func TestDaemonPolicyAPIAndRecovery(t *testing.T) {
	dir := t.TempDir()
	fb := newFakeBackend()
	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	h := handler(fb, tm, nil, dir)

	// Default policy is manual.
	r1 := doReq(h, http.MethodGet, "/api/v1/daemon/policy", nil, nil)
	if r1.Code != http.StatusOK {
		t.Fatalf("GET policy = %d", r1.Code)
	}
	var got DaemonPolicy
	if err := json.Unmarshal(r1.Body.Bytes(), &got); err != nil || got.DefaultStartupPolicy != PolicyManual {
		t.Fatalf("default policy = %+v, err=%v", got, err)
	}

	// Update policy to restore_last with per-VM auto_start.
	want := DaemonPolicy{
		Version:               1,
		DefaultStartupPolicy:  PolicyRestoreLast,
		VMStartupPolicies:     map[string]string{"dev-1234": PolicyAutoStart},
		MaxRetries:            3,
		RetryWindowSeconds:    900,
		InitialBackoffSeconds: 15,
	}
	r2 := doReq(h, http.MethodPut, "/api/v1/daemon/policy", want, nil)
	if r2.Code != http.StatusOK {
		t.Fatalf("PUT policy = %d: %s", r2.Code, r2.Body.String())
	}

	// Reject invalid policy.
	bad := want
	bad.DefaultStartupPolicy = "invalid"
	r3 := doReq(h, http.MethodPut, "/api/v1/daemon/policy", bad, nil)
	if r3.Code != http.StatusBadRequest {
		t.Fatalf("bad PUT policy = %d, want 400", r3.Code)
	}

	// Corrupt primary daemon.json and verify recovery from .bak.
	want.MaxRetries = 2
	_ = SaveDaemonPolicy(dir, want) // creates .bak from previous valid save
	_ = os.WriteFile(PolicyPath(dir), []byte("{corrupt"), 0600)
	recovered := LoadDaemonPolicy(dir)
	if recovered.DefaultStartupPolicy != PolicyRestoreLast {
		t.Fatalf("recovered policy = %+v, want restore_last from backup", recovered)
	}
}

func TestReconcileStartupPolicies(t *testing.T) {
	dir := t.TempDir()
	fb := newFakeBackend()
	fb.vms["vm-manual"] = VM{Name: "vm-manual", Status: "Stopped"}
	fb.vms["vm-auto"] = VM{Name: "vm-auto", Status: "Stopped"}
	fb.vms["vm-restore"] = VM{Name: "vm-restore", Status: "Stopped"}

	// Seed previous running state containing only vm-restore.
	if err := SaveVMState(dir, []VM{{Name: "vm-restore", Status: "Running"}}); err != nil {
		t.Fatal(err)
	}
	pol := DefaultDaemonPolicy()
	pol.DefaultStartupPolicy = PolicyManual
	pol.VMStartupPolicies = map[string]string{
		"vm-auto":    PolicyAutoStart,
		"vm-restore": PolicyRestoreLast,
	}
	if err := SaveDaemonPolicy(dir, pol); err != nil {
		t.Fatal(err)
	}

	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())

	ReconcileStartup(context.Background(), dir, fb, tm)

	// Wait for tasks to finish.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		vAuto, _ := fb.Get(context.Background(), "vm-auto")
		vRestore, _ := fb.Get(context.Background(), "vm-restore")
		if vAuto.Status == "Running" && vRestore.Status == "Running" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	vManual, _ := fb.Get(context.Background(), "vm-manual")
	vAuto, _ := fb.Get(context.Background(), "vm-auto")
	vRestore, _ := fb.Get(context.Background(), "vm-restore")
	if vManual.Status != "Stopped" {
		t.Fatalf("vm-manual should remain Stopped, got %s", vManual.Status)
	}
	if vAuto.Status != "Running" {
		t.Fatalf("vm-auto should be Running, got %s", vAuto.Status)
	}
	if vRestore.Status != "Running" {
		t.Fatalf("vm-restore should be Running, got %s", vRestore.Status)
	}
}

func TestRetryTrackerExponentialBackoff(t *testing.T) {
	rt := NewRetryTracker()
	pol := DefaultDaemonPolicy() // MaxRetries=3, InitialBackoff=15s, Window=900s
	now := time.Now()

	ok1, d1 := rt.RecordFailure("dev-1", pol, now)
	ok2, d2 := rt.RecordFailure("dev-1", pol, now.Add(time.Minute))
	ok3, d3 := rt.RecordFailure("dev-1", pol, now.Add(2*time.Minute))
	ok4, _ := rt.RecordFailure("dev-1", pol, now.Add(3*time.Minute))

	if !ok1 || d1 != 15*time.Second || !ok2 || d2 != 30*time.Second || !ok3 || d3 != 60*time.Second {
		t.Fatalf("unexpected backoff sequence: (%v,%v) (%v,%v) (%v,%v)", ok1, d1, ok2, d2, ok3, d3)
	}
	if ok4 {
		t.Fatalf("4th failure within window should exceed MaxRetries=3")
	}

	rt.Reset("dev-1")
	okAfterReset, dAfterReset := rt.RecordFailure("dev-1", pol, now.Add(4*time.Minute))
	if !okAfterReset || dAfterReset != 15*time.Second {
		t.Fatalf("after Reset expected fresh backoff, got (%v, %v)", okAfterReset, dAfterReset)
	}
}
