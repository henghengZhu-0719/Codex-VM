//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "path/filepath"
 "strings"
 "time"
)

type VolumeRequest struct {
 Action string `json:"action"`
 Path string `json:"path"`
 Mode string `json:"mode"`
}

type ProxyRequest struct {
 Action string `json:"action"`
 SourceID string `json:"source_id,omitempty"`
 HostDownload bool `json:"host_download,omitempty"`
 Input json.RawMessage `json:"input,omitempty"`
}

type Managers interface {
 ChangeVolume(context.Context,string,VolumeRequest) error
 NetworkStatus(context.Context)(any,error)
 NetworkQuery(context.Context,string,string)(any,error)
 ChangeProxy(context.Context,ProxyRequest) error
}

// Explicit allowlist: no shell commands, arbitrary arguments or output
// containing proxy credentials are recorded in the task journal.
func ValidateProxyRequest(in ProxyRequest) bool {
 switch in.Action {
 case "config","import","manual","apply":
  if in.SourceID!="" || in.HostDownload{return false}
  raw:=strings.TrimSpace(string(in.Input))
  return len(raw)>1 && raw[0]=='{' && json.Valid(in.Input)
 case "refresh":
  return in.SourceID!="" && len(in.SourceID)<=256 && len(in.Input)==0
 case "delete":
  return in.SourceID!="" && len(in.SourceID)<=256 && !in.HostDownload && len(in.Input)==0
 case "stop","gate-close","probe":
  return in.SourceID=="" && !in.HostDownload && len(in.Input)==0
 }
 return false
}

func registerManagerRoutes(mux *http.ServeMux,inventory Inventory,tasks *TaskManager){
 manager,ok:=inventory.(Managers);if !ok{return}
 send:=func(w http.ResponseWriter,status int,data any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(status);_ = json.NewEncoder(w).Encode(data)
 }
 decode:=func(w http.ResponseWriter,r *http.Request,limit int64,out any)bool{
  r.Body=http.MaxBytesReader(w,r.Body,limit)
  dec:=json.NewDecoder(r.Body);dec.DisallowUnknownFields()
  if err:=dec.Decode(out);err!=nil{return false}
  return dec.Decode(new(any))==io.EOF
 }
 submit:=func(w http.ResponseWriter,kind,target string,work func(context.Context)([]VM,error)){
  t,err:=tasks.SubmitTarget(kind,target,10*time.Minute,work)
  if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
  w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
 }
 mux.HandleFunc("GET /api/v1/network/status",func(w http.ResponseWriter,r *http.Request){
  result,err:=manager.NetworkStatus(r.Context())
  if err!=nil{send(w,503,map[string]string{"error":"network status unavailable"});return}
  send(w,200,result)
 })
 for _,kind:=range []string{"delay","connections"}{
  mux.HandleFunc("GET /api/v1/network/"+kind,func(w http.ResponseWriter,r *http.Request){
   node:=r.URL.Query().Get("node")
   if kind=="delay" && (node=="" || len(node)>256){send(w,400,map[string]string{"error":"node required"});return}
   result,err:=manager.NetworkQuery(r.Context(),kind,node)
   if err!=nil{send(w,503,map[string]string{"error":"network query unavailable"});return}
   send(w,200,result)
  })
 }
 if tasks==nil{return}
 mux.HandleFunc("POST /api/v1/vms/{id}/mounts",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id")
  var in VolumeRequest
  if !namePattern.MatchString(name) || name=="base" || name=="base-building" || !decode(w,r,16384,&in) ||
   (in.Action!="add" && in.Action!="remove") || (in.Mode!="ro" && in.Mode!="rw") || !filepath.IsAbs(in.Path){
   send(w,400,map[string]string{"error":"invalid volume request"});return
  }
  submit(w,"volume-"+in.Action,name,func(ctx context.Context)([]VM,error){return nil,manager.ChangeVolume(ctx,name,in)})
 })
 mux.HandleFunc("POST /api/v1/network/actions",func(w http.ResponseWriter,r *http.Request){
  var in ProxyRequest
  if !decode(w,r,13<<20,&in) || !ValidateProxyRequest(in){send(w,400,map[string]string{"error":"invalid proxy request"});return}
  submit(w,"proxy-"+in.Action,"@network",func(ctx context.Context)([]VM,error){return nil,manager.ChangeProxy(ctx,in)})
 })
}
