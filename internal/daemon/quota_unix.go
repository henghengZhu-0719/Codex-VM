//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "net/http"
 "time"
 "github.com/sylvinus/agent-vm/internal/quota"
)

type QuotaManager interface {
 CachedQuota(string)(quota.Snapshot,bool)
 RefreshQuota(context.Context,string)error
}

func registerQuotaRoutes(mux *http.ServeMux,inventory Inventory,tasks *TaskManager){
 manager,ok:=inventory.(QuotaManager);if !ok{return}
 send:=func(w http.ResponseWriter,code int,data any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(code);_ = json.NewEncoder(w).Encode(data)
 }
 mux.HandleFunc("GET /api/v1/vms/{id}/quotas",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id");if !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid VM name"});return}
  snap,ok:=manager.CachedQuota(name)
  if !ok{send(w,200,map[string]any{"available":false});return}
  send(w,200,map[string]any{"available":true,"stale":time.Since(snap.FetchedAt)>20*time.Minute,"snapshot":snap})
 })
 if tasks==nil{return}
 mux.HandleFunc("POST /api/v1/vms/{id}/quotas/refresh",func(w http.ResponseWriter,r *http.Request){
  name:=r.PathValue("id");if !namePattern.MatchString(name)||r.ContentLength!=0{send(w,400,map[string]string{"error":"invalid request"});return}
  t,err:=tasks.SubmitTarget("quota-refresh",name,90*time.Second,func(ctx context.Context)([]VM,error){return nil,manager.RefreshQuota(ctx,name)})
  if err!=nil{send(w,409,map[string]string{"error":"task unavailable"});return}
  w.Header().Set("Location","/api/v1/tasks/"+t.ID);send(w,202,t)
 })
}
