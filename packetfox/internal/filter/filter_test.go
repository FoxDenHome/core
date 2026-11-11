package filter

import "testing"

func TestNormalize(t *testing.T) {
	f := Filter{Hosts: []string{" 10.2.0.1 ", "fd2c:f4cb:63be:2::1", "10.2.0.0/16", "10.2.0.1", ""}, Ports: []int{443, 80, 443}}
	if err := f.Normalize(); err != nil {
		t.Fatal(err)
	}
	want := []string{"10.2.0.0/16", "10.2.0.1/32", "fd2c:f4cb:63be:2::1/128"}
	if len(f.Hosts) != len(want) {
		t.Fatalf("hosts = %v", f.Hosts)
	}
	for i := range want {
		if f.Hosts[i] != want[i] {
			t.Fatalf("hosts = %v", f.Hosts)
		}
	}
	if len(f.Ports) != 2 || f.Ports[0] != 80 {
		t.Fatalf("ports = %v", f.Ports)
	}

	for _, bad := range []Filter{
		{Hosts: []string{"nope"}},
		{Ports: []int{0}},
		{Protocol: "sctp"},
		{Protocol: "icmp", Ports: []int{1}},
		{BPF: "tcp' ; rm -rf /"},
		{BPF: "-z /bin/sh"},
	} {
		if err := bad.Normalize(); err == nil {
			t.Errorf("%+v: no error", bad)
		}
	}
}

func TestBPFExpr(t *testing.T) {
	f := Filter{Hosts: []string{"10.2.0.1", "10.3.0.0/16"}, Ports: []int{22}, Protocol: "tcp"}
	if err := f.Normalize(); err != nil {
		t.Fatal(err)
	}
	want := "((host 10.2.0.1 or net 10.3.0.0/16) and (port 22) and tcp) or (vlan and ((host 10.2.0.1 or net 10.3.0.0/16) and (port 22) and tcp))"
	if got := f.BPFExpr(); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if (Filter{}).BPFExpr() != "" {
		t.Error("empty filter should compile to nothing")
	}
}

func TestRouterMatchers(t *testing.T) {
	f := Filter{Hosts: []string{"10.2.0.1"}, Ports: []int{53}}
	_ = f.Normalize()
	m, ok := f.RouterMatchers("ip")
	if !ok || len(m) != 4 {
		t.Fatalf("ip: %v %v", ok, m)
	}
	if m[3]["dst-address-list"] != "pfox" || m[3]["src-address-list"] != "!pfox" || m[3]["protocol"] != "udp" || m[3]["port"] != "53" {
		t.Errorf("unexpected %v", m[3])
	}
	if _, ok := f.RouterMatchers("ipv6"); ok {
		t.Error("IPv4-only filter should not match IPv6")
	}

	f = Filter{Protocol: "icmp"}
	m, ok = f.RouterMatchers("ipv6")
	if !ok || len(m) != 1 || m[0]["protocol"] != "icmpv6" {
		t.Errorf("icmpv6: %v", m)
	}
}
