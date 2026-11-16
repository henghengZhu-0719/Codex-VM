package netgate

import (
 "context"
 "encoding/json"
 "net"
 "net/http"
 "os"
 "path/filepath"
 "runtime"
 "testing"
 "time"
)

func controlRequest(t *testing.T,c *Control,method,path,token string)(int,map[string]any){
 t.Helper()
 client:=&http.Client{Timeout:time.Second,Transport:&http.Transport{
  DialContext:func(ctx context.Context,_,_ string)(net.Conn,error){
   return (&net.Dialer{}).DialContext(ctx,"unix",c.Record.Socket)
  },
 }}
 defer client.CloseIdleConnections()
 req,err:=http.NewRequest(method,"http://netgate"+path,nil)
 if err!=nil{t.Fatal(err)}
 if token!=""{req.Header.Set("Authorization","Bearer "+token)}
 resp,err:=client.Do(req)
 if err!=nil{t.Fatal(err)}
 defer resp.Body.Close()
 data:=map[string]any{}
 _=json.NewDecoder(resp.Body).Decode(&data)
 return resp.StatusCode,data
}

func TestControlRequiresAuthenticationAndNeverGrants(t *testing.T){
 if runtime.GOOS=="windows"{t.Skip("Unix permission checks do not establish a private control socket on Windows")}
 parent,err:=os.MkdirTemp("","ngtest-")
 if err!=nil{t.Fatal(err)}
 t.Cleanup(func(){_ = os.RemoveAll(parent)})
 gate:=New()
 c,err:=StartControl(parent,gate)
 if err!=nil{t.Fatal(err)}
 defer c.Close()
 if mode,err:=os.Stat(c.Record.Socket);err!=nil || mode.Mode().Perm()!=0600{
  t.Fatalf("socket mode: %v %v",mode,err)
 }
 if mode,err:=os.Stat(filepath.Join(c.dir,"control.json"));err!=nil || mode.Mode().Perm()!=0600{
  t.Fatalf("record mode: %v %v",mode,err)
 }
 if status,_:=controlRequest(t,c,"GET","/status","");status!=http.StatusForbidden{t.Fatal(status)}
 if status,_:=controlRequest(t,c,"POST","/grant",c.Record.Token);status!=http.StatusNotFound{t.Fatal(status)}
 if status,_:=controlRequest(t,c,"POST","/check",c.Record.Token);status!=http.StatusOK{t.Fatal(status)}
 if state,_:=gate.Status();state!=Checking{t.Fatal(state)}
 if status,_:=controlRequest(t,c,"POST","/close",c.Record.Token);status!=http.StatusOK{t.Fatal(status)}
 if state,_:=gate.Status();state!=Closed{t.Fatal(state)}
}

func TestControlRejectsWorldReadableParent(t *testing.T){
 parent:=filepath.Join(t.TempDir(),"bad")
 if err:=os.Mkdir(parent,0755);err!=nil{t.Fatal(err)}
 if _,err:=StartControl(parent,New());err==nil{t.Fatal("accepted public control directory")}
}

func TestControlCheckReturnsHostProbeReport(t *testing.T){
 if runtime.GOOS=="windows"{t.Skip("Unix permission checks do not establish a private control socket on Windows")}
 parent,err:=os.MkdirTemp("","ngtest-")
 if err!=nil{t.Fatal(err)}
 t.Cleanup(func(){_ = os.RemoveAll(parent)})
 gate:=New()
 ctl,err:=StartControl(parent,gate,func(ctx context.Context,epoch uint64) SafetyReport{
  return SafetyReport{Policy:SafetyPolicyVersion,RunID:"run",Configuration:"config",CheckEpoch:epoch,CreatedAt:time.Now()}
 })
 if err!=nil{t.Fatal(err)}
 defer ctl.Close()
 status,data:=controlRequest(t,ctl,"POST","/check",ctl.Record.Token)
 if status!=http.StatusOK || data["policy"]!=SafetyPolicyVersion || data["run_id"]!="run"{t.Fatalf("status=%d report=%v",status,data)}
 state,epoch:=gate.Status()
 if state!=Checking || data["check_epoch"]!=float64(epoch){t.Fatalf("state=%s epoch=%d report=%v",state,epoch,data)}
}
