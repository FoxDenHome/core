package tunnel

import (
	"errors"
	"fmt"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"strings"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

const (
	rulePrioSuppress = 5208
	rulePrioTunnel   = 5209
)

type platformState struct {
	routes []netlink.Route
	rules  []*netlink.Rule
}

func (t *Tunnel) create(mtu int) error {
	name := t.opts.Name
	if l, err := netlink.LinkByName(name); err == nil {
		log.Printf("tunnel: removing stale interface %s", name)
		_ = netlink.LinkDel(l)
	}

	if !t.opts.ForceUserspace {
		err := netlink.LinkAdd(&netlink.Wireguard{LinkAttrs: netlink.LinkAttrs{Name: name, MTU: mtu}})
		if err == nil {
			t.name, t.backend = name, "kernel"
			return t.linkUp()
		}
		log.Printf("tunnel: kernel wireguard unavailable (%v), falling back to wireguard-go", err)
	}

	us, err := startUserspace(name, mtu)
	if err != nil {
		return err
	}
	t.us, t.name, t.backend = us, us.name, "userspace"
	return t.linkUp()
}

func (t *Tunnel) link() (netlink.Link, error) {
	return netlink.LinkByName(t.name)
}

func (t *Tunnel) linkUp() error {
	l, err := t.link()
	if err != nil {
		return err
	}
	return netlink.LinkSetUp(l)
}

func (t *Tunnel) destroy() error {
	if t.us != nil {
		// Closing the TUN removes the interface.
		return nil
	}
	l, err := t.link()
	if err != nil {
		return nil
	}
	return netlink.LinkDel(l)
}

func (t *Tunnel) setAddresses(cfg Config) error {
	l, err := t.link()
	if err != nil {
		return err
	}
	if err := netlink.LinkSetMTU(l, cfg.MTU); err != nil {
		return err
	}
	want := map[netip.Prefix]bool{}
	for _, p := range cfg.Addresses {
		want[p] = true
		a := &netlink.Addr{IPNet: ptr(prefixToIPNet(p))}
		a.IPNet.IP = p.Addr().AsSlice() // keep host bits
		if p.Addr().Is6() {
			a.Flags = unix.IFA_F_NODAD
		}
		if err := netlink.AddrReplace(l, a); err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
	}
	have, err := netlink.AddrList(l, netlink.FAMILY_ALL)
	if err != nil {
		return err
	}
	for _, a := range have {
		addr, _ := netip.AddrFromSlice(a.IP)
		ones, _ := a.Mask.Size()
		p := netip.PrefixFrom(addr.Unmap(), ones)
		if addr.IsLinkLocalUnicast() || want[p] {
			continue
		}
		_ = netlink.AddrDel(l, &a)
	}
	return netlink.LinkSetUp(l)
}

func (t *Tunnel) setRoutes(cfg Config) error {
	l, err := t.link()
	if err != nil {
		return err
	}
	idx := l.Attrs().Index

	// Both modes route through RouteTable behind the fwmark rules: the tunnel's
	// own (marked) packets never re-enter it, even when the endpoint lies in a
	// routed prefix (at home it is the router's LAN address), and anything
	// more specific than a default route in main, like the directly attached
	// network, still wins.
	routes := cfg.Routes
	if cfg.FullTunnel {
		routes = FullTunnelRoutes
	}
	var want []netlink.Route
	for _, p := range routes {
		want = append(want, netlink.Route{LinkIndex: idx, Dst: ptr(prefixToIPNet(p)), Table: RouteTable})
	}

	for _, old := range t.plat.routes {
		if !containsRoute(want, old) {
			_ = netlink.RouteDel(&old)
		}
	}
	for i := range want {
		if err := netlink.RouteReplace(&want[i]); err != nil {
			return fmt.Errorf("route %s: %w", want[i].Dst, err)
		}
	}
	t.plat.routes = want
	return t.addRules()
}

func containsRoute(rs []netlink.Route, r netlink.Route) bool {
	for _, x := range rs {
		if x.Table == r.Table && x.Dst.String() == r.Dst.String() {
			return true
		}
	}
	return false
}

// addRules installs wg-quick style policy routing: everything not carrying
// our firewall mark goes to RouteTable, except where main has a more specific
// route than the default (suppress_prefixlength 0), which keeps the local LAN
// reachable.
func (t *Tunnel) addRules() error {
	if len(t.plat.rules) > 0 {
		return nil
	}
	// rp_filter would otherwise drop replies to marked packets.
	_ = os.WriteFile("/proc/sys/net/ipv4/conf/all/src_valid_mark", []byte("1"), 0o644)

	for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		suppress := netlink.NewRule()
		suppress.Family = fam
		suppress.Priority = rulePrioSuppress
		suppress.Table = unix.RT_TABLE_MAIN
		suppress.SuppressPrefixlen = 0

		tunnel := netlink.NewRule()
		tunnel.Family = fam
		tunnel.Priority = rulePrioTunnel
		tunnel.Table = RouteTable
		tunnel.Mark = FirewallMark
		tunnel.Invert = true

		for _, r := range []*netlink.Rule{suppress, tunnel} {
			_ = netlink.RuleDel(r)
			if err := netlink.RuleAdd(r); err != nil {
				t.delRules()
				return fmt.Errorf("adding rule: %w", err)
			}
			t.plat.rules = append(t.plat.rules, r)
		}
	}
	return nil
}

func (t *Tunnel) delRules() {
	for _, r := range t.plat.rules {
		_ = netlink.RuleDel(r)
	}
	t.plat.rules = nil
}

func (t *Tunnel) clearRoutes() error {
	t.delRules()
	for _, r := range t.plat.routes {
		_ = netlink.RouteDel(&r)
	}
	t.plat.routes = nil
	return nil
}

// CleanupStale removes leftovers of a previous run that died without cleanup.
func CleanupStale(opts Options) {
	if l, err := netlink.LinkByName(opts.Name); err == nil {
		_ = netlink.LinkDel(l)
	}
	t := &Tunnel{}
	for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		for _, prio := range []int{rulePrioSuppress, rulePrioTunnel} {
			r := netlink.NewRule()
			r.Family = fam
			r.Priority = prio
			t.plat.rules = append(t.plat.rules, r)
		}
	}
	t.delRules()
}

func (t *Tunnel) setDNS(cfg Config) error {
	if _, err := exec.LookPath("resolvectl"); err != nil {
		return errors.New("resolvectl not found; DNS for the tunnel requires systemd-resolved")
	}
	servers := make([]string, 0, len(cfg.DNSServers))
	for _, s := range cfg.DNSServers {
		servers = append(servers, s.String())
	}
	domains := make([]string, 0, len(cfg.DNSDomains)+1)
	for _, d := range cfg.DNSDomains {
		domains = append(domains, "~"+strings.TrimPrefix(d, "~"))
	}
	defaultRoute := "false"
	if cfg.FullTunnel {
		domains = append(domains, "~.")
		defaultRoute = "true"
	}
	for _, args := range [][]string{
		append([]string{"dns", t.name}, servers...),
		append([]string{"domain", t.name}, domains...),
		{"default-route", t.name, defaultRoute},
	} {
		if out, err := exec.Command("resolvectl", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("resolvectl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
	}
	return nil
}

func (t *Tunnel) clearDNS() error {
	if _, err := exec.LookPath("resolvectl"); err != nil {
		return nil
	}
	_ = exec.Command("resolvectl", "revert", t.name).Run()
	return nil
}

func ptr[T any](v T) *T { return &v }
