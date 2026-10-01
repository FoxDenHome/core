package registry

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/registry/registrytest"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func settings() Settings {
	return Settings{
		Interface:        "wg-vpn",
		Pool:             netip.MustParsePrefix("10.100.10.0/24"),
		IPv6Base:         netip.MustParseAddr("fd2c:f4cb:63be::"),
		Host:             "vpn.foxden.network",
		InternalPrefixes: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
		Networks:         []string{"mgmt", "lan"},
	}
}

func key() string {
	k, _ := wgtypes.GeneratePrivateKey()
	return k.PublicKey().String()
}

func adminPeer(f *registrytest.Router, name string, n int) {
	f.Tables[pathPeers] = append(f.Tables[pathPeers], routeros.Row{
		".id": fmt.Sprintf("*%d", n), "interface": "wg-vpn", "name": name, "public-key": key(),
		"allowed-address": fmt.Sprintf("10.100.10.%d/32,fd2c:f4cb:63be::a64:a%02x/128", n, n),
	})
}

func upsert(t *testing.T, f *registrytest.Router, owner, device, k string) error {
	t.Helper()
	ctx := context.Background()
	snap, err := Read(ctx, f, settings())
	if err != nil {
		t.Fatal(err)
	}
	id, attrs, err := snap.Upsert(settings(), owner, device, k)
	if err != nil {
		return err
	}
	return Apply(ctx, f, id, attrs)
}

func read(t *testing.T, f *registrytest.Router) *Snapshot {
	t.Helper()
	snap, err := Read(context.Background(), f, settings())
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

func TestUpsertAllocatesFirstFree(t *testing.T) {
	f := registrytest.New()
	adminPeer(f, "fennec", 1)
	adminPeer(f, "capefox", 2)
	adminPeer(f, "wizzy-laptop", 4)

	if err := upsert(t, f, "dori", "laptop", key()); err != nil {
		t.Fatal(err)
	}
	p := read(t, f).ByName("dori-laptop")
	if p == nil || p.Owner != "dori" || p.Device() != "laptop" {
		t.Fatalf("peer not registered: %+v", p)
	}
	want := []netip.Prefix{netip.MustParsePrefix("10.100.10.3/32"), netip.MustParsePrefix("fd2c:f4cb:63be::a64:a03/128")}
	if !slices.Equal(p.Addresses, want) {
		t.Fatalf("addresses = %v, want %v", p.Addresses, want)
	}
}

func TestUpsertOverwritesOwnDevice(t *testing.T) {
	f := registrytest.New()
	if err := upsert(t, f, "dori", "laptop", key()); err != nil {
		t.Fatal(err)
	}
	before := read(t, f).ByName("dori-laptop")
	newKey := key()
	if err := upsert(t, f, "dori", "laptop", newKey); err != nil {
		t.Fatal(err)
	}
	snap := read(t, f)
	after := snap.ByName("dori-laptop")
	if len(snap.Peers) != 1 || after.PublicKey != newKey || !slices.Equal(after.Addresses, before.Addresses) {
		t.Fatalf("overwrite did not keep the device: %+v", snap.Peers)
	}
}

func TestUpsertRejects(t *testing.T) {
	f := registrytest.New()
	adminPeer(f, "fennec", 1)
	fennecKey := read(t, f).ByName("fennec").PublicKey
	k := key()
	if err := upsert(t, f, "dori", "laptop", k); err != nil {
		t.Fatal(err)
	}

	for name, c := range map[string]struct{ owner, device, key, want string }{
		"someone else's key": {"wizzy", "laptop", k, "someone else"},
		"admin peer's key":   {"dori", "pc", fennecKey, "someone else"},
		"own key twice":      {"dori", "pc", k, `your device "laptop"`},
		"bad name":           {"dori", "Laptop!", key(), "device names"},
		"bad key":            {"dori", "pc", "nope", "not a WireGuard"},
	} {
		err := upsert(t, f, c.owner, c.device, c.key)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v, want error containing %q", name, err, c.want)
		}
	}
}

func TestPoolExhaustion(t *testing.T) {
	f := registrytest.New()
	set := settings()
	set.Pool = netip.MustParsePrefix("10.100.10.0/30") // .1 and .2 only
	snap := read(t, f)
	for _, dev := range []string{"a", "b"} {
		id, attrs, err := snap.Upsert(set, "dori", dev, key())
		if err != nil {
			t.Fatal(err)
		}
		_ = Apply(context.Background(), f, id, attrs)
		snap = read(t, f)
	}
	if _, _, err := snap.Upsert(set, "dori", "c", key()); err == nil {
		t.Fatal("pool should be exhausted")
	}
}

