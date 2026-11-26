//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "net/url"
 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/quota"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vm"
 "github.com/sylvinus/agent-vm/internal/vmname"
)

func (d *daemonInventory) CachedQuota(name string)(quota.Snapshot,bool){
 d.quotaMu.Lock();defer d.quotaMu.Unlock()
 v,ok:=d.quotas[name];return v,ok
}

func (d *daemonInventory) RefreshQuota(ctx context.Context,name string)error{
 d.mu.Lock();defer d.mu.Unlock()
 if name==vmname.Template || name=="base-building" || vmname.IsScratch(name){return errors.New("not a project VM")}
 inst,err:=d.instance(ctx,name);if err!=nil{return err}
 if inst.Status!=vm.Running{return errors.New("VM not running")}
 b,err:=d.app.readOnlyBackend();if err!=nil{return err}
 snap,err:=quota.Query(ctx,b,name);if err!=nil{return err}
 d.quotaMu.Lock();defer d.quotaMu.Unlock()
 if d.quotas==nil{d.quotas=make(map[string]quota.Snapshot)}
 d.quotas[name]=snap
 return nil
}

func daemonQuotaCommand(args []string,streams IO)int{
 if len(args)!=3 || (args[1]!="status" && args[1]!="refresh"){fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon quota {status|refresh} VM");return 2}
 st,err:=state.Default();if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
 path:="/api/v1/vms/"+url.PathEscape(args[2])+"/quotas"
 var result any
 if args[1]=="refresh"{err=c.SubmitEmpty(context.Background(),path+"/refresh",&result)}else{err=c.Get(context.Background(),path,&result)}
 if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
 if err=enc.Encode(result);err!=nil{return 1};return 0
}
