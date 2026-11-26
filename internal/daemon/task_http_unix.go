//go:build darwin || linux

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/sylvinus/agent-vm/internal/remote"
)

// HostManager optionally exposes local registry of remote hosts (no credentials).
type HostManager interface {
	ListHosts(context.Context) ([]remote.Host, error)
	UpsertHost(context.Context, remote.Host) (remote.Host, error)
	RemoveHost(context.Context, string) error
}

func registerHostRoutes(mux *http.ServeMux, inventory Inventory) {
	mgr, ok := inventory.(HostManager)
	if !ok {
		return
	}
	mux.HandleFunc("GET /api/v1/hosts", func(w http.ResponseWriter, r *http.Request) {
		hosts, err := mgr.ListHosts(r.Context())
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "hosts_unavailable", "host inventory unavailable")
			return
		}
		if hosts == nil {
			hosts = []remote.Host{}
		}
		writeJSON(w, http.StatusOK, hosts)
	})
	mux.HandleFunc("POST /api/v1/hosts", func(w http.ResponseWriter, r *http.Request) {
		var in remote.Host
		if !decodeStrictJSON(w, r, 4096, &in) {
			writeError(w, http.StatusBadRequest, "invalid_request", "invalid host payload")
			return
		}
		saved, err := mgr.UpsertHost(r.Context(), in)
		if err != nil {
			if errors.Is(err, remote.ErrInvalid) {
				writeError(w, http.StatusBadRequest, "invalid_host", err.Error())
				return
			}
			writeError(w, http.StatusServiceUnavailable, "host_save_failed", "failed to save host")
			return
		}
		writeJSON(w, http.StatusOK, saved)
	})
	mux.HandleFunc("DELETE /api/v1/hosts/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if r.ContentLength != 0 {
			writeError(w, http.StatusBadRequest, "invalid_request", "request body not supported")
			return
		}
		err := mgr.RemoveHost(r.Context(), name)
		if err != nil {
			switch {
			case errors.Is(err, remote.ErrInvalid):
				writeError(w, http.StatusBadRequest, "invalid_host", err.Error())
			case errors.Is(err, remote.ErrNotFound):
				writeError(w, http.StatusNotFound, "not_found", "host not found")
			default:
				writeError(w, http.StatusServiceUnavailable, "host_delete_failed", "failed to remove host")
			}
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "deleted", "name": name})
	})
}

