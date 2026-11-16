# Managed-network integration status

This branch contains **work in progress**, not a verified safe VM network boundary.

## Implemented source units

- `internal/egress`: HTTP CONNECT / SOCKS5 TCP dialer, host-DNS-bootstrap prohibition, proxy-only DoH client.
- `internal/netgate`: closed-by-default state, epoch revocation, active-connection shutdown, bounded safety-report validation and tests.
- `internal/limaembed/network_hooks.go`: optional managed-mode hook installation. Managed mode starts **Closed**. Its authenticated host control endpoint can run preliminary host probes; no grant endpoint exists.
- Lima and gVisor patches in `patches/` provide GuestDial / DNSExchange forwarding hooks.

## Important limitations

1. **Do not deploy this branch for security-sensitive workloads.** Guest isolation and real host packet capture have not been verified.
2. The installed Go toolchain must satisfy `go.mod` (currently Go 1.26.10).
3. The managed gate cannot open automatically. Host probes measure proxy tunneling, DoH and the closed gate, but guest boundary, UDP, IPv6 and exit consistency remain unknown. No incomplete report grants access.
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

**Stop at failures:** do not silently revert to the unguarded network path.

Only after clean builds, test with real QEMU and VZ instances while observing host traffic (TCP direct routes, DNS port 53/853, UDP and IPv6). Confirm proxy failure disables networking before considering an integration ready.

## Next milestones

1. Implement independent guest and host isolation measurements, then use complete trusted reports to authorize bounded leases.
2. Verify private control and configuration access on Windows with ACLs.
3. Validate the synchronized source and workflow on each CI platform.
4. Validate DoH, TCP revocation, direct-connection absence and DNS/UDP/IPv6 leak behavior on a real macOS host.
5. Add Mihomo lifecycle, node management and SwiftUI surfaces only after the safety core passes the tests.
