//go:build darwin || linux

package cli

import (
 "context"
 "encoding/json"
 "fmt"
 "net/url"
 "github.com/sylvinus/agent-vm/internal/daemon"
 "github.com/sylvinus/agent-vm/internal/resource"
 "github.com/sylvinus/agent-vm/internal/state"
 "github.com/sylvinus/agent-vm/internal/vm"
)

func (d *daemonInventory) ResourceStatus(ctx context.Context,name string)(daemon.ResourceStatus,error){
 d.mu.Lock();defer d.mu.Unlock()
 inst,err:=d.instance(ctx,name);if err!=nil{return daemon.ResourceStatus{},err}
 result:=daemon.ResourceStatus{VM:vmDTO(inst)}
 if inst.Status!=vm.Running{return result,nil}
 b,err:=d.app.readOnlyBackend();if err!=nil{return result,err}
 if metrics,err:=resource.Inspect(ctx,b,name);err==nil{result.Guest=&metrics;result.GuestAvailable=true}
 if balloon,err:=resource.InspectBalloon(ctx,inst.Dir);err==nil{result.Balloon=&balloon;result.BalloonAvailable=true}
 return result,nil
}

func daemonUsageCommand(args []string,streams IO)int{
 if len(args)!=2{fmt.Fprintln(streams.Stderr,"Usage: agent-vm daemon usage NAME");return 2}
 st,err:=state.Default();if err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 c:=daemon.NewClient(daemon.SocketPath(string(st)));defer c.Close()
 var result any
 if err=c.Get(context.Background(),"/api/v1/vms/"+url.PathEscape(args[1])+"/usage",&result);err!=nil{fmt.Fprintln(streams.Stderr,err);return 1}
 enc:=json.NewEncoder(streams.Stdout);enc.SetIndent("","  ")
 if err=enc.Encode(result);err!=nil{return 1};return 0
}
