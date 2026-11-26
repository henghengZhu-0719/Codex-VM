//go:build darwin || linux

package cli

import (
 "bytes"
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "path/filepath"
 "time"
 "github.com/sylvinus/agent-vm/internal/managedproxy"
 "net/url"

 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vmname"
)

// Construct an isolated command adapter rather than mutating shared IO
// or copying the app's synchronization primitives.
func (d *daemonInventory) managerApp(input io.Reader)*app{
 return &app{io:IO{Stdin:input,Stdout:io.Discard,Stderr:io.Discard},state:d.app.state,ui:d.app.ui,newBack:d.app.readOnlyBackend}
}

func (d *daemonInventory) ChangeVolume(ctx context.Context,name string,in daemon.VolumeRequest)error{
 d.mu.Lock();defer d.mu.Unlock()
 if name==vmname.Template || name=="base-building" || vmname.IsScratch(name){return errors.New("not a managed project VM")}
 if err:=ctx.Err();err!=nil{return err}
 a:=d.managerApp(nil)
 if a.vmVolumeCmd(ctx,[]string{in.Action,name,in.Path,in.Mode})!=0{return errors.New("volume settings not saved")}
 return nil
}

func (d *daemonInventory) NetworkStatus(ctx context.Context)(any,error){
 a:=d.managerApp(nil)
 unlock,err:=a.lockVM(ctx,"app-proxy");if err!=nil{return nil,err};defer unlock()
 st,err:=a.buildProxyStatus(ctx);if err!=nil{return nil,err}
 // Retain selection and basic source/node metadata; omit raw URLs,
 // arbitrary backend errors, probe bodies and gate control credentials.
 sources:=make([]map[string]any,0,len(st.Sources))
 for _,src:=range st.Sources {
  sources=append(sources,map[string]any{"id":src.ID,"name":src.Name,"remote":src.Remote,"interval_hours":src.Interval,"updated_at":src.Updated,"nodes":src.Nodes})
 }
 return map[string]any{"proxy_mode":st.ProxyMode,"managed_enabled":st.ManagedEnabled,"use_proxy":st.UseProxy,"running":st.Running,
  "core_available":st.CoreAvailable,"port":st.Port,"selected":st.Selected,"route":st.Route,"sources":sources,"gate_count":len(st.Gates)},nil
}

// Queries use the existing proxy lock without occupying the VM operation lane.
func (d *daemonInventory) NetworkQuery(ctx context.Context,kind,node string)(any,error){
 a:=d.managerApp(nil)
 ctx,cancel:=context.WithTimeout(ctx,12*time.Second);defer cancel()
 unlock,err:=a.lockVM(ctx,"app-proxy");if err!=nil{return nil,err};defer unlock()
 switch kind {
 case "delay":
  s,err:=managedproxy.Load(string(a.state));if err!=nil{return nil,err}
  delay,err:=managedproxy.Delay(ctx,string(a.state),s,node);if err!=nil{return nil,err}
  return map[string]any{"node":node,"delay_ms":delay},nil
 case "connections":
  // Unlike the legacy helper, distinguish controller failure from no traffic.
  var raw struct {
   Upload int64 `json:"uploadTotal"`
   Download int64 `json:"downloadTotal"`
   Connections []struct {
    Upload int64 `json:"upload"`
    Download int64 `json:"download"`
    Metadata struct { Network string `json:"network"` } `json:"metadata"`
   } `json:"connections"`
  }
  if err:=managedproxy.API(ctx,string(a.state),"GET","/connections",nil,&raw);err!=nil{return nil,err}
  return map[string]any{"upload_total":raw.Upload,"download_total":raw.Download,"connection_count":len(raw.Connections)},nil
 }
 return nil,errors.New("unsupported network query")
}

func (d *daemonInventory) VerifyEgress(ctx context.Context) error {
	s, err := managedproxy.Load(string(d.app.state))
	if err != nil {
		// No managed proxy config exists yet; default host network isolation applies.
		return nil
	}
	if !s.ManagedEnabled {
		return nil
	}
	checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if !managedproxy.Running(checkCtx, string(d.app.state), s) {
		return errors.New("managed proxy is enabled but core is not running; fail-closed egress check failed")
	}
	return nil
}

func (d *daemonInventory) ChangeProxy(ctx context.Context, in daemon.ProxyRequest) error {
 d.mu.Lock();defer d.mu.Unlock()
 if !daemon.ValidateProxyRequest(in){return errors.New("unsupported proxy action")}
 if err:=ctx.Err();err!=nil{return err}
 a:=d.managerApp(bytes.NewReader(in.Input))
 args:=[]string{in.Action}
 if in.SourceID!=""{args=append(args,in.SourceID)}
 if in.HostDownload{args=append(args,"--host")}
 if a.proxyCmd(ctx,args)!=0{return errors.New("proxy operation failed")}
 return nil
}

func daemonManagerCommand(args []string,streams IO)int{
 fail:=func(err error)int{fmt.Fprintln(streams.Stderr,err);return 1}
 usage:=func()int{fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon volume {add|remove} NAME PATH {ro|rw}; daemon proxy {status|config|import|manual|apply|refresh|delete|stop|gate-close|probe|delay|connections}");return 2}
 st,err:=state.Default();if err!=nil{return fail(err)}
 c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
 ctx:=context.Background()
 var result any
 switch args[0]{
 case "volume":
  if len(args)!=5 || (args[1]!="add" && args[1]!="remove"){return usage()}
  path,err:=filepath.Abs(args[3]);if err!=nil{return fail(err)}
  // Resolve path on the local daemon host, not in the guest.
  err=c.SubmitManager(ctx,"/api/v1/vms/"+url.PathEscape(args[2])+"/mounts",daemon.VolumeRequest{Action:args[1],Path:path,Mode:args[4]},&result)
  if err!=nil{return fail(err)}
 case "proxy":
  if len(args)<2{return usage()}
  in:=daemon.ProxyRequest{Action:args[1]}
  if in.Action=="delay" || in.Action=="connections" {
   path:="/api/v1/network/"+in.Action
   if in.Action=="delay"{if len(args)!=3{return usage()};path+="?node="+url.QueryEscape(args[2])}else if len(args)!=2{return usage()}
   if err=c.Get(ctx,path,&result);err!=nil{return fail(err)}
   break
  }
  if in.Action=="status"{
   if len(args)!=2{return usage()}
   if err=c.Get(ctx,"/api/v1/network/status",&result);err!=nil{return fail(err)}
   break
  }
  switch in.Action{
  case "config","import","manual","apply":
   if len(args)!=2 || streams.Stdin==nil{return usage()}
   raw,err:=io.ReadAll(io.LimitReader(streams.Stdin,(12<<20)+1));if err!=nil{return fail(err)}
   if len(raw)>12<<20{return fail(errors.New("proxy input too large"))}
   in.Input=json.RawMessage(raw)
  case "refresh","delete":
   if len(args)<3 || len(args)>4{return usage()}
   in.SourceID=args[2]
   if len(args)==4{if args[3]!="--host" || in.Action!="refresh"{return usage()};in.HostDownload=true}
  default:
   if len(args)!=2{return usage()}
  }
  if !daemon.ValidateProxyRequest(in){return usage()}
  if err=c.SubmitManager(ctx,"/api/v1/network/actions",in,&result);err!=nil{return fail(err)}
 }
 enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
 if err=enc.Encode(result);err!=nil{return fail(err)}
 return 0
}
