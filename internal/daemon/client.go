// Package daemon provides an opt-in local management transport.
package daemon

import (
 "context"
 "bytes"
 "io"
 "encoding/json"
 "fmt"
 "net"
 "net/http"
 "net/url"
 "time"
)

// Client only dials the explicitly selected Unix socket.
type Client struct { http *http.Client; transport *http.Transport }

func NewClient(socket string) *Client {
 t := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
  return (&net.Dialer{Timeout: 3*time.Second}).DialContext(ctx,"unix",socket)
 }}
 return &Client{http:&http.Client{Transport:t, Timeout:15*time.Second, CheckRedirect:func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},transport:t}
}

func (c *Client) Close() { c.transport.CloseIdleConnections() }

func (c *Client) Get(ctx context.Context, path string, out any) error {
 return c.request(ctx,http.MethodGet,path,http.StatusOK,out)
}

func (c *Client) SubmitInventory(ctx context.Context,out any) error {
 return c.request(ctx,http.MethodPost,"/api/v1/tasks/inventory",http.StatusAccepted,out)
}

func (c *Client) ChangeVM(ctx context.Context, name, action string, out any) error {
 if action!="start" && action!="stop"{return fmt.Errorf("unsupported VM action")}
 return c.request(ctx,http.MethodPost,"/api/v1/vms/"+url.PathEscape(name)+"/"+action,http.StatusAccepted,out)
}

func (c *Client) CreateVM(ctx context.Context, input any, out any) error {
 data,err:=json.Marshal(input);if err!=nil{return err}
 return c.requestBody(ctx,http.MethodPost,"/api/v1/vms",http.StatusAccepted,bytes.NewReader(data),out)
}

func (c *Client) DeleteVM(ctx context.Context,name string,out any) error {
 return c.request(ctx,http.MethodDelete,"/api/v1/vms/"+url.PathEscape(name)+"?confirm="+url.QueryEscape(name),http.StatusAccepted,out)
}

func (c *Client) request(ctx context.Context, method,path string,status int,out any) error {
 return c.requestBody(ctx,method,path,status,nil,out)
}

func (c *Client) requestBody(ctx context.Context, method,path string,status int,body io.Reader,out any) error {
 req, err := http.NewRequestWithContext(ctx,method,"http://agent-vm"+path,body)
 if err==nil && body!=nil{req.Header.Set("Content-Type","application/json")}
 if err != nil { return err }
 resp,err:=c.http.Do(req)
 if err!=nil {return err}
 defer resp.Body.Close()
 if resp.StatusCode!=status {return fmt.Errorf("daemon: HTTP %d",resp.StatusCode)}
 return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) SubmitManager(ctx context.Context,path string,input any,out any) error {
 data,err:=json.Marshal(input);if err!=nil{return err}
 return c.requestBody(ctx,http.MethodPost,path,http.StatusAccepted,bytes.NewReader(data),out)
}
