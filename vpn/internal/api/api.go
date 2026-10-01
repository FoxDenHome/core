// Package api is the local control protocol between foxden-vpnd (root) and the
// unprivileged tray applet: plain JSON over HTTP on a unix socket.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

const DefaultSocket = "/var/run/foxden-vpn.sock"

const (
	ModeSplit = "split"
	ModeFull  = "full"
)

const (
	LocationUnknown = "unknown"
	LocationOffline = "offline"
	LocationLAN     = "lan"
	LocationWAN     = "wan"
)

const (
	TunnelDown       = "down"
	TunnelIdle       = "idle"
	TunnelConnecting = "connecting"
	TunnelConnected  = "connected"
)

type Network struct {
	Name     string   `json:"name"`
	Enabled  bool     `json:"enabled"`
	Prefixes []string `json:"prefixes"`
}

type Status struct {
	PublicKey      string    `json:"public_key"`
	Provisioned    bool      `json:"provisioned"`
	ProvisionError string    `json:"provision_error,omitempty"`
	PeerName       string    `json:"peer_name,omitempty"`
	Addresses      []string  `json:"addresses,omitempty"`
	Enabled        bool      `json:"enabled"`
	Mode           string    `json:"mode"`
	Networks       []Network `json:"networks"`
	Location       string    `json:"location"`
	Tunnel         string    `json:"tunnel"`
	Backend        string    `json:"backend,omitempty"`
	Interface      string    `json:"interface,omitempty"`
	Endpoint       string    `json:"endpoint,omitempty"`
	LastHandshake  time.Time `json:"last_handshake,omitzero"`
	RxBytes        int64     `json:"rx_bytes"`
	TxBytes        int64     `json:"tx_bytes"`
	Error          string    `json:"error,omitempty"`
}

// SettingsUpdate changes only the fields that are set.
type SettingsUpdate struct {
	Enabled *bool           `json:"enabled,omitempty"`
	Mode    *string         `json:"mode,omitempty"`
	Network map[string]bool `json:"network,omitempty"`
}

type Client struct {
	http *http.Client
}

func NewClient(socket string) *Client {
	return &Client{http: &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socket)
			},
		},
	}}
}

func (c *Client) do(method, path string, body any) (*Status, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, "http://foxden-vpnd"+path, r)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("%s: %s", resp.Status, bytes.TrimSpace(msg))
	}
	var st Status
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return nil, err
	}
	return &st, nil
}

func (c *Client) Status() (*Status, error) {
	return c.do(http.MethodGet, "/v1/status", nil)
}

func (c *Client) Update(u SettingsUpdate) (*Status, error) {
	return c.do(http.MethodPost, "/v1/settings", u)
}

func (c *Client) Refresh() (*Status, error) {
	return c.do(http.MethodPost, "/v1/refresh", nil)
}
