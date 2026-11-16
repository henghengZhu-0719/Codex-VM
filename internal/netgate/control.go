package netgate

import (
 "context"
 "crypto/rand"
 "crypto/subtle"
 "encoding/hex"
 "encoding/json"
 "errors"
 "io"
 "net"
 "net/http"
 "os"
 "path/filepath"
 "time"
)

type ControlRecord struct {
 Socket string `json:"socket"`
 Token string `json:"token"`
}

// Control offers status, close and begin-check to a trusted local host client.
// It deliberately DOES NOT expose grant or renew endpoints: untrusted callers
// cannot submit self-attested Passed reports to open the gate.
type Control struct {
 Gate *Gate
 server *http.Server
 listener net.Listener
 dir string
 Record ControlRecord
}

func StartControl(parent string, gate *Gate) (*Control,error){
 if gate==nil{return nil,errors.New("netgate: nil gate")}
 if err:=os.MkdirAll(parent,0700);err!=nil{return nil,err}
 info,err:=os.Lstat(parent)
 if err!=nil{return nil,err}
 if !info.IsDir() || info.Mode().Perm()&0077!=0{return nil,errors.New("netgate: control parent is not private")}
 dir,err:=os.MkdirTemp(parent,"netgate-")
 if err!=nil{return nil,err}
 cleanup:=func(){_ = os.RemoveAll(dir)}
 if err:=os.Chmod(dir,0700);err!=nil{cleanup();return nil,err}
 socket:=filepath.Join(dir,"control.sock")
 listener,err:=net.Listen("unix",socket)
 if err!=nil{cleanup();return nil,err}
 if err:=os.Chmod(socket,0600);err!=nil{listener.Close();cleanup();return nil,err}
 var secret [32]byte
 if _,err:=rand.Read(secret[:]);err!=nil{listener.Close();cleanup();return nil,err}
 ctl:=&Control{Gate:gate,dir:dir,listener:listener,Record:ControlRecord{Socket:socket,Token:hex.EncodeToString(secret[:])}}
 // Keep the bearer token in private host storage, never in a VM share.
 record,err:=json.Marshal(ctl.Record)
 if err!=nil{listener.Close();cleanup();return nil,err}
 recordPath:=filepath.Join(dir,"control.json")
 if err:=os.WriteFile(recordPath,record,0600);err!=nil{listener.Close();cleanup();return nil,err}
 srv:=&http.Server{ReadHeaderTimeout:3*time.Second,ReadTimeout:5*time.Second,WriteTimeout:5*time.Second,IdleTimeout:5*time.Second,MaxHeaderBytes:8192}
 srv.Handler=http.HandlerFunc(ctl.handle)
 ctl.server=srv
 go func(){_ = srv.Serve(listener)}()
 return ctl,nil
}

func (c *Control) handle(w http.ResponseWriter,r *http.Request){
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("Content-Type","application/json")
 if r.Host!="netgate" || r.Header.Get("Origin")!="" || subtle.ConstantTimeCompare(
  []byte(r.Header.Get("Authorization")),[]byte("Bearer "+c.Record.Token))!=1{
  http.Error(w,"forbidden",http.StatusForbidden);return
 }
 switch {
 case r.Method=="GET" && r.URL.Path=="/status":
  state,epoch:=c.Gate.Status()
  _=json.NewEncoder(w).Encode(struct{
   State State `json:"state"`
   Epoch uint64 `json:"epoch"`
  }{state,epoch})
 case r.Method=="POST" && r.URL.Path=="/close":
  c.Gate.Revoke()
  _,_=io.WriteString(w,`{"state":"closed"}`)
 case r.Method=="POST" && r.URL.Path=="/check":
  epoch:=c.Gate.BeginCheck()
  _=json.NewEncoder(w).Encode(struct{
   State State `json:"state"`
   Epoch uint64 `json:"epoch"`
  }{Checking,epoch})
 default:
  http.NotFound(w,r)
 }
}

func (c *Control) Close() error {
 if c==nil{return nil}
 c.Gate.Revoke()
 ctx,cancel:=context.WithTimeout(context.Background(),2*time.Second);defer cancel()
 err:=c.server.Shutdown(ctx)
 _=c.listener.Close()
 _=os.RemoveAll(c.dir)
 return err
}
