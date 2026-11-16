// Package managedproxy owns agent-vm's private proxy configuration, Clash/Mihomo
// subscription/node store, local Mihomo core lifecycle, and host-side egress/gate probing.
package managedproxy

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/sylvinus/agent-vm/internal/egress"
	"github.com/sylvinus/agent-vm/internal/netguard"
	"go.yaml.in/yaml/v4"
)

const (
	Group                 = "CAGE"
	MaxImport             = 8 << 20
	maxStoreSize          = 32 << 20
	DefaultCustomProxyURL = "http://10.126.126.1:8787"
	DefaultDNSURL         = "https://1.1.1.1/dns-query"
	DefaultPort           = 17896
	ProxyModeCustom       = "custom"
	ProxyModeMihomo       = "mihomo"
	netguardMarker        = " # Agent VM HTTP proxy"
)

type Node struct {
	ID     string         `json:"id"`
	Name   string         `json:"name"`
	Type   string         `json:"type"`
	Config map[string]any `json:"config"`
}

type Source struct {
	ID        string      `json:"id"`
	Name      string      `json:"name"`
	URL       string      `json:"url,omitempty"`
	Interval  int         `json:"interval_hours"`
	Updated   time.Time   `json:"updated_at"`
	Attempted time.Time   `json:"attempted_at"`
	Error     string      `json:"error,omitempty"`
	Usage     string      `json:"usage,omitempty"`
	Nodes     []Node      `json:"nodes"`
	Skipped   []NodeIssue `json:"skipped,omitempty"`
}

type Store struct {
	Version        int      `json:"version"`
	ProxyMode      string   `json:"proxy_mode"`
	ManagedEnabled bool     `json:"managed_enabled"`
	UseProxy       bool     `json:"use_proxy"`
	CustomProxyURL string   `json:"custom_proxy_url"`
	DNSURL         string   `json:"dns_url"`
	Port           int      `json:"port"`
	Auth           string   `json:"auth"`
	Revision       string   `json:"revision"`
	Selected       string   `json:"selected"`
	Chain          []string `json:"chain,omitempty"`
	Sources        []Source `json:"sources"`
}

func Token() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func Dir(stateDir string) string {
	return filepath.Join(stateDir, "proxy")
}

func ManagedNetworkConfigPath(stateDir string) string {
	return filepath.Join(stateDir, "managed-network.json")
}

func Socket(stateDir string) string {
	h := sha256.Sum256([]byte(filepath.Clean(stateDir)))
	if runtime.GOOS == "windows" {
		return filepath.Join(os.TempDir(), fmt.Sprintf("agentvm-proxy-%x", h[:8]), "control.sock")
	}
	return filepath.Join("/tmp", fmt.Sprintf("agentvm-proxy-%d-%x", os.Getuid(), h[:8]), "control.sock")
}

func DefaultStore() Store {
	return Store{
		Version:        1,
		ProxyMode:      ProxyModeCustom,
		ManagedEnabled: false,
		UseProxy:       true,
		CustomProxyURL: DefaultCustomProxyURL,
		DNSURL:         DefaultDNSURL,
		Port:           DefaultPort,
		Auth:           Token(),
		Sources:        []Source{},
	}
}

func (s *Store) normalizeDefaults() {
	if s.Version == 0 {
		s.Version = 1
	}
	if s.ProxyMode != ProxyModeCustom && s.ProxyMode != ProxyModeMihomo {
		s.ProxyMode = ProxyModeCustom
	}
	if strings.TrimSpace(s.CustomProxyURL) == "" {
		s.CustomProxyURL = DefaultCustomProxyURL
	}
	if strings.TrimSpace(s.DNSURL) == "" {
		s.DNSURL = DefaultDNSURL
	}
	if s.Port == 0 {
		s.Port = DefaultPort
	}
	if s.Auth == "" {
		s.Auth = Token()
	}
	if s.Sources == nil {
		s.Sources = []Source{}
	}
}

func ValidateProxyURL(raw string) error {
	_, err := egress.New(strings.TrimSpace(raw), func(string, netip.AddrPort) bool { return false })
	return err
}

func ValidateDNSURL(raw string) error {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u == nil || u.Scheme != "https" || u.User != nil || u.Hostname() == "" || u.Fragment != "" {
		return errors.New("DoH 地址必须使用 HTTPS 且不能包含用户名或片段")
	}
	ip, err := netip.ParseAddr(u.Hostname())
	if err != nil || !ip.Unmap().Is4() {
		return errors.New("DoH 地址必须使用 IPv4 字面量（避免宿主机 DNS 启动依赖），例如 https://1.1.1.1/dns-query")
	}
	if u.Port() != "" && u.Port() != "443" {
		return errors.New("DoH 地址端口必须为 443")
	}
	if u.Path == "" || u.Path == "/" {
		return errors.New("DoH 地址必须包含查询路径，例如 /dns-query")
	}
	return nil
}

