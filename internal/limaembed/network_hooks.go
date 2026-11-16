package limaembed

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "net"
 "net/netip"
 "os"
 "path/filepath"
 "strings"

 limadns "github.com/lima-vm/lima/v2/pkg/hostagent/dns"
 mdns "github.com/miekg/dns"
 "github.com/lima-vm/lima/v2/pkg/networks/usernet"
 "github.com/sylvinus/agent-vm/internal/egress"
 "github.com/sylvinus/agent-vm/internal/netgate"
 "github.com/sylvinus/agent-vm/internal/netguard"
)

const managedNetworkConfigEnv = "AGENT_VM_MANAGED_NETWORK_CONFIG"

type managedNetworkConfig struct {
 ProxyURL string `json:"proxy_url"`
 DNSURL string `json:"dns_url"`
}

func loadManagedNetworkConfig(path string)(managedNetworkConfig,error){
 var cfg managedNetworkConfig
 fi,err:=os.Lstat(path);if err!=nil{return cfg,err}
 if !fi.Mode().IsRegular(){return cfg,errors.New("managed network config must be a regular file")}
 if fi.Mode().Perm()&0077!=0{return cfg,errors.New("managed network config must not be group/world readable")}
 f,err:=os.Open(path);if err!=nil{return cfg,err};defer f.Close()
 decoder:=json.NewDecoder(io.LimitReader(f,65537));decoder.DisallowUnknownFields()
 if err:=decoder.Decode(&cfg);err!=nil{return cfg,fmt.Errorf("invalid managed network JSON: %w",err)}
 var extra any
 if decoder.Decode(&extra)!=io.EOF{return cfg,errors.New("managed network config must contain one JSON object")}
 if cfg.ProxyURL=="" || cfg.DNSURL=="" {return cfg,errors.New("both proxy_url and dns_url are required")}
 return cfg,nil
}

// installManagedNetwork is called before HostAgent starts the guest.
// It deliberately keeps the gate CLOSED: only a trusted host-side safety
// checker/control socket (future phase) may authorize an epoch.
func installManagedNetwork(path string, policy *netguard.Policy, instance string)(*netgate.Gate,func(context.Context,uint64) netgate.SafetyReport,error){
 cfg,err:=loadManagedNetworkConfig(filepath.Clean(path));if err!=nil{return nil,nil,err}
 // No ordinary netguard allow rule may widen a managed proxy guest's access
 // to host/private addresses or to UDP.
 defaultPolicy:=&netguard.Policy{}
 public:=func(network string,dst netip.AddrPort)bool{
  if network!="tcp" || !dst.IsValid() || !dst.Addr().Unmap().Is4(){return false}
  addr:=dst.Addr().Unmap()
  if !addr.IsGlobalUnicast() || addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast(){return false}
  return defaultPolicy.Allows("tcp",dst) && policy.Allows("tcp",dst)
 }
 dialer,err:=egress.New(cfg.ProxyURL,public);if err!=nil{return nil,nil,err}
 gate:=netgate.New()
 resolver,err:=egress.NewResolverWithTracker(dialer,cfg.DNSURL,gate.Dial);if err!=nil{return nil,nil,err}
 usernet.Outbound=func(network string,dst netip.AddrPort)bool{
  state,_:=gate.Status()
  return state==netgate.Open && public(network,dst)
 }
 usernet.GuestDial=func(ctx context.Context,network,addr string)(net.Conn,error){
  if network!="tcp" {return nil,egress.ErrDenied}
  dst,err:=netip.ParseAddrPort(addr)
  if err!=nil || !public(network,dst){return nil,egress.ErrDenied}
  return gate.Dial(ctx,func(ctx context.Context)(net.Conn,error){return dialer.DialContext(ctx,"tcp",dst)})
 }
 exchange:=func(ctx context.Context,q *mdns.Msg)(*mdns.Msg,error){
  state,epoch:=gate.Status()
  if state!=netgate.Open{return nil,netgate.ErrClosed}
  response,err:=resolver.Exchange(ctx,q)
  stateAfter,newEpoch:=gate.Status()
  if stateAfter!=netgate.Open || epoch!=newEpoch{return nil,netgate.ErrStale}
  return response,err
 }
 usernet.DNSExchange=exchange
 limadns.Exchange=exchange
 usernet.Names=nil;usernet.Answered=nil
 limadns.Names=nil;limadns.Answered=nil
 check,err:=newSafetyProbe(cfg,policy,gate,dialer,instance);if err!=nil{return nil,nil,err}
 return gate,check,nil
}

// ManagedNetworkRequested returns true only when a config path is explicitly
// passed by the trusted host process. The guest never receives the file path.
func managedNetworkRequested() string {return strings.TrimSpace(os.Getenv(managedNetworkConfigEnv))}
