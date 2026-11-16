package egress

import (
 "bufio"
 "context"
 "errors"
 "io"
 "net"
 "net/http"
 "net/netip"
 "testing"
 "time"

 "github.com/sylvinus/agent-vm/internal/netgate"

 "github.com/miekg/dns"
)

func TestResolverRejectsNonHTTPSAndHostDNSBootstrap(t *testing.T){
 g,err:=New("http://127.0.0.1:18080",func(string,netip.AddrPort)bool{return true})
 if err!=nil{t.Fatal(err)}
 for _,endpoint:=range []string{"http://1.1.1.1/dns-query","https://cloudflare-dns.com/dns-query","https://1.1.1.1/","https://user:pass@1.1.1.1/dns-query"}{
  if _,err:=NewResolver(g,endpoint);err==nil{t.Fatalf("accepted unsafe endpoint %s",endpoint)}
 }
 if _,err:=NewResolver(g,"https://1.1.1.1/dns-query");err!=nil{t.Fatal(err)}
}

func TestResolverNoConnectionInAAAAOrLocalName(t *testing.T){
 g,_:=New("http://127.0.0.1:18080",func(string,netip.AddrPort)bool{return true})
 r,_:=NewResolver(g,"https://1.1.1.1/dns-query")
 q:=new(dns.Msg);q.SetQuestion("test.example.",dns.TypeAAAA)
 answer,err:=r.Exchange(context.Background(),q)
 if err!=nil || len(answer.Answer)!=0{t.Fatalf("unexpected AAAA response: %v %v",answer,err)}
 q.SetQuestion("host.local.",dns.TypeA)
 answer,err=r.Exchange(context.Background(),q)
 if err!=nil || answer.Rcode!=dns.RcodeNameError{t.Fatalf("unexpected local response: %v %v",answer,err)}
}

func TestResolverRejectsNilQuestion(t *testing.T){
 g,_:=New("http://127.0.0.1:18080",func(string,netip.AddrPort)bool{return true})
 r,_:=NewResolver(g,"https://1.1.1.1/dns-query")
 _,err:=r.Exchange(context.Background(),nil)
 if err==nil || errors.Is(err,context.Canceled){t.Fatal(err)}
}

func TestMixedAAAAAndAQueryFailClosed(t *testing.T){
 g,_:=New("http://127.0.0.1:18080",func(string,netip.AddrPort)bool{return true})
 r,_:=NewResolver(g,"https://1.1.1.1/dns-query")
 q:=new(dns.Msg)
 q.SetQuestion("example.org.",dns.TypeAAAA)
 q.Question=append(q.Question,dns.Question{Name:"example.org.",Qtype:dns.TypeA,Qclass:dns.ClassINET})
 if _,err:=r.Exchange(context.Background(),q);err==nil{t.Fatal("mixed IPv6 query was accepted")}
}

func TestResolverRevocationClosesInFlightTunnel(t *testing.T) {
 gate:=netgate.New()
 epoch:=gate.BeginCheck()
 if err:=gate.Authorize(epoch,time.Minute);err!=nil{t.Fatal(err)}
 proxy,_:=New("http://127.0.0.1:18080",func(string,netip.AddrPort)bool{return true})
 connected:=make(chan struct{})
 closed:=make(chan struct{})
 proxy.DialProxy=func(ctx context.Context,network,address string)(net.Conn,error){
  client,server:=net.Pipe()
  go func(){
   defer close(closed)
   defer server.Close()
   req,err:=http.ReadRequest(bufio.NewReader(server))
   if err!=nil{return}
   if req.Method!="CONNECT"{return}
   if _,err:=io.WriteString(server,"HTTP/1.1 200 Connection Established\r\n\r\n");err!=nil{return}
   close(connected)
   _,_=io.Copy(io.Discard,server)
  }()
  return client,nil
 }
 resolver,err:=NewResolverWithTracker(proxy,"https://1.1.1.1/dns-query",gate.Dial)
 if err!=nil{t.Fatal(err)}
 done:=make(chan error,1)
 go func(){q:=new(dns.Msg);q.SetQuestion("example.org.",dns.TypeA);_,err:=resolver.Exchange(context.Background(),q);done<-err}()
 select{case <-connected:case <-time.After(5*time.Second):t.Fatal("proxy tunnel did not connect")}
 gate.Revoke()
 select{case <-closed:case <-time.After(5*time.Second):t.Fatal("revocation did not close DNS tunnel")}
 select{case err:=<-done:if err==nil{t.Fatal("DNS request succeeded after revocation")};case <-time.After(5*time.Second):t.Fatal("DNS request did not stop")}
}