func registerTaskRoutes(mux *http.ServeMux, inventory Inventory, tasks *TaskManager, shutdown <-chan struct{}) {
	mux.HandleFunc("POST /api/v1/tasks/inventory", func(w http.ResponseWriter, r *http.Request) {
		// This endpoint accepts no input and cannot execute arbitrary commands.
		if r.ContentLength != 0 {
			writeError(w, http.StatusBadRequest, "invalid_request", "request body not supported")
			return
		}
		key, ok := readIdempotencyKey(r)
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
			return
		}
		t, err := tasks.SubmitTargetWithKey("inventory", "", key, 2*time.Minute, inventory.List)
		if err != nil {
			if errors.Is(err, ErrBusy) {
				writeError(w, http.StatusTooManyRequests, "queue_busy", http.StatusText(http.StatusTooManyRequests))
				return
			}
			writeError(w, http.StatusServiceUnavailable, "service_unavailable", http.StatusText(http.StatusServiceUnavailable))
			return
		}
		w.Header().Set("Location", "/api/v1/tasks/"+t.ID)
		writeJSON(w, http.StatusAccepted, t)
	})

	if lifecycle, ok := inventory.(Lifecycle); ok {
		for _, action := range []string{"start", "stop"} {
			action := action
			mux.HandleFunc("POST /api/v1/vms/{id}/"+action, func(w http.ResponseWriter, r *http.Request) {
				name := r.PathValue("id")
				if !namePattern.MatchString(name) || name == "base" || name == "base-building" || r.ContentLength != 0 {
					writeError(w, http.StatusBadRequest, "invalid_request", "invalid VM or request body")
					return
				}
				key, ok := readIdempotencyKey(r)
				if !ok {
					writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
					return
				}
				t, err := tasks.SubmitTargetWithKey("vm-"+action, name, key, 10*time.Minute, func(ctx context.Context) ([]VM, error) {
					v, err := lifecycle.Change(ctx, name, action)
					if err != nil {
						return nil, err
					}
					return []VM{v}, nil
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

	// Pause/resume endpoints are explicitly defined by the v1 contract.
	// Until the hypervisor backend exposes true suspend/resume, return 501.
	for _, action := range []string{"pause", "resume"} {
		action := action
		mux.HandleFunc("POST /api/v1/vms/{id}/"+action, func(w http.ResponseWriter, r *http.Request) {
			name := r.PathValue("id")
			if !namePattern.MatchString(name) || name == "base" || name == "base-building" || r.ContentLength != 0 {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid VM or request body")
				return
			}
			writeError(w, http.StatusNotImplemented, "not_implemented", "VM "+action+" is not supported by the current backend")
		})
	}

	if creator, ok := inventory.(Creator); ok {
		mux.HandleFunc("POST /api/v1/vms", func(w http.ResponseWriter, r *http.Request) {
			key, ok := readIdempotencyKey(r)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
				return
			}
			var input CreateRequest
			if !decodeStrictJSON(w, r, 8192, &input) {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid create request")
				return
			}
			input, name, err := creator.ResolveCreate(input)
			if err != nil || !namePattern.MatchString(name) {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid project or resource settings")
				return
			}
			t, err := tasks.SubmitTargetWithKey("vm-create", name, key, 15*time.Minute, func(ctx context.Context) ([]VM, error) {
				v, err := creator.Create(ctx, input, name)
				if err != nil {
					return nil, err
				}
				return []VM{v}, nil
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

	if lifecycle, ok := inventory.(Lifecycle); ok {
		mux.HandleFunc("DELETE /api/v1/vms/{id}", func(w http.ResponseWriter, r *http.Request) {
			name := r.PathValue("id")
			if !namePattern.MatchString(name) || name == "base" || name == "base-building" || r.ContentLength != 0 || r.URL.Query().Get("confirm") != name {
				writeError(w, http.StatusBadRequest, "confirmation_required", "explicit VM name confirmation required")
				return
			}
			key, ok := readIdempotencyKey(r)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
				return
			}
			t, err := tasks.SubmitTargetWithKey("vm-delete", name, key, 10*time.Minute, func(ctx context.Context) ([]VM, error) {
				v, err := lifecycle.Change(ctx, name, "delete")
				if err != nil {
					return nil, err
				}
				return []VM{v}, nil
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

	mux.HandleFunc("GET /api/v1/tasks", func(w http.ResponseWriter, r *http.Request) {
		snapshot, _ := tasks.Snapshot()
		writeJSON(w, http.StatusOK, snapshot)
	})
	mux.HandleFunc("GET /api/v1/tasks/{id}", func(w http.ResponseWriter, r *http.Request) {
		t, ok := tasks.Get(r.PathValue("id"))
		if !ok {
			writeError(w, http.StatusNotFound, "not_found", "task not found")
			return
		}
		writeJSON(w, http.StatusOK, t)
	})
	mux.HandleFunc("POST /api/v1/tasks/{id}/cancel", func(w http.ResponseWriter, r *http.Request) {
		if r.ContentLength != 0 {
			writeError(w, http.StatusBadRequest, "invalid_request", "request body not supported")
			return
		}
		t, err := tasks.Cancel(r.PathValue("id"))
		if err != nil {
			switch {
			case errors.Is(err, ErrNotFound):
				writeError(w, http.StatusNotFound, "not_found", "task not found")
			case errors.Is(err, ErrNotCancellable):
				writeError(w, http.StatusConflict, "not_cancellable", "task is already finished")
			default:
				writeError(w, http.StatusServiceUnavailable, "cancel_failed", "unable to cancel task")
			}
			return
		}
		writeJSON(w, http.StatusOK, t)
	})

	slots := make(chan struct{}, 8)
	mux.HandleFunc("GET /api/v1/events", func(w http.ResponseWriter, r *http.Request) {
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			writeError(w, http.StatusTooManyRequests, "stream_limit_reached", "event stream limit reached")
			return
		}
		controller := http.NewResponseController(w)
		if err := controller.SetWriteDeadline(time.Time{}); err != nil && !errors.Is(err, http.ErrNotSupported) {
			writeError(w, http.StatusInternalServerError, "streaming_unavailable", "streaming unavailable")
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache, no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Agent-VM-API-Version", APIVersion)
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			snapshot, changed := tasks.Snapshot()
			data, err := json.Marshal(snapshot)
			if err != nil {
				return
			}
			if err := controller.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return
			}
			if _, err = fmt.Fprintf(w, "event: tasks\ndata: %s\n\n", data); err != nil {
				return
			}
			if controller.Flush() != nil {
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-shutdown:
				return
			case <-changed:
			case <-ticker.C:
			}
		}
	})
}
