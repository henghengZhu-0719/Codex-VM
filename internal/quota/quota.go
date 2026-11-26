package quota

import (
 "bytes"
 "context"
 _ "embed"
 "encoding/json"
 "errors"
 "io"
 "strings"
 "time"

 "github.com/sylvinus/agent-vm/internal/vm"
)

//go:embed query.py
var script string

type Window struct {
 Label string `json:"label"`
 UsedPercent int `json:"used_percent"`
 ResetAfterSeconds *int64 `json:"reset_after_seconds,omitempty"`
 ResetAt *int64 `json:"reset_at,omitempty"`
}
type Agent struct {
 Status string `json:"status"`
 PlanType string `json:"plan_type,omitempty"`
 Windows []Window `json:"windows,omitempty"`
}
type Snapshot struct {
 Agents map[string]Agent `json:"agents"`
 FetchedAt time.Time `json:"fetched_at"`
}

// Credentials remain inside the guest. Only typed usage fields are returned.
func Query(ctx context.Context,b vm.Backend,name string)(Snapshot,error){
 ctx,cancel:=context.WithTimeout(ctx,75*time.Second);defer cancel()
 var out bytes.Buffer
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Args:[]string{"python3","-"},Stdin:strings.NewReader(script),Stdout:&out,Stderr:io.Discard})
 if err!=nil{return Snapshot{},err}
 if code!=0{return Snapshot{},errors.New("quota query failed")}
 var snap Snapshot
 if err=json.Unmarshal(out.Bytes(),&snap);err!=nil{return Snapshot{},err}
 if snap.Agents==nil{return Snapshot{},errors.New("invalid quota response")}
 for name,a:=range snap.Agents{
  if name!="codex" && name!="agy" && name!="claude"{delete(snap.Agents,name);continue}
  if len(a.PlanType)>80 || strings.Contains(a.PlanType,"@"){a.PlanType=""}
  for i:=range a.Windows{a.Windows[i].UsedPercent=max(0,min(100,a.Windows[i].UsedPercent))}
  snap.Agents[name]=a
 }
 snap.FetchedAt=time.Now().UTC()
 return snap,nil
}