func Load(stateDir string) (Store, error) {
	s := DefaultStore()
	f, err := os.Open(filepath.Join(Dir(stateDir), "sources.json"))
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return Store{}, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxStoreSize+1))
	if err != nil {
		return Store{}, err
	}
	var loaded Store
	if len(b) > maxStoreSize || json.Unmarshal(b, &loaded) != nil {
		return Store{}, errors.New("代理配置无效，请检查或重置私有配置")
	}
	loaded.normalizeDefaults()
	if loaded.Version != 1 || loaded.Port < 1024 || loaded.Port > 65535 || len(loaded.Auth) != 48 {
		return Store{}, errors.New("代理配置参数越界或损坏，请检查或重置私有配置")
	}
	return loaded, nil
}

func writePrivate(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		_ = os.Chmod(dir, 0o700)
	}
	f, err := os.CreateTemp(dir, ".proxy-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmp)
		}
	}()
	if runtime.GOOS != "windows" {
		if err = f.Chmod(0o600); err != nil {
			_ = f.Close()
			return err
		}
	}
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	cleanup = false
	if runtime.GOOS != "windows" {
		_ = os.Chmod(path, 0o600)
	}
	return nil
}

func (s Store) Save(stateDir string) error {
	s.normalizeDefaults()
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if len(b) > maxStoreSize {
		return errors.New("代理来源配置总大小超过 32 MiB，请减少来源或节点；原配置已保留")
	}
	return writePrivate(filepath.Join(Dir(stateDir), "sources.json"), append(b, '\n'))
}

func (s Store) Endpoint() string {
	return fmt.Sprintf("socks5://cage:%s@127.0.0.1:%d", s.Auth, s.Port)
}

func (s Store) EffectiveProxyURL() string {
	if s.ProxyMode == ProxyModeMihomo {
		return s.Endpoint()
	}
	if strings.TrimSpace(s.CustomProxyURL) != "" {
		return strings.TrimSpace(s.CustomProxyURL)
	}
	return DefaultCustomProxyURL
}

// SyncManagedNetworkFile writes managed-network.json with 0600 permissions so
// hostagent can enable egress/DoH/netgate hooks when AGENT_VM_MANAGED_NETWORK_CONFIG is set.
func (s Store) SyncManagedNetworkFile(stateDir string) (string, error) {
	s.normalizeDefaults()
	payload := struct {
		ProxyURL string `json:"proxy_url"`
		DNSURL   string `json:"dns_url"`
	}{
		ProxyURL: s.EffectiveProxyURL(),
		DNSURL:   strings.TrimSpace(s.DNSURL),
	}
	b, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return "", err
	}
	path := ManagedNetworkConfigPath(stateDir)
	if err := writePrivate(path, append(b, '\n')); err != nil {
		return "", err
	}
	return path, nil
}

// SyncNetguardFile updates the legacy HTTP proxy allow rule in ~/.agent-vm/network
// without altering user-authored rules.
func (s Store) SyncNetguardFile(stateDir string) error {
	s.normalizeDefaults()
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(stateDir, netguard.FileName)
	oldBytes, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var lines []string
	for _, line := range strings.Split(strings.TrimSuffix(string(oldBytes), "\n"), "\n") {
		if line == "" && len(oldBytes) == 0 {
			continue
		}
		if strings.HasSuffix(line, netguardMarker) {
			continue
		}
		lines = append(lines, line)
	}
	for len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if s.UseProxy && s.ProxyMode == ProxyModeCustom {
		if u, err := url.Parse(s.EffectiveProxyURL()); err == nil && u.Host != "" {
			if port, err := strconv.Atoi(u.Port()); err == nil && port > 0 && port <= 65535 {
				lines = append(lines, "allow "+u.Host+netguardMarker)
			}
		}
	}
	content := ""
	if len(lines) > 0 {
		content = strings.Join(lines, "\n") + "\n"
	}
	if content == string(oldBytes) {
		return nil
	}
	f, err := os.CreateTemp(stateDir, ".network-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmp)
		}
	}()
	if _, err = f.WriteString(content); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	cleanup = false
	return nil
}

func (s Store) Find(id string) (Node, bool) {
	for _, src := range s.Sources {
		for _, n := range src.Nodes {
			if n.ID == id {
				return n, true
			}
		}
	}
	return Node{}, false
}

func (s Store) Count() int {
	n := 0
	for _, src := range s.Sources {
		n += len(src.Nodes)
	}
	return n
}

