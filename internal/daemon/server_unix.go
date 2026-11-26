//go:build darwin || linux

package daemon

import (
 "context"
 "encoding/json"
 "errors"
 "fmt"
 "log/slog"
 "net"
 "net/http"
 "os"
 "path/filepath"
 "regexp"
 "syscall"
 "time"
)

type VM struct {
 Name string `json:"name"`
 Status string `json:"status"`
 CPUs int `json:"cpus"`
 Memory int64 `json:"memory_bytes"`
 Disk int64 `json:"disk_bytes"`
}

type Inventory interface {
 List(context.Context) ([]VM,error)
 Get(context.Context,string) (VM,error)
 Mounts(context.Context,string) (any,error)
}

var ErrNotFound=errors.New("VM not found")
var namePattern=regexp.MustCompile("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$")

func SocketPath(state string) string { return filepath.Join(state,"run","agent-vm.sock") }

func Handler(inventory Inventory) http.Handler {
 return handler(inventory,nil,nil)
}

func handler(inventory Inventory,tasks *TaskManager,shutdown <-chan struct{}) http.Handler {
 mux:=http.NewServeMux()
 send:=func(w http.ResponseWriter,status int,v any){
  w.Header().Set("Content-Type","application/json")
  w.Header().Set("Cache-Control","no-store")
  w.WriteHeader(status)
  _=json.NewEncoder(w).Encode(v)
 }
 fail:=func(w http.ResponseWriter,err error){
  status:=http.StatusServiceUnavailable
  if errors.Is(err,ErrNotFound){status=http.StatusNotFound}
  // Avoid exposing local paths or credentials from backend errors.
  slog.Warn("inventory request failed","status",status)
  send(w,status,map[string]string{"error":http.StatusText(status)})
 }
 mux.HandleFunc("GET /health",func(w http.ResponseWriter,r *http.Request){
  send(w,200,map[string]any{"status":"ok","api_version":1})
 })
 mux.HandleFunc("GET /api/v1/vms",func(w http.ResponseWriter,r *http.Request){
  v,err:=inventory.List(r.Context());if err!=nil{fail(w,err);return}
  if v==nil{v=[]VM{}}
  send(w,200,v)
 })
 lookup:=func(w http.ResponseWriter,r *http.Request,kind string){
  name:=r.PathValue("id")
  if !namePattern.MatchString(name){send(w,400,map[string]string{"error":"invalid VM name"});return}
  if kind=="mounts" {
   v,err:=inventory.Mounts(r.Context(),name);if err!=nil{fail(w,err);return};send(w,200,v);return
  }
  v,err:=inventory.Get(r.Context(),name);if err!=nil{fail(w,err);return};send(w,200,v)
 }
 mux.HandleFunc("GET /api/v1/vms/{id}",func(w http.ResponseWriter,r *http.Request){lookup(w,r,"detail")})
 mux.HandleFunc("GET /api/v1/vms/{id}/resources",func(w http.ResponseWriter,r *http.Request){lookup(w,r,"resources")})
 mux.HandleFunc("GET /api/v1/vms/{id}/mounts",func(w http.ResponseWriter,r *http.Request){lookup(w,r,"mounts")})
 if tasks!=nil{registerTaskRoutes(mux,inventory,tasks,shutdown)}
 registerManagerRoutes(mux,inventory,tasks)
 registerBrowserRoutes(mux,inventory,tasks)
 registerResourceRoutes(mux,inventory)
 return http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  // No browser-origin requests; this is a local native-client protocol.
  if r.Header.Get("Origin")!="" || r.Host!="agent-vm" {send(w,403,map[string]string{"error":"forbidden"});return}
  mux.ServeHTTP(w,r)
 })
}

func Serve(ctx context.Context,state string, inventory Inventory) error {
 socket:=SocketPath(state)
 dir:=filepath.Dir(socket)
 if err:=os.MkdirAll(dir,0700);err!=nil{return err}
 info,err:=os.Lstat(dir);if err!=nil{return err}
 owner,ok:=info.Sys().(*syscall.Stat_t)
 if !info.IsDir() || !ok || int(owner.Uid)!=os.Getuid() || info.Mode().Perm()!=0700 {
  return fmt.Errorf("daemon run directory must be owned by current user with mode 0700")
 }
 // Never unlink the lock file: the kernel releases the lock on exit.
 lock,err:=os.OpenFile(filepath.Join(dir,"agent-vm.lock"),os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW,0600)
 if err!=nil{return err};defer lock.Close()
 if err=syscall.Flock(int(lock.Fd()),syscall.LOCK_EX|syscall.LOCK_NB);err!=nil{return fmt.Errorf("daemon lock: %w",err)}
 if old,err:=os.Lstat(socket);err==nil{
  if old.Mode()&os.ModeSocket==0{return errors.New("refusing to remove non-socket at daemon path")}
  conn,dialErr:=net.DialTimeout("unix",socket,time.Second)
  if dialErr==nil{conn.Close();return errors.New("daemon socket is already active")}
  if !errors.Is(dialErr,syscall.ECONNREFUSED){return fmt.Errorf("cannot verify stale socket: %w",dialErr)}
  if err=os.Remove(socket);err!=nil{return err}
 }else if !os.IsNotExist(err){return err}
 listener,err:=net.Listen("unix",socket);if err!=nil{return err}
 defer listener.Close()
 if err=os.Chmod(socket,0600);err!=nil{return err}
 tasks,err:=NewTaskManager(ctx,filepath.Join(dir,"tasks.json"));if err!=nil{return err}
 streamCtx,stopStreams:=context.WithCancel(ctx);defer stopStreams()
 defer func(){closeCtx,cancel:=context.WithTimeout(context.Background(),10*time.Second);defer cancel();if err:=tasks.Close(closeCtx);err!=nil{slog.Error("task shutdown incomplete","error",err)}}()
 srv:=&http.Server{Handler:handler(inventory,tasks,streamCtx.Done()),ReadHeaderTimeout:5*time.Second,ReadTimeout:10*time.Second,WriteTimeout:30*time.Second,IdleTimeout:30*time.Second,MaxHeaderBytes:16<<10}
 stopped:=make(chan struct{})
 shutdownDone:=make(chan struct{})
 go func(){defer close(shutdownDone);select{case <-ctx.Done():
  shutdown,cancel:=context.WithTimeout(context.Background(),10*time.Second)
  defer cancel()
  if srv.Shutdown(shutdown)!=nil{_ = srv.Close()}
 case <-stopped:}}()
 slog.Info("agent-vm daemon listening")
 err=srv.Serve(listener)
 stopStreams()
 close(stopped)
 <-shutdownDone
 if errors.Is(err,http.ErrServerClosed){return nil}
 return err
}
