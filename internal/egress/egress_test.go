package egress

import (
 "bufio"
 "context"
 "errors"
 "io"
 "net"
 "net/netip"
 "strings"
 "testing"
 "time"
)
func TestMissingProxy(t *testing.T){if _,err:=New("",nil);!errors.Is(err,ErrNoProxy){t.Fatal(err)}}
func TestUnsupportedScheme(t *testing.T){if _,err:=New("ftp://127.0.0.1:1080",nil);err==nil{t.Fatal("expected error")}}
func TestDeniedNeverDials(t *testing.T){
 g,err:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return false});if err!=nil{t.Fatal(err)}
 called:=false;g.DialProxy=func(context.Context,string,string)(net.Conn,error){called=true;return nil,nil}
 _,err=g.DialContext(context.Background(),"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
 if !errors.Is(err,ErrDenied)||called{t.Fatalf("err=%v called=%v",err,called)}
}
func TestNoDirectFallback(t *testing.T){
 g,_:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return true})
 upstream:=errors.New("proxy offline")
 g.DialProxy=func(context.Context,string,string)(net.Conn,error){return nil,upstream}
 _,err:=g.DialContext(context.Background(),"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
 if !errors.Is(err,upstream){t.Fatal(err)}
}
func TestHTTPConnect(t *testing.T){
 g,_:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return true})
 c1,c2:=net.Pipe();defer c2.Close()
 g.DialProxy=func(context.Context,string,string)(net.Conn,error){return c1,nil}
 go func(){
  rd:=bufio.NewReader(c2)
  line,_:=rd.ReadString('\n')
  if !strings.HasPrefix(line,"CONNECT 1.1.1.1:443 "){return}
  for {h,err:=rd.ReadString('\n');if err!=nil{return};if h=="\r\n"{break}}
  _,_=io.WriteString(c2,"HTTP/1.1 200 Connection Established\r\n\r\n")
 }()
 c,err:=g.DialContext(context.Background(),"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
 if err!=nil{t.Fatal(err)};_ = c.Close()
}
func TestRevokedDuringHandshake(t *testing.T){
 allowed:=true
 g,_:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return allowed})
 a,b:=net.Pipe();defer b.Close()
 g.DialProxy=func(context.Context,string,string)(net.Conn,error){return a,nil}
 go func(){
  rd:=bufio.NewReader(b)
  for {s,err:=rd.ReadString('\n');if err!=nil{return};if s=="\r\n"{break}}
  allowed=false
  _,_=io.WriteString(b,"HTTP/1.1 200 OK\r\n\r\n")
 }()
 _,err:=g.DialContext(context.Background(),"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
 if !errors.Is(err,ErrDenied){t.Fatal(err)}
}

func TestCancelledHTTPConnectHandshakeReturnsWithoutFallback(t *testing.T){
 g,_:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return true})
 client,upstream:=net.Pipe()
 defer upstream.Close()
 g.DialProxy=func(context.Context,string,string)(net.Conn,error){return client,nil}
 ctx,cancel:=context.WithCancel(context.Background())
 done:=make(chan error,1)
 go func(){
  _,err:=g.DialContext(ctx,"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
  done<-err
 }()
 // Read headers but never respond; cancel while waiting for CONNECT status.
 rd:=bufio.NewReader(upstream)
 for {
  line,err:=rd.ReadString('\n')
  if err!=nil{t.Fatal(err)}
  if line=="\r\n"{break}
 }
 cancel()
 select {
 case err:=<-done:
  if err==nil{t.Fatal("cancelled handshake unexpectedly succeeded")}
 case <-time.After(time.Second):
  t.Fatal("cancelled proxy handshake did not stop")
 }
}

func TestHTTPConnectPreservesImmediateTunnelPayload(t *testing.T){
 g,_:=New("http://127.0.0.1:1080",func(string,netip.AddrPort)bool{return true})
 client,proxy:=net.Pipe()
 defer proxy.Close()
 g.DialProxy=func(context.Context,string,string)(net.Conn,error){return client,nil}
 go func(){
  reader:=bufio.NewReader(proxy)
  for {
   line,err:=reader.ReadString('\n')
   if err!=nil{return}
   if line=="\r\n"{break}
  }
  _,_=io.WriteString(proxy,"HTTP/1.1 200 Connection Established\r\n\r\nhello")
 }()
 conn,err:=g.DialContext(context.Background(),"tcp",netip.MustParseAddrPort("1.1.1.1:443"))
 if err!=nil{t.Fatal(err)}
 defer conn.Close()
 _=conn.SetReadDeadline(time.Now().Add(time.Second))
 buf:=make([]byte,5)
 if _,err:=io.ReadFull(conn,buf);err!=nil{t.Fatal(err)}
 if string(buf)!="hello"{t.Fatalf("unexpected payload %q",buf)}
}
