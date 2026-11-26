//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "net/url"

 "github.com/sylvinus/agent-vm/internal/browser"
 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vm"
 "github.com/sylvinus/agent-vm/internal/vmname"
)

func (d *daemonInventory) BrowserStatus(ctx context.Context,name string)(browser.Status,error){
 d.mu.Lock();defer d.mu.Unlock()
 inst,err:=d.instance(ctx,name);if err!=nil{return browser.Status{},err}
 if inst.Status!=vm.Running{return browser.Status{},errors.New("VM not running")}
 b,err:=d.app.readOnlyBackend();if err!=nil{return browser.Status{},err}
 return browser.Inspect(ctx,b,name)
}

func (d *daemonInventory) BrowserChange(ctx context.Context,name,action string,in browser.Settings)error{
 d.mu.Lock();defer d.mu.Unlock()
 if name==vmname.Template || name=="base-building" || vmname.IsScratch(name){return errors.New("not a managed project VM")}
 unlock,err:=d.app.lockVM(ctx,name);if err!=nil{return err};defer unlock()
 if err=ctx.Err();err!=nil{return err}
 inst,err:=d.instance(ctx,name);if err!=nil{return err}
 if inst.Status!=vm.Running{return errors.New("VM not running")}
 b,err:=d.app.readOnlyBackend();if err!=nil{return err}
 return browser.Change(ctx,b,name,action,in)
}

func daemonBrowserCommand(args []string,streams IO)int{
 if len(args)!=3{fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon browser {status|start|stop|restart} NAME");return 2}
 st,err:=state.Default();if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
 path:="/api/v1/vms/"+url.PathEscape(args[2])+"/browser"
 var result any
 switch args[1]{
 case "status":err=c.Get(context.Background(),path,&result)
 case "start","stop","restart":err=c.SubmitManager(context.Background(),path+"/"+args[1],browser.Settings{},&result)
 default:return 2
 }
 if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
 if err=enc.Encode(result);err!=nil{return 1};return 0
}
