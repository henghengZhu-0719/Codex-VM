// Package egress routes guest TCP through an explicitly configured upstream proxy.
// Connection failures never fall back to direct guest-destination dialing.
package egress

import (
 "bufio"
 "context"
 "encoding/base64"
 "errors"
 "fmt"
 "io"
 "net"
 "net/netip"
 "net/url"
 "strconv"
 "strings"
 "time"
)

var ErrDenied = errors.New("egress: destination denied")
var ErrNoProxy = errors.New("egress: proxy not configured")

type Allow func(network string, dst netip.AddrPort) bool

type Gate struct {
 ProxyURL *url.URL
 Allow Allow
 DialProxy func(context.Context,string,string)(net.Conn,error)
 Timeout time.Duration
}

func New(proxy string, allow Allow)(*Gate,error){
 if strings.TrimSpace(proxy)=="" {return nil,ErrNoProxy}
 u,err:=url.Parse(proxy);if err!=nil{return nil,fmt.Errorf("egress: invalid proxy: %w",err)}
 if u.Scheme!="http" && u.Scheme!="socks5" {return nil,fmt.Errorf("egress: unsupported proxy scheme %q",u.Scheme)}
 if u.Hostname()=="" || u.Port()=="" || u.Path!="" || u.RawQuery!="" || u.Fragment!="" {return nil,errors.New("egress: invalid proxy endpoint")}
 if ip,err:=netip.ParseAddr(u.Hostname());err!=nil || !ip.IsValid(){return nil,errors.New("egress: proxy server must use a numeric IP to avoid host DNS bootstrap")}
 port,err:=strconv.Atoi(u.Port());if err!=nil || port<1 || port>65535{return nil,errors.New("egress: invalid proxy port")}
 return &Gate{ProxyURL:u,Allow:allow,Timeout:10*time.Second},nil
}

func (g *Gate) DialContext(ctx context.Context, network string, dst netip.AddrPort)(net.Conn,error){
 if g==nil || g.ProxyURL==nil{return nil,ErrNoProxy}
 if network!="tcp" || !dst.IsValid() || dst.Port()==0 || !dst.Addr().Unmap().Is4(){return nil,ErrDenied}
 if g.Allow==nil || !g.Allow(network,dst){return nil,ErrDenied}
 timeout:=g.Timeout;if timeout<=0{timeout=10*time.Second}
 ctx,cancel:=context.WithTimeout(ctx,timeout);defer cancel()
 dial:=g.DialProxy;if dial==nil{d:=&net.Dialer{};dial=d.DialContext}
 c,err:=dial(ctx,"tcp",g.ProxyURL.Host)
 if err!=nil{return nil,fmt.Errorf("egress: upstream connection failed: %w",err)}
 // Context cancellation must interrupt a stalled proxy handshake, not only
 // the initial TCP dial. Stop the callback before returning a live tunnel.
 stopCancel:=context.AfterFunc(ctx,func(){_ = c.Close()})
 keep:=false
 defer func(){stopCancel();if !keep {_=c.Close()}}()
 if deadline,has:=ctx.Deadline();has{_ = c.SetDeadline(deadline)}
 switch g.ProxyURL.Scheme{
 case "http":err=connectHTTP(c,g.ProxyURL,dst.String())
 case "socks5":err=connectSOCKS5(c,g.ProxyURL,dst)
 default:err=ErrNoProxy
 }
 if err!=nil{return nil,err}
 if err:=ctx.Err();err!=nil{return nil,err}
 if !g.Allow(network,dst){return nil,ErrDenied}
 _=c.SetDeadline(time.Time{})
 keep=true
 return c,nil
}

func connectHTTP(c net.Conn,u *url.URL,target string)error{
 var auth string
 if u.User!=nil{password,_:=u.User.Password();auth="Proxy-Authorization: Basic "+base64.StdEncoding.EncodeToString([]byte(u.User.Username()+":"+password))+"\r\n"}
 if _,err:=io.WriteString(c,"CONNECT "+target+" HTTP/1.1\r\nHost: "+target+"\r\n"+auth+"\r\n");err!=nil{return fmt.Errorf("egress: CONNECT write: %w",err)}
 br:=bufio.NewReaderSize(c,1)
 line,err:=br.ReadString('\n');if err!=nil{return fmt.Errorf("egress: CONNECT response: %w",err)}
 if len(line)>8192{return errors.New("egress: response too long")}
 fields:=strings.Fields(line)
 if len(fields)<2 || !strings.HasPrefix(fields[0],"HTTP/1.") || fields[1]!="200"{return errors.New("egress: CONNECT rejected")}
 for i:=0;i<64;i++{
  h,err:=br.ReadString('\n');if err!=nil{return err}
  if len(h)>8192{return errors.New("egress: oversized CONNECT header")}
  if h=="\r\n"{if br.Buffered()!=0{return errors.New("egress: unexpected tunnel bytes")};return nil}
 }
 return errors.New("egress: too many CONNECT headers")
}

func connectSOCKS5(c net.Conn,u *url.URL,dst netip.AddrPort)error{
 methods:=[]byte{0}
 if u.User!=nil{methods=[]byte{2}}
 if _,err:=c.Write(append([]byte{5,1},methods...));err!=nil{return err}
 reply:=make([]byte,2)
 if _,err:=io.ReadFull(c,reply);err!=nil{return err}
 if reply[0]!=5 || reply[1]!=methods[0]{return errors.New("egress: SOCKS5 method rejected")}
 if u.User!=nil{
  user:=u.User.Username();password,_:=u.User.Password()
  if len(user)==0 || len(user)>255 || len(password)>255{return errors.New("egress: invalid SOCKS5 credentials")}
  request:=append([]byte{1,byte(len(user))},[]byte(user)...)
  request=append(request,byte(len(password)));request=append(request,[]byte(password)...)
  if _,err:=c.Write(request);err!=nil{return err}
  if _,err:=io.ReadFull(c,reply);err!=nil{return err}
  if reply[0]!=1 || reply[1]!=0{return errors.New("egress: SOCKS5 authentication failed")}
 }
 addr:=dst.Addr().Unmap().As4()
 request:=append([]byte{5,1,0,1},addr[:]...)
 request=append(request,byte(dst.Port()>>8),byte(dst.Port()))
 if _,err:=c.Write(request);err!=nil{return err}
 head:=make([]byte,4);if _,err:=io.ReadFull(c,head);err!=nil{return err}
 if head[0]!=5 || head[1]!=0 || head[2]!=0{return fmt.Errorf("egress: SOCKS5 CONNECT failed (%d)",head[1])}
 n:=0
 switch head[3]{
 case 1:n=4
 case 4:n=16
 case 3:
  b:=[]byte{0};if _,err:=io.ReadFull(c,b);err!=nil{return err};n=int(b[0])
 default:return errors.New("egress: invalid SOCKS5 reply")
 }
 _,err:=io.CopyN(io.Discard,c,int64(n+2));return err
}
