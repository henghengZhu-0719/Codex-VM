//go:build darwin || linux

package daemon

import (
	"context"
	"net/http"

	"github.com/sylvinus/agent-vm/internal/resource"
)

type ResourceStatus struct {
	VM               VM                `json:"vm"`
	Guest            *resource.Metrics `json:"guest,omitempty"`
	Balloon          *resource.Balloon `json:"balloon,omitempty"`
	GuestAvailable   bool              `json:"guest_available"`
	BalloonAvailable bool              `json:"balloon_available"`
}

type ResourceManager interface {
	ResourceStatus(context.Context, string) (ResourceStatus, error)
}

func registerResourceRoutes(mux *http.ServeMux, inventory Inventory, stateDir string) {
	mux.HandleFunc("GET /api/v1/host/capabilities", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, resource.DetectHostCapabilities())
	})
	if stateDir != "" {
		mux.HandleFunc("GET /api/v1/resource/policy", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, http.StatusOK, resource.LoadPolicy(stateDir))
		})
		mux.HandleFunc("PUT /api/v1/resource/policy", func(w http.ResponseWriter, r *http.Request) {
			var in resource.Policy
			if !decodeStrictJSON(w, r, 4096, &in) {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid resource policy payload")
				return
			}
			if err := resource.SavePolicy(stateDir, in); err != nil {
				writeError(w, http.StatusBadRequest, "invalid_policy", err.Error())
				return
			}
			writeJSON(w, http.StatusOK, resource.LoadPolicy(stateDir))
		})
	}
	mux.HandleFunc("GET /api/v1/vms/{id}/usage", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		manager, ok := inventory.(ResourceManager)
		if !ok {
			writeError(w, http.StatusNotImplemented, "not_implemented", "resource inspection unavailable")
			return
		}
		status, err := manager.ResourceStatus(r.Context(), name)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "resource_unavailable", "resource status unavailable")
			return
		}
		writeJSON(w, http.StatusOK, status)
	})
	mux.HandleFunc("GET /api/v1/resource/evaluate/{id}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		manager, ok := inventory.(ResourceManager)
		if !ok {
			writeError(w, http.StatusNotImplemented, "not_implemented", "resource inspection unavailable")
			return
		}
		status, err := manager.ResourceStatus(r.Context(), name)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "resource_unavailable", "resource status unavailable")
			return
		}
		hasSession := false
		if sm, ok := inventory.(SessionManager); ok {
			if sessions, serr := sm.Sessions(r.Context(), name); serr == nil && len(sessions) > 0 {
				hasSession = true
			}
		}
		browserRunning := false
		if bm, ok := inventory.(BrowserManager); ok {
			if bs, berr := bm.BrowserStatus(r.Context(), name); berr == nil && bs.Running {
				browserRunning = true
			}
		}
		pol := resource.LoadPolicy(stateDir)
		decision := resource.Evaluate(pol, status.Guest, hasSession, browserRunning, 0, 0)
		writeJSON(w, http.StatusOK, map[string]any{
			"vm":       name,
			"policy":   pol,
			"decision": decision,
		})
	})
}
