//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "net/http"
 "github.com/sylvinus/agent-vm/internal/resource"
)

type ResourceStatus struct {
 VM VM `json:"vm"`
 Guest *resource.Metrics `json:"guest,omitempty"`
 Balloon *resource.Balloon `json:"balloon,omitempty"`
 GuestAvailable bool `json:"guest_available"`
 BalloonAvailable bool `json:"balloon_available"`
}

type ResourceManager interface {
 ResourceStatus(context.Context,string)(ResourceStatus,error)
}

func registerResourceRoutes(mux *http.ServeMux,inventory Inventory){
 mux.HandleFunc("GET /api/v1/vms/{id}/usage",func(w http.ResponseWriter,r *http.Request){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  name:=r.PathValue("id")
  if !namePattern.MatchString(name){w.WriteHeader(400);_ = json.NewEncoder(w).Encode(map[string]string{"error":"invalid VM name"});return}
  manager,ok:=inventory.(ResourceManager)
  if !ok{w.WriteHeader(501);return}
  status,err:=manager.ResourceStatus(r.Context(),name)
  if err!=nil{w.WriteHeader(503);_ = json.NewEncoder(w).Encode(map[string]string{"error":"resource status unavailable"});return}
  _=json.NewEncoder(w).Encode(status)
 })
}
