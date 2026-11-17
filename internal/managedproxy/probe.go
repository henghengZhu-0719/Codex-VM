package managedproxy

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/miekg/dns"
	"github.com/sylvinus/agent-vm/internal/egress"
	"github.com/sylvinus/agent-vm/internal/netgate"
)

type GateInstance struct {
	Dir    string `json:"dir"`
	Socket string `json:"socket"`
	State  string `json:"state"`
	Epoch  uint64 `json:"epoch"`
	Error  string `json:"error,omitempty"`
}

type ProbeResult struct {
	CheckedAt     time.Time             `json:"checked_at"`
	ProxyURL      string                `json:"proxy_url"`
	DNSURL        string                `json:"dns_url"`
	ExitIP        string                `json:"exit_ip,omitempty"`
	ExitIPError   string                `json:"exit_ip_error,omitempty"`
	GateTriggered bool                  `json:"gate_triggered"`
	GateCheckError string              `json:"gate_check_error,omitempty"`
	Report        *netgate.SafetyReport `json:"report,omitempty"`
	Error         string                `json:"error,omitempty"`
}

func gateHTTPClient(socket string) (*http.Client, func()) {
	tr := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "unix", socket)
		},
	}
	return &http.Client{
		Transport: tr,
		Timeout:   25 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("redirect refused")
		},
	}, tr.CloseIdleConnections
}

func callGateControl(ctx context.Context, rec netgate.ControlRecord, method, path string, reply any) error {
	client, cleanup := gateHTTPClient(rec.Socket)
	defer cleanup()
	req, err := http.NewRequestWithContext(ctx, method, "http://netgate"+path, nil)
	if err != nil {
		return err
	}
	req.Host = "netgate"
	req.Header.Set("Authorization", "Bearer "+rec.Token)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("gate control returned HTTP %d", resp.StatusCode)
	}
	if reply != nil {
		return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(reply)
	}
	return nil
}

func loadGateRecords(stateDir string) []struct {
	dir string
	rec netgate.ControlRecord
} {
	pattern := filepath.Join(stateDir, ".netgate-private", "netgate-*", "control.json")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return nil
	}
	var out []struct {
		dir string
		rec netgate.ControlRecord
	}
	for _, p := range matches {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var rec netgate.ControlRecord
		if json.Unmarshal(b, &rec) == nil && rec.Socket != "" && rec.Token != "" {
			out = append(out, struct {
				dir string
				rec netgate.ControlRecord
			}{dir: filepath.Dir(p), rec: rec})
		}
	}
	return out
}

func DiscoverGateControls(ctx context.Context, stateDir string) []GateInstance {
	records := loadGateRecords(stateDir)
	instances := make([]GateInstance, 0, len(records))
	for _, item := range records {
		var status struct {
			State netgate.State `json:"state"`
			Epoch uint64        `json:"epoch"`
		}
		callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := callGateControl(callCtx, item.rec, http.MethodGet, "/status", &status)
		cancel()
		if err != nil {
			continue
		}
		instances = append(instances, GateInstance{
			Dir:    filepath.Base(item.dir),
			Socket: item.rec.Socket,
			State:  string(status.State),
			Epoch:  status.Epoch,
		})
	}
	return instances
}

func TriggerGateCheck(ctx context.Context, stateDir string) ([]netgate.SafetyReport, error) {
	records := loadGateRecords(stateDir)
	var reports []netgate.SafetyReport
	var failures []error
	for _, item := range records {
		var rep netgate.SafetyReport
		if err := callGateControl(ctx, item.rec, http.MethodPost, "/check", &rep); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", filepath.Base(item.dir), err))
			continue
		}
		reports = append(reports, rep)
	}
	return reports, errors.Join(failures...)
}

func CloseAllGates(ctx context.Context, stateDir string) (int, error) {
	records := loadGateRecords(stateDir)
	closed := 0
	var firstErr error
	for _, item := range records {
		if err := callGateControl(ctx, item.rec, http.MethodPost, "/close", nil); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		closed++
	}
	return closed, firstErr
}

func LoadLastProbe(stateDir string) *ProbeResult {
	b, err := os.ReadFile(filepath.Join(Dir(stateDir), "last-probe.json"))
	if err != nil {
		return nil
	}
	var res ProbeResult
	if json.Unmarshal(b, &res) != nil {
		return nil
	}
	return &res
}

func saveLastProbe(stateDir string, res ProbeResult) {
	if b, err := json.MarshalIndent(res, "", "  "); err == nil {
		_ = writePrivate(filepath.Join(Dir(stateDir), "last-probe.json"), append(b, '\n'))
	}
}

func RunProbe(ctx context.Context, stateDir string, s Store) (ProbeResult, error) {
	s.normalizeDefaults()
	res := ProbeResult{
		CheckedAt: time.Now(),
		ProxyURL:  s.EffectiveProxyURL(),
		DNSURL:    s.DNSURL,
	}
	if err := ValidateProxyURL(res.ProxyURL); err != nil {
		res.Error = err.Error()
		saveLastProbe(stateDir, res)
		return res, err
	}
	if err := ValidateDNSURL(res.DNSURL); err != nil {
		res.Error = err.Error()
		saveLastProbe(stateDir, res)
		return res, err
	}

	reports, gateErr := TriggerGateCheck(ctx, stateDir)
	if gateErr != nil {
		res.GateCheckError = gateErr.Error()
	}
	if len(reports) > 0 {
		rep := reports[0]
		res.GateTriggered = true
		res.Report = &rep
	}

	dialer, err := egress.New(res.ProxyURL, func(network string, dst netip.AddrPort) bool {
		return network == "tcp" && dst.IsValid() && publicIP(dst.Addr())
	})
	if err != nil {
		res.Error = err.Error()
		saveLastProbe(stateDir, res)
		return res, err
	}

	if res.Report == nil {
		rep := runLocalSafetyProbe(ctx, dialer, res.ProxyURL, res.DNSURL)
		res.Report = &rep
	}

	if ip, err := probeExitIP(ctx, dialer, res.DNSURL); err != nil {
		res.ExitIPError = err.Error()
	} else {
		res.ExitIP = ip
	}
	saveLastProbe(stateDir, res)
	return res, nil
}

