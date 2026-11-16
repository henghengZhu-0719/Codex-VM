package managedproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"go.yaml.in/yaml/v4"
)

type pidRecord struct {
	PID    int    `json:"pid"`
	Socket string `json:"socket"`
}

type ConnectionItem struct {
	ID       string `json:"id"`
	Host     string `json:"host"`
	Port     string `json:"port"`
	Network  string `json:"network"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
}

type ConnectionsSnapshot struct {
	UploadTotal   int64            `json:"upload_total"`
	DownloadTotal int64            `json:"download_total"`
	Connections   []ConnectionItem `json:"connections"`
}

func mihomoBinaryName() string {
	if runtime.GOOS == "windows" {
		return "mihomo.exe"
	}
	return "mihomo"
}

// CorePath locates the bundled mihomo binary without searching PATH.
func CorePath(stateDir string) (string, error) {
	name := mihomoBinaryName()
	var dirs []string
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs,
			filepath.Dir(exe),
			filepath.Join(filepath.Dir(exe), "..", "proxy-core"),
		)
		if realExe, err := filepath.EvalSymlinks(exe); err == nil && realExe != exe {
			dirs = append(dirs,
				filepath.Dir(realExe),
				filepath.Join(filepath.Dir(realExe), "..", "proxy-core"),
			)
		}
	}
	if stateDir != "" {
		dirs = append(dirs, filepath.Join(stateDir, "bin"))
	}
	for _, dir := range dirs {
		p := filepath.Clean(filepath.Join(dir, name))
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() && (runtime.GOOS == "windows" || st.Mode()&0o111 != 0) {
			return p, nil
		}
	}
	return "", errors.New("未找到内置 Mihomo 代理核心，请重新构建应用或放置到 ~/.agent-vm/bin/mihomo")
}

func CoreVersion(ctx context.Context, stateDir string) string {
	core, err := CorePath(stateDir)
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, core, "-v").Output()
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return strings.TrimSpace(line)
}

func Validate(ctx context.Context, stateDir string, s Store) error {
	core, err := CorePath(stateDir)
	if err != nil {
		return err
	}
	b, err := s.Runtime(stateDir)
	if err != nil {
		return err
	}
	dir := Dir(stateDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, "validate-*.yaml")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if runtime.GOOS != "windows" {
		_ = f.Chmod(0o600)
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	_ = f.Close()
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, core, "-t", "-d", dir, "-f", tmp)
	cmd.Env = coreProcessEnv(dir)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(out.String())
		if msg != "" {
			lines := strings.Split(msg, "\n")
			msg = lines[len(lines)-1]
			if len(msg) > 180 {
				msg = msg[:180]
			}
			return fmt.Errorf("Mihomo 配置校验失败（%s）；原配置已保留", msg)
		}
		return errors.New("Mihomo 配置校验失败，请核对节点协议和参数；原配置已保留")
	}
	return nil
}

func API(ctx context.Context, stateDir, method, path string, body any, reply any) error {
	sock := Socket(stateDir)
	tr := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "unix", sock)
		},
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{
		Transport: tr,
		Timeout:   10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("redirect refused")
		},
	}
	var data []byte
	var err error
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://agentvm-proxy"+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return fmt.Errorf("mihomo API status %d", res.StatusCode)
	}
	if reply != nil {
		return json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(reply)
	}
	return nil
}

func boundInterface(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var cfg struct {
		Interface string `yaml:"interface-name"`
	}
	if yaml.Unmarshal(data, &cfg) != nil {
		return ""
	}
	return cfg.Interface
}

func bindInterface(data []byte, name string) ([]byte, error) {
	if name == "" {
		return data, nil
	}
	var config map[string]any
	if err := yaml.Unmarshal(data, &config); err != nil || config == nil {
		return nil, errors.New("代理运行配置无效")
	}
	config["interface-name"] = name
	if nodes, ok := config["proxies"].([]any); ok {
		for _, item := range nodes {
			if node, ok := item.(map[string]any); ok {
				if _, bound := node["interface-name"]; bound {
					node["interface-name"] = name
				}
			}
		}
	}
	return yaml.Marshal(config)
}

func routeUsesLoopback(s Store) bool {
	route, err := s.Route()
	if err != nil {
		return false
	}
	for _, id := range route {
		n, ok := s.Find(id)
		if !ok {
			continue
		}
		server, _ := n.Config["server"].(string)
		server = strings.ToLower(strings.TrimSpace(server))
		if server == "localhost" || server == "127.0.0.1" || server == "::1" {
			return true
		}
	}
	return false
}

// PhysicalInterface detects the preferred reachable physical IPv4 interface on macOS.
func PhysicalInterface(ctx context.Context) (string, error) {
	if runtime.GOOS != "darwin" {
		return "", errors.New("not darwin")
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	hardware, err := exec.CommandContext(ctx, "/usr/sbin/networksetup", "-listallhardwareports").Output()
	if err != nil {
		return "", err
	}
	routeOut, _ := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "default").Output()
	nwiOut, _ := exec.CommandContext(ctx, "/usr/sbin/scutil", "--nwi").Output()
	usable := map[string]bool{}
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil && ip.To4() != nil && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified() {
				usable[iface.Name] = true
			}
		}
	}
	physical := map[string]bool{}
	for _, line := range strings.Split(string(hardware), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "Device:" && usable[fields[1]] {
			physical[fields[1]] = true
		}
	}
	inIPv4, candidate := false, ""
	var reachable []string
	for _, line := range strings.Split(string(nwiOut), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "IPv4 network interface information") {
			inIPv4 = true
		} else if strings.HasPrefix(line, "IPv6 network interface information") {
			break
		}
		if !inIPv4 {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[1] == ":" && fields[2] == "flags" {
			candidate = fields[0]
		}
		if strings.HasPrefix(line, "reach") && strings.Contains(line, "(Reachable)") && physical[candidate] {
			reachable = append(reachable, candidate)
		}
	}
	for _, line := range strings.Split(string(routeOut), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "interface:" {
			for _, name := range reachable {
				if fields[1] == name {
					return name, nil
				}
			}
		}
	}
	if len(reachable) > 0 {
		return reachable[0], nil
	}
	return "", errors.New("未找到可用物理 IPv4 网卡")
}

func checkRunning(ctx context.Context, stateDir string, s Store) error {
	var cfg struct {
		Port         int    `json:"mixed-port"`
		Interface    string `json:"interface-name"`
		UnifiedDelay bool   `json:"unified-delay"`
	}
	var group struct {
		Now string `json:"now"`
	}
	if err := API(ctx, stateDir, http.MethodGet, "/configs", nil, &cfg); err != nil {
		return err
	}
	if cfg.Port != s.Port || !cfg.UnifiedDelay {
		return errors.New("proxy config mismatch")
	}
	if bound := boundInterface(filepath.Join(Dir(stateDir), "config.yaml")); bound != "" && cfg.Interface != bound {
		return errors.New("proxy interface mismatch")
	}
	if err := API(ctx, stateDir, http.MethodGet, "/proxies/"+Group, nil, &group); err != nil {
		return err
	}
	if group.Now != s.Selected {
		return errors.New("proxy selection mismatch")
	}
	return nil
}

func Running(ctx context.Context, stateDir string, s Store) bool {
	return checkRunning(ctx, stateDir, s) == nil
}

func Start(ctx context.Context, stateDir string, s Store) error {
	core, err := CorePath(stateDir)
	if err != nil {
		return err
	}
	if err := Validate(ctx, stateDir, s); err != nil {
		return err
	}
	if err := Stop(stateDir); err != nil {
		return err
	}
	ln, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", s.Port))
	if err != nil {
		return fmt.Errorf("本地代理端口 127.0.0.1:%d 已被占用，请更换独立端口", s.Port)
	}
	_ = ln.Close()

	sock := Socket(stateDir)
	if err := os.MkdirAll(filepath.Dir(sock), 0o700); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		_ = os.Chmod(filepath.Dir(sock), 0o700)
	}
	_ = os.Remove(sock)

	b, err := s.Runtime(stateDir)
	if err != nil {
		return err
	}
	if runtime.GOOS == "darwin" && !routeUsesLoopback(s) {
		if iface, err := PhysicalInterface(ctx); err == nil && iface != "" {
			if bound, err := bindInterface(b, iface); err == nil {
				b = bound
			}
		}
	}
	dir := Dir(stateDir)
	cfgPath := filepath.Join(dir, "config.yaml")
	if err := writePrivate(cfgPath, b); err != nil {
		return err
	}
	logPath := filepath.Join(dir, "mihomo.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()

	cmd := exec.Command(core, "-d", dir, "-f", cfgPath)
	cmd.Env = coreProcessEnv(dir)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	configureDetachedCmd(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("无法启动 Mihomo 核心：%w", err)
	}
	rec, _ := json.Marshal(pidRecord{PID: cmd.Process.Pid, Socket: sock})
	if err := writePrivate(filepath.Join(dir, "mihomo.json"), rec); err != nil {
		_ = stopPID(cmd.Process.Pid)
		return err
	}
	_ = cmd.Process.Release()

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			_ = Stop(stateDir)
			return ctx.Err()
		case <-deadline.C:
			_ = Stop(stateDir)
			return errors.New("Mihomo 核心启动超时，请查看 ~/.agent-vm/proxy/mihomo.log")
		case <-ticker.C:
			probeCtx, cancel := context.WithTimeout(ctx, 1*time.Second)
			ok := Running(probeCtx, stateDir, s)
			cancel()
			if ok {
				if runtime.GOOS != "windows" {
					_ = os.Chmod(sock, 0o600)
				}
				return nil
			}
		}
	}
}

func Stop(stateDir string) error {
	pidPath := filepath.Join(Dir(stateDir), "mihomo.json")
	if data, err := os.ReadFile(pidPath); err == nil {
		var rec pidRecord
		if json.Unmarshal(data, &rec) == nil && rec.PID > 0 {
			if err := stopPID(rec.PID); err != nil {
				return err
			}
		}
		_ = os.Remove(pidPath)
	}
	_ = os.Remove(Socket(stateDir))
	return nil
}

func Delay(ctx context.Context, stateDir string, s Store, nodeID string) (int, error) {
	if _, ok := s.Find(nodeID); !ok {
		return 0, errors.New("节点不存在")
	}
	var res struct {
		Delay int `json:"delay"`
	}
	endpoint := "/proxies/" + url.PathEscape(nodeID) + "/delay?timeout=5000&url=" + url.QueryEscape("https://www.gstatic.com/generate_204")
	if err := API(ctx, stateDir, http.MethodGet, endpoint, nil, &res); err != nil {
		return 0, errors.New("测速失败或节点未载入核心，请先应用代理")
	}
	return res.Delay, nil
}

func Connections(ctx context.Context, stateDir string) (ConnectionsSnapshot, error) {
	var raw struct {
		Upload      int64 `json:"uploadTotal"`
		Download    int64 `json:"downloadTotal"`
		Connections []struct {
			ID       string `json:"id"`
			Upload   int64  `json:"upload"`
			Download int64  `json:"download"`
			Metadata struct {
				Network string `json:"network"`
				Host    string `json:"host"`
				IP      string `json:"destinationIP"`
				Port    string `json:"destinationPort"`
			} `json:"metadata"`
		} `json:"connections"`
	}
	snap := ConnectionsSnapshot{Connections: []ConnectionItem{}}
	if err := API(ctx, stateDir, http.MethodGet, "/connections", nil, &raw); err != nil {
		return snap, nil
	}
	snap.UploadTotal = raw.Upload
	snap.DownloadTotal = raw.Download
	for i, c := range raw.Connections {
		if i >= 100 {
			break
		}
		host := c.Metadata.Host
		if host == "" {
			host = c.Metadata.IP
		}
		snap.Connections = append(snap.Connections, ConnectionItem{
			ID:       c.ID,
			Host:     host,
			Port:     c.Metadata.Port,
			Network:  c.Metadata.Network,
			Upload:   c.Upload,
			Download: c.Download,
		})
	}
	return snap, nil
}
