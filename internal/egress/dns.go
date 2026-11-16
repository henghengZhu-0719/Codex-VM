package egress

import (
 "bytes"
 "context"
 "errors"
 "fmt"
 "io"
 "net"
 "net/http"
 "net/netip"
 "net/url"
 "strings"
 "time"

 "github.com/miekg/dns"
)

// Resolver only accepts numeric IPv4 DoH endpoints to avoid host DNS bootstrap.
// All HTTPS sockets are created by the same mandatory proxy dialer.
type Resolver struct {
 url string
 client *http.Client
}

func NewResolver(g *Gate, endpoint string) (*Resolver,error) {
 if g==nil || g.ProxyURL==nil {return nil,ErrNoProxy}
 u,err:=url.Parse(endpoint)
 if err!=nil || u==nil || u.Scheme!="https" || u.User!=nil || u.Hostname()=="" || u.Fragment!="" {
  return nil,errors.New("egress: DoH endpoint must be HTTPS without credentials or fragment")
 }
 ip,err:=netip.ParseAddr(u.Hostname())
 if err!=nil || !ip.Unmap().Is4(){return nil,errors.New("egress: DoH endpoint must use an IPv4 literal (no host DNS bootstrap)")}
 if u.Port()!="" && u.Port()!="443" {return nil,errors.New("egress: DoH endpoint requires port 443")}
 if u.Path=="" || u.Path=="/" {return nil,errors.New("egress: DoH endpoint requires a query path")}
 tr:=&http.Transport{
  Proxy:nil,
  DisableKeepAlives:true,
  DialContext:func(ctx context.Context,network,address string)(net.Conn,error){
   // The transport may pass a hostname here on redirects or altered URL.
   host,port,err:=net.SplitHostPort(address)
   if err!=nil || host!=u.Hostname() || port!="443" {return nil,ErrDenied}
   dst:=netip.AddrPortFrom(ip.Unmap(),443)
   return g.DialContext(ctx,"tcp",dst)
  },
 }
 client:=&http.Client{Timeout:20*time.Second,Transport:tr,CheckRedirect:func(*http.Request,[]*http.Request)error{return errors.New("egress: DoH redirects refused")}}
 return &Resolver{url:endpoint,client:client},nil
}

func (r *Resolver) Exchange(ctx context.Context,q *dns.Msg)(*dns.Msg,error){
 if q==nil || len(q.Question)==0 {return nil,errors.New("egress: empty DNS question")}
 for _,question:=range q.Question{
  name:=strings.ToLower(strings.TrimSuffix(question.Name,"."))
  if question.Qtype==dns.TypeAAAA {
   answer:=new(dns.Msg);answer.SetReply(q);return answer,nil
  }
  if name=="localhost" || strings.HasSuffix(name,".localhost") || strings.HasSuffix(name,".local") || strings.HasSuffix(name,".internal"){
   answer:=new(dns.Msg);answer.SetRcode(q,dns.RcodeNameError);return answer,nil
  }
 }
 wire,err:=q.Pack();if err!=nil{return nil,err}
 ctx,cancel:=context.WithTimeout(ctx,20*time.Second);defer cancel()
 for attempt:=0;attempt<3;attempt++{
  attemptCtx,done:=context.WithTimeout(ctx,6*time.Second)
  answer,retry,err:=r.exchangeOnce(attemptCtx,q,wire)
  done()
  if err==nil || !retry{return answer,err}
  if ctx.Err()!=nil{return nil,ctx.Err()}
 }
 return nil,err
}

func (r *Resolver) exchangeOnce(ctx context.Context,q *dns.Msg,wire []byte)(*dns.Msg,bool,error){
 req,err:=http.NewRequestWithContext(ctx,http.MethodPost,r.url,bytes.NewReader(wire))
 if err!=nil{return nil,false,err}
 req.Header.Set("Content-Type","application/dns-message")
 req.Header.Set("Accept","application/dns-message")
 resp,err:=r.client.Do(req)
 if err!=nil{return nil,true,fmt.Errorf("egress: DoH unavailable through proxy: %w",err)}
 defer resp.Body.Close()
 if resp.StatusCode!=http.StatusOK{return nil,resp.StatusCode==429||resp.StatusCode>=500,fmt.Errorf("egress: DoH status %d",resp.StatusCode)}
 if !strings.HasPrefix(strings.ToLower(resp.Header.Get("Content-Type")),"application/dns-message"){return nil,false,errors.New("egress: unexpected DoH response media type")}
 body,err:=io.ReadAll(io.LimitReader(resp.Body,65537))
 if err!=nil{return nil,true,err}
 if len(body)>65536 {return nil,false,errors.New("egress: oversized DoH response")}
 answer:=new(dns.Msg)
 if err:=answer.Unpack(body);err!=nil{return nil,false,err}
 if !answer.Response || answer.Id!=q.Id || len(answer.Question)!=len(q.Question){return nil,false,errors.New("egress: invalid DoH response")}
 for i,question:=range q.Question{if answer.Question[i]!=question{return nil,false,errors.New("egress: mismatched DoH question")}}
 return answer,false,nil
}
