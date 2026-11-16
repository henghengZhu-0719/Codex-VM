# Managed-network integration status

This branch contains **work in progress**, not a verified safe VM network boundary.

## Implemented source units

- `internal/egress`: HTTP CONNECT / SOCKS5 TCP dialer, host-DNS-bootstrap prohibition, proxy-only DoH client.
- `internal/netgate`: closed-by-default state, epoch revocation, active-connection shutdown, bounded safety-report validation and tests.
- `internal/limaembed/network_hooks.go`: optional managed-mode hook installation. Current managed mode intentionally starts **Closed** and has no trusted external grant control service.
- Lima and gVisor patches in `patches/` provide GuestDial / DNSExchange forwarding hooks.

## Important limitations

1. **Do not deploy this branch for security-sensitive workloads.** Third-party patches have not been synchronized and verified against the lockfile.
2. The installed Go toolchain must satisfy `go.mod` (currently Go 1.26.10).
3. The managed gate cannot open automatically: a host-authenticated safety checker and control socket still need to be added.
4. Legacy mode preserves the original behavior; merely setting environment proxy variables does not enforce full VM routing.
5. DNS safety only covers the two hooked DNS handlers and has not been validated with host packet capture.
6. QEMU/VZ leak tests and integration tests remain pending.

## Maintainer validation checklist

From the repo root, on a macOS build machine with the correct Go toolchain:

```sh
scripts/third-party-sync all --check
make check-third-party
go test ./internal/egress ./internal/netgate ./internal/limaembed
go test -race ./internal/egress ./internal/netgate
go test github.com/containers/gvisor-tap-vsock/pkg/...
go test github.com/lima-vm/lima/v2/pkg/networks/usernet github.com/lima-vm/lima/v2/pkg/hostagent/dns
make
```

The first command may fail while new patch ordering or baseline compatibility is being reconciled. **Stop at failures:** do not silently revert to the unguarded network path.

Only after clean builds, test with real QEMU and VZ instances while observing host traffic (TCP direct routes, DNS port 53/853, UDP and IPv6). Confirm proxy failure disables networking before considering an integration ready.

## Next milestones

1. Synchronize and correct Lima/gVisor patchsets.
2. Introduce host-authenticated gate control with no guest-visible credential.
3. Implement actual trusted host-side safety probes, bind reports to instance/config/epoch and authorize bounded leases.
4. Validate DoH, TCP revocation, direct-connection absence and DNS/UDP/IPv6 leak behavior on a real macOS host.
5. Add Mihomo lifecycle, node management and SwiftUI surfaces only after the safety core passes the tests.
