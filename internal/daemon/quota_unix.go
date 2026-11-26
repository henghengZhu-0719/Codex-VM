//go:build darwin || linux

package daemon

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/sylvinus/agent-vm/internal/quota"
)

type QuotaManager interface {
	CachedQuota(string) (quota.Snapshot, bool)
	RefreshQuota(context.Context, string) error
}

func registerQuotaRoutes(mux *http.ServeMux, inventory Inventory, tasks *TaskManager) {
	manager, ok := inventory.(QuotaManager)
	if !ok {
		return
	}
	mux.HandleFunc("GET /api/v1/vms/{id}/quotas", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		snap, ok := manager.CachedQuota(name)
		if !ok {
			writeJSON(w, http.StatusOK, map[string]any{"available": false})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"available": true, "stale": time.Since(snap.FetchedAt) > 20*time.Minute, "snapshot": snap})
	})
	if tasks == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/vms/{id}/quotas/refresh", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) || r.ContentLength != 0 {
			writeError(w, http.StatusBadRequest, "invalid_request", "invalid request")
			return
		}
		key, ok := readIdempotencyKey(r)
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
			return
		}
		t, err := tasks.SubmitTargetWithKey("quota-refresh", name, key, 90*time.Second, func(ctx context.Context) ([]VM, error) {
			return nil, manager.RefreshQuota(ctx, name)
		})
		if err != nil {
			if errors.Is(err, ErrBusy) {
				writeError(w, http.StatusConflict, "task_conflict", "task unavailable")
				return
			}
			writeError(w, http.StatusServiceUnavailable, "service_unavailable", http.StatusText(http.StatusServiceUnavailable))
			return
		}
		w.Header().Set("Location", "/api/v1/tasks/"+t.ID)
		writeJSON(w, http.StatusAccepted, t)
	})
}

// Poll at most one eligible VM per tick, avoiding a busy mutation queue.
func pollQuotas(ctx context.Context, inventory Inventory, tasks *TaskManager) {
	manager, ok := inventory.(QuotaManager)
	if !ok {
		return
	}
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	attempted := map[string]time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		snapshot, _ := tasks.Snapshot()
		busy := false
		for _, t := range snapshot {
			if t.Status == "queued" || t.Status == "running" {
				busy = true
				break
			}
		}
		if busy {
			continue
		}
		sample, cancel := context.WithTimeout(ctx, 10*time.Second)
		vms, err := inventory.List(sample)
		cancel()
		if err != nil {
			continue
		}
		present := map[string]bool{}
		for _, v := range vms {
			present[v.Name] = true
		}
		for name := range attempted {
			if !present[name] {
				delete(attempted, name)
			}
		}
		for _, v := range vms {
			if v.Status != "Running" || v.Name == "base" || v.Name == "base-building" || !namePattern.MatchString(v.Name) {
				continue
			}
			if time.Since(attempted[v.Name]) < 20*time.Minute {
				continue
			}
			if snap, ok := manager.CachedQuota(v.Name); ok && time.Since(snap.FetchedAt) < 20*time.Minute {
				continue
			}
			name := v.Name
			if _, err := tasks.SubmitTarget("quota-refresh", name, 90*time.Second, func(ctx context.Context) ([]VM, error) {
				return nil, manager.RefreshQuota(ctx, name)
			}); err == nil {
				attempted[name] = time.Now()
			}
			break
		}
	}
}