func (s *Store) Import(name, rawURL string, data []byte, id string, interval int, usage string) error {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 100 {
		return errors.New("请填写 1–100 字节的来源名称")
	}
	if interval < 0 || interval > 168 {
		return errors.New("更新间隔应为 0–168 小时，0 表示手动更新")
	}
	if id == "" {
		id = Token()[:16]
	}
	nodes, skipped, err := parseNodes(data, id)
	if err != nil {
		return err
	}
	src := Source{
		ID:        id,
		Name:      name,
		URL:       rawURL,
		Interval:  interval,
		Updated:   time.Now(),
		Attempted: time.Now(),
		Nodes:     nodes,
		Usage:     usage,
		Skipped:   skipped,
	}
	for i := range s.Sources {
		if s.Sources[i].ID == id {
			route, routeErr := s.Route()
			if s.Selected != "" && routeErr != nil {
				return routeErr
			}
			available := make(map[string]bool, len(nodes))
			for _, n := range nodes {
				available[n.ID] = true
			}
			required := make(map[string]bool, len(route))
			for _, hop := range route {
				required[hop] = true
			}
			for _, old := range s.Sources[i].Nodes {
				if required[old.ID] && !available[old.ID] {
					reason := "节点未包含在更新中"
					for _, issue := range skipped {
						if issue.Name == old.Name {
							reason = issue.Reason
							break
						}
					}
					return fmt.Errorf("订阅更新移除或跳过了当前出口或中转节点 %q：%s；原配置已保留，请先应用其他节点再更新", old.Name, reason)
				}
			}
			s.Sources[i] = src
			return nil
		}
	}
	s.Sources = append(s.Sources, src)
	return nil
}

func unsafeOption(v any) bool {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			if unsafeField(k, val) {
				return true
			}
		}
	case map[any]any:
		for k, val := range x {
			key, _ := k.(string)
			if unsafeField(key, val) {
				return true
			}
		}
	case []any:
		for _, val := range x {
			if unsafeOption(val) {
				return true
			}
		}
	}
	return false
}

func unsafeField(key string, value any) bool {
	key = optionKey(key)
	if strings.Contains(key, "path") && key != "path" {
		return true
	}
	switch key {
	case "ca", "certificate", "private-key", "interface-name", "routing-mark":
		return true
	}
	return unsafeOption(value)
}

func (s Store) Route() ([]string, error) {
	if _, ok := s.Find(s.Selected); !ok {
		return nil, errors.New("请先选择有效的最终出口")
	}
	if len(s.Chain) > 0 {
		if s.Chain[len(s.Chain)-1] != s.Selected {
			return nil, errors.New("代理链与最终出口不一致，请重新配置代理")
		}
		seen := map[string]bool{}
		for _, id := range s.Chain {
			if _, ok := s.Find(id); !ok {
				return nil, errors.New("代理链中的节点已被移除，请重新选择；原配置已保留")
			}
			if seen[id] {
				return nil, errors.New("代理链不能重复使用同一个节点")
			}
			seen[id] = true
		}
		return append([]string(nil), s.Chain...), nil
	}
	var reversed []string
	seen := map[string]bool{}
	for id := s.Selected; id != ""; {
		n, ok := s.Find(id)
		if !ok || seen[id] {
			return nil, errors.New("导入的代理链存在循环或缺失节点，请检查来源配置")
		}
		seen[id] = true
		reversed = append(reversed, id)
		id, _ = n.Config["dialer-proxy"].(string)
	}
	for i, j := 0, len(reversed)-1; i < j; i, j = i+1, j-1 {
		reversed[i], reversed[j] = reversed[j], reversed[i]
	}
	return reversed, nil
}

func (s Store) Runtime(stateDir string) ([]byte, error) {
	if _, err := s.Route(); err != nil {
		return nil, err
	}
	dialers := map[string]string{}
	for i, id := range s.Chain {
		dialers[id] = ""
		if i > 0 {
			dialers[id] = s.Chain[i-1]
		}
	}
	proxies := []map[string]any{}
	for _, src := range s.Sources {
		for _, n := range src.Nodes {
			config := make(map[string]any, len(n.Config))
			for key, value := range n.Config {
				config[key] = value
			}
			if err := normalizeWebSocket(config); err != nil {
				return nil, fmt.Errorf("节点 %q：%w", n.Name, err)
			}
			if via, overridden := dialers[n.ID]; overridden {
				delete(config, "dialer-proxy")
				if via != "" {
					config["dialer-proxy"] = via
				}
			}
			proxies = append(proxies, config)
		}
	}
	dnsTarget := strings.TrimSpace(s.DNSURL)
	if dnsTarget == "" {
		dnsTarget = DefaultDNSURL
	}
	dns := map[string]any{
		"enable":                  true,
		"ipv6":                    false,
		"use-hosts":               false,
		"use-system-hosts":        false,
		"default-nameserver":      BootstrapDNSURLs(),
		"proxy-server-nameserver": BootstrapDNSURLs(),
		"nameserver":              []string{dnsTarget + "#" + Group},
	}
	config := map[string]any{
		"mixed-port":               s.Port,
		"bind-address":             "127.0.0.1",
		"allow-lan":                false,
		"authentication":           []string{"cage:" + s.Auth},
		"skip-auth-prefixes":       []string{},
		"mode":                     "rule",
		"ipv6":                     false,
		"log-level":                "warning",
		"find-process-mode":        "off",
		"external-controller-unix": Socket(stateDir),
		"tun":                      map[string]any{"enable": false},
		"dns":                      dns,
		"geo-auto-update":          false,
		"profile":                  map[string]any{"store-selected": false},
		"proxies":                  proxies,
		"proxy-groups":             []any{map[string]any{"name": Group, "type": "select", "proxies": []string{s.Selected}}},
		"rules":                    []string{"MATCH," + Group},
		"unified-delay":            true,
	}
	return yaml.Marshal(config)
}
