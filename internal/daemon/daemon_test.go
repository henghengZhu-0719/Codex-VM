//go:build darwin || linux

package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/browser"
	"github.com/sylvinus/agent-vm/internal/quota"
	"github.com/sylvinus/agent-vm/internal/remote"
	"github.com/sylvinus/agent-vm/internal/resource"
	"github.com/sylvinus/agent-vm/internal/session"
)

type fakeBackend struct {
	mu           sync.Mutex
	vms          map[string]VM
	hosts        map[string]remote.Host
	quotas       map[string]quota.Snapshot
	changeHook   func(ctx context.Context, name, action string) (VM, error)
	changeCalls  atomic.Int32
	volumeCalls  atomic.Int32
	proxyCalls   atomic.Int32
	browserCalls atomic.Int32
	sessionCalls atomic.Int32
}

func newFakeBackend() *fakeBackend {
	return &fakeBackend{
		vms: map[string]VM{
			"dev-1234": {Name: "dev-1234", Status: "Stopped", CPUs: 4, Memory: 8 << 30, Disk: 40 << 30},
		},
		hosts:  map[string]remote.Host{},
		quotas: map[string]quota.Snapshot{},
	}
}

func (f *fakeBackend) List(ctx context.Context) ([]VM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]VM, 0, len(f.vms))
	for _, v := range f.vms {
		out = append(out, v)
	}
	return out, nil
}

func (f *fakeBackend) Get(ctx context.Context, name string) (VM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	v, ok := f.vms[name]
	if !ok {
		return VM{}, ErrNotFound
	}
	return v, nil
}

func (f *fakeBackend) Mounts(ctx context.Context, name string) (any, error) {
	if _, err := f.Get(ctx, name); err != nil {
		return nil, err
	}
	return []map[string]any{{"location": "/tmp/project", "writable": true}}, nil
}

func (f *fakeBackend) Change(ctx context.Context, name, action string) (VM, error) {
	f.changeCalls.Add(1)
	if f.changeHook != nil {
		return f.changeHook(ctx, name, action)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	v, ok := f.vms[name]
	if !ok {
		return VM{}, ErrNotFound
	}
	switch action {
	case "start":
		v.Status = "Running"
		f.vms[name] = v
	case "stop":
		v.Status = "Stopped"
		f.vms[name] = v
	case "delete":
		delete(f.vms, name)
		return VM{Name: name, Status: "Deleted"}, nil
	}
	return v, nil
}

func (f *fakeBackend) ResolveCreate(in CreateRequest) (CreateRequest, string, error) {
	if !filepath.IsAbs(in.Project) {
		return in, "", errors.New("project must be absolute")
	}
	return in, "proj-abcd", nil
}

func (f *fakeBackend) Create(ctx context.Context, in CreateRequest, name string) (VM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	v := VM{Name: name, Status: "Running", CPUs: max(1, in.CPUs), Memory: 4 << 30, Disk: 20 << 30}
	f.vms[name] = v
	return v, nil
}

func (f *fakeBackend) ChangeVolume(ctx context.Context, name string, req VolumeRequest) error {
	f.volumeCalls.Add(1)
	return nil
}

func (f *fakeBackend) NetworkStatus(ctx context.Context) (any, error) {
	return map[string]any{"proxy_mode": "managed", "running": true, "gate_count": 1}, nil
}

func (f *fakeBackend) NetworkQuery(ctx context.Context, kind, node string) (any, error) {
	if kind == "delay" {
		return map[string]any{"node": node, "delay_ms": 42}, nil
	}
	return map[string]any{"upload_total": 100, "download_total": 200, "connection_count": 2}, nil
}

func (f *fakeBackend) ChangeProxy(ctx context.Context, req ProxyRequest) error {
	f.proxyCalls.Add(1)
	return nil
}

func (f *fakeBackend) BrowserStatus(ctx context.Context, name string) (browser.Status, error) {
	return browser.Status{Installed: true, Running: true, PID: 123, TreeRSSMB: 256, CDPAvailable: true}, nil
}

func (f *fakeBackend) BrowserChange(ctx context.Context, name, action string, s browser.Settings) error {
	f.browserCalls.Add(1)
	return nil
}

func (f *fakeBackend) ResourceStatus(ctx context.Context, name string) (ResourceStatus, error) {
	v, err := f.Get(ctx, name)
	if err != nil {
		return ResourceStatus{}, err
	}
	return ResourceStatus{
		VM:             v,
		Guest:          &resource.Metrics{CPUPercent: 1.5, MemoryTotalBytes: 8 << 30, MemoryAvailableBytes: 6 << 30},
		GuestAvailable: true,
	}, nil
}

func (f *fakeBackend) Sessions(ctx context.Context, name string) ([]session.Session, error) {
	return []session.Session{{Name: "work", Agent: "codex", Attached: 0}}, nil
}

func (f *fakeBackend) SessionTools(ctx context.Context, name string) (session.Tools, error) {
	return session.Tools{Tmux: true, Agents: map[string]session.ToolStatus{"codex": {Installed: true, LoginHint: "credential_file_present"}}}, nil
}

func (f *fakeBackend) ChangeSession(ctx context.Context, name, action string, req SessionRequest) error {
	f.sessionCalls.Add(1)
	return nil
}

func (f *fakeBackend) CachedQuota(name string) (quota.Snapshot, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	s, ok := f.quotas[name]
	return s, ok
}

func (f *fakeBackend) RefreshQuota(ctx context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.quotas[name] = quota.Snapshot{FetchedAt: time.Now().UTC(), Agents: map[string]quota.Agent{"codex": {Status: "ok"}}}
	return nil
}

func (f *fakeBackend) ListHosts(ctx context.Context) ([]remote.Host, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]remote.Host, 0, len(f.hosts))
	for _, h := range f.hosts {
		out = append(out, h)
	}
	return out, nil
}

