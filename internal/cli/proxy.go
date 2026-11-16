package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/sylvinus/agent-vm/internal/managedproxy"
	"go.yaml.in/yaml/v4"
)

type proxyNodeDTO struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Type string `json:"type"`
}

type proxySourceDTO struct {
	ID       string                   `json:"id"`
	Name     string                   `json:"name"`
	Remote   bool                     `json:"remote"`
	Host     string                   `json:"host,omitempty"`
	Interval int                      `json:"interval_hours"`
	Updated  time.Time                `json:"updated_at"`
	Error    string                   `json:"error,omitempty"`
	Usage    string                   `json:"usage,omitempty"`
	Nodes    []proxyNodeDTO           `json:"nodes"`
	Skipped  []managedproxy.NodeIssue `json:"skipped,omitempty"`
}

type proxyStatusDTO struct {
	ProxyMode         string                    `json:"proxy_mode"`
	ManagedEnabled    bool                      `json:"managed_enabled"`
	UseProxy          bool                      `json:"use_proxy"`
	CustomProxyURL    string                    `json:"custom_proxy_url"`
	DisplayProxyURL   string                    `json:"display_proxy_url"`
	ManagedConfigPath string                    `json:"managed_config_path"`
	DNSURL            string                    `json:"dns_url"`
	BootstrapDNS      []string                  `json:"bootstrap_dns"`
	Port              int                       `json:"port"`
	Selected          string                    `json:"selected"`
	Route             []string                  `json:"route"`
	RouteError        string                    `json:"route_error,omitempty"`
	Running           bool                      `json:"running"`
	CoreAvailable     bool                      `json:"core_available"`
	CorePath          string                    `json:"core_path,omitempty"`
	CoreVersion       string                    `json:"core_version,omitempty"`
	Sources           []proxySourceDTO          `json:"sources"`
	Gates             []managedproxy.GateInstance `json:"gates"`
	LastProbe         *managedproxy.ProbeResult `json:"last_probe,omitempty"`
}

func (e *app) proxyCmd(ctx context.Context, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm proxy <status|config|import|manual|refresh|delete|apply|stop|delay|connections|probe|gate-close>")
		return exitUsage
	}
	sub, rest := args[0], args[1:]
	var err error
	switch sub {
	case "status":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy status")
		}
		err = e.writeProxyStatus(ctx)
	case "config":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy config")
		}
		err = e.proxyConfigCmd(ctx)
	case "import":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy import")
		}
		err = e.proxyImportCmd(ctx)
	case "manual":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy manual")
		}
		err = e.proxyManualCmd(ctx)
	case "refresh":
		if len(rest) < 1 || len(rest) > 2 {
			return e.proxyUsage("agent-vm proxy refresh <source-id> [--host]")
		}
		host := len(rest) == 2 && rest[1] == "--host"
		if len(rest) == 2 && !host {
			return e.proxyUsage("agent-vm proxy refresh <source-id> [--host]")
		}
		err = e.proxyRefreshCmd(ctx, rest[0], host)
	case "delete":
		if len(rest) != 1 {
			return e.proxyUsage("agent-vm proxy delete <source-id>")
		}
		err = e.proxyDeleteCmd(ctx, rest[0])
	case "apply":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy apply")
		}
		err = e.proxyApplyCmd(ctx)
	case "stop":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy stop")
		}
		err = e.proxyStopCmd(ctx)
	case "delay":
		if len(rest) > 1 {
			return e.proxyUsage("agent-vm proxy delay [node-id]")
		}
		nodeID := ""
		if len(rest) == 1 {
			nodeID = rest[0]
		}
		err = e.proxyDelayCmd(ctx, nodeID)
	case "connections":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy connections")
		}
		err = e.proxyConnectionsCmd(ctx)
	case "probe":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy probe")
		}
		err = e.proxyProbeCmd(ctx)
	case "gate-close":
		if len(rest) != 0 {
			return e.proxyUsage("agent-vm proxy gate-close")
		}
		err = e.proxyGateCloseCmd(ctx)
	default:
		return e.proxyUsage("agent-vm proxy <status|config|import|manual|refresh|delete|apply|stop|delay|connections|probe|gate-close>")
	}
	if err != nil {
		fmt.Fprintln(e.io.Stderr, err)
		return 1
	}
	return 0
}

