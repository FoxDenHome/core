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
	// Build identifies the daemon's executable. When it changes, the daemon
	// was updated, and the tray updates itself too.
	Build          string `json:"build,omitempty"`
	PublicKey      string `json:"public_key"`
	Provisioned    bool   `json:"provisioned"`
	ProvisionError string `json:"provision_error,omitempty"`
	// LastCheck is when provisioning was last fetched.
	LastCheck time.Time `json:"last_check,omitzero"`
	PeerName  string    `json:"peer_name,omitempty"`
	Addresses []string  `json:"addresses,omitempty"`
	Enabled   bool      `json:"enabled"`
	Mode      string    `json:"mode"`
	Networks  []Network `json:"networks"`
	Location  string    `json:"location"`
	// HomeNetworks are the networks we are attached to at home; they are
	// reached directly, not through the tunnel.
	HomeNetworks  []string  `json:"home_networks,omitempty"`
	Tunnel        string    `json:"tunnel"`
	Backend       string    `json:"backend,omitempty"`
	Interface     string    `json:"interface,omitempty"`
	Endpoint      string    `json:"endpoint,omitempty"`
	LastHandshake time.Time `json:"last_handshake,omitzero"`
	RxBytes       int64     `json:"rx_bytes"`
	TxBytes       int64     `json:"tx_bytes"`
	Error         string    `json:"error,omitempty"`
	Services      []Service `json:"services,omitempty"`
	// PortalURL is where devices are registered and managed.
	PortalURL string `json:"portal_url,omitempty"`
}

const (
	ServicePending      = "pending"
	ServiceUnsupported  = "unsupported"
	ServiceNotInstalled = "not-installed"
	ServiceUnmanaged    = "unmanaged" // installed by hand, not touched
	ServiceRunning      = "running"
	ServiceError        = "error"
)

// Service is an auxiliary service the daemon can install and keep updated.
type Service struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Version     string `json:"version,omitempty"`
	// Wanted is nil while the service is unmanaged.
	Wanted *bool  `json:"wanted,omitempty"`
	State  string `json:"state"`
	Detail string `json:"detail,omitempty"`
}

// EnrollStart is the key to register, from POST /v1/enroll/start.
type EnrollStart struct {
	PublicKey string `json:"public_key"`
	// Replace is the peer this enrollment should replace by default (the
	// device itself when regenerating its key).
	Replace string `json:"replace,omitempty"`
}

type EnrollStartRequest struct {
	// Regenerate enrolls a new key; the current one stays active until the
	// portal has accepted the new one.
	Regenerate bool `json:"regenerate"`
}

// EnrollCompleteRequest carries what the portal redirected to the tray.
type EnrollCompleteRequest struct {
	Token     string `json:"token"`
	Challenge string `json:"challenge"`
}

// SettingsUpdate changes only the fields that are set.
type SettingsUpdate struct {
	Enabled *bool           `json:"enabled,omitempty"`
	Mode    *string         `json:"mode,omitempty"`
	Network map[string]bool `json:"network,omitempty"`
	// Services enables or disables (uninstalls) auxiliary services by name.
	Services map[string]bool `json:"services,omitempty"`
}

type Client struct {
	http *http.Client
}

func NewClient(socket string) *Client {
	return &Client{http: &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socket)
			},
		},
	}}
}

func (c *Client) do(method, path string, body any, timeout time.Duration) (*Status, error) {
	var st Status
	if err := c.call(method, path, body, timeout, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

func (c *Client) call(method, path string, body any, timeout time.Duration, out any) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://foxden-vpnd"+path, r)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s", bytes.TrimSpace(msg))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) Status() (*Status, error) {
	return c.do(http.MethodGet, "/v1/status", nil, 10*time.Second)
}

func (c *Client) Update(u SettingsUpdate) (*Status, error) {
	return c.do(http.MethodPost, "/v1/settings", u, 10*time.Second)
}

// Refresh makes the daemon fetch provisioning now and waits for the result.
func (c *Client) Refresh() (*Status, error) {
	return c.do(http.MethodPost, "/v1/refresh", nil, 45*time.Second)
}

func (c *Client) EnrollStart(regenerate bool) (*EnrollStart, error) {
	var out EnrollStart
	if err := c.call(http.MethodPost, "/v1/enroll/start", EnrollStartRequest{Regenerate: regenerate}, 10*time.Second, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// EnrollComplete hands the portal's redirect to the daemon, which proves it
// holds the key and installs the configuration the portal returns.
func (c *Client) EnrollComplete(token, challenge string) (*Status, error) {
	var st Status
	if err := c.call(http.MethodPost, "/v1/enroll/complete", EnrollCompleteRequest{Token: token, Challenge: challenge}, 90*time.Second, &st); err != nil {
		return nil, err
	}
	return &st, nil
}
