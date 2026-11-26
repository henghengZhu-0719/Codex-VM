//go:build darwin || linux

package daemon

import "context"

// Lifecycle is optional; the read-only inventory can be used independently.
type Lifecycle interface {
 Change(ctx context.Context, name, action string) (VM,error)
}

type CreateRequest struct {
 Project string `json:"project"`
 CPUs int `json:"cpus,omitempty"`
 MemoryGiB int `json:"memory_gib,omitempty"`
 DiskGiB int `json:"disk_gib,omitempty"`
 ReadOnly bool `json:"read_only,omitempty"`
}

type Creator interface {
 ResolveCreate(CreateRequest) (CreateRequest,string,error)
 Create(context.Context,CreateRequest,string) (VM,error)
}
