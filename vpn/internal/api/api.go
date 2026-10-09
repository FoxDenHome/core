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

	"github.com/FoxDenHome/core/vpn/internal/provision"
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
	// Build identifies the daemon's executable, and Executable is where it
	// is. The tray is the same binary: when its build differs, it restarts
	// into Executable.
	Build          string `json:"build,omitempty"`
	Executable     string `json:"executable,omitempty"`
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
	// Shares the owner may mount.
	Shares []Share `json:"shares,omitempty"`
	// Launcher is what the Servers menu offers.
	Launcher *provision.Launcher `json:"launcher,omitempty"`
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

// KerberosCertRequest asks for a PKINIT certificate for the device owner.
type KerberosCertRequest struct {
	// PublicKey is the session's PKINIT key (PKIX DER, base64).
	PublicKey string `json:"public_key"`
}

// KerberosCert is a PKINIT client certificate for the device owner.
type KerberosCert struct {
	Principal   string    `json:"principal"`
	Certificate string    `json:"certificate"`
	CA          string    `json:"ca"`
	Expires     time.Time `json:"expires"`
}

// ExposeTicket lets `foxden-vpnd expose` open tunnels on the expose edge
// for this device. It is short-lived; get a new one per connection.
type ExposeTicket struct {
	Ticket  string    `json:"ticket"`
	Expires time.Time `json:"expires"`
	// Edges are the control service's addresses (host:port), reached
	// through the tunnel, and ServerName the name on its certificate.
	Edges      []string `json:"edges"`
	ServerName string   `json:"server_name"`
}

// Share is an SMB share the device's owner may mount.
type Share struct {
	Name    string `json:"name"`
	Comment string `json:"comment,omitempty"`
	// Host serves the share over TCP; the macOS tray mounts it directly.
	Host string `json:"host,omitempty"`
	Home bool   `json:"home,omitempty"`
}

// Mount is one of the caller's SMB mounts.
type Mount struct {
	Source    string `json:"source"`
	Path      string `json:"path"`
	Transport string `json:"transport"`
}

type MountRequest struct {
	Share string `json:"share,omitempty"`
	Path  string `json:"path"`
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

func (c *Client) KerberosCert(publicKey string) (*KerberosCert, error) {
	var out KerberosCert
	if err := c.call(http.MethodPost, "/v1/kerberos/cert", KerberosCertRequest{PublicKey: publicKey}, 90*time.Second, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) ExposeTicket() (*ExposeTicket, error) {
	var out ExposeTicket
	if err := c.call(http.MethodPost, "/v1/expose/ticket", nil, 90*time.Second, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Mounts() ([]Mount, error) {
	var out []Mount
	err := c.call(http.MethodGet, "/v1/mounts", nil, 10*time.Second, &out)
	return out, err
}

func (c *Client) Mount(share, path string) (*Mount, error) {
	var out Mount
	if err := c.call(http.MethodPost, "/v1/mounts", MountRequest{Share: share, Path: path}, 3*time.Minute, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Unmount(path string) error {
	var out struct{}
	return c.call(http.MethodPost, "/v1/mounts/unmount", MountRequest{Path: path}, 30*time.Second, &out)
}
