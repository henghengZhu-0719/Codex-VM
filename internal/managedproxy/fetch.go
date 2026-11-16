package managedproxy

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/miekg/dns"
	"github.com/sylvinus/agent-vm/internal/egress"
)

// BootstrapDNSURLs provides numeric DoH resolvers that avoid host system DNS lookups.
func BootstrapDNSURLs() []string {
	return []string{"https://1.1.1.1/dns-query", "https://223.5.5.5/dns-query"}
}

func publicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	return ip.Is4() && ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() &&
		!netip.MustParsePrefix("100.64.0.0/10").Contains(ip) && !netip.MustParsePrefix("198.18.0.0/15").Contains(ip)
}

func subscriptionRedirectPolicy(r *http.Request, via []*http.Request) error {
	if len(via) >= 3 || r.URL.Scheme != "https" || r.URL.User != nil {
		return errors.New("订阅重定向被拒绝")
	}
	return nil
}

// HostDownloadClient routes subscription downloads over the host environment proxy (if any),
// resolving the subscription server via public numeric DoH rather than host system DNS.
func HostDownloadClient() *http.Client {
	return &http.Client{
		Transport:     subscriptionHostTransport{resolvers: BootstrapDNSURLs()},
		Timeout:       30 * time.Second,
		CheckRedirect: subscriptionRedirectPolicy,
	}
}

// ProxyDownloadClient routes subscription downloads and DoH lookups strictly through proxyURL.
func ProxyDownloadClient(proxyURL, dnsURL string) (*http.Client, error) {
	dialer, err := egress.New(proxyURL, func(network string, dst netip.AddrPort) bool {
		return network == "tcp" && dst.IsValid() && publicIP(dst.Addr())
	})
	if err != nil {
		return nil, err
	}
	resolver, err := egress.NewResolver(dialer, dnsURL)
	if err != nil {
		return nil, err
	}
	return &http.Client{
		Transport:     subscriptionProxyTransport{dialer: dialer, resolver: resolver},
		Timeout:       30 * time.Second,
		CheckRedirect: subscriptionRedirectPolicy,
	}, nil
}

type subscriptionProxyTransport struct {
	dialer   *egress.Gate
	resolver *egress.Resolver
}

func (t subscriptionProxyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	host := req.URL.Hostname()
	ip, err := netip.ParseAddr(host)
	if err != nil {
		q := new(dns.Msg)
		q.SetQuestion(dns.Fqdn(host), dns.TypeA)
		ans, rerr := t.resolver.Exchange(req.Context(), q)
		if rerr != nil {
			return nil, rerr
		}
		ip, err = firstPublicA(ans)
		if err != nil {
			return nil, err
		}
	}
	if !publicIP(ip) {
		return nil, errors.New("订阅服务器必须使用公网 IPv4 地址")
	}
	port := uint16(443)
	if p := req.URL.Port(); p != "" {
		n, perr := strconv.ParseUint(p, 10, 16)
		if perr != nil || n == 0 {
			return nil, errors.New("订阅服务器端口无效")
		}
		port = uint16(n)
	}
	dst := netip.AddrPortFrom(ip.Unmap(), port)
	tr := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		TLSClientConfig:   &tls.Config{ServerName: host},
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return t.dialer.DialContext(ctx, "tcp", dst)
		},
	}
	defer tr.CloseIdleConnections()
	return tr.RoundTrip(req)
}

type subscriptionHostTransport struct {
	resolvers []string
}

func (t subscriptionHostTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	routing := req.Clone(req.Context())
	routing.URL.Path, routing.URL.RawPath, routing.URL.RawQuery = "", "", ""
	route, err := http.ProxyFromEnvironment(routing)
	if err != nil {
		return nil, err
	}
	tr := &http.Transport{
		Proxy:             http.ProxyURL(route),
		DisableKeepAlives: true,
		DialContext:       (&net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second,
	}
	defer tr.CloseIdleConnections()
	host := req.URL.Hostname()
	ip, err := netip.ParseAddr(host)
	if err != nil {
		dnsClient := &http.Client{
			Transport: tr,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return errors.New("DNS redirect refused")
			},
		}
		ip, err = resolveInfrastructureWith(req.Context(), host, dnsClient, t.resolvers)
		if err != nil {
			return nil, err
		}
	}
	if !publicIP(ip) {
		return nil, errors.New("订阅服务器必须使用公网 IPv4 地址")
	}
	target := tr.Clone()
	defer target.CloseIdleConnections()
	if target.TLSClientConfig == nil {
		target.TLSClientConfig = &tls.Config{}
	}
	if route != nil && route.Scheme == "https" {
		outer := target.TLSClientConfig.Clone()
		outer.ServerName, outer.NextProtos = route.Hostname(), []string{"http/1.1"}
		target.DialTLSContext = (&tls.Dialer{Config: outer, NetDialer: &net.Dialer{Timeout: 10 * time.Second}}).DialContext
	}
	target.TLSClientConfig.ServerName = host
	pinned := req.Clone(req.Context())
	pinned.Host = req.URL.Host
	pinned.URL.Host = ip.Unmap().String()
	if port := req.URL.Port(); port != "" {
		pinned.URL.Host = net.JoinHostPort(ip.Unmap().String(), port)
	}
	return target.RoundTrip(pinned)
}

