//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "time"
 "github.com/sylvinus/agent-vm/internal/session"
)

type SessionRequest struct {
 Name string `json:"name"`
 Agent string `json:"agent"`
}
type SessionManager interface {
 Sessions(context.Context,string)([]session.Session,error)
 SessionTools(context.Context,string)(session.Tools,error)
 ChangeSession(context.Context,string,string,SessionRequest)error
}

func registerSessionRoutes(mux *http.ServeMux,inventory Inventory,tasks *TaskManager){
 manager,ok:=inventory.(SessionManager);if !ok{return}
 send:=func(w http.ResponseWriter,status int,data any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(status);_ = json.NewEncoder(w).Encode(data)
 }
 mux.HandleFunc("GET /api/v1/vms/{id}/sessions",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id");if !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid VM name"});return}
  result,err:=manager.Sessions(r.Context(),name);if err!=nil{send(w,503,map[string]string{"error":"session inventory unavailable"});return};send(w,200,result)
 })
 mux.HandleFunc("GET /api/v1/vms/{id}/sessions/tools",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id");if !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid VM name"});return}
  result,err:=manager.SessionTools(r.Context(),name);if err!=nil{send(w,503,map[string]string{"error":"tools unavailable"});return};send(w,200,result)
 })
 if tasks==nil{return}
 mux.HandleFunc("POST /api/v1/vms/{id}/sessions/install-tmux",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id");if !namePattern.MatchString(name)||r.ContentLength!=0{send(w,400,map[string]string{"error":"invalid request"});return}
  t,err:=tasks.SubmitTarget("session-install-tmux",name,5*time.Minute,func(ctx context.Context)([]VM,error){return nil,manager.ChangeSession(ctx,name,"install-tmux",SessionRequest{})})
  if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
  w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
 })
 for _,action:=range []string{"create","stop"}{
  mux.HandleFunc("POST /api/v1/vms/{id}/sessions/"+action,func(w http.ResponseWriter,r *http.Request){
   name:=r.PathValue("id")
   r.Body=http.MaxBytesReader(w,r.Body,4096)
   dec:=json.NewDecoder(r.Body);dec.DisallowUnknownFields()
   var in SessionRequest
   if !namePattern.MatchString(name)||dec.Decode(&in)!=nil||dec.Decode(new(any))!=io.EOF||!session.ValidName(in.Name)||(action=="create"&&!session.ValidAgent(in.Agent))||(action=="stop"&&in.Agent!=""){
    send(w,400,map[string]string{"error":"invalid session request"});return
   }
   t,err:=tasks.SubmitTarget("session-"+action,name,time.Minute,func(ctx context.Context)([]VM,error){return nil,manager.ChangeSession(ctx,name,action,in)})
   if err!=nil{status:=503;if errors.Is(err,ErrBusy){status=409};send(w,status,map[string]string{"error":http.StatusText(status)});return}
   w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
  })
 }
}
