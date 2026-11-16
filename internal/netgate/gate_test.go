package netgate

import (
 "context"
 "errors"
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
