//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "os"
 "os/signal"
 "sync"
 "syscall"

 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vm"
)

// A single app owns the existing read-only backend. Serialize calls until
// its thread-safety and shared Lima configuration have been audited.
type daemonInventory struct { app *app; mu sync.Mutex }

func vmDTO(v *vm.Instance) daemon.VM {
 return daemon.VM{Name:v.Name, Status:string(v.Status), CPUs:v.CPUs, Memory:v.Memory, Disk:v.Disk}
}

func (d *daemonInventory) List(ctx context.Context)([]daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 vms,err:=d.app.lookVMs(ctx);if err!=nil{return nil,err}
 out:=make([]daemon.VM,0,len(vms))
 for _,v:=range vms{out=append(out,vmDTO(v))}
 return out,nil
}

func (d *daemonInventory) instance(ctx context.Context,name string)(*vm.Instance,error){
 b,err:=d.app.readOnlyBackend();if err!=nil{return nil,err}
 v,err:=b.Get(ctx,name)
 if errors.Is(err,vm.ErrNotFound){return nil,daemon.ErrNotFound}
 return v,err
}

func (d *daemonInventory) Get(ctx context.Context,name string)(daemon.VM,error){
 d.mu.Lock();defer d.mu.Unlock()
 v,err:=d.instance(ctx,name);if err!=nil{return daemon.VM{},err};return vmDTO(v),nil
}

func (d *daemonInventory) Mounts(ctx context.Context,name string)(any,error){
 d.mu.Lock();defer d.mu.Unlock()
 v,err:=d.instance(ctx,name);if err!=nil{return nil,err};return v.Mounts,nil
}

func daemonCommand(args []string, streams IO) int {
 if len(args)!=1 {fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon <serve|status|list>");return 2}
 st,err:=state.Default()
 if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 switch args[0]{
 case "serve":
  a,err:=newApp(IO{Stdin:nil,Stdout:io.Discard,Stderr:streams.Stderr})
  if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  ctx,cancel:=signal.NotifyContext(context.Background(),os.Interrupt,syscall.SIGTERM);defer cancel()
  if err=daemon.Serve(ctx,string(st),&daemonInventory{app:a});err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  return 0
 case "status","list":
  c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
  path:="/health";if args[0]=="list"{path="/api/v1/vms"}
  var result any
  if err:=c.Get(context.Background(),path,&result);err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
  enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
  if err:=enc.Encode(result);err!=nil{return 1};return 0
 default:
  fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon <serve|status|list>");return 2
 }
}
