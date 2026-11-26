package resource

import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "net"
 "net/http"
 "path/filepath"
 "time"
)

type Balloon struct {
 TargetBytes int64 `json:"targetBytes"`
 MaxBytes int64 `json:"maxBytes"`
 MinBytes int64 `json:"minBytes"`
}

// Only observe the existing hostagent API. Do not compete with the Desktop
// memory policy by writing balloon targets from a second controller.
func InspectBalloon(ctx context.Context,vmDir string)(Balloon,error){
 t:=&http.Transport{DialContext:func(ctx context.Context,_,_ string)(net.Conn,error){
  return (&net.Dialer{Timeout:2*time.Second}).DialContext(ctx,"unix",filepath.Join(vmDir,"ha.sock"))
 }}
 defer t.CloseIdleConnections()
 c:=&http.Client{Transport:t,Timeout:3*time.Second,CheckRedirect:func(*http.Request,[]*http.Request)error{return http.ErrUseLastResponse}}
 req,err:=http.NewRequestWithContext(ctx,http.MethodGet,"http://localhost/v1/memory/balloon",nil);if err!=nil{return Balloon{},err}
 resp,err:=c.Do(req);if err!=nil{return Balloon{},err};defer resp.Body.Close()
 if resp.StatusCode!=200{return Balloon{},errors.New("balloon unavailable")}
 var b Balloon
 if err=json.NewDecoder(io.LimitReader(resp.Body,65536)).Decode(&b);err!=nil{return Balloon{},err}
 if b.MaxBytes<=0 || b.MinBytes<0 || b.MinBytes>b.MaxBytes || b.TargetBytes<0 || b.TargetBytes>b.MaxBytes{return Balloon{},errors.New("invalid balloon response")}
 return b,nil
}
