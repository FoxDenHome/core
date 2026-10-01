// Package tunnel owns the WireGuard interface plus the addresses, routes and
// DNS settings that hang off it. Apply is idempotent and only touches what
// changed, so the daemon can call it on every tick.
package tunnel

import (
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"slices"
	"time"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// FirewallMark is set on the tunnel's own UDP socket (Linux) so full-tunnel
// policy routing can keep it out of the tunnel.
const FirewallMark = 0xf0d3

// RouteTable is the Linux routing table used for full-tunnel default routes.
const RouteTable = 0xf0d3

// StateDir is where platform code keeps state that must survive a crash
// (macOS: the DNS settings it overrode). Set by the daemon.
var StateDir string

type Options struct {
	// Name is the interface name on Linux; on macOS the kernel assigns utunN.
	Name           string
	ForceUserspace bool
}

type Config struct {
	PrivateKey   wgtypes.Key
	PeerKey      wgtypes.Key
	PresharedKey *wgtypes.Key
	// Endpoint may be invalid, in which case the current one is kept.
	Endpoint   netip.AddrPort
	Keepalive  time.Duration
	MTU        int
	Addresses  []netip.Prefix
	Routes     []netip.Prefix
	FullTunnel bool
	DNSServers []netip.Addr
	DNSDomains []string
}

type Stats struct {
	LastHandshake time.Time
	RxBytes       int64
	TxBytes       int64
	Endpoint      string
}

type Tunnel struct {
	opts    Options
	wg      *wgctrl.Client
	name    string
	backend string
	us      *userspaceDevice
	applied *Config
	plat    platformState
}

func New(opts Options) *Tunnel {
	return &Tunnel{opts: opts}
}

func (t *Tunnel) Name() string    { return t.name }
func (t *Tunnel) Backend() string { return t.backend }
func (t *Tunnel) Up() bool        { return t.name != "" }

// Apply brings the tunnel up (if needed) and converges it on cfg. netChanged
// forces re-evaluation of state derived from the physical network (macOS
// endpoint bypass route).
func (t *Tunnel) Apply(cfg Config, netChanged bool) error {
	if t.name == "" {
		if err := t.create(cfg.MTU); err != nil {
			return fmt.Errorf("creating interface: %w", err)
		}
		if t.wg == nil {
			c, err := wgctrl.New()
			if err != nil {
				_ = t.Down()
				return err
			}
			t.wg = c
		}
		log.Printf("tunnel: created %s (%s)", t.name, t.backend)
	}

	if err := t.configureWireGuard(cfg); err != nil {
		return fmt.Errorf("configuring wireguard: %w", err)
	}

	prev := t.applied
	if prev == nil || prev.MTU != cfg.MTU || !slices.Equal(prev.Addresses, cfg.Addresses) {
		if err := t.setAddresses(cfg); err != nil {
			return fmt.Errorf("setting addresses: %w", err)
		}
	}
	if prev == nil || netChanged || prev.FullTunnel != cfg.FullTunnel || !slices.Equal(prev.Routes, cfg.Routes) ||
		prev.Endpoint != cfg.Endpoint {
		if err := t.setRoutes(cfg); err != nil {
			return fmt.Errorf("setting routes: %w", err)
		}
	}
	if prev == nil || prev.FullTunnel != cfg.FullTunnel || !slices.Equal(prev.DNSServers, cfg.DNSServers) ||
		!slices.Equal(prev.DNSDomains, cfg.DNSDomains) {
		if err := t.setDNS(cfg); err != nil {
			// Not fatal: the tunnel still works by IP.
			log.Printf("tunnel: setting DNS: %v", err)
		}
	}

	c := cfg
	if !c.Endpoint.IsValid() && prev != nil {
		c.Endpoint = prev.Endpoint
	}
	t.applied = &c
	return nil
}

func (t *Tunnel) configureWireGuard(cfg Config) error {
	peer := wgtypes.PeerConfig{
		PublicKey:                   cfg.PeerKey,
		PresharedKey:                cfg.PresharedKey,
		PersistentKeepaliveInterval: &cfg.Keepalive,
		ReplaceAllowedIPs:           true,
	}
	if cfg.Endpoint.IsValid() {
		peer.Endpoint = net.UDPAddrFromAddrPort(cfg.Endpoint)
	}
	for _, p := range cfg.Routes {
		peer.AllowedIPs = append(peer.AllowedIPs, prefixToIPNet(p))
	}
	peers := []wgtypes.PeerConfig{peer}
	if t.applied != nil && t.applied.PeerKey != cfg.PeerKey {
		peers = append(peers, wgtypes.PeerConfig{PublicKey: t.applied.PeerKey, Remove: true})
	}
	mark := FirewallMark
	return t.wg.ConfigureDevice(t.name, wgtypes.Config{
		PrivateKey:   &cfg.PrivateKey,
		FirewallMark: &mark,
		Peers:        peers,
	})
}

// ResetSession drops the peer's session keys by removing and re-adding it, so
// an idle split tunnel is genuinely disconnected until traffic needs it again.
func (t *Tunnel) ResetSession() error {
	if t.name == "" || t.applied == nil {
		return nil
	}
	if err := t.wg.ConfigureDevice(t.name, wgtypes.Config{
		Peers: []wgtypes.PeerConfig{{PublicKey: t.applied.PeerKey, Remove: true}},
	}); err != nil {
		return err
	}
	return t.configureWireGuard(*t.applied)
}

func (t *Tunnel) Stats() (Stats, error) {
	if t.name == "" || t.applied == nil {
		return Stats{}, errors.New("tunnel is down")
	}
	dev, err := t.wg.Device(t.name)
	if err != nil {
		return Stats{}, err
	}
	for _, p := range dev.Peers {
		if p.PublicKey != t.applied.PeerKey {
			continue
		}
		s := Stats{LastHandshake: p.LastHandshakeTime, RxBytes: p.ReceiveBytes, TxBytes: p.TransmitBytes}
		if p.Endpoint != nil {
			s.Endpoint = p.Endpoint.String()
		}
		return s, nil
	}
	return Stats{}, errors.New("peer missing from device")
}

func (t *Tunnel) Down() error {
	if t.name == "" {
		return nil
	}
	var errs []error
	errs = append(errs, t.clearDNS(), t.clearRoutes(), t.destroy())
	if t.us != nil {
		t.us.Close()
		t.us = nil
	}
	log.Printf("tunnel: removed %s", t.name)
	t.name = ""
	t.backend = ""
	t.applied = nil
	return errors.Join(errs...)
}

func (t *Tunnel) Close() error {
	err := t.Down()
	if t.wg != nil {
		_ = t.wg.Close()
		t.wg = nil
	}
	return err
}

func prefixToIPNet(p netip.Prefix) net.IPNet {
	p = p.Masked()
	return net.IPNet{
		IP:   p.Addr().AsSlice(),
		Mask: net.CIDRMask(p.Bits(), p.Addr().BitLen()),
	}
}

// FullTunnelRoutes are the allowed IPs for full-tunnel mode.
var FullTunnelRoutes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/0"),
	netip.MustParsePrefix("::/0"),
}
