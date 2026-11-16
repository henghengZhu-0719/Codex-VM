package limaembed

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/egress"
	"github.com/sylvinus/agent-vm/internal/netgate"
	"github.com/sylvinus/agent-vm/internal/netguard"
)

func TestSafetyProbeDoesNotGrantWhenProxyFailsOrGuestChecksAreMissing(t *testing.T) {
	cfg := managedNetworkConfig{ProxyURL: "http://127.0.0.1:18080", DNSURL: "https://1.1.1.1/dns-query"}
	dialer, err := egress.New(cfg.ProxyURL, func(string, netip.AddrPort) bool { return true })
	if err != nil {
		t.Fatal(err)
	}
	dialer.DialProxy = func(context.Context, string, string) (net.Conn, error) { return nil, errors.New("proxy unavailable") }
	gate := netgate.New()
	probe, err := newSafetyProbe(cfg, &netguard.Policy{}, gate, dialer, "test-vm")
	if err != nil {
		t.Fatal(err)
	}
	epoch := gate.BeginCheck()
	report := probe(context.Background(), epoch)
	states := map[string]netgate.CheckState{}
	for _, check := range report.Checks {
		states[check.ID] = check.State
	}
	for _, id := range []string{"proxy_transport", "dns_transport"} {
		if states[id] != netgate.Failed {
			t.Errorf("%s: %s", id, states[id])
		}
	}
	if states["fail_closed"] != netgate.Passed {
		t.Errorf("fail_closed: %s", states["fail_closed"])
	}
	for _, id := range []string{"egress_policy", "udp_policy", "ipv6_policy", "host_boundary", "exit_consistency"} {
		if states[id] != netgate.Unknown {
			t.Errorf("%s: %s", id, states[id])
		}
	}
	if err := gate.GrantReport(report, report.RunID, report.Configuration, time.Minute); err == nil {
		t.Fatal("incomplete report opened gate")
	}
	if state, _ := gate.Status(); state == netgate.Open {
		t.Fatal("gate opened")
	}
}
