package resource

import "runtime"

// HostCapabilities reports virtualization and resource capacity for macOS and Linux hosts.
// Prevents assuming a low-resource VPS (e.g. 1C1G) can run full VMs or Chromium.
type HostCapabilities struct {
	OS                 string `json:"os"`
	Arch               string `json:"arch"`
	CPUs               int    `json:"cpus"`
	MemoryBytes        uint64 `json:"memory_bytes"`
	Hypervisor         string `json:"hypervisor"`
	KVMAvailable       bool   `json:"kvm_available"`
	VMRecommended      bool   `json:"vm_recommended"`
	BrowserRecommended bool   `json:"browser_recommended"`
	Note               string `json:"note,omitempty"`
}

// DetectHostCapabilities inspects host CPU, RAM, and virtualization availability.
func DetectHostCapabilities() HostCapabilities {
	cpus := runtime.NumCPU()
	mem := detectHostMemoryBytes()
	hv, kvm := detectHypervisor()
	const minVMRAM = uint64(4) << 30
	vmOK := cpus >= 2 && mem >= minVMRAM && (hv == "vz" || hv == "kvm" || hv == "qemu-tcg")
	browserOK := cpus >= 2 && mem >= minVMRAM && vmOK
	note := ""
	if !vmOK {
		note = "host resources or virtualization are insufficient for full VMs; suitable for network relay / EasyTier only"
	} else if hv == "qemu-tcg" {
		note = "KVM unavailable; software emulation (QEMU TCG) is slow and not recommended for heavy workloads"
	}
	return HostCapabilities{
		OS:                 runtime.GOOS,
		Arch:               runtime.GOARCH,
		CPUs:               cpus,
		MemoryBytes:        mem,
		Hypervisor:         hv,
		KVMAvailable:       kvm,
		VMRecommended:      vmOK,
		BrowserRecommended: browserOK,
		Note:               note,
	}
}