func (e *app) proxyUsage(usage string) int {
	fmt.Fprintln(e.io.Stderr, "Usage:", usage)
	return exitUsage
}

func (e *app) readJSONInput(dst any, limit int64) error {
	raw, err := io.ReadAll(io.LimitReader(e.io.Stdin, limit+1))
	if err != nil {
		return err
	}
	if int64(len(raw)) > limit {
		return errors.New("输入内容过大")
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return fmt.Errorf("无效 JSON 输入：%w", err)
	}
	return nil
}

func (e *app) writeJSONOutput(v any) error {
	enc := json.NewEncoder(e.io.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func (e *app) buildProxyStatus(ctx context.Context) (proxyStatusDTO, error) {
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return proxyStatusDTO{}, err
	}
	sources := make([]proxySourceDTO, 0, len(s.Sources))
	for _, src := range s.Sources {
		nodes := make([]proxyNodeDTO, 0, len(src.Nodes))
		for _, n := range src.Nodes {
			nodes = append(nodes, proxyNodeDTO{ID: n.ID, Name: n.Name, Type: n.Type})
		}
		host := ""
		if u, err := url.Parse(src.URL); err == nil {
			host = u.Hostname()
		}
		sources = append(sources, proxySourceDTO{
			ID:       src.ID,
			Name:     src.Name,
			Remote:   src.URL != "",
			Host:     host,
			Interval: src.Interval,
			Updated:  src.Updated,
			Error:    src.Error,
			Usage:    src.Usage,
			Nodes:    nodes,
			Skipped:  src.Skipped,
		})
	}
	route, routeErr := s.Route()
	if route == nil {
		route = append([]string{}, s.Chain...)
	}
	routeErrMsg := ""
	if _, ok := s.Find(s.Selected); ok && routeErr != nil {
		routeErrMsg = routeErr.Error()
	}
	probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	corePath, coreErr := managedproxy.CorePath(stateDir)
	coreVersion := ""
	if coreErr == nil {
		coreVersion = managedproxy.CoreVersion(probeCtx, stateDir)
	}
	running := managedproxy.Running(probeCtx, stateDir, s)
	gates := managedproxy.DiscoverGateControls(probeCtx, stateDir)
	displayProxy := s.CustomProxyURL
	if s.ProxyMode == managedproxy.ProxyModeMihomo {
		displayProxy = fmt.Sprintf("socks5://127.0.0.1:%d (内置 Mihomo)", s.Port)
	}
	return proxyStatusDTO{
		ProxyMode:         s.ProxyMode,
		ManagedEnabled:    s.ManagedEnabled,
		UseProxy:          s.UseProxy,
		CustomProxyURL:    s.CustomProxyURL,
		DisplayProxyURL:   displayProxy,
		ManagedConfigPath: managedproxy.ManagedNetworkConfigPath(stateDir),
		DNSURL:            s.DNSURL,
		BootstrapDNS:      managedproxy.BootstrapDNSURLs(),
		Port:              s.Port,
		Selected:          s.Selected,
		Route:             route,
		RouteError:        routeErrMsg,
		Running:           running,
		CoreAvailable:     coreErr == nil,
		CorePath:          corePath,
		CoreVersion:       coreVersion,
		Sources:           sources,
		Gates:             gates,
		LastProbe:         managedproxy.LoadLastProbe(stateDir),
	}, nil
}

func (e *app) writeProxyStatus(ctx context.Context) error {
	st, err := e.buildProxyStatus(ctx)
	if err != nil {
		return err
	}
	return e.writeJSONOutput(st)
}

func (e *app) persistAndSync(s managedproxy.Store) error {
	stateDir := string(e.state)
	if err := s.Save(stateDir); err != nil {
		return err
	}
	if err := s.SyncNetguardFile(stateDir); err != nil {
		return err
	}
	if _, err := s.SyncManagedNetworkFile(stateDir); err != nil {
		return err
	}
	return nil
}

func (e *app) proxyConfigCmd(ctx context.Context) error {
	var in struct {
		ProxyMode      *string `json:"proxy_mode"`
		ManagedEnabled *bool   `json:"managed_enabled"`
		UseProxy       *bool   `json:"use_proxy"`
		CustomProxyURL *string `json:"custom_proxy_url"`
		DNSURL         *string `json:"dns_url"`
		Port           *int    `json:"port"`
	}
	if err := e.readJSONInput(&in, 64<<10); err != nil {
		return err
	}
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	prevEffective := s.EffectiveProxyURL()
	prevDNS := s.DNSURL
	prevManaged := s.ManagedEnabled

	if in.ProxyMode != nil {
		mode := strings.TrimSpace(*in.ProxyMode)
		if mode != managedproxy.ProxyModeCustom && mode != managedproxy.ProxyModeMihomo {
			return errors.New("代理模式仅支持 custom 或 mihomo")
		}
		s.ProxyMode = mode
	}
	if in.ManagedEnabled != nil {
		s.ManagedEnabled = *in.ManagedEnabled
	}
	if in.UseProxy != nil {
		s.UseProxy = *in.UseProxy
	}
	if in.CustomProxyURL != nil {
		raw := strings.TrimSpace(*in.CustomProxyURL)
		if err := managedproxy.ValidateProxyURL(raw); err != nil {
			return fmt.Errorf("自定义代理地址无效（需使用 http:// 或 socks5:// 加数字 IP 与端口）：%w", err)
		}
		s.CustomProxyURL = raw
	}
	if in.DNSURL != nil {
		raw := strings.TrimSpace(*in.DNSURL)
		if err := managedproxy.ValidateDNSURL(raw); err != nil {
			return err
		}
		s.DNSURL = raw
	}
	if in.Port != nil {
		if *in.Port < 1024 || *in.Port > 65535 {
			return errors.New("本地 Mihomo 端口应为 1024–65535")
		}
		s.Port = *in.Port
	}
	if s.ProxyMode == managedproxy.ProxyModeMihomo && s.UseProxy {
		s.ManagedEnabled = true
	}

	if err := e.persistAndSync(s); err != nil {
		return err
	}
	if s.ProxyMode != managedproxy.ProxyModeMihomo || !s.UseProxy {
		_ = managedproxy.Stop(stateDir)
	}
	if prevEffective != s.EffectiveProxyURL() || prevDNS != s.DNSURL || prevManaged != s.ManagedEnabled {
		_, _ = managedproxy.CloseAllGates(ctx, stateDir)
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) downloadSubscription(ctx context.Context, s managedproxy.Store, rawURL string, hostDownload bool) ([]byte, string, error) {
	var client *http.Client
	var err error
	if hostDownload {
		client = managedproxy.HostDownloadClient()
	} else {
		client, err = managedproxy.ProxyDownloadClient(s.EffectiveProxyURL(), s.DNSURL)
		if err != nil {
			return nil, "", err
		}
	}
	defer client.CloseIdleConnections()
	return managedproxy.Fetch(ctx, client, rawURL)
}

func (e *app) validateCandidate(ctx context.Context, s managedproxy.Store) error {
	stateDir := string(e.state)
	if _, err := managedproxy.CorePath(stateDir); err != nil {
		return nil
	}
	candidate := s
	if len(candidate.Sources) == 0 || len(candidate.Sources[0].Nodes) == 0 {
		return nil
	}
	if _, ok := candidate.Find(candidate.Selected); !ok {
		candidate.Selected = candidate.Sources[0].Nodes[0].ID
		candidate.Chain = nil
	}
	return managedproxy.Validate(ctx, stateDir, candidate)
}

func (e *app) proxyImportCmd(ctx context.Context) error {
	var in struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		URL          string `json:"url"`
		Content      string `json:"content"`
		Interval     int    `json:"interval_hours"`
		HostDownload bool   `json:"host_download"`
	}
	if err := e.readJSONInput(&in, 12<<20); err != nil {
		return err
	}
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	data := []byte(in.Content)
	usage := ""
	if strings.TrimSpace(in.URL) != "" {
		data, usage, err = e.downloadSubscription(ctx, s, in.URL, in.HostDownload)
		if err != nil {
			return err
		}
	}
	if err := s.Import(in.Name, strings.TrimSpace(in.URL), data, in.ID, in.Interval, usage); err != nil {
		return err
	}
	if err := e.validateCandidate(ctx, s); err != nil {
		return err
	}
	if _, ok := s.Find(s.Selected); !ok && len(s.Sources) > 0 && len(s.Sources[0].Nodes) > 0 {
		s.Selected = s.Sources[0].Nodes[0].ID
		s.Chain = nil
	}
	if err := e.persistAndSync(s); err != nil {
		return err
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyManualCmd(ctx context.Context) error {
	var in managedproxy.ManualNodeInput
	if err := e.readJSONInput(&in, 128<<10); err != nil {
		return err
	}
	nodeYAML, err := managedproxy.BuildManualNodeYAML(in)
	if err != nil {
		return err
	}
	sourceName := strings.TrimSpace(in.SourceName)
	if sourceName == "" {
		sourceName = "手动节点"
	}
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}

	var parsed struct {
		Proxies []map[string]any `yaml:"proxies"`
	}
	if err := yaml.Unmarshal(nodeYAML, &parsed); err != nil || len(parsed.Proxies) != 1 {
		return errors.New("无法序列化手动节点配置")
	}
	var merged []map[string]any
	for _, src := range s.Sources {
		if src.ID == "manual" {
			for _, n := range src.Nodes {
				cfg := maps.Clone(n.Config)
				cfg["name"] = n.Name
				merged = append(merged, cfg)
			}
			break
		}
	}
	merged = append(merged, parsed.Proxies[0])
	mergedYAML, err := yaml.Marshal(map[string]any{"proxies": merged})
	if err != nil {
		return err
	}
	if err := s.Import(sourceName, "", mergedYAML, "manual", 0, ""); err != nil {
		return err
	}
	if err := e.validateCandidate(ctx, s); err != nil {
		return err
	}
	for _, src := range s.Sources {
		if src.ID == "manual" && len(src.Nodes) > 0 {
			if _, ok := s.Find(s.Selected); !ok {
				s.Selected = src.Nodes[len(src.Nodes)-1].ID
				s.Chain = nil
			}
			break
		}
	}
	if err := e.persistAndSync(s); err != nil {
		return err
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyRefreshCmd(ctx context.Context, sourceID string, hostDownload bool) error {
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	idx := -1
	for i := range s.Sources {
		if s.Sources[i].ID == sourceID {
			idx = i
			break
		}
	}
	if idx < 0 || s.Sources[idx].URL == "" {
		return errors.New("未找到该远程订阅来源")
	}
	src := s.Sources[idx]
	data, usage, err := e.downloadSubscription(ctx, s, src.URL, hostDownload)
	if err != nil {
		s.Sources[idx].Error = err.Error()
		s.Sources[idx].Attempted = time.Now()
		_ = s.Save(stateDir)
		return err
	}
	if err := s.Import(src.Name, src.URL, data, src.ID, src.Interval, usage); err != nil {
		s.Sources[idx].Error = err.Error()
		s.Sources[idx].Attempted = time.Now()
		_ = s.Save(stateDir)
		return err
	}
	if err := e.validateCandidate(ctx, s); err != nil {
		s.Sources[idx].Error = err.Error()
		s.Sources[idx].Attempted = time.Now()
		_ = s.Save(stateDir)
		return err
	}
	if err := e.persistAndSync(s); err != nil {
		return err
	}
	if s.ProxyMode == managedproxy.ProxyModeMihomo && managedproxy.Running(ctx, stateDir, s) {
		_, _ = managedproxy.CloseAllGates(ctx, stateDir)
		if err := managedproxy.Start(ctx, stateDir, s); err != nil {
			return err
		}
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyDeleteCmd(ctx context.Context, sourceID string) error {
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	idx := -1
	for i := range s.Sources {
		if s.Sources[i].ID == sourceID {
			idx = i
			break
		}
	}
	if idx < 0 {
		return errors.New("订阅来源不存在")
	}
	if len(s.Chain) > 1 {
		for _, id := range s.Chain {
			for _, n := range s.Sources[idx].Nodes {
				if n.ID == id {
					return errors.New("该来源包含当前代理链中的节点，请先切换并应用其他节点后再删除")
				}
			}
		}
	}
	removedSelected := false
	for _, n := range s.Sources[idx].Nodes {
		if n.ID == s.Selected {
			removedSelected = true
			break
		}
	}
	s.Sources = append(s.Sources[:idx], s.Sources[idx+1:]...)
	if removedSelected {
		s.Selected = ""
		s.Chain = nil
		_, _ = managedproxy.CloseAllGates(ctx, stateDir)
		_ = managedproxy.Stop(stateDir)
	}
	if err := e.persistAndSync(s); err != nil {
		return err
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyApplyCmd(ctx context.Context) error {
	var in struct {
		Selected string   `json:"selected"`
		Route    []string `json:"route"`
		Port     int      `json:"port"`
	}
	if err := e.readJSONInput(&in, 64<<10); err != nil {
		return err
	}
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	if len(in.Route) > 0 {
		s.Chain = append([]string(nil), in.Route...)
		s.Selected = s.Chain[len(s.Chain)-1]
	} else if in.Selected != "" {
		s.Selected = in.Selected
		if len(s.Chain) > 0 {
			s.Chain[len(s.Chain)-1] = in.Selected
		}
	}
	if in.Port != 0 {
		if in.Port < 1024 || in.Port > 65535 {
			return errors.New("本地 Mihomo 端口应为 1024–65535")
		}
		s.Port = in.Port
	}
	if _, err := s.Route(); err != nil {
		return err
	}
	if err := managedproxy.Validate(ctx, stateDir, s); err != nil {
		return err
	}
	_, _ = managedproxy.CloseAllGates(ctx, stateDir)
	s.Revision = managedproxy.Token()
	s.ProxyMode = managedproxy.ProxyModeMihomo
	s.ManagedEnabled = true
	s.UseProxy = true
	if err := managedproxy.Start(ctx, stateDir, s); err != nil {
		return err
	}
	if err := e.persistAndSync(s); err != nil {
		return err
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyStopCmd(ctx context.Context) error {
	stateDir := string(e.state)
	_, _ = managedproxy.CloseAllGates(ctx, stateDir)
	if err := managedproxy.Stop(stateDir); err != nil {
		return err
	}
	return e.writeProxyStatus(ctx)
}

func (e *app) proxyDelayCmd(ctx context.Context, nodeID string) error {
	stateDir := string(e.state)
	s, err := managedproxy.Load(stateDir)
	if err != nil {
		return err
	}
	delays := map[string]int{}
	errs := map[string]string{}
	if nodeID != "" {
		d, derr := managedproxy.Delay(ctx, stateDir, s, nodeID)
		if derr != nil {
			return derr
		}
		delays[nodeID] = d
		return e.writeJSONOutput(map[string]any{"delays": delays, "errors": errs})
	}
	var ids []string
	for _, src := range s.Sources {
		for _, n := range src.Nodes {
			ids = append(ids, n.ID)
		}
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 6)
	for _, id := range ids {
		wg.Add(1)
		go func(nid string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			d, derr := managedproxy.Delay(ctx, stateDir, s, nid)
			mu.Lock()
			if derr != nil {
				errs[nid] = derr.Error()
			} else {
				delays[nid] = d
			}
			mu.Unlock()
		}(id)
	}
	wg.Wait()
	return e.writeJSONOutput(map[string]any{"delays": delays, "errors": errs})
}

func (e *app) proxyConnectionsCmd(ctx context.Context) error {
	snap, err := managedproxy.Connections(ctx, string(e.state))
	if err != nil {
		return err
	}
	return e.writeJSONOutput(snap)
}

func (e *app) proxyProbeCmd(ctx context.Context) error {
	s, err := managedproxy.Load(string(e.state))
	if err != nil {
		return err
	}
	res, err := managedproxy.RunProbe(ctx, string(e.state), s)
	if err != nil && res.Report == nil {
		return err
	}
	return e.writeJSONOutput(res)
}

func (e *app) proxyGateCloseCmd(ctx context.Context) error {
	n, err := managedproxy.CloseAllGates(ctx, string(e.state))
	if err != nil {
		return err
	}
	return e.writeJSONOutput(map[string]any{"closed": n})
}
