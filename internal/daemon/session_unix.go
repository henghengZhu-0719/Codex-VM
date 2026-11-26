//go:build darwin || linux

package daemon

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/sylvinus/agent-vm/internal/session"
)

type SessionRequest struct {
	Name  string `json:"name"`
	Agent string `json:"agent"`
}

type SessionManager interface {
	Sessions(context.Context, string) ([]session.Session, error)
	SessionTools(context.Context, string) (session.Tools, error)
	ChangeSession(context.Context, string, string, SessionRequest) error
}

func registerSessionRoutes(mux *http.ServeMux, inventory Inventory, tasks *TaskManager) {
	manager, ok := inventory.(SessionManager)
	if !ok {
		return
	}
	mux.HandleFunc("GET /api/v1/vms/{id}/sessions", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		result, err := manager.Sessions(r.Context(), name)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "sessions_unavailable", "session inventory unavailable")
			return
		}
		writeJSON(w, http.StatusOK, result)
	})
	mux.HandleFunc("GET /api/v1/vms/{id}/sessions/tools", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		if !namePattern.MatchString(name) {
			writeError(w, http.StatusBadRequest, "invalid_vm_name", "invalid VM name")
			return
		}
		result, err := manager.SessionTools(r.Context(), name)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "tools_unavailable", "tools unavailable")
			return
		}
		writeJSON(w, http.StatusOK, result)
	})
	if tasks == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/vms/{id}/sessions/install-tmux", func(w http.ResponseWriter, r *http.Request) {
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
		t, err := tasks.SubmitTargetWithKey("session-install-tmux", name, key, 5*time.Minute, func(ctx context.Context) ([]VM, error) {
			return nil, manager.ChangeSession(ctx, name, "install-tmux", SessionRequest{})
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
	for _, action := range []string{"create", "stop"} {
		action := action
		mux.HandleFunc("POST /api/v1/vms/{id}/sessions/"+action, func(w http.ResponseWriter, r *http.Request) {
			name := r.PathValue("id")
			key, ok := readIdempotencyKey(r)
			if !ok {
				writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
				return
			}
			var in SessionRequest
			if !namePattern.MatchString(name) || !decodeStrictJSON(w, r, 4096, &in) || !session.ValidName(in.Name) ||
				(action == "create" && !session.ValidAgent(in.Agent)) || (action == "stop" && in.Agent != "") {
				writeError(w, http.StatusBadRequest, "invalid_request", "invalid session request")
				return
			}
			t, err := tasks.SubmitTargetWithKey("session-"+action, name, key, time.Minute, func(ctx context.Context) ([]VM, error) {
				return nil, manager.ChangeSession(ctx, name, action, in)
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
