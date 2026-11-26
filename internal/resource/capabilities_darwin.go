//go:build darwin

package resource

import (
	"runtime"

	"golang.org/x/sys/unix"
)

func detectHostMemoryBytes() uint64 {
	v, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return 0
	}
	return v
}

func detectHypervisor() (string, bool) {
	if runtime.GOARCH == "arm64" {
		return "vz", false
	}
	return "qemu", false
}
