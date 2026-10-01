// Package registry treats the routers' wg-vpn peer table as the database of
// VPN devices: ownership lives in the peer comment, addresses in
// allowed-address. Nothing else stores state, so the VPN keeps working with
// the portal (or Kanidm) down.
package registry

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
)

const (
	pathWireGuard = "/interface/wireguard"
	pathPeers     = "/interface/wireguard/peers"
	ownerPrefix   = "vpn-portal owner="
)

// API is the subset of a RouterOS connection the registry needs.
type API interface {
	Print(ctx context.Context, path string, query routeros.Row) ([]routeros.Row, error)
	Add(ctx context.Context, path string, attrs routeros.Row) error
	Set(ctx context.Context, path, id string, attrs routeros.Row) error
	Remove(ctx context.Context, path, id string) error
}

type Settings struct {
	Interface string `json:"interface"`
	// Pool is where new devices get their IPv4 address; the IPv6 address
	// embeds it under IPv6Base (10.100.10.4 -> fd2c:f4cb:63be::a64:a04).
	Pool             netip.Prefix   `json:"pool"`
	IPv6Base         netip.Addr     `json:"ipv6_base"`
	Host             string         `json:"host"`
	DNSDomains       []string       `json:"dns_domains"`
	InternalPrefixes []netip.Prefix `json:"internal_prefixes"`
	// Networks are the VLAN names offered to clients, in display order. Each
	// maps to interface vlan-<name>, with resolvers on vrrp-<name>-dns(6).
	Networks []string `json:"networks"`
}

type Peer struct {
	ID        string
	Name      string
	Owner     string
	PublicKey string
	Addresses []netip.Prefix
	Disabled  bool
	// LastHandshake is RouterOS' "time since", e.g. "1m23s"; empty if never.
	LastHandshake string
	raw           routeros.Row
}

type Snapshot struct {
	Server routeros.Row
	Peers  []Peer
	addrs  map[string][]netip.Prefix
}

