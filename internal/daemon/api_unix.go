//go:build darwin || linux

package daemon

import (
	"encoding/json"
	"io"
	"net/http"
	"regexp"
)

const APIVersion = "1"

var idempotencyKeyPattern = regexp.MustCompile(`^[a-zA-Z0-9._:-]{1,128}$`)

// APIError is the unified error payload returned by all daemon HTTP endpoints.
// Keeping top-level "error" preserves compatibility with simple string-error clients.
type APIError struct {
	Code  string `json:"code"`
	Error string `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Agent-VM-API-Version", APIVersion)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, APIError{Code: code, Error: message})
}

func decodeStrictJSON(w http.ResponseWriter, r *http.Request, limit int64, out any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(out); err != nil {
		return false
	}
	return dec.Decode(new(any)) == io.EOF
}

// readIdempotencyKey validates an optional Idempotency-Key header.
// Returns (key, true) when absent or valid, and ("", false) when malformed.
func readIdempotencyKey(r *http.Request) (string, bool) {
	key := r.Header.Get("Idempotency-Key")
	if key == "" {
		return "", true
	}
	if !idempotencyKeyPattern.MatchString(key) {
		return "", false
	}
	return key, true
}