func (f *fakeBackend) UpsertHost(ctx context.Context, h remote.Host) (remote.Host, error) {
	if err := remote.Validate(h); err != nil {
		return remote.Host{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hosts[h.Name] = h
	return h, nil
}

func (f *fakeBackend) RemoveHost(ctx context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.hosts[name]; !ok {
		return remote.ErrNotFound
	}
	delete(f.hosts, name)
	return nil
}

func doReq(h http.Handler, method, path string, body any, headers map[string]string) *httptest.ResponseRecorder {
	var rBody *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rBody = bytes.NewReader(b)
	} else {
		rBody = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, "http://agent-vm"+path, rBody)
	req.Host = "agent-vm"
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func waitTaskStatus(t *testing.T, tm *TaskManager, id, want string) Task {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		task, ok := tm.Get(id)
		if ok && task.Status == want {
			return task
		}
		time.Sleep(15 * time.Millisecond)
	}
	got, _ := tm.Get(id)
	t.Fatalf("task %s status = %q, want %q (error=%q)", id, got.Status, want, got.Error)
	return Task{}
}

func TestSecurityHeadersAndUnifiedErrorFormat(t *testing.T) {
	fb := newFakeBackend()
	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	h := handler(fb, tm, nil, "")

	// Reject Origin header (no browser CORS).
	rec := doReq(h, http.MethodGet, "/health", nil, map[string]string{"Origin": "https://evil.example"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("Origin status = %d, want 403", rec.Code)
	}
	var apiErr APIError
	if err := json.Unmarshal(rec.Body.Bytes(), &apiErr); err != nil || apiErr.Code != "forbidden" || apiErr.Error == "" {
		t.Fatalf("unexpected error payload: %s", rec.Body.String())
	}

	// Reject wrong Host header.
	req := httptest.NewRequest(http.MethodGet, "http://localhost/health", nil)
	req.Host = "localhost"
	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req)
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("bad Host status = %d, want 403", rec2.Code)
	}

	// Valid health check includes API version header.
	rec3 := doReq(h, http.MethodGet, "/health", nil, nil)
	if rec3.Code != http.StatusOK || rec3.Header().Get("X-Agent-VM-API-Version") != "1" {
		t.Fatalf("health = %d, version=%q", rec3.Code, rec3.Header().Get("X-Agent-VM-API-Version"))
	}

	// Pause/resume return explicit 501.
	for _, action := range []string{"pause", "resume"} {
		r := doReq(h, http.MethodPost, "/api/v1/vms/dev-1234/"+action, nil, nil)
		if r.Code != http.StatusNotImplemented {
			t.Fatalf("%s status = %d, want 501", action, r.Code)
		}
	}
}

