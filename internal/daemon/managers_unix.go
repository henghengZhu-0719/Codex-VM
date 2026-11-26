//go:build darwin || linux

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"time"
)

type VolumeRequest struct {
	Action string `json:"action"`
	Path   string `json:"path"`
	Mode   string `json:"mode"`
}

type ProxyRequest struct {
	Action       string          `json:"action"`
	SourceID     string          `json:"source_id,omitempty"`
	HostDownload bool            `json:"host_download,omitempty"`
	Input        json.RawMessage `json:"input,omitempty"`
}

type Managers interface {
	ChangeVolume(context.Context, string, VolumeRequest) error
	NetworkStatus(context.Context) (any, error)
	NetworkQuery(context.Context, string, string) (any, error)
	ChangeProxy(context.Context, ProxyRequest) error
}

// Explicit allowlist: no shell commands, arbitrary arguments or output
// containing proxy credentials are recorded in the task journal.
func ValidateProxyRequest(in ProxyRequest) bool {
	switch in.Action {
	case "config", "import", "manual", "apply":
		if in.SourceID != "" || in.HostDownload {
			return false
		}
		raw := strings.TrimSpace(string(in.Input))
		return len(raw) > 1 && raw[0] == '{' && json.Valid(in.Input)
	case "refresh":
		return in.SourceID != "" && len(in.SourceID) <= 256 && len(in.Input) == 0
	case "delete":
		return in.SourceID != "" && len(in.SourceID) <= 256 && !in.HostDownload && len(in.Input) == 0
	case "stop", "gate-close", "probe":
		return in.SourceID == "" && !in.HostDownload && len(in.Input) == 0
	}
	return false
}

func registerManagerRoutes(mux *http.ServeMux, inventory Inventory, tasks *TaskManager) {
	manager, ok := inventory.(Managers)
	if !ok {
		return
	}
	submit := func(w http.ResponseWriter, r *http.Request, kind, target string, work func(context.Context) ([]VM, error)) {
		key, ok := readIdempotencyKey(r)
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "invalid Idempotency-Key header")
			return
		}
		t, err := tasks.SubmitTargetWithKey(kind, target, key, 10*time.Minute, work)
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
	}
	mux.HandleFunc("GET /api/v1/network/status", func(w http.ResponseWriter, r *http.Request) {
		result, err := manager.NetworkStatus(r.Context())
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "network_unavailable", "network status unavailable")
			return
		}
		writeJSON(w, http.StatusOK, result)
	})
	for _, kind := range []string{"delay", "connections"} {
		kind := kind
		mux.HandleFunc("GET /api/v1/network/"+kind, func(w http.ResponseWriter, r *http.Request) {
			node := r.URL.Query().Get("node")
			if kind == "delay" && (node == "" || len(node) > 256) {
				writeError(w, http.StatusBadRequest, "invalid_request", "node required")
				return
			}
			result, err := manager.NetworkQuery(r.Context(), kind, node)
			if err != nil {
				writeError(w, http.StatusServiceUnavailable, "network_query_unavailable", "network query unavailable")
				return
			}
			writeJSON(w, http.StatusOK, result)
		})
	}
	if tasks == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/vms/{id}/mounts", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("id")
		var in VolumeRequest
		if !namePattern.MatchString(name) || name == "base" || name == "base-building" || !decodeStrictJSON(w, r, 16384, &in) ||
			(in.Action != "add" && in.Action != "remove") || (in.Mode != "ro" && in.Mode != "rw") || !filepath.IsAbs(in.Path) {
			writeError(w, http.StatusBadRequest, "invalid_request", "invalid volume request")
			return
		}
		submit(w, r, "volume-"+in.Action, name, func(ctx context.Context) ([]VM, error) { return nil, manager.ChangeVolume(ctx, name, in) })
	})
	mux.HandleFunc("POST /api/v1/network/actions", func(w http.ResponseWriter, r *http.Request) {
		var in ProxyRequest
		if !decodeStrictJSON(w, r, 13<<20, &in) || !ValidateProxyRequest(in) {
			writeError(w, http.StatusBadRequest, "invalid_request", "invalid proxy request")
			return
		}
		submit(w, r, "proxy-"+in.Action, "@network", func(ctx context.Context) ([]VM, error) { return nil, manager.ChangeProxy(ctx, in) })
	})
}
