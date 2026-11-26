//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "time"

 "github.com/sylvinus/agent-vm/internal/browser"
)

type BrowserManager interface {
 BrowserStatus(context.Context,string)(browser.Status,error)
 BrowserChange(context.Context,string,string,browser.Settings)error
}

func registerBrowserRoutes(mux *http.ServeMux,inventory Inventory,tasks *TaskManager){
 manager,ok:=inventory.(BrowserManager);if !ok{return}
 send:=func(w http.ResponseWriter,status int,data any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(status);_ = json.NewEncoder(w).Encode(data)
 }
 mux.HandleFunc("GET /api/v1/vms/{id}/browser",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id")
  if !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid VM name"});return}
  result,err:=manager.BrowserStatus(r.Context(),name)
  if err!=nil{send(w,503,map[string]string{"error":"browser status unavailable"});return}
  send(w,200,result)
 })
 if tasks==nil{return}
 for _,action:=range []string{"start","stop","restart"}{
  mux.HandleFunc("POST /api/v1/vms/{id}/browser/"+action,func(w http.ResponseWriter,r *http.Request){
   name:=r.PathValue("id")
   if !namePattern.MatchString(name) || name=="base" || name=="base-building"{send(w,400,map[string]string{"error":"invalid VM name"});return}
   var in browser.Settings
   if r.ContentLength!=0{
    r.Body=http.MaxBytesReader(w,r.Body,4096)
    dec:=json.NewDecoder(r.Body);dec.DisallowUnknownFields()
    if err:=dec.Decode(&in);err!=nil || dec.Decode(new(any))!=io.EOF{send(w,400,map[string]string{"error":"invalid settings"});return}
   }
   if in.Width<0 || in.Width>4096 || in.Height<0 || in.Height>2560 || in.Scale<0 || in.Scale>2{send(w,400,map[string]string{"error":"invalid dimensions"});return}
   t,err:=tasks.SubmitTarget("browser-"+action,name,2*time.Minute,func(ctx context.Context)([]VM,error){return nil,manager.BrowserChange(ctx,name,action,in)})
   if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
   w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
  })
 }
}