var deviceName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,30}$`)

func ValidDeviceName(s string) bool { return deviceName.MatchString(s) }

func ValidPublicKey(s string) bool {
	b, err := base64.StdEncoding.DecodeString(s)
	return err == nil && len(b) == 32
}

// PeerName is the RouterOS peer name for a user's device.
func PeerName(owner, device string) string { return owner + "-" + device }

// Device is the user-facing device name of a peer owned via the portal.
func (p Peer) Device() string { return strings.TrimPrefix(p.Name, p.Owner+"-") }

func parseBool(s string) bool { return s == "true" || s == "yes" }

func parsePeer(r routeros.Row) Peer {
	p := Peer{
		ID:            r[".id"],
		Name:          r["name"],
		PublicKey:     r["public-key"],
		Disabled:      parseBool(r["disabled"]),
		LastHandshake: r["last-handshake"],
		raw:           r,
	}
	if o, ok := strings.CutPrefix(r["comment"], ownerPrefix); ok {
		p.Owner = o
	}
	for _, a := range strings.Split(r["allowed-address"], ",") {
		if pfx, err := netip.ParsePrefix(strings.TrimSpace(a)); err == nil {
			p.Addresses = append(p.Addresses, pfx)
		}
	}
	return p
}

func Read(ctx context.Context, c API, s Settings) (*Snapshot, error) {
	servers, err := c.Print(ctx, pathWireGuard, routeros.Row{"name": s.Interface})
	if err != nil {
		return nil, err
	}
	if len(servers) != 1 {
		return nil, fmt.Errorf("interface %s not found", s.Interface)
	}
	peers, err := c.Print(ctx, pathPeers, routeros.Row{"interface": s.Interface})
	if err != nil {
		return nil, err
	}
	snap := &Snapshot{Server: servers[0], addrs: map[string][]netip.Prefix{}}
	for _, r := range peers {
		snap.Peers = append(snap.Peers, parsePeer(r))
	}
	for _, path := range []string{"/ip/address", "/ipv6/address"} {
		rows, err := c.Print(ctx, path, nil)
		if err != nil {
			return nil, err
		}
		for _, r := range rows {
			if parseBool(r["disabled"]) || parseBool(r["invalid"]) {
				continue
			}
			p, err := netip.ParsePrefix(r["address"])
			// Unresolved from-pool templates (e.g. ::2:0:0:0:1) live in ::/8.
			if err != nil || p.Addr().IsLinkLocalUnicast() || netip.MustParsePrefix("::/8").Contains(p.Addr()) {
				continue
			}
			snap.addrs[r["interface"]] = append(snap.addrs[r["interface"]], p)
		}
	}
	return snap, nil
}

func (s *Snapshot) ByKey(key string) *Peer {
	for i := range s.Peers {
		if s.Peers[i].PublicKey == key {
			return &s.Peers[i]
		}
	}
	return nil
}

func (s *Snapshot) ByName(name string) *Peer {
	for i := range s.Peers {
		if s.Peers[i].Name == name {
			return &s.Peers[i]
		}
	}
	return nil
}

func (s *Snapshot) OwnedBy(owner string) []Peer {
	var out []Peer
	for _, p := range s.Peers {
		if p.Owner == owner {
			out = append(out, p)
		}
	}
	return out
}

// NextAddresses picks the first free address of the pool.
func (s *Snapshot) NextAddresses(set Settings) (netip.Prefix, netip.Prefix, error) {
	used := map[netip.Addr]bool{}
	for _, p := range s.Peers {
		for _, a := range p.Addresses {
			used[a.Masked().Addr()] = true
		}
	}
	pool := set.Pool.Masked()
	for a := pool.Addr().Next(); pool.Contains(a.Next()); a = a.Next() { // skip network and broadcast
		if used[a] {
			continue
		}
		v4 := a.As4()
		v6 := set.IPv6Base.As16()
		copy(v6[12:], v4[:])
		return netip.PrefixFrom(a, 32), netip.PrefixFrom(netip.AddrFrom16(v6), 128), nil
	}
	return netip.Prefix{}, netip.Prefix{}, errors.New("address pool exhausted")
}

// collapse masks prefixes and drops ones covered by another.
func collapse(ps []netip.Prefix) []netip.Prefix {
	var masked []netip.Prefix
	for _, p := range ps {
		masked = append(masked, p.Masked())
	}
	var out []netip.Prefix
	for _, p := range masked {
		covered := slices.ContainsFunc(masked, func(q netip.Prefix) bool {
			return q != p && q.Bits() < p.Bits() && q.Contains(p.Addr())
		})
		if !covered && !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	slices.SortFunc(out, func(a, b netip.Prefix) int {
		if a.Addr().Is4() != b.Addr().Is4() {
			if a.Addr().Is4() {
				return -1
			}
			return 1
		}
		return a.Addr().Compare(b.Addr())
	})
	return out
}

func hosts(ps []netip.Prefix) []netip.Addr {
	var out []netip.Addr
	for _, p := range ps {
		out = append(out, p.Addr())
	}
	return out
}

// Config builds the provisioning handed to p, or nil if it gets none.
func (s *Snapshot) Config(p Peer, set Settings) *provision.Config {
	if p.Disabled {
		return nil
	}
	var addrs []netip.Prefix
	for _, a := range p.Addresses {
		if a.IsSingleIP() {
			addrs = append(addrs, a)
		}
	}
	if len(addrs) == 0 {
		return nil
	}
	port, _ := strconv.Atoi(s.Server["listen-port"])
	mtu, _ := strconv.Atoi(s.Server["mtu"])
	vpn := s.addrs[set.Interface]
	cfg := &provision.Config{
		Version:   provision.Version,
		Name:      p.Name,
		Addresses: addrs,
		MTU:       mtu,
		Server: provision.Server{
			PublicKey:    s.Server["public-key"],
			PresharedKey: p.raw["preshared-key"],
			Host:         set.Host,
			Port:         uint16(port),
		},
		DNS:              provision.DNS{Servers: hosts(vpn), Domains: set.DNSDomains},
		VPNPrefixes:      collapse(vpn),
		InternalPrefixes: set.InternalPrefixes,
	}
	for _, name := range set.Networks {
		prefixes := collapse(s.addrs["vlan-"+name])
		if len(prefixes) == 0 {
			continue
		}
		dns := append(hosts(s.addrs["vrrp-"+name+"-dns"]), hosts(s.addrs["vrrp-"+name+"-dns6"])...)
		cfg.Networks = append(cfg.Networks, provision.Network{Name: name, Prefixes: prefixes, DNS: dns})
	}
	return cfg
}

// Upsert registers key as owner's device, replacing the key of an existing
// device of the same name (keeping its addresses) or allocating new ones.
// It returns the attributes to write; the caller applies them everywhere.
func (s *Snapshot) Upsert(set Settings, owner, device, key string) (id string, attrs routeros.Row, err error) {
	if !ValidDeviceName(device) {
		return "", nil, errors.New("device names are 1-31 lowercase letters, digits and dashes")
	}
	if !ValidPublicKey(key) {
		return "", nil, errors.New("that is not a WireGuard public key")
	}
	name := PeerName(owner, device)
	if other := s.ByKey(key); other != nil && other.Name != name {
		if other.Owner == owner {
			return "", nil, fmt.Errorf("this key is already registered as your device %q", other.Device())
		}
		return "", nil, errors.New("this key is already registered to someone else")
	}
	if existing := s.ByName(name); existing != nil {
		if existing.Owner != owner {
			return "", nil, fmt.Errorf("peer name %q is taken", name)
		}
		return existing.ID, routeros.Row{"public-key": key, "disabled": "false"}, nil
	}
	v4, v6, err := s.NextAddresses(set)
	if err != nil {
		return "", nil, err
	}
	return "", routeros.Row{
		"interface":       set.Interface,
		"name":            name,
		"comment":         ownerPrefix + owner,
		"public-key":      key,
		"allowed-address": v4.String() + "," + v6.String(),
		"responder":       "true",
	}, nil
}

// SyncFields are mirrored from the primary router to the others.
var SyncFields = []string{"name", "comment", "public-key", "preshared-key", "allowed-address", "responder", "disabled"}

// Mirror makes c's peers on the interface match primary.
func Mirror(ctx context.Context, c API, set Settings, primary *Snapshot) error {
	rows, err := c.Print(ctx, pathPeers, routeros.Row{"interface": set.Interface})
	if err != nil {
		return err
	}
	have := map[string]routeros.Row{}
	for _, r := range rows {
		have[r["public-key"]] = r
	}
	var errs []error
	for _, p := range primary.Peers {
		cur, ok := have[p.PublicKey]
		delete(have, p.PublicKey)
		// Fields the primary lacks are cleared, unless the backup lacks them too
		// (older RouterOS may not know e.g. responder).
		want := routeros.Row{}
		for _, f := range SyncFields {
			v, inPrimary := p.raw[f]
			if _, inCur := cur[f]; inPrimary || (ok && inCur) {
				want[f] = v
			}
		}
		switch {
		case !ok:
			want["interface"] = set.Interface
			errs = append(errs, c.Add(ctx, pathPeers, want))
		case slices.ContainsFunc(SyncFields, func(f string) bool { return cur[f] != want[f] }):
			errs = append(errs, c.Set(ctx, pathPeers, cur[".id"], want))
		}
	}
	for _, stray := range have {
		errs = append(errs, c.Remove(ctx, pathPeers, stray[".id"]))
	}
	return errors.Join(errs...)
}

func Apply(ctx context.Context, c API, id string, attrs routeros.Row) error {
	if id == "" {
		return c.Add(ctx, pathPeers, attrs)
	}
	return c.Set(ctx, pathPeers, id, attrs)
}

func Remove(ctx context.Context, c API, id string) error {
	return c.Remove(ctx, pathPeers, id)
}

// FindByKey looks a peer's id up on a router where ids differ from the primary.
func FindByKey(ctx context.Context, c API, set Settings, key string) (string, error) {
	rows, err := c.Print(ctx, pathPeers, routeros.Row{"interface": set.Interface, "public-key": key})
	if err != nil || len(rows) == 0 {
		return "", err
	}
	return rows[0][".id"], nil
}
