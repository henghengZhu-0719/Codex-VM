package cli

import (
	"context"
	"encoding/json"
	"fmt"
)

// vmMountsCmd exposes the host/guest mapping for one existing VM to native clients.
func (e *app) vmMountsCmd(ctx context.Context, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm vm-mounts NAME")
		return exitUsage
	}
	b, err := e.readOnlyBackend()
	if err != nil {
		fmt.Fprintln(e.io.Stderr, err)
		return 1
	}
	instance, err := b.Get(ctx, args[0])
	if err != nil {
		fmt.Fprintln(e.io.Stderr, err)
		return 1
	}
	if err := json.NewEncoder(e.io.Stdout).Encode(instance.Mounts); err != nil {
		return 1
	}
	return 0
}
