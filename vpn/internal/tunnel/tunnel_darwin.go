package tunnel

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// macOS has no kernel WireGuard, so this always runs wireguard-go on a utun
// and configures it with ifconfig/route/networksetup, like wg-quick does.

const resolverDir = "/etc/resolver"
const resolverMarker = "# managed by foxden-vpnd"

type bypassRoute struct {
	dst     netip.Prefix
	gateway string
	iface   string
}

type platformState struct {
	routes   []netip.Prefix
	bypass   *bypassRoute
	resolver []string
	savedDNS map[string][]string
}

var fullTunnelSplitRoutes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/1"),
	netip.MustParsePrefix("128.0.0.0/1"),
	netip.MustParsePrefix("::/1"),
	netip.MustParsePrefix("8000::/1"),
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (t *Tunnel) create(mtu int) error {
	us, err := startUserspace("utun", mtu)
	if err != nil {
		return err
	}
	t.us, t.name, t.backend = us, us.name, "userspace"
	return nil
}

func (t *Tunnel) destroy() error { return nil }

func family(p netip.Prefix) string {
	if p.Addr().Is4() {
		return "-inet"
	}
	return "-inet6"
}

func (t *Tunnel) setAddresses(cfg Config) error {
	if err := run("ifconfig", t.name, "mtu", fmt.Sprint(cfg.MTU)); err != nil {
		return err
	}
	// utun interfaces only gain addresses here, and are recreated on change,
	// so re-adding is enough.
	for _, p := range cfg.Addresses {
		var err error
		if p.Addr().Is4() {
			err = run("ifconfig", t.name, "inet", p.String(), p.Addr().String(), "alias")
		} else {
			err = run("ifconfig", t.name, "inet6", p.String(), "alias")
		}
		if err != nil {
			return err
		}
	}
	return run("ifconfig", t.name, "up")
}

func (t *Tunnel) wantRoutes(cfg Config) []netip.Prefix {
	if cfg.FullTunnel {
		return fullTunnelSplitRoutes
	}
	return cfg.Routes
}

func (t *Tunnel) setRoutes(cfg Config) error {
	want := t.wantRoutes(cfg)
	for _, old := range t.plat.routes {
		if !containsPrefix(want, old) {
			_ = run("route", "-q", "-n", "delete", family(old), old.String(), "-interface", t.name)
		}
	}
	for _, p := range want {
		if containsPrefix(t.plat.routes, p) {
			continue
		}
		if err := run("route", "-q", "-n", "add", family(p), p.String(), "-interface", t.name); err != nil {
			return err
		}
	}
	t.plat.routes = append([]netip.Prefix(nil), want...)

	// If the endpoint lies inside a tunneled prefix (always in full tunnel
	// mode; at home it is the router's LAN address), it must keep going via
	// the physical default gateway, which changes as the laptop roams.
	var bypass *bypassRoute
	ep := cfg.Endpoint.Addr().Unmap()
	if cfg.Endpoint.IsValid() && slices.ContainsFunc(want, func(p netip.Prefix) bool { return p.Contains(ep) }) {
		gw, iface, err := defaultGateway(ep.Is4())
		if err != nil {
			log.Printf("tunnel: no physical default route for endpoint bypass: %v", err)
		} else {
			bypass = &bypassRoute{dst: netip.PrefixFrom(ep, ep.BitLen()), gateway: gw, iface: iface}
		}
	}
	if old := t.plat.bypass; old != nil && (bypass == nil || *old != *bypass) {
		_ = run("route", "-q", "-n", "delete", family(old.dst), old.dst.String())
		t.plat.bypass = nil
	}
	if bypass != nil && t.plat.bypass == nil {
		args := []string{"-q", "-n", "add", family(bypass.dst), bypass.dst.String()}
		if bypass.gateway != "" {
			args = append(args, bypass.gateway)
		} else {
			args = append(args, "-interface", bypass.iface)
		}
		if err := run("route", args...); err != nil {
			return err
		}
		t.plat.bypass = bypass
	}
	return nil
}

func containsPrefix(ps []netip.Prefix, p netip.Prefix) bool {
	for _, x := range ps {
		if x == p {
			return true
		}
	}
	return false
}

// defaultGateway returns the physical default route. Our own full-tunnel
// routes are /1s, so "default" still resolves to the real one.
func defaultGateway(v4 bool) (gateway, iface string, err error) {
	fam := "-inet"
	if !v4 {
		fam = "-inet6"
	}
	out, err := exec.Command("route", "-n", "get", fam, "default").Output()
	if err != nil {
		return "", "", err
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), ":")
		if !ok {
			continue
		}
		switch k {
		case "gateway":
			gateway = strings.TrimSpace(v)
		case "interface":
			iface = strings.TrimSpace(v)
		}
	}
	if iface == "" || strings.HasPrefix(iface, "utun") {
		return "", "", errors.New("no default route")
	}
	return gateway, iface, nil
}