func TestConfig(t *testing.T) {
	f := registrytest.New()
	if err := upsert(t, f, "dori", "laptop", key()); err != nil {
		t.Fatal(err)
	}
	snap := read(t, f)
	cfg := snap.Config(*snap.ByName("dori-laptop"), settings())
	if cfg == nil {
		t.Fatal("no config")
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Networks) != 1 || cfg.Networks[0].Name != "lan" { // mgmt is disabled on the router
		t.Fatalf("networks = %+v", cfg.Networks)
	}
	got := fmt.Sprint(cfg.Networks[0].Prefixes, cfg.Networks[0].DNS, cfg.VPNPrefixes, cfg.DNS.Servers)
	want := "[10.2.0.0/16 2a0e:7d44:f069:a02::/64] [10.2.0.53] [10.100.0.0/16 fd2c:f4cb:63be::a64:0/112] [10.100.0.1 fd2c:f4cb:63be::a64:1]"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestMirror(t *testing.T) {
	primary, backup := registrytest.New(), registrytest.New()
	adminPeer(primary, "fennec", 1)
	adminPeer(backup, "stray", 9)
	if err := upsert(t, primary, "dori", "laptop", key()); err != nil {
		t.Fatal(err)
	}
	snap := read(t, primary)
	backup.Tables[pathPeers] = append(backup.Tables[pathPeers], routeros.Row{
		".id": "*50", "interface": "wg-vpn", "name": "fennec-old", "public-key": snap.ByName("fennec").PublicKey, "comment": "stale",
	})
	backup.Tables[pathPeers] = append(backup.Tables[pathPeers], routeros.Row{
		".id": "*51", "interface": "wg-s2s", "name": "icefox", "public-key": key(),
	})

	if err := mirror(context.Background(), backup, settings(), snap); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, r := range backup.Tables[pathPeers] {
		names = append(names, r["name"])
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"dori-laptop", "fennec", "icefox"}) {
		t.Fatalf("backup peers = %v", names)
	}
	for _, r := range backup.Tables["/interface/wireguard/peers"] {
		if r["name"] == "fennec" && r["comment"] != "" {
			t.Fatalf("stale comment not cleared: %q", r["comment"])
		}
	}
	before := len(backup.Ops)
	if err := mirror(context.Background(), backup, settings(), snap); err != nil {
		t.Fatal(err)
	}
	if len(backup.Ops) != before {
		t.Fatalf("second mirror was not a no-op: %v", backup.Ops[before:])
	}
}

// Replacing a device's key keeps its name, so the backup row must be updated in
// place; adding it first collides with the old row's name.
func TestMirrorKeyReplaced(t *testing.T) {
	primary, backup := registrytest.New(), registrytest.New()
	if err := upsert(t, primary, "dori", "fennec", key()); err != nil {
		t.Fatal(err)
	}
	if err := mirror(context.Background(), backup, settings(), read(t, primary)); err != nil {
		t.Fatal(err)
	}
	newKey := key()
	if err := upsert(t, primary, "dori", "fennec", newKey); err != nil {
		t.Fatal(err)
	}
	backup.Ops = nil
	if err := mirror(context.Background(), backup, settings(), read(t, primary)); err != nil {
		t.Fatal(err)
	}
	rows := backup.Tables["/interface/wireguard/peers"]
	if len(rows) != 1 || rows[0]["public-key"] != newKey || !slices.Equal(backup.Ops, []string{"set"}) {
		t.Fatalf("backup = %v, ops = %v", rows, backup.Ops)
	}
}

// A key moving from one peer name to another must not trip over itself either.
func TestMirrorKeySwap(t *testing.T) {
	primary, backup := registrytest.New(), registrytest.New()
	k1, k2 := key(), key()
	for _, d := range []struct{ dev, k string }{{"a", k1}, {"b", k2}} {
		if err := upsert(t, primary, "dori", d.dev, d.k); err != nil {
			t.Fatal(err)
		}
	}
	if err := mirror(context.Background(), backup, settings(), read(t, primary)); err != nil {
		t.Fatal(err)
	}
	// Remove "a" and give its key to a new device "c" on the primary.
	snap := read(t, primary)
	if err := Remove(context.Background(), primary, snap.ByName("dori-a").ID); err != nil {
		t.Fatal(err)
	}
	if err := upsert(t, primary, "dori", "c", k1); err != nil {
		t.Fatal(err)
	}
	if err := mirror(context.Background(), backup, settings(), read(t, primary)); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range backup.Tables["/interface/wireguard/peers"] {
		got = append(got, r["name"]+"="+r["public-key"])
	}
	slices.Sort(got)
	want := []string{"dori-b=" + k2, "dori-c=" + k1}
	if !slices.Equal(got, want) {
		t.Fatalf("backup = %v, want %v", got, want)
	}
}

// mirror is Mirror with all errors folded into one.
func mirror(ctx context.Context, c API, set Settings, primary *Snapshot) error {
	results, err := Mirror(ctx, c, set, primary)
	errs := []error{err}
	for _, e := range results {
		errs = append(errs, e)
	}
	return errors.Join(errs...)
}
