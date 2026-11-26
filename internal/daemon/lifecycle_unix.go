//go:build darwin || linux

package daemon

import "context"

// Lifecycle is optional; the read-only inventory can be used independently.
type Lifecycle interface {
 Change(ctx context.Context, name, action string) (VM,error)
}
