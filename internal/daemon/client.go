// Package daemon provides an opt-in local management transport.
package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

// Client only dials the explicitly selected Unix socket.
type Client struct {
	http      *http.Client
	transport *http.Transport
}

func NewClient(socket string) *Client {
	return NewClientWithDialer(func(ctx context.Context) (net.Conn, error) {
		return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", socket)
	}, 15*time.Second)
}

// NewClientWithDialer builds a Client using a custom transport dialer (e.g. Unix socket or SSH stdio bridge).
func NewClientWithDialer(dial func(ctx context.Context) (net.Conn, error), timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	t := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dial(ctx)
		},
		DisableKeepAlives: true,
	}
	return &Client{
		http: &http.Client{
			Transport: t,
			Timeout:   timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		transport: t,
	}
}

func (c *Client) Close() { c.transport.CloseIdleConnections() }

func (c *Client) Get(ctx context.Context, path string, out any) error {
	return c.request(ctx, http.MethodGet, path, http.StatusOK, out)
}

func (c *Client) SubmitInventory(ctx context.Context, out any) error {
	return c.request(ctx, http.MethodPost, "/api/v1/tasks/inventory", http.StatusAccepted, out)
}

func (c *Client) ChangeVM(ctx context.Context, name, action string, out any) error {
	if action != "start" && action != "stop" {
		return fmt.Errorf("unsupported VM action")
	}
	return c.request(ctx, http.MethodPost, "/api/v1/vms/"+url.PathEscape(name)+"/"+action, http.StatusAccepted, out)
}

func (c *Client) CreateVM(ctx context.Context, input any, out any) error {
	data, err := json.Marshal(input)
	if err != nil {
		return err
	}
	return c.requestBody(ctx, http.MethodPost, "/api/v1/vms", http.StatusAccepted, "", bytes.NewReader(data), out)
}

func (c *Client) DeleteVM(ctx context.Context, name string, out any) error {
	return c.request(ctx, http.MethodDelete, "/api/v1/vms/"+url.PathEscape(name)+"?confirm="+url.QueryEscape(name), http.StatusAccepted, out)
}

func (c *Client) CancelTask(ctx context.Context, id string, out any) error {
	return c.request(ctx, http.MethodPost, "/api/v1/tasks/"+url.PathEscape(id)+"/cancel", http.StatusOK, out)
}

func (c *Client) SubmitManager(ctx context.Context, path string, input any, out any) error {
	data, err := json.Marshal(input)
	if err != nil {
		return err
	}
	return c.requestBody(ctx, http.MethodPost, path, http.StatusAccepted, "", bytes.NewReader(data), out)
}

func (c *Client) SubmitWithKey(ctx context.Context, method, path, idempotencyKey string, input any, out any) error {
	var body io.Reader
	if input != nil {
		data, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = bytes.NewReader(data)
	}
	return c.requestBody(ctx, method, path, http.StatusAccepted, idempotencyKey, body, out)
}

func (c *Client) SubmitEmpty(ctx context.Context, path string, out any) error {
	return c.request(ctx, http.MethodPost, path, http.StatusAccepted, out)
}

func (c *Client) request(ctx context.Context, method, path string, status int, out any) error {
	return c.requestBody(ctx, method, path, status, "", nil, out)
}

func (c *Client) requestBody(ctx context.Context, method, path string, status int, idempotencyKey string, body io.Reader, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, "http://agent-vm"+path, body)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != status {
		var apiErr struct {
			Code  string `json:"code"`
			Error string `json:"error"`
		}
		if json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&apiErr) == nil && apiErr.Error != "" {
			if apiErr.Code != "" {
				return fmt.Errorf("daemon: HTTP %d (%s): %s", resp.StatusCode, apiErr.Code, apiErr.Error)
			}
			return fmt.Errorf("daemon: HTTP %d: %s", resp.StatusCode, apiErr.Error)
		}
		return fmt.Errorf("daemon: HTTP %d", resp.StatusCode)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
