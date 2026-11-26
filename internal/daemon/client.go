// Package daemon provides an opt-in local management transport.
package daemon

import (
 "context"
 "encoding/json"
 "fmt"
 "net"
 "net/http"
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
 req, err := http.NewRequestWithContext(ctx,http.MethodGet,"http://agent-vm"+path,nil)
 if err != nil { return err }
 resp,err:=c.http.Do(req)
 if err!=nil {return err}
 defer resp.Body.Close()
 if resp.StatusCode!=http.StatusOK {return fmt.Errorf("daemon: HTTP %d",resp.StatusCode)}
 return json.NewDecoder(resp.Body).Decode(out)
}