func TestTaskIdempotencyAndCancellation(t *testing.T) {
	fb := newFakeBackend()
	started := make(chan struct{})
	release := make(chan struct{})
	fb.changeHook = func(ctx context.Context, name, action string) (VM, error) {
		if action == "start" {
			close(started)
			select {
			case <-ctx.Done():
				return VM{}, ctx.Err()
			case <-release:
				return VM{Name: name, Status: "Running"}, nil
			}
		}
		return VM{Name: name, Status: "Stopped"}, nil
	}

	tm, err := NewTaskManager(context.Background(), filepath.Join(t.TempDir(), "tasks.json"))
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	h := handler(fb, tm, nil, "")

	// Submit with Idempotency-Key.
	r1 := doReq(h, http.MethodPost, "/api/v1/vms/dev-1234/start", nil, map[string]string{"Idempotency-Key": "req-001"})
	if r1.Code != http.StatusAccepted {
		t.Fatalf("start status = %d: %s", r1.Code, r1.Body.String())
	}
	var t1 Task
	if err := json.Unmarshal(r1.Body.Bytes(), &t1); err != nil {
		t.Fatal(err)
	}
	<-started

	// Same Idempotency-Key returns same task instead of 409 conflict.
	r2 := doReq(h, http.MethodPost, "/api/v1/vms/dev-1234/start", nil, map[string]string{"Idempotency-Key": "req-001"})
	if r2.Code != http.StatusAccepted {
		t.Fatalf("idempotent replay status = %d, want 202", r2.Code)
	}
	var t2 Task
	_ = json.Unmarshal(r2.Body.Bytes(), &t2)
	if t2.ID != t1.ID {
		t.Fatalf("idempotent replay returned different task ID: %s vs %s", t2.ID, t1.ID)
	}

	// Different request for same target returns 409 Conflict.
	rConflict := doReq(h, http.MethodPost, "/api/v1/vms/dev-1234/stop", nil, nil)
	if rConflict.Code != http.StatusConflict {
		t.Fatalf("conflict status = %d, want 409", rConflict.Code)
	}

	// Enqueue a second task (inventory) while worker is busy, then cancel it while queued.
	rQueued := doReq(h, http.MethodPost, "/api/v1/tasks/inventory", nil, nil)
	if rQueued.Code != http.StatusAccepted {
		t.Fatalf("queued inventory status = %d", rQueued.Code)
	}
	var tQueued Task
	_ = json.Unmarshal(rQueued.Body.Bytes(), &tQueued)

	rCancelQueued := doReq(h, http.MethodPost, "/api/v1/tasks/"+tQueued.ID+"/cancel", nil, nil)
	if rCancelQueued.Code != http.StatusOK {
		t.Fatalf("cancel queued status = %d: %s", rCancelQueued.Code, rCancelQueued.Body.String())
	}
	waitTaskStatus(t, tm, tQueued.ID, "cancelled")

	// Cancel the running task.
	rCancelRunning := doReq(h, http.MethodPost, "/api/v1/tasks/"+t1.ID+"/cancel", nil, nil)
	if rCancelRunning.Code != http.StatusOK {
		t.Fatalf("cancel running status = %d: %s", rCancelRunning.Code, rCancelRunning.Body.String())
	}
	waitTaskStatus(t, tm, t1.ID, "cancelled")

	// Cancelling an already finished task returns 409.
	rCancelAgain := doReq(h, http.MethodPost, "/api/v1/tasks/"+t1.ID+"/cancel", nil, nil)
	if rCancelAgain.Code != http.StatusConflict {
		t.Fatalf("cancel finished status = %d, want 409", rCancelAgain.Code)
	}
}

