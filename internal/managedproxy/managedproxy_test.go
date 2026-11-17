package managedproxy

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/egress"
	"github.com/sylvinus/agent-vm/internal/netgate"
	"go.yaml.in/yaml/v4"
)

func TestStoreSaveLoadAndSyncFiles(t *testing.T) {
	dir := t.TempDir()
	userNet := "allow 192.168.10.5:8080 # user rule\ndomain example.com\n"
	if err := os.WriteFile(filepath.Join(dir, "network"), []byte(userNet), 0o644); err != nil {
		t.Fatal(err)
	}

	s := DefaultStore()
	s.ProxyMode = ProxyModeCustom
	s.UseProxy = true
	s.CustomProxyURL = "http://10.126.126.1:8787"
	s.DNSURL = "https://223.5.5.5/dns-query"
	s.ManagedEnabled = true
	if err := s.Save(dir); err != nil {
		t.Fatal(err)
	}
	if err := s.SyncNetguardFile(dir); err != nil {
		t.Fatal(err)
	}
	cfgPath, err := s.SyncManagedNetworkFile(dir)
	if err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.ManagedEnabled || loaded.DNSURL != "https://223.5.5.5/dns-query" || loaded.EffectiveProxyURL() != "http://10.126.126.1:8787" {
		t.Fatalf("unexpected loaded store: %+v", loaded)
	}

	netBytes, err := os.ReadFile(filepath.Join(dir, "network"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(netBytes), "allow 192.168.10.5:8080 # user rule") ||
		!strings.Contains(string(netBytes), "allow 10.126.126.1:8787"+netguardMarker) {
		t.Fatalf("unexpected netguard file:\n%s", string(netBytes))
	}

	if fi, err := os.Stat(cfgPath); err != nil {
		t.Fatal(err)
	} else if runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Fatalf("expected 0600 on %s, got %v", cfgPath, fi.Mode().Perm())
	}

	// Switching to mihomo removes legacy custom proxy allow rule while preserving user rules.
	loaded.ProxyMode = ProxyModeMihomo
	if err := loaded.SyncNetguardFile(dir); err != nil {
		t.Fatal(err)
	}
	netBytes, _ = os.ReadFile(filepath.Join(dir, "network"))
	if strings.Contains(string(netBytes), netguardMarker) || !strings.Contains(string(netBytes), "allow 192.168.10.5:8080 # user rule") {
		t.Fatalf("unexpected netguard file after mihomo switch:\n%s", string(netBytes))
	}
}

