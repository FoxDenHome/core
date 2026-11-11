// Package config is pfox's configuration. Nix generates it from the flake
// (see nix/modules/lib/global/packetfox.nix), so the device inventory always
// matches the hosts that exist.
package config

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"time"
)

type Config struct {
	Listen  string `json:"listen"`
	DataDir string `json:"data_dir"`
	Sharkd  string `json:"sharkd"`

	// Where the routers send their TZSP streams.
	Collector Collector `json:"collector"`

	Routers []Router    `json:"routers"`
	Agents  []SSHDevice `json:"agents"`
	APs     []SSHDevice `json:"aps"`

	// Every known host, for picking filter targets and for knowing which
	// capture point a destination address lives behind.
	Endpoints []Endpoint `json:"endpoints"`

	// Private key pfox logs in to agents with.
	SSHKeyFile string `json:"ssh_key_file"`

	Limits Limits `json:"limits"`

	// Secrets, from the environment.
	RouterOSPassword string `json:"-"`
	UniFiSSHUser     string `json:"-"`
	UniFiSSHPassword string `json:"-"`
}

type Collector struct {
	IPv4     string `json:"ipv4"`
	IPv6     string `json:"ipv6"`
	BasePort int    `json:"base_port"`
}

type Router struct {
	Name     string `json:"name"`
	Address  string `json:"address"` // host:port of the RouterOS API
	Username string `json:"username"`
	// The router's own addresses and the VIPs it may hold.
	Addresses []string `json:"addresses"`
}

type SSHDevice struct {
	Name    string `json:"name"`
	Address string `json:"address"`
	// SSHFP records, "<algorithm> <fptype> <hex>", from the repo.
	SSHFP []string `json:"sshfp"`
	User  string   `json:"user,omitempty"`
}

type Endpoint struct {
	Name string `json:"name"`
	// NixOS system the host is defined on, and the netns it lives in there
	// ("" for hosts in the root netns).
	System     string      `json:"system"`
	Netns      string      `json:"netns"`
	Interfaces []Interface `json:"interfaces"`
}

type Interface struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
	MAC       string   `json:"mac,omitempty"`
	FQDNs     []string `json:"fqdns"`
}

type Limits struct {
	MaxPackets  int      `json:"max_packets"`
	MaxDuration Duration `json:"max_duration"`
	MaxSessions int      `json:"max_sessions"`
}

type Duration struct{ time.Duration }

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	v, err := time.ParseDuration(s)
	d.Duration = v
	return err
}

func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(d.String())
}

func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{
		Listen:  "127.0.0.1:1447",
		DataDir: "/var/lib/packetfox",
		Sharkd:  "sharkd",
		Limits: Limits{
			MaxPackets:  500000,
			MaxDuration: Duration{30 * time.Minute},
			MaxSessions: 20,
		},
	}
	cfg.Collector.BasePort = 37008
	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	cfg.RouterOSPassword = os.Getenv("ROUTEROS_PASSWORD")
	cfg.UniFiSSHUser = os.Getenv("UNIFI_SSH_USERNAME")
	cfg.UniFiSSHPassword = os.Getenv("UNIFI_SSH_PASSWORD")
	return cfg, nil
}

// EndpointAddrs returns the addresses of an endpoint, without prefix lengths.
func (e Endpoint) Addrs() []netip.Addr {
	var out []netip.Addr
	for _, iface := range e.Interfaces {
		for _, a := range iface.Addresses {
			if p, err := netip.ParsePrefix(a); err == nil {
				out = append(out, p.Addr())
			} else if ip, err := netip.ParseAddr(a); err == nil {
				out = append(out, ip)
			}
		}
	}
	return out
}