func TestTaskPersistenceAndCorruptRecovery(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tasks.json")

	// 1. Seed a queued task directly in tasks.json, verify restart marks it interrupted.
	seed := map[string]Task{
		"t1": {ID: "t1", Kind: "vm-start", Target: "dev-1234", Status: "running", CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()},
	}
	raw, _ := json.Marshal(seed)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	tm1, err := NewTaskManager(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := tm1.Get("t1")
	if !ok || got.Status != "interrupted" {
		t.Fatalf("recovered task = %+v (ok=%v), want interrupted", got, ok)
	}
	_ = tm1.Close(context.Background())

	// 2. Corrupt primary tasks.json; should recover from tasks.json.bak.
	if err := os.WriteFile(path, []byte("{corrupt json"), 0600); err != nil {
		t.Fatal(err)
	}
	tm2, err := NewTaskManager(context.Background(), path)
	if err != nil {
		t.Fatalf("recovery from backup failed: %v", err)
	}
	if _, ok := tm2.Get("t1"); !ok {
		t.Fatalf("expected t1 to be recovered from .bak")
	}
	_ = tm2.Close(context.Background())

	// 3. Corrupt both primary and backup; should start cleanly without crashing.
	_ = os.WriteFile(path, []byte("{corrupt"), 0600)
	_ = os.WriteFile(path+".bak", []byte("{also corrupt"), 0600)
	tm3, err := NewTaskManager(context.Background(), path)
	if err != nil {
		t.Fatalf("clean boot after double corruption failed: %v", err)
	}
	snap, _ := tm3.Snapshot()
	if len(snap) != 0 {
		t.Fatalf("expected empty task map, got %d", len(snap))
	}
	_ = tm3.Close(context.Background())
}

func TestTaskPanicRecovery(t *testing.T) {
	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	task, err := tm.Submit("panic-test", func(ctx context.Context) ([]VM, error) {
		panic("boom")
	})
	if err != nil {
		t.Fatal(err)
	}
	waitTaskStatus(t, tm, task.ID, "failed")
}

func TestAllManagerAndHostEndpoints(t *testing.T) {
	fb := newFakeBackend()
	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	h := handler(fb, tm, nil, "")

	// Hosts CRUD.
	rAddHost := doReq(h, http.MethodPost, "/api/v1/hosts", remote.Host{Name: "mac-pro", Address: "10.0.0.2", User: "dev", Port: 22}, nil)
	if rAddHost.Code != http.StatusOK {
		t.Fatalf("upsert host = %d: %s", rAddHost.Code, rAddHost.Body.String())
	}
	rListHosts := doReq(h, http.MethodGet, "/api/v1/hosts", nil, nil)
	if rListHosts.Code != http.StatusOK || !strings.Contains(rListHosts.Body.String(), "mac-pro") {
		t.Fatalf("list hosts = %d: %s", rListHosts.Code, rListHosts.Body.String())
	}
	rDelHost := doReq(h, http.MethodDelete, "/api/v1/hosts/mac-pro", nil, nil)
	if rDelHost.Code != http.StatusOK {
		t.Fatalf("delete host = %d: %s", rDelHost.Code, rDelHost.Body.String())
	}

	// Read endpoints.
	for _, path := range []string{
		"/api/v1/vms",
		"/api/v1/vms/dev-1234",
		"/api/v1/vms/dev-1234/resources",
		"/api/v1/vms/dev-1234/mounts",
		"/api/v1/vms/dev-1234/usage",
		"/api/v1/vms/dev-1234/browser",
		"/api/v1/vms/dev-1234/sessions",
		"/api/v1/vms/dev-1234/sessions/tools",
		"/api/v1/vms/dev-1234/quotas",
		"/api/v1/network/status",
		"/api/v1/network/delay?node=n1",
		"/api/v1/network/connections",
	} {
		rec := doReq(h, http.MethodGet, path, nil, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
		}
	}

	// Quota refresh task.
	rQ := doReq(h, http.MethodPost, "/api/v1/vms/dev-1234/quotas/refresh", nil, nil)
	if rQ.Code != http.StatusAccepted {
		t.Fatalf("quota refresh = %d: %s", rQ.Code, rQ.Body.String())
	}
	var qt Task
	_ = json.Unmarshal(rQ.Body.Bytes(), &qt)
	waitTaskStatus(t, tm, qt.ID, "succeeded")
}

func TestSSEEventStream(t *testing.T) {
	fb := newFakeBackend()
	tm, err := NewTaskManager(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	defer tm.Close(context.Background())
	shutdown := make(chan struct{})
	h := handler(fb, tm, shutdown, "")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "http://agent-vm/api/v1/events", nil).WithContext(ctx)
	req.Host = "agent-vm"
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		defer close(done)
		h.ServeHTTP(rec, req)
	}()

	time.Sleep(50 * time.Millisecond)
	close(shutdown)
	<-done

	if ct := rec.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("Content-Type = %q, want text/event-stream", ct)
	}
	sc := bufio.NewScanner(bytes.NewReader(rec.Body.Bytes()))
	foundEvent := false
	for sc.Scan() {
		if sc.Text() == "event: tasks" {
			foundEvent = true
			break
		}
	}
	if !foundEvent {
		t.Fatalf("SSE output missing event: tasks: %q", rec.Body.String())
	}
}

func TestRotatingWriter(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "logs", "daemon.log")
	w, err := NewRotatingWriter(logPath, 64, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()

	for i := 0; i < 6; i++ {
		if _, err := w.Write([]byte("0123456789abcdef0123456789abcdef\n")); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(logPath); err != nil {
		t.Fatalf("active log missing: %v", err)
	}
	if _, err := os.Stat(logPath + ".1"); err != nil {
		t.Fatalf("rotated backup .1 missing: %v", err)
	}
	if _, err := os.Stat(logPath + ".3"); !os.IsNotExist(err) {
		t.Fatalf("backup .3 should not exist when maxBackups=2")
	}
	info, err := os.Stat(logPath)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("log file mode = %v, want 0600", info.Mode().Perm())
	}
}
