// Package filter is the capture filter. One filter is compiled into a BPF
// expression for tcpdump on hosts and APs, and into firewall rules for the
// routers, so every capture point sees the same traffic.
package filter

import (
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

type Filter struct {
	// Addresses or prefixes; a packet matches if its source or destination
	// is in one of them.
	Hosts []string `json:"hosts"`
	// A packet matches if its source or destination port is one of these.
	Ports []int `json:"ports"`
	// "", "tcp", "udp" or "icmp" (ICMP and ICMPv6).
	Protocol string `json:"protocol"`
	// Extra BPF, ANDed with the rest. Only hosts and APs apply it; the
	// routers can't.
	BPF string `json:"bpf"`
}

// bpfSafe is what a BPF expression may contain. No quotes, so it can be
// single-quoted for a remote shell, and no leading dash.
var bpfSafe = regexp.MustCompile(`^[A-Za-z0-9 _.:/()!&|=<>\[\]+*%^,-]*$`)

func ValidBPF(s string) bool {
	return bpfSafe.MatchString(s) && !strings.HasPrefix(strings.TrimSpace(s), "-")
}

func (f *Filter) Normalize() error {
	var hosts []string
	for _, h := range f.Hosts {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		p, err := ParseHost(h)
		if err != nil {
			return err
		}
		hosts = append(hosts, p.String())
	}
	slices.Sort(hosts)
	f.Hosts = slices.Compact(hosts)
	for _, p := range f.Ports {
		if p < 1 || p > 65535 {
			return fmt.Errorf("invalid port %d", p)
		}
	}
	slices.Sort(f.Ports)
	f.Ports = slices.Compact(f.Ports)
	switch f.Protocol {
	case "", "tcp", "udp", "icmp":
	default:
		return fmt.Errorf("invalid protocol %q", f.Protocol)
	}
	if f.Protocol == "icmp" && len(f.Ports) > 0 {
		return errors.New("ICMP has no ports")
	}
	f.BPF = strings.TrimSpace(f.BPF)
	if !ValidBPF(f.BPF) {
		return errors.New("BPF expression contains forbidden characters")
	}
	return nil
}

func ParseHost(h string) (netip.Prefix, error) {
	if strings.Contains(h, "/") {
		p, err := netip.ParsePrefix(h)
		if err != nil {
			return p, fmt.Errorf("invalid prefix %q", h)
		}
		return p.Masked(), nil
	}
	a, err := netip.ParseAddr(h)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("invalid address %q", h)
	}
	return netip.PrefixFrom(a, a.BitLen()), nil
}

func (f Filter) Prefixes() []netip.Prefix {
	var out []netip.Prefix
	for _, h := range f.Hosts {
		if p, err := ParseHost(h); err == nil {
			out = append(out, p)
		}
	}
	return out
}

// Empty reports whether the filter would match all traffic.
func (f Filter) Empty() bool {
	return len(f.Hosts) == 0 && len(f.Ports) == 0 && f.Protocol == "" && f.BPF == ""
}

// BPFExpr compiles the filter for tcpdump. VLAN-tagged frames (trunk
// interfaces) are matched too.
func (f Filter) BPFExpr() string {
	var parts []string
	if len(f.Hosts) > 0 {
		var hs []string
		for _, p := range f.Prefixes() {
			if p.IsSingleIP() {
				hs = append(hs, "host "+p.Addr().String())
			} else {
				hs = append(hs, "net "+p.String())
			}
		}
		parts = append(parts, "("+strings.Join(hs, " or ")+")")
	}
	if len(f.Ports) > 0 {
		var ps []string
		for _, p := range f.Ports {
			ps = append(ps, "port "+strconv.Itoa(p))
		}
		parts = append(parts, "("+strings.Join(ps, " or ")+")")
	}
	switch f.Protocol {
	case "tcp", "udp":
		parts = append(parts, f.Protocol)
	case "icmp":
		parts = append(parts, "(icmp or icmp6)")
	}
	if f.BPF != "" {
		parts = append(parts, "("+f.BPF+")")
	}
	if len(parts) == 0 {
		return ""
	}
	expr := strings.Join(parts, " and ")
	return fmt.Sprintf("(%s) or (vlan and (%s))", expr, expr)
}

// AddressList is the RouterOS address list holding the filter's hosts.
const AddressList = "pfox"

// RouterRule is one RouterOS firewall rule, as API attributes.
type RouterRule map[string]string

// RouterMatchers returns the matcher sets for one family ("ip" or "ipv6"):
// a packet matches the filter if it matches any of them. The address list
// AddressList must hold the family's hosts. ok is false if the filter
// can't match anything in this family.
func (f Filter) RouterMatchers(family string) (matchers []RouterRule, ok bool) {
	var famHosts int
	for _, p := range f.Prefixes() {
		if p.Addr().Is4() == (family == "ip") {
			famHosts++
		}
	}
	if len(f.Hosts) > 0 && famHosts == 0 {
		return nil, false
	}

	var protos []RouterRule
	switch {
	case f.Protocol == "icmp":
		if family == "ip" {
			protos = []RouterRule{{"protocol": "icmp"}}
		} else {
			protos = []RouterRule{{"protocol": "icmpv6"}}
		}
	case len(f.Ports) > 0:
		var ps []string
		for _, p := range f.Ports {
			ps = append(ps, strconv.Itoa(p))
		}
		port := strings.Join(ps, ",")
		if f.Protocol != "" {
			protos = []RouterRule{{"protocol": f.Protocol, "port": port}}
		} else {
			protos = []RouterRule{{"protocol": "tcp", "port": port}, {"protocol": "udp", "port": port}}
		}
	case f.Protocol != "":
		protos = []RouterRule{{"protocol": f.Protocol}}
	default:
		protos = []RouterRule{{}}
	}

	addrs := []RouterRule{{}}
	if famHosts > 0 {
		// Two rules, so traffic between two listed hosts matches only once
		addrs = []RouterRule{
			{"src-address-list": AddressList},
			{"dst-address-list": AddressList, "src-address-list": "!" + AddressList},
		}
	}

	for _, a := range addrs {
		for _, p := range protos {
			m := RouterRule{}
			for k, v := range a {
				m[k] = v
			}
			for k, v := range p {
				m[k] = v
			}
			matchers = append(matchers, m)
		}
	}
	return matchers, true
}
