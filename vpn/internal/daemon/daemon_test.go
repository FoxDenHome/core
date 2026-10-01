package daemon

import (
	"context"
	"net/netip"
	"slices"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func pfx(s ...string) []netip.Prefix {
	var out []netip.Prefix
	for _, x := range s {
		out = append(out, netip.MustParsePrefix(x))
	}
	return out
}

func testProv(t *testing.T) *provision.Config {
	server, _ := wgtypes.GeneratePrivateKey()
	return &provision.Config{
		Version:     provision.Version,
		Addresses:   pfx("10.100.10.4/32", "fd2c:f4cb:63be::a64:a04/128"),
		MTU:         1280,
		Server:      provision.Server{PublicKey: server.PublicKey().String(), Host: "vpn.example", Port: 13231},
		VPNPrefixes: pfx("10.100.0.0/16", "fd2c:f4cb:63be::a64:0/112"),
		Networks: []provision.Network{
			{Name: "mgmt", Prefixes: pfx("10.1.0.0/16", "fd2c:f4cb:63be:1::/64")},
			{Name: "lan", Prefixes: pfx("10.2.0.0/16", "2a0e:7d44:f069:a02::/64")},
		},
		InternalPrefixes: pfx("10.0.0.0/8"),
	}
}

func testDaemon() *Daemon {
	k, _ := wgtypes.GeneratePrivateKey()
	return &Daemon{key: k}
}

func TestBuildConfigSplit(t *testing.T) {
	d := testDaemon()
	cfg, err := d.buildConfig(Settings{Mode: api.ModeSplit, DisabledNetworks: []string{"mgmt"}}, testProv(t))
	if err != nil {
		t.Fatal(err)
	}
	want := pfx("10.2.0.0/16", "10.100.0.0/16", "2a0e:7d44:f069:a02::/64", "fd2c:f4cb:63be::a64:0/112")
	if !slices.Equal(cfg.Routes, want) {
		t.Fatalf("routes = %v, want %v", cfg.Routes, want)
	}
	if cfg.FullTunnel || cfg.Keepalive != 0 {
		t.Fatal("split tunnel must not keep the session alive")
	}
}

func TestBuildConfigFull(t *testing.T) {
	d := testDaemon()
	cfg, err := d.buildConfig(Settings{Mode: api.ModeFull}, testProv(t))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.FullTunnel || !slices.Equal(cfg.Routes, tunnel.FullTunnelRoutes) || cfg.Keepalive == 0 {
		t.Fatalf("unexpected full tunnel config %+v", cfg)
	}
}

func TestBuildConfigNeverRoutesEndpoint(t *testing.T) {
	d := testDaemon()
	d.candidates = []netip.AddrPort{netip.MustParseAddrPort("[2a0e:7d44:f069:a02::1]:13231")}
	cfg, err := d.buildConfig(Settings{Mode: api.ModeSplit}, testProv(t))
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(cfg.Routes, netip.MustParsePrefix("2a0e:7d44:f069:a02::/64")) {
		t.Fatalf("endpoint's prefix is routed into the tunnel: %v", cfg.Routes)
	}
}

func TestDetectLocation(t *testing.T) {
	prov := testProv(t)
	ctx := context.Background()
	if got := detectLocation(ctx, prov, nil); got != api.LocationOffline {
		t.Fatalf("no addresses: got %s", got)
	}
	// Holding a FoxDen-looking address without a FoxDen resolver is not home.
	addrs := []localAddr{{iface: "lo", addr: netip.MustParseAddr("10.2.5.5")}}
	if got := detectLocation(ctx, prov, addrs); got != api.LocationWAN {
		t.Fatalf("got %s", got)
	}
}
