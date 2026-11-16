package egress

import (
 "context"
 "errors"
 "net/netip"
 "testing"

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
