package limaembed

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"time"

	"github.com/miekg/dns"
	"github.com/sylvinus/agent-vm/internal/egress"
	"github.com/sylvinus/agent-vm/internal/netgate"
	"github.com/sylvinus/agent-vm/internal/netguard"
)

// newSafetyProbe only reports measurements it actually performs. In particular,
// host-side probes cannot establish the guest's full network isolation.
func newSafetyProbe(cfg managedNetworkConfig, policy *netguard.Policy, gate *netgate.Gate, dialer *egress.Gate, instance string) (func(context.Context, uint64) netgate.SafetyReport, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(struct {
		Config  managedNetworkConfig
		Open    bool
		Allow   []netguard.Rule
		Domains []string
	}{cfg, policy.Open, policy.Allow, policy.Domains})
	if err != nil {
		return nil, err
	}
	fingerprint := sha256.Sum256(encoded)
	runID := instance + ":" + hex.EncodeToString(nonce[:])
	configuration := hex.EncodeToString(fingerprint[:])
	endpoint, err := url.Parse(cfg.DNSURL)
	if err != nil {
		return nil, err
	}
	ip, err := netip.ParseAddr(endpoint.Hostname())
	if err != nil {
		return nil, err
	}
	dst := netip.AddrPortFrom(ip.Unmap(), 443)
	return func(ctx context.Context, epoch uint64) netgate.SafetyReport {
		report := netgate.SafetyReport{Policy: netgate.SafetyPolicyVersion, RunID: runID, Configuration: configuration, CheckEpoch: epoch, CreatedAt: time.Now()}
		add := func(id string, state netgate.CheckState, evidence string) {
			report.Checks = append(report.Checks, netgate.SafetyCheck{ID: id, State: state, Evidence: evidence, CheckedAt: time.Now()})
		}
		probeCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		conn, err := dialer.DialContext(probeCtx, "tcp", dst)
		if err != nil {
			add("proxy_transport", netgate.Failed, "proxy tunnel to configured DNS endpoint failed")
		} else {
			_ = conn.Close()
			add("proxy_transport", netgate.Passed, "proxy tunnel to configured DNS endpoint established")
		}
		// The checker uses a separate resolver because the production resolver is
		// gate-tracked and must remain closed while checks are in progress.
		probeResolver, err := egress.NewResolver(dialer, cfg.DNSURL)
		if err == nil {
			q := new(dns.Msg)
			q.SetQuestion("example.com.", dns.TypeA)
			var answer *dns.Msg
			answer, err = probeResolver.Exchange(probeCtx, q)
			if err == nil && answer == nil {
				err = errors.New("empty DNS response")
			}
		}
		if err != nil {
			add("dns_transport", netgate.Failed, "DNS over HTTPS through proxy failed")
		} else {
			add("dns_transport", netgate.Passed, "DNS over HTTPS through proxy succeeded")
		}
		called := false
		c, err := gate.Dial(probeCtx, func(context.Context) (net.Conn, error) { called = true; return nil, nil })
		if c != nil {
			_ = c.Close()
		}
		if errors.Is(err, netgate.ErrClosed) && !called {
			add("fail_closed", netgate.Passed, "gate denied a connection while checking")
		} else {
			add("fail_closed", netgate.Failed, "gate did not deny a connection while checking")
		}
		for _, id := range []string{"egress_policy", "udp_policy", "ipv6_policy", "host_boundary", "exit_consistency"} {
			add(id, netgate.Unknown, "requires independent guest and host network measurements")
		}
		return report
	}, nil
}
