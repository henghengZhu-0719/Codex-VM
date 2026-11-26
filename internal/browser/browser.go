// Package browser runs the existing guest Chromium lifecycle over the VM backend.
package browser

import (
 "bytes"
 "context"
 _ "embed"
 "encoding/base64"
 "encoding/json"
 "errors"
 "fmt"
 "io"
 "strings"

 "github.com/sylvinus/agent-vm/internal/vm"
)

//go:embed scripts/status.py
var statusScript string
//go:embed scripts/prepare.py
var prepareScript string
//go:embed scripts/stop.py
var stopScript string

type Status struct {
 Installed bool `json:"installed"`
 Running bool `json:"appRunning"`
 PID int `json:"browserPID"`
 RSSMB int `json:"browserRSSMB"`
 TreeRSSMB int `json:"browserTreeRSSMB"`
 ProcessCount int `json:"browserProcessCount"`
 CPUSeconds float64 `json:"browserCPUSeconds"`
 CDPAvailable bool `json:"cdpAvailable"`
 Missing []string `json:"missing"`
}

type Settings struct {
 Width int `json:"width"`
 Height int `json:"height"`
 Scale float64 `json:"scale"`
}

func run(ctx context.Context,b vm.Backend,name,script string)([]byte,error){
 var out bytes.Buffer
 code,err:=b.Shell(ctx,name,vm.ShellOpts{Args:[]string{"python3","-u","-"},Stdin:strings.NewReader(script),Stdout:&out,Stderr:io.Discard})
 if err!=nil{return nil,err}
 if code!=0{return nil,fmt.Errorf("browser guest command exited %d",code)}
 return out.Bytes(),nil
}

func Inspect(ctx context.Context,b vm.Backend,name string)(Status,error){
 raw,err:=run(ctx,b,name,statusScript);if err!=nil{return Status{},err}
 var status Status
 if err=json.Unmarshal(raw,&status);err!=nil{return Status{},err}
 return status,nil
}

func Change(ctx context.Context,b vm.Backend,name,action string,settings Settings)error{
 switch action{
 case "stop":
  if _,err:=run(ctx,b,name,stopScript);err!=nil{return err}
 case "start","restart":
  if settings.Width==0{settings.Width=1280}
  if settings.Height==0{settings.Height=800}
  if settings.Scale==0{settings.Scale=1}
  data,err:=json.Marshal(map[string]any{"name":name,"width":settings.Width,"height":settings.Height,"scale":settings.Scale,"restartApp":action=="restart"})
  if err!=nil{return err}
  prefix:="import json, base64\nsettings = json.loads(base64.b64decode('"+base64.StdEncoding.EncodeToString(data)+"'))\n"
  if _,err=run(ctx,b,name,prefix+prepareScript);err!=nil{return err}
 default:return errors.New("invalid browser action")
 }
 status,err:=Inspect(ctx,b,name);if err!=nil{return err}
 if action=="stop"{if status.Running{return errors.New("browser still running")}}else if !status.Running || !status.CDPAvailable{return errors.New("browser health check failed")}
 return nil
}
