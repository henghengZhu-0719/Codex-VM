//go:build darwin || linux

package daemon

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

const (
	defaultMaxLogBytes = 10 << 20 // 10 MiB per log file
	defaultMaxBackups  = 5
)

// RotatingWriter is a thread-safe file writer that rotates when size exceeds maxBytes.
// All created directories use mode 0700 and log files use mode 0600.
type RotatingWriter struct {
	mu         sync.Mutex
	path       string
	maxBytes   int64
	maxBackups int
	file       *os.File
	size       int64
}

// NewRotatingWriter opens (or creates) a private 0600 log file at path with size-based rotation.
func NewRotatingWriter(path string, maxBytes int64, maxBackups int) (*RotatingWriter, error) {
	if maxBytes <= 0 {
		maxBytes = defaultMaxLogBytes
	}
	if maxBackups < 1 {
		maxBackups = defaultMaxBackups
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || int(owner.Uid) != os.Getuid() || info.Mode().Perm() != 0700 {
		return nil, fmt.Errorf("daemon log directory must be owned by current user with mode 0700")
	}
	w := &RotatingWriter{
		path:       path,
		maxBytes:   maxBytes,
		maxBackups: maxBackups,
	}
	if err := w.openLocked(); err != nil {
		return nil, err
	}
	return w, nil
}

func (w *RotatingWriter) openLocked() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	if !info.Mode().IsRegular() {
		f.Close()
		return errors.New("daemon log path is not a regular file")
	}
	if err := f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	w.file = f
	w.size = info.Size()
	return nil
}

func (w *RotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return 0, errors.New("log writer closed")
	}
	if w.size+int64(len(p)) > w.maxBytes && w.size > 0 {
		if err := w.rotateLocked(); err != nil {
			return 0, err
		}
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return n, err
}

func (w *RotatingWriter) rotateLocked() error {
	if w.file != nil {
		if err := w.file.Close(); err != nil {
			return err
		}
		w.file = nil
	}
	// Shift existing backups: .(maxBackups-1) -> .maxBackups, ..., .1 -> .2, current -> .1
	oldest := fmt.Sprintf("%s.%d", w.path, w.maxBackups)
	_ = os.Remove(oldest)
	for i := w.maxBackups - 1; i >= 1; i-- {
		src := fmt.Sprintf("%s.%d", w.path, i)
		dst := fmt.Sprintf("%s.%d", w.path, i+1)
		if _, err := os.Lstat(src); err == nil {
			_ = os.Rename(src, dst)
		}
	}
	if _, err := os.Lstat(w.path); err == nil {
		if err := os.Rename(w.path, w.path+".1"); err != nil {
			return err
		}
	}
	return w.openLocked()
}

func (w *RotatingWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

// LogPath returns the structured daemon log file path under the state directory.
func LogPath(state string) string {
	return filepath.Join(state, "logs", "daemon.log")
}

// SetupLogger configures a structured JSON slog logger writing to a rotating log file
// (and optionally an additional writer such as stderr). Caller must call the returned closer.
func SetupLogger(state string, extra io.Writer) (*slog.Logger, func() error, error) {
	rw, err := NewRotatingWriter(LogPath(state), defaultMaxLogBytes, defaultMaxBackups)
	if err != nil {
		return nil, nil, err
	}
	var out io.Writer = rw
	if extra != nil {
		out = io.MultiWriter(rw, extra)
	}
	logger := slog.New(slog.NewJSONHandler(out, &slog.HandlerOptions{Level: slog.LevelInfo}))
	return logger, rw.Close, nil
}