func (t *Tunnel) clearRoutes() error {
	// Interface routes vanish with the utun; only the bypass is ours to undo.
	if b := t.plat.bypass; b != nil {
		_ = run("route", "-q", "-n", "delete", family(b.dst), b.dst.String())
	}
	t.plat.routes = nil
	t.plat.bypass = nil
	return nil
}

func (t *Tunnel) setDNS(cfg Config) error {
	var servers []string
	for _, s := range cfg.DNSServers {
		servers = append(servers, s.String())
	}

	// Per-domain resolvers cover split mode, and the internal zones in full mode.
	var body strings.Builder
	body.WriteString(resolverMarker + "\n")
	for _, s := range servers {
		body.WriteString("nameserver " + s + "\n")
	}
	if err := os.MkdirAll(resolverDir, 0o755); err != nil {
		return err
	}
	written := map[string]bool{}
	for _, d := range cfg.DNSDomains {
		d = strings.TrimSuffix(strings.TrimPrefix(d, "~"), ".")
		if err := os.WriteFile(filepath.Join(resolverDir, d), []byte(body.String()), 0o644); err != nil {
			return err
		}
		written[d] = true
	}
	for _, d := range t.plat.resolver {
		if !written[d] {
			removeResolver(d)
		}
	}
	t.plat.resolver = t.plat.resolver[:0]
	for d := range written {
		t.plat.resolver = append(t.plat.resolver, d)
	}

	if cfg.FullTunnel {
		return t.overrideServiceDNS(servers)
	}
	return t.restoreServiceDNS()
}

func removeResolver(domain string) {
	p := filepath.Join(resolverDir, domain)
	if b, err := os.ReadFile(p); err == nil && strings.HasPrefix(string(b), resolverMarker) {
		_ = os.Remove(p)
	}
}

func savedDNSPath() string { return filepath.Join(StateDir, "saved-dns.json") }

func networkServices() ([]string, error) {
	out, err := exec.Command("networksetup", "-listallnetworkservices").Output()
	if err != nil {
		return nil, err
	}
	var svcs []string
	for i, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if i == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue // header line, disabled services
		}
		svcs = append(svcs, line)
	}
	return svcs, nil
}

// overrideServiceDNS points every network service at the tunnel resolvers,
// remembering the previous setting on disk so it survives a crash.
func (t *Tunnel) overrideServiceDNS(servers []string) error {
	if t.plat.savedDNS == nil {
		svcs, err := networkServices()
		if err != nil {
			return err
		}
		saved := map[string][]string{}
		for _, svc := range svcs {
			out, err := exec.Command("networksetup", "-getdnsservers", svc).Output()
			if err != nil {
				continue
			}
			var cur []string
			for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
				if _, err := netip.ParseAddr(l); err == nil {
					cur = append(cur, l)
				}
			}
			saved[svc] = cur
		}
		b, _ := json.Marshal(saved)
		if err := os.WriteFile(savedDNSPath(), b, 0o600); err != nil {
			return err
		}
		t.plat.savedDNS = saved
	}
	for svc := range t.plat.savedDNS {
		if err := run("networksetup", append([]string{"-setdnsservers", svc}, servers...)...); err != nil {
			log.Printf("tunnel: %v", err)
		}
	}
	return nil
}

func (t *Tunnel) restoreServiceDNS() error {
	saved := t.plat.savedDNS
	if saved == nil {
		return nil
	}
	restoreDNS(saved)
	t.plat.savedDNS = nil
	return nil
}

func restoreDNS(saved map[string][]string) {
	for svc, servers := range saved {
		args := []string{"-setdnsservers", svc}
		if len(servers) == 0 {
			args = append(args, "Empty")
		} else {
			args = append(args, servers...)
		}
		if err := run("networksetup", args...); err != nil {
			log.Printf("tunnel: restoring DNS: %v", err)
		}
	}
	_ = os.Remove(savedDNSPath())
}

func (t *Tunnel) clearDNS() error {
	for _, d := range t.plat.resolver {
		removeResolver(d)
	}
	t.plat.resolver = nil
	return t.restoreServiceDNS()
}

// CleanupStale undoes DNS changes from a previous run that died without
// cleanup. utun interfaces disappear with their process.
func CleanupStale(Options) {
	if b, err := os.ReadFile(savedDNSPath()); err == nil {
		var saved map[string][]string
		if json.Unmarshal(b, &saved) == nil {
			log.Printf("tunnel: restoring DNS settings left over from a previous run")
			restoreDNS(saved)
		}
	}
	entries, _ := os.ReadDir(resolverDir)
	for _, e := range entries {
		removeResolver(e.Name())
	}
}
