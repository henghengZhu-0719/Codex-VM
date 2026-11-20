// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/lima-vm/lima/v2/pkg/driver"
	"github.com/lima-vm/lima/v2/pkg/hostagent"
	"github.com/lima-vm/lima/v2/pkg/httputil"
)

type Backend struct {
	Agent *hostagent.HostAgent
}

func (b *Backend) onError(w http.ResponseWriter, err error, ec int) {
	// Set headers before WriteHeader — calling WriteHeader flushes headers.
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(ec)
	// err may potentially contain credential info (in a future version),
	// but it is safe to return the err to the client, because we do not expose the socket to the internet
	e := httputil.ErrorJSON{
		Message: err.Error(),
	}
	_ = json.NewEncoder(w).Encode(e)
}

// GetInfo is the handler for GET /v1/info.
func (b *Backend) GetInfo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	ctx := r.Context()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	info, err := b.Agent.Info(ctx)
	if err != nil {
		b.onError(w, err, http.StatusInternalServerError)
		return
	}
	m, err := json.Marshal(info)
	if err != nil {
		b.onError(w, err, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(m)
}

// GetScreenshot is the handler for GET /v1/screenshot.
func (b *Backend) GetScreenshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	ctx := r.Context()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	format := strings.ToLower(r.URL.Query().Get("format"))
	if format == "" {
		format = "png"
	}
	if format != "png" && format != "bmp" {
		b.onError(w, fmt.Errorf("unsupported format %q: must be png or bmp", format), http.StatusBadRequest)
		return
	}
	data, err := b.Agent.Screenshot(ctx, format)
	if err != nil {
		ec := http.StatusInternalServerError
		switch {
		case errors.Is(err, driver.ErrDriverNotScreenshotter):
			ec = http.StatusNotImplemented
		case errors.Is(err, driver.ErrNoDisplay):
			ec = http.StatusUnprocessableEntity
		}
		b.onError(w, err, ec)
		return
	}
	ct := "image/png"
	if format == "bmp" {
		ct = "image/bmp"
	}
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// HandleMemoryBalloon is the handler for GET/POST /v1/memory/balloon.
func (b *Backend) HandleMemoryBalloon(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	switch r.Method {
	case http.MethodGet:
		info, err := b.Agent.GetMemoryBalloon(ctx)
		if err != nil {
			ec := http.StatusInternalServerError
			if errors.Is(err, driver.ErrDriverNotMemoryBallooner) {
				ec = http.StatusNotImplemented
			}
			b.onError(w, err, ec)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(info)
	case http.MethodPost:
		var req struct {
			TargetBytes uint64 `json:"targetBytes"`
			TargetMB    uint64 `json:"targetMB"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
			b.onError(w, fmt.Errorf("invalid JSON body: %w", err), http.StatusBadRequest)
			return
		}
		target := req.TargetBytes
		if target == 0 && req.TargetMB > 0 {
			target = req.TargetMB * 1024 * 1024
		}
		info, err := b.Agent.SetMemoryBalloon(ctx, target)
		if err != nil {
			ec := http.StatusInternalServerError
			if errors.Is(err, driver.ErrDriverNotMemoryBallooner) {
				ec = http.StatusNotImplemented
			}
			b.onError(w, err, ec)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(info)
	default:
		w.Header().Set("Allow", "GET, POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func AddRoutes(r *http.ServeMux, b *Backend) {
	r.Handle("/v1/info", http.HandlerFunc(b.GetInfo))
	r.Handle("/v1/screenshot", http.HandlerFunc(b.GetScreenshot))
	r.Handle("/v1/memory/balloon", http.HandlerFunc(b.HandleMemoryBalloon))
}