func TestImportValidationAndRuntime(t *testing.T) {
	yamlData := `
proxies:
  - name: relay-1
    type: socks5
    server: 198.51.100.10
    port: 1080
    udp: true
  - name: exit-1
    type: vmess
    server: 198.51.100.20
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
    network: ws
    ws-path: /ws
    ws-headers:
      host: example.com
  - name: bad-ssh
    type: ssh
    server: 198.51.100.30
    port: 22
    username: root
    private-key: /etc/passwd
  - name: bad-ca
    type: trojan
    server: 198.51.100.40
    port: 443
    password: secret
    ca: /tmp/ca.pem
`
	s := DefaultStore()
	if err := s.Import("sub1", "https://example.com/sub.yaml", []byte(yamlData), "src1", 12, ""); err != nil {
		t.Fatal(err)
	}
	if len(s.Sources) != 1 || len(s.Sources[0].Nodes) != 2 || len(s.Sources[0].Skipped) != 2 {
		t.Fatalf("unexpected import result: nodes=%d skipped=%+v", len(s.Sources[0].Nodes), s.Sources[0].Skipped)
	}
	relay := s.Sources[0].Nodes[0]
	exit := s.Sources[0].Nodes[1]
	s.Chain = []string{relay.ID, exit.ID}
	s.Selected = exit.ID

	route, err := s.Route()
	if err != nil || len(route) != 2 || route[0] != relay.ID || route[1] != exit.ID {
		t.Fatalf("unexpected route %v: %v", route, err)
	}

	dir := t.TempDir()
	rawYAML, err := s.Runtime(dir)
	if err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	if err := yaml.Unmarshal(rawYAML, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed["mixed-port"] != DefaultPort || parsed["bind-address"] != "127.0.0.1" {
		t.Fatalf("unexpected runtime config header: %+v", parsed)
	}
	proxies, _ := parsed["proxies"].([]any)
	if len(proxies) != 2 {
		t.Fatalf("expected 2 proxies in runtime, got %d", len(proxies))
	}
}

func TestBuildManualNodeYAML(t *testing.T) {
	b, err := BuildManualNodeYAML(ManualNodeInput{
		Name:   "local-socks",
		Type:   "socks5",
		Server: "198.51.100.5",
		Port:   1080,
	})
	if err != nil {
		t.Fatal(err)
	}
	nodes, err := Parse(b, "manual1")
	if err != nil || len(nodes) != 1 || nodes[0].Name != "local-socks" {
		t.Fatalf("unexpected parsed manual node: %+v, err=%v", nodes, err)
	}
	if _, err := BuildManualNodeYAML(ManualNodeInput{Name: "bad", Type: "socks5", Server: "1.2.3.4", Port: 70000}); err == nil {
		t.Fatal("expected invalid port error")
	}
}

func TestValidateProxyAndDNSURL(t *testing.T) {
	if err := ValidateProxyURL("http://10.126.126.1:8787"); err != nil {
		t.Fatal(err)
	}
	if err := ValidateProxyURL("http://localhost:8787"); err == nil {
		t.Fatal("expected hostname proxy rejection")
	}
	if err := ValidateDNSURL("https://1.1.1.1/dns-query"); err != nil {
		t.Fatal(err)
	}
	if err := ValidateDNSURL("https://dns.google/dns-query"); err == nil {
		t.Fatal("expected hostname DoH rejection")
	}
}

func TestGateControlsAndLocalSafetyProbe(t *testing.T) {
	dialer, err := egress.New("http://127.0.0.1:18080", nil)
	if err != nil {
		t.Fatal(err)
	}
	rep := runLocalSafetyProbe(context.Background(), dialer, "http://127.0.0.1:18080", DefaultDNSURL)
	if len(rep.Checks) != 8 {
		t.Fatalf("expected 8 checks, got %d", len(rep.Checks))
	}
	states := map[string]netgate.CheckState{}
	for _, c := range rep.Checks {
		states[c.ID] = c.State
	}
	if states["fail_closed"] != netgate.Passed {
		t.Fatalf("expected fail_closed passed, got %s", states["fail_closed"])
	}
	if states["egress_policy"] != netgate.Unknown || states["host_boundary"] != netgate.Unknown {
		t.Fatalf("expected unmeasured guest checks to remain unknown: %+v", states)
	}

	if runtime.GOOS == "windows" {
		return
	}
	stateDir, err := os.MkdirTemp("/tmp", "mpgate-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(stateDir) })
	parent := filepath.Join(stateDir, ".netgate-private")
	gate := netgate.New()
	ctl, err := netgate.StartControl(parent, gate, func(ctx context.Context, epoch uint64) netgate.SafetyReport {
		return netgate.SafetyReport{
			Policy:        netgate.SafetyPolicyVersion,
			RunID:         "test-run",
			Configuration: "test-cfg",
			CheckEpoch:    epoch,
			CreatedAt:     time.Now(),
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ctl.Close()

	discovered := DiscoverGateControls(context.Background(), stateDir)
	if len(discovered) != 1 || discovered[0].State != string(netgate.Closed) {
		t.Fatalf("unexpected discovered controls: %+v", discovered)
	}
	reports, err := TriggerGateCheck(context.Background(), stateDir)
	if err != nil || len(reports) != 1 || reports[0].RunID != "test-run" {
		t.Fatalf("unexpected trigger check result: %+v, err=%v", reports, err)
	}
	if n, err := CloseAllGates(context.Background(), stateDir); err != nil || n != 1 {
		t.Fatalf("close all gates: n=%d err=%v", n, err)
	}
	if st, _ := gate.Status(); st != netgate.Closed {
		t.Fatalf("expected closed gate after CloseAllGates, got %s", st)
	}
}

func TestHostDownloadClientRejectsNonHTTPS(t *testing.T) {
	c := HostDownloadClient()
	if _, _, err := Fetch(context.Background(), c, "http://example.com/sub.yaml"); err == nil {
		t.Fatal("expected http subscription URL to be rejected")
	}
	_ = http.StatusOK
}

func TestTriggerGateCheckReportsUnreachableControls(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix socket control")
	}
	stateDir := t.TempDir()
	dir := filepath.Join(stateDir, ".netgate-private", "netgate-unreachable")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	// The record is discoverable, but no host control server is listening.
	rec := netgate.ControlRecord{
		Socket: filepath.Join(dir, "missing.sock"),
		Token:  "test-token",
	}
	data, err := json.Marshal(rec)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "control.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	reports, err := TriggerGateCheck(context.Background(), stateDir)
	if err == nil || !strings.Contains(err.Error(), "netgate-unreachable") {
		t.Fatalf("expected actionable gate-control error, got %v", err)
	}
	if len(reports) != 0 {
		t.Fatalf("unexpected reports: %+v", reports)
	}
}
