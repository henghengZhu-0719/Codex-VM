//go:build !darwin && !linux

package resource

func detectHostMemoryBytes() uint64   { return 0 }
func detectHypervisor() (string, bool) { return "none", false }