func resolveInfrastructureWith(ctx context.Context, host string, client *http.Client, servers []string) (netip.Addr, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(host), dns.TypeA)
	wire, err := q.Pack()
	if err != nil {
		return netip.Addr{}, errors.New("订阅域名无效")
	}
	type result struct {
		ip  netip.Addr
		err error
	}
	results := make(chan result, len(servers))
	for _, server := range servers {
		go func(srv string) {
			ip, qerr := queryInfrastructureDNS(ctx, client, srv, q, wire)
			results <- result{ip, qerr}
		}(server)
	}
	for range servers {
		select {
		case <-ctx.Done():
			return netip.Addr{}, ctx.Err()
		case res := <-results:
			if res.err == nil {
				return res.ip, nil
			}
		}
	}
	return netip.Addr{}, errors.New("基础设施 DoH 解析不可用或未返回公网 IPv4；未使用系统 DNS 回退")
}

func queryInfrastructureDNS(ctx context.Context, client *http.Client, server string, q *dns.Msg, wire []byte) (netip.Addr, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, server, bytes.NewReader(wire))
	if err != nil {
		return netip.Addr{}, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := client.Do(req)
	if err != nil {
		return netip.Addr{}, errors.New("DoH 查询失败")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 65536))
	var answer dns.Msg
	if err != nil || resp.StatusCode != http.StatusOK || answer.Unpack(body) != nil || answer.Id != q.Id ||
		!answer.Response || answer.Truncated || answer.Rcode != dns.RcodeSuccess || len(answer.Question) != 1 ||
		!strings.EqualFold(answer.Question[0].Name, q.Question[0].Name) || answer.Question[0].Qtype != dns.TypeA || answer.Question[0].Qclass != dns.ClassINET {
		return netip.Addr{}, errors.New("DoH 响应无效")
	}
	return firstPublicA(&answer)
}

func firstPublicA(answer *dns.Msg) (netip.Addr, error) {
	if answer == nil || answer.Rcode != dns.RcodeSuccess {
		return netip.Addr{}, errors.New("DNS 查询未返回成功结果")
	}
	for _, rr := range answer.Answer {
		if a, ok := rr.(*dns.A); ok {
			if ip, ok := netip.AddrFromSlice(a.A); ok && publicIP(ip) {
				return ip.Unmap(), nil
			}
		}
	}
	return netip.Addr{}, errors.New("未解析到可用公网 IPv4 地址")
}

func usageSummary(raw string) string {
	var parts []string
	for _, field := range strings.Split(raw, ";") {
		kv := strings.SplitN(strings.TrimSpace(field), "=", 2)
		if len(kv) != 2 {
			continue
		}
		if kv[0] != "upload" && kv[0] != "download" && kv[0] != "total" && kv[0] != "expire" {
			continue
		}
		if _, err := strconv.ParseUint(kv[1], 10, 64); err == nil {
			parts = append(parts, kv[0]+"="+kv[1])
		}
	}
	return strings.Join(parts, "; ")
}

func Fetch(ctx context.Context, client *http.Client, rawURL string) ([]byte, string, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return nil, "", errors.New("订阅需要完整的 HTTPS 网址，不支持地址内用户名和密码")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, "", errors.New("订阅网址无效")
	}
	req.Header.Set("User-Agent", "clash.meta/AgentVM")
	res, err := client.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("订阅下载失败：%w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", errors.New("订阅服务器返回 HTTP " + strconv.Itoa(res.StatusCode))
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, MaxImport+1))
	if err != nil || len(b) > MaxImport {
		return nil, "", errors.New("订阅下载中断或超过 8 MiB")
	}
	usage := ""
	if raw := res.Header.Get("Subscription-Userinfo"); len(raw) < 300 {
		usage = usageSummary(raw)
	}
	return b, usage, nil
}
