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

func registerResourceRoutes(mux *http.ServeMux, inventory Inventory) {
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
}