func runLocalSafetyProbe(ctx context.Context, dialer *egress.Gate, proxyURL, dnsURL string) netgate.SafetyReport {
	var nonce [16]byte
	_, _ = rand.Read(nonce[:])
	encoded, _ := json.Marshal(struct {
		ProxyURL string `json:"proxy_url"`
		DNSURL   string `json:"dns_url"`
	}{proxyURL, dnsURL})
	fp := sha256.Sum256(encoded)

	gate := netgate.New()
	epoch := gate.BeginCheck()
	report := netgate.SafetyReport{
		Policy:        netgate.SafetyPolicyVersion,
		RunID:         "host-probe:" + hex.EncodeToString(nonce[:]),
		Configuration: hex.EncodeToString(fp[:]),
		CheckEpoch:    epoch,
		CreatedAt:     time.Now(),
	}
	add := func(id string, state netgate.CheckState, evidence string) {
		report.Checks = append(report.Checks, netgate.SafetyCheck{
			ID:        id,
			State:     state,
			Evidence:  evidence,
			CheckedAt: time.Now(),
		})
	}
	probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	if u, err := url.Parse(dnsURL); err == nil {
		if ip, err := netip.ParseAddr(u.Hostname()); err == nil {
			conn, derr := dialer.DialContext(probeCtx, "tcp", netip.AddrPortFrom(ip.Unmap(), 443))
			if derr != nil {
				add("proxy_transport", netgate.Failed, "经代理隧道连接 DoH 端点失败："+derr.Error())
			} else {
				_ = conn.Close()
				add("proxy_transport", netgate.Passed, "经代理隧道建立至 "+ip.Unmap().String()+":443 的 TCP 隧道成功")
			}
		}
	}

	resolver, err := egress.NewResolver(dialer, dnsURL)
	if err == nil {
		q := new(dns.Msg)
		q.SetQuestion("example.com.", dns.TypeA)
		ans, rerr := resolver.Exchange(probeCtx, q)
		if rerr != nil || ans == nil || ans.Rcode != dns.RcodeSuccess {
			if rerr == nil {
				rerr = errors.New("未返回有效 DNS 应答")
			}
			add("dns_transport", netgate.Failed, "代理内 DoH 解析失败："+rerr.Error())
		} else {
			add("dns_transport", netgate.Passed, "代理内 DoH 查询 example.com 成功")
		}
	} else {
		add("dns_transport", netgate.Failed, err.Error())
	}

	called := false
	c, gerr := gate.Dial(probeCtx, func(context.Context) (net.Conn, error) {
		called = true
		return nil, nil
	})
	if c != nil {
		_ = c.Close()
	}
	if errors.Is(gerr, netgate.ErrClosed) && !called {
		add("fail_closed", netgate.Passed, "门禁在 Checking/Closed 状态下拒绝未授权连接")
	} else {
		add("fail_closed", netgate.Failed, "门禁未能阻断未授权连接")
	}

	for _, id := range []string{"egress_policy", "udp_policy", "ipv6_policy", "host_boundary", "exit_consistency"} {
		add(id, netgate.Unknown, "需在运行中的 QEMU/VZ 来宾虚拟机与宿主机抓包边界测试后确认")
	}
	return report
}

func probeExitIP(ctx context.Context, dialer *egress.Gate, dnsURL string) (string, error) {
	resolver, err := egress.NewResolver(dialer, dnsURL)
	if err != nil {
		return "", err
	}
	tr := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, _, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			q := new(dns.Msg)
			q.SetQuestion(dns.Fqdn(host), dns.TypeA)
			ans, err := resolver.Exchange(ctx, q)
			if err != nil {
				return nil, err
			}
			ip, err := firstPublicA(ans)
			if err != nil {
				return nil, err
			}
			rawConn, err := dialer.DialContext(ctx, "tcp", netip.AddrPortFrom(ip, 443))
			if err != nil {
				return nil, err
			}
			tlsConn := tls.Client(rawConn, &tls.Config{ServerName: host})
			if err := tlsConn.HandshakeContext(ctx); err != nil {
				_ = rawConn.Close()
				return nil, err
			}
			return tlsConn, nil
		},
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{
		Transport: tr,
		Timeout:   8 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("probe redirect refused")
		},
	}
	var lastErr error
	for _, endpoint := range []string{"https://ipv4.icanhazip.com/", "https://api.ipify.org/"} {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, rerr := io.ReadAll(io.LimitReader(resp.Body, 256))
		_ = resp.Body.Close()
		if rerr != nil || resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("HTTP %d", resp.StatusCode)
			continue
		}
		ip, perr := netip.ParseAddr(strings.TrimSpace(string(body)))
		if perr == nil && publicIP(ip) {
			return ip.Unmap().String(), nil
		}
		lastErr = errors.New("未返回有效公网 IPv4")
	}
	if lastErr == nil {
		lastErr = errors.New("出口 IP 探测失败")
	}
	return "", lastErr
}
