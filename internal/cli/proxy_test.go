package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runProxy(t *testing.T, stateDir, stdin string, args ...string) (int, string, string) {
	t.Helper()
	t.Setenv("AGENT_VM_STATE_DIR", stateDir)
	var stdout, stderr bytes.Buffer
	code := Main(append([]string{"proxy"}, args...), IO{
		Stdin:  strings.NewReader(stdin),
		Stdout: &stdout,
		Stderr: &stderr,
	})
	return code, stdout.String(), stderr.String()
}

func TestProxyCommandWorkflow(t *testing.T) {
	stateDir := t.TempDir()

	// Rejects VM options.
	r := run(t, "--readonly", "proxy", "status")
	if r.Code != exitUsage {
		t.Fatalf("expected exitUsage, got %d (%s)", r.Code, r.Stderr)
	}

	// Status returns defaults.
	code, out, errOut := runProxy(t, stateDir, "")
	if code != exitUsage || errOut == "" {
		t.Fatalf("expected usage error without subcommand, got %d", code)
	}
	code, out, errOut = runProxy(t, stateDir, "", "status")
	if code != 0 {
		t.Fatalf("status failed (%d): %s", code, errOut)
	}
	var st proxyStatusDTO
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("status JSON invalid: %v\n%s", err, out)
	}
	if st.ProxyMode != "custom" || st.DNSURL != "https://1.1.1.1/dns-query" || st.Port != 17896 {
		t.Fatalf("unexpected default status: %+v", st)
	}

	// Config updates managed network file and netguard file.
	code, out, errOut = runProxy(t, stateDir, `{"custom_proxy_url":"http://10.126.126.1:8787","dns_url":"https://223.5.5.5/dns-query","managed_enabled":true}`, "config")
	if code != 0 {
		t.Fatalf("config failed (%d): %s", code, errOut)
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatal(err)
	}
	if !st.ManagedEnabled || st.DNSURL != "https://223.5.5.5/dns-query" {
		t.Fatalf("unexpected updated config: %+v", st)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "managed-network.json")); err != nil {
		t.Fatalf("expected managed-network.json: %v", err)
	}

	// Rejects hostname DoH URL.
	code, _, _ = runProxy(t, stateDir, `{"dns_url":"https://dns.google/dns-query"}`, "config")
	if code == 0 {
		t.Fatal("expected hostname DoH rejection")
	}

	// Import YAML and manual node, then delete.
	importJSON := `{"name":"local-sub","content":"proxies:\n  - name: n1\n    type: socks5\n    server: 198.51.100.1\n    port: 1080\n"}`
	code, out, errOut = runProxy(t, stateDir, importJSON, "import")
	if code != 0 {
		t.Fatalf("import failed (%d): %s", code, errOut)
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatal(err)
	}
	if len(st.Sources) != 1 || len(st.Sources[0].Nodes) != 1 || st.Selected == "" {
		t.Fatalf("unexpected imported sources: %+v", st.Sources)
	}
	subID := st.Sources[0].ID

	manualJSON := `{"name":"m1","type":"http","server":"198.51.100.2","port":8080}`
	code, out, errOut = runProxy(t, stateDir, manualJSON, "manual")
	if code != 0 {
		t.Fatalf("manual failed (%d): %s", code, errOut)
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatal(err)
	}
	if len(st.Sources) != 2 {
		t.Fatalf("expected 2 sources after manual add, got %d", len(st.Sources))
	}

	code, out, errOut = runProxy(t, stateDir, "", "delete", subID)
	if code != 0 {
		t.Fatalf("delete failed (%d): %s", code, errOut)
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatal(err)
	}
	if len(st.Sources) != 1 {
		t.Fatalf("expected 1 source after delete, got %d", len(st.Sources))
	}

	// Gate close succeeds cleanly even with no running gates.
	code, out, errOut = runProxy(t, stateDir, "", "gate-close")
	if code != 0 || !strings.Contains(out, `"closed": 0`) {
		t.Fatalf("gate-close unexpected (%d): %s / %s", code, out, errOut)
	}
}
