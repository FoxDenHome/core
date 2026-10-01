package daemon

import (
	"context"
	"net"
	"net/netip"
	"slices"
	"strings"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// Public resolvers used when the system resolver only gives us the internal
// answer for the endpoint (it does once tunnel DNS is active).
var publicResolvers = []netip.AddrPort{
	netip.MustParseAddrPort("1.1.1.1:53"),
	netip.MustParseAddrPort("9.9.9.9:53"),
	netip.MustParseAddrPort("[2606:4700:4700::1111]:53"),
	netip.MustParseAddrPort("[2620:fe::fe]:53"),
}

type localAddr struct {
	iface string
	addr  netip.Addr
}

// physicalAddrs lists usable addresses on every interface except loopback and
// our tunnel.
func physicalAddrs(tunnelIface string) []localAddr {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []localAddr
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 || ifc.Name == tunnelIface {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip, ok := netip.AddrFromSlice(ipn.IP)
			if !ok {
				continue
			}
			ip = ip.Unmap()
			if ip.IsLinkLocalUnicast() || ip.IsLoopback() {
				continue
			}
			out = append(out, localAddr{iface: ifc.Name, addr: ip})
		}
	}
	return out
}

// fingerprint changes whenever the laptop's physical network attachment does.
func fingerprint(addrs []localAddr) string {
	parts := make([]string, 0, len(addrs))
	for _, a := range addrs {
		parts = append(parts, a.iface+"="+a.addr.String())
	}
	slices.Sort(parts)
	return strings.Join(parts, ",")
}

func lookup(ctx context.Context, r *net.Resolver, host string, timeout time.Duration) []netip.Addr {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ips, err := r.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil
	}
	for i := range ips {
		ips[i] = ips[i].Unmap()
	}
	return ips
}

// home describes where we are.
type home struct {
	Location string
	// Networks are the FoxDen networks we are directly attached to (at home
	// only). Their traffic stays off the tunnel.
	Networks []string
	// Endpoints are the internal addresses of the VPN endpoint, as the home
	// resolver gave them (at home only).
	Endpoints []netip.Addr
}

// detectLocation decides whether we are on a FoxDen LAN. We only count as home
// if we hold an address in one of the FoxDen networks *and* that network's own
// resolver gives the internal answer for the VPN endpoint, so a random hotel
// that happens to use the same RFC1918 range does not fool us.
func detectLocation(ctx context.Context, prov *provision.Config, addrs []localAddr) home {
	if len(addrs) == 0 {
		return home{Location: api.LocationOffline}
	}
	if prov == nil {
		return home{Location: api.LocationUnknown}
	}
	h := home{Location: api.LocationWAN}
	for _, n := range prov.Networks {
		for _, a := range addrs {
			if !slices.ContainsFunc(n.Prefixes, func(p netip.Prefix) bool { return p.Contains(a.addr) }) {
				continue
			}
			if !slices.Contains(h.Networks, n.Name) {
				h.Networks = append(h.Networks, n.Name)
			}
			if len(h.Endpoints) > 0 {
				continue // already confirmed
			}
			for _, dns := range n.DNS {
				if dns.Is4() != a.addr.Is4() {
					continue
				}
				server := netip.AddrPortFrom(dns, 53)
				for _, ip := range queryDNS(ctx, server, a.iface, prov.Server.Host, 1500*time.Millisecond) {
					if prov.IsInternal(ip) && !slices.Contains(h.Endpoints, ip) {
						h.Endpoints = append(h.Endpoints, ip)
					}
				}
				if len(h.Endpoints) > 0 {
					break
				}
			}
		}
	}
	if len(h.Endpoints) == 0 {
		// Not home: overlapping addresses elsewhere say nothing about VLANs.
		return home{Location: api.LocationWAN}
	}
	h.Location = api.LocationLAN
	slices.SortStableFunc(h.Endpoints, func(a, b netip.Addr) int { // IPv4 first
		switch {
		case a.Is4() == b.Is4():
			return 0
		case a.Is4():
			return -1
		default:
			return 1
		}
	})
	return h
}

// resolveEndpoint returns the public endpoint candidates, best first. Internal
// answers are dropped: we only dial the endpoint when away from home.
func resolveEndpoint(ctx context.Context, prov *provision.Config, addrs []localAddr) []netip.AddrPort {
	filter := func(ips []netip.Addr) []netip.Addr {
		return slices.DeleteFunc(ips, func(ip netip.Addr) bool {
			return prov.IsInternal(ip) || !ip.IsGlobalUnicast() || ip.IsPrivate()
		})
	}
	ips := filter(lookup(ctx, net.DefaultResolver, prov.Server.Host, 5*time.Second))
	if len(ips) == 0 {
		for _, s := range publicResolvers {
			if ips = filter(queryDNS(ctx, s, "", prov.Server.Host, 3*time.Second)); len(ips) > 0 {
				break
			}
		}
	}

	var have4, have6 bool
	for _, a := range addrs {
		if a.addr.Is4() {
			have4 = true
		} else if a.addr.IsGlobalUnicast() && !a.addr.IsPrivate() {
			have6 = true
		}
	}
	var v4, v6 []netip.AddrPort
	for _, ip := range ips {
		ap := netip.AddrPortFrom(ip, prov.Server.Port)
		if ip.Is4() && have4 {
			v4 = append(v4, ap)
		} else if ip.Is6() && have6 {
			v6 = append(v6, ap)
		}
	}
	// IPv4 first: broken IPv6 on foreign networks is far more common than
	// broken IPv4. A stuck handshake rotates to the next candidate anyway.
	return append(v4, v6...)
}
