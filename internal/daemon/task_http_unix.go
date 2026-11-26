//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "net/http"
 "io"
 "time"
)

func registerTaskRoutes(mux *http.ServeMux,inventory Inventory,tasks *TaskManager,shutdown <-chan struct{}){
 send:=func(w http.ResponseWriter,status int,v any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(status)
  _=json.NewEncoder(w).Encode(v)
 }
 mux.HandleFunc("POST /api/v1/tasks/inventory",func(w http.ResponseWriter,r *http.Request){
  // This endpoint accepts no input and cannot execute arbitrary commands.
  if r.ContentLength!=0{send(w,400,map[string]string{"error":"request body not supported"});return}
  t,err:=tasks.Submit("inventory",inventory.List)
  if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=429};send(w,status,map[string]string{"error":http.StatusText(status)});return}
  w.Header().Set("Location","/api/v1/tasks/"+t.ID)
  send(w,202,t)
 })
 if lifecycle,ok:=inventory.(Lifecycle);ok {
  for _,action:=range []string{"start","stop"} {
   mux.HandleFunc("POST /api/v1/vms/{id}/"+action,func(w http.ResponseWriter,r *http.Request){
    name:=r.PathValue("id")
    if !namePattern.MatchString(name) || name=="base" || name=="base-building" || r.ContentLength!=0 {send(w,400,map[string]string{"error":"invalid VM or request body"});return}
    t,err:=tasks.SubmitTarget("vm-"+action,name,10*time.Minute,func(ctx context.Context)([]VM,error){
     v,err:=lifecycle.Change(ctx,name,action);if err!=nil{return nil,err};return []VM{v},nil
    })
    if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
    w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
   })
  }
 }
 if creator,ok:=inventory.(Creator);ok {
  mux.HandleFunc("POST /api/v1/vms",func(w http.ResponseWriter,r *http.Request){
   r.Body=http.MaxBytesReader(w,r.Body,8192)
   dec:=json.NewDecoder(r.Body);dec.DisallowUnknownFields()
   var input CreateRequest
   if err:=dec.Decode(&input);err!=nil{send(w,400,map[string]string{"error":"invalid create request"});return}
   if err:=dec.Decode(new(any));err!=io.EOF{send(w,400,map[string]string{"error":"unexpected request data"});return}
   input,name,err:=creator.ResolveCreate(input)
   if err!=nil || !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid project or resource settings"});return}
   t,err:=tasks.SubmitTarget("vm-create",name,15*time.Minute,func(ctx context.Context)([]VM,error){
    v,err:=creator.Create(ctx,input,name);if err!=nil{return nil,err};return []VM{v},nil
   })
   if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
   w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
  })
 }
 if lifecycle,ok:=inventory.(Lifecycle);ok{
  mux.HandleFunc("DELETE /api/v1/vms/{id}",func(w http.ResponseWriter,r *http.Request){
   name:=r.PathValue("id")
   if !namePattern.MatchString(name) || name=="base" || name=="base-building" || r.ContentLength!=0 || r.URL.Query().Get("confirm")!=name{
    send(w,400,map[string]string{"error":"explicit VM name confirmation required"});return
   }
   t,err:=tasks.SubmitTarget("vm-delete",name,10*time.Minute,func(ctx context.Context)([]VM,error){
    v,err:=lifecycle.Change(ctx,name,"delete");if err!=nil{return nil,err};return []VM{v},nil
   })
   if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
   w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
  })
 }
 mux.HandleFunc("GET /api/v1/tasks",func(w http.ResponseWriter,r *http.Request){
  snapshot,_:=tasks.Snapshot();send(w,200,snapshot)
 })
 mux.HandleFunc("GET /api/v1/tasks/{id}",func(w http.ResponseWriter,r *http.Request){
  t,ok:=tasks.Get(r.PathValue("id"));if !ok{send(w,404,map[string]string{"error":"task not found"});return};send(w,200,t)
 })
 slots:=make(chan struct{},8)
 mux.HandleFunc("GET /api/v1/events",func(w http.ResponseWriter,r *http.Request){
  select{case slots<-struct{}{}:defer func(){<-slots}();default:send(w,429,map[string]string{"error":"event stream limit reached"});return}
  controller:=http.NewResponseController(w)
  if err:=controller.SetWriteDeadline(time.Time{});err!=nil{send(w,500,map[string]string{"error":"streaming unavailable"});return}
  w.Header().Set("Content-Type","text/event-stream")
  w.Header().Set("Cache-Control","no-cache, no-store")
  w.Header().Set("X-Content-Type-Options","nosniff")
  ticker:=time.NewTicker(15*time.Second);defer ticker.Stop()
  for {
   snapshot,changed:=tasks.Snapshot()
   data,err:=json.Marshal(snapshot);if err!=nil{return}
   if controller.SetWriteDeadline(time.Now().Add(5*time.Second))!=nil{return}
   if _,err=fmt.Fprintf(w,"event: tasks\ndata: %s\n\n",data);err!=nil{return}
   if controller.Flush()!=nil{return}
   select {
   case <-r.Context().Done():return
   case <-shutdown:return
   case <-changed:
   case <-ticker.C:
   }
  }
 })
}
