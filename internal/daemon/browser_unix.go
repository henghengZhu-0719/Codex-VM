//go:build darwin || linux

package daemon

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/sylvinus/agent-vm/internal/browser"
)

type BrowserManager interface {
	BrowserStatus(context.Context, string) (browser.Status, error)
	BrowserChange(context.Context, string, string, browser.Settings) error
}

func registerBrowserRoutes(mux *http.ServeMux, inventory Inventory, tasks *TaskManager) {
	manager, ok := inventory.(BrowserManager)
	if !ok {
		return
	}
	mux.HandleFunc("GET /api/v1/vms/{id}/browser", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		result, err := manager.BrowserStatus(r.Context(), name)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "browser_unavailable", "browser status unavailable")
			return
		}
		writeJSON(w, http.StatusOK, result)
	})
	if tasks == nil {
		return
	}
	for _, action := range []string{"start", "stop", "restart"} {
		action := action
		mux.HandleFunc("POST /api/v1/vms/{id}/browser/"+action, func(w http.ResponseWriter, r *http.Request) {
			name := r.PathValue("id")
			if !namePattern.MatchString(name) || name == "base" || name == "base-building" {
				writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
				return
			}
			key, ok := readIdempotencyKey(r)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
				return
			}
			var in browser.Settings
			if r.ContentLength != 0 {
				if !decodeStrictJSON(w, r, 4096, &in) {
					writeError(w, http.StatusBadRequest, "invalid_request", "invalid settings")
					return
				}
			}
			if in.Width < 0 || in.Width > 4096 || in.Height < 0 || in.Height > 2560 || in.Scale < 0 || in.Scale > 2 {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid dimensions")
				return
			}
			t, err := tasks.SubmitTargetWithKey("browser-"+action, name, key, 2*time.Minute, func(ctx context.Context) ([]VM, error) {
				return nil, manager.BrowserChange(ctx, name, action, in)
			})
			if err != nil {
				if errors.Is(err, ErrBusy) {
					writeError(w, http.StatusConflict, "task_conflict", http.StatusText(http.StatusConflict))
					return
				}
				writeError(w, http.StatusServiceUnavailable, "service_unavailable", http.StatusText(http.StatusServiceUnavailable))
				return
			}
			w.Header().Set("Location", "/api/v1/tasks/"+t.ID)
			writeJSON(w, http.StatusAccepted, t)
		})
	}
}
