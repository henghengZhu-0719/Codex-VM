package netgate

import (
 "context"
 "errors"
 "io"
 "net"
 "testing"
 "time"
)
func openGate(t *testing.T)*Gate { t.Helper();g:=New();epoch:=g.BeginCheck();if err:=g.Authorize(epoch,time.Second);err!=nil{t.Fatal(err)};return g }
func TestClosedByDefault(t *testing.T){g:=New();called:=false;_,err:=g.Dial(context.Background(),func(context.Context)(net.Conn,error){called=true;return nil,nil});if !errors.Is(err,ErrClosed)||called{t.Fatalf("err=%v called=%v",err,called)}}
func TestRevokeClosesConnection(t *testing.T){g:=openGate(t);a,b:=net.Pipe();defer b.Close();c,err:=g.Dial(context.Background(),func(context.Context)(net.Conn,error){return a,nil});if err!=nil{t.Fatal(err)};g.Revoke();if _,err=c.Write([]byte("x"));!errors.Is(err,ErrStale){t.Fatalf("write err=%v",err)};if s,_:=g.Status();s!=Closed{t.Fatal(s)}}
func TestRaceWithDial(t *testing.T){g:=openGate(t);entered:=make(chan struct{});resume:=make(chan struct{});result:=make(chan error,1);go func(){_,err:=g.Dial(context.Background(),func(context.Context)(net.Conn,error){close(entered);<-resume;a,b:=net.Pipe();b.Close();return a,nil});result<-err}();<-entered;g.Revoke();close(resume);if err:=<-result;!errors.Is(err,ErrStale){t.Fatal(err)}}
func TestLeaseExpiry(t *testing.T){g:=New();e:=g.BeginCheck();if err:=g.Authorize(e,time.Millisecond);err!=nil{t.Fatal(err)};time.Sleep(5*time.Millisecond);if s,_:=g.Status();s!=Closed{t.Fatal(s)}}
func TestOldCheckCannotAuthorize(t *testing.T){g:=New();e:=g.BeginCheck();g.Revoke();if err:=g.Authorize(e,time.Second);!errors.Is(err,ErrStale){t.Fatal(err)}}

func TestLeaseClosesActiveConnectionWithoutStatusPolling(t *testing.T){
 g:=New();epoch:=g.BeginCheck()
 if err:=g.Authorize(epoch,10*time.Millisecond);err!=nil{t.Fatal(err)}
 a,b:=net.Pipe();defer b.Close()
 conn,err:=g.Dial(context.Background(),func(context.Context)(net.Conn,error){return a,nil})
 if err!=nil{t.Fatal(err)}
 defer conn.Close()
 deadline:=time.After(500*time.Millisecond)
 for {
  if err:=a.SetReadDeadline(time.Now());err!=nil {break}
  select {case <-deadline:t.Fatal("lease did not close active connection");default:time.Sleep(time.Millisecond)}
 }
}

func TestRevocationCancelsInFlightDial(t *testing.T) {
 g:=openGate(t)
 entered:=make(chan struct{})
 canceled:=make(chan struct{})
 done:=make(chan error,1)
 go func(){
  _,err:=g.Dial(context.Background(),func(ctx context.Context)(net.Conn,error){
   close(entered)
   <-ctx.Done()
   close(canceled)
   return nil,ctx.Err()
  })
  done<-err
 }()
 <-entered
 g.Revoke()
 select {
 case <-canceled:
 case <-time.After(time.Second):t.Fatal("in-flight dial not canceled on revoke")
 }
 if err:=<-done;!errors.Is(err,ErrStale){t.Fatalf("expected stale authorization: %v",err)}
}

func TestTrackedConnectionPreservesHalfClose(t *testing.T) {
 listener,err:=net.Listen("tcp","127.0.0.1:0")
 if err!=nil{t.Fatal(err)}
 defer listener.Close()
 gate:=openGate(t)
 conn,err:=gate.Dial(context.Background(),func(ctx context.Context)(net.Conn,error){return (&net.Dialer{}).DialContext(ctx,"tcp",listener.Addr().String())})
 if err!=nil{t.Fatal(err)}
 defer conn.Close()
 peer,err:=listener.Accept()
 if err!=nil{t.Fatal(err)}
 defer peer.Close()
 if err:=peer.SetDeadline(time.Now().Add(time.Second));err!=nil{t.Fatal(err)}
 if _,err:=conn.Write([]byte("request"));err!=nil{t.Fatal(err)}
 halfClose,ok:=conn.(interface{CloseWrite() error})
 if !ok{t.Fatal("tracked connection cannot half-close")}
 if err:=halfClose.CloseWrite();err!=nil{t.Fatal(err)}
 request,err:=io.ReadAll(peer)
 if err!=nil || string(request)!="request"{t.Fatalf("request %q: %v",request,err)}
 if _,err:=peer.Write([]byte("response"));err!=nil{t.Fatal(err)}
 response:=make([]byte,len("response"))
 if _,err:=io.ReadFull(conn,response);err!=nil || string(response)!="response"{t.Fatalf("response %q: %v",response,err)}
}
