package provision

import (
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"

	"golang.org/x/crypto/nacl/box"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func seal(t *testing.T, cfg any, server, peer wgtypes.Key) []byte {
	t.Helper()
	plain, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var nonce [24]byte
	_, _ = rand.Read(nonce[:])
	pk, sk := [32]byte(peer.PublicKey()), [32]byte(server)
	return box.Seal(nonce[:], plain, &nonce, &pk, &sk)
}

func keys(t *testing.T) (server, peer wgtypes.Key) {
	t.Helper()
	server, _ = wgtypes.GeneratePrivateKey()
	peer, _ = wgtypes.GeneratePrivateKey()
	return
}

func sample(server wgtypes.Key) Config {
	return Config{
		Version:          Version,
		Name:             "laptop",
		Addresses:        []netip.Prefix{netip.MustParsePrefix("10.100.10.4/32")},
		Server:           Server{PublicKey: server.PublicKey().String(), Host: "vpn.foxden.network", Port: 13231},
		InternalPrefixes: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
	}
}

func TestFetch(t *testing.T) {
	server, peer := keys(t)
	blob := seal(t, sample(server), server, peer)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/peers/"+BlobName(peer.PublicKey()) {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(blob)
	}))
	defer srv.Close()

	cfg, err := Fetch(t.Context(), srv.URL+"/peers/", peer, server.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Name != "laptop" || cfg.MTU != 1280 || !cfg.IsInternal(netip.MustParseAddr("10.2.1.1")) {
		t.Fatalf("unexpected config %+v", cfg)
	}

	other, _ := wgtypes.GeneratePrivateKey()
	if _, err := Fetch(t.Context(), srv.URL+"/peers", other, server.PublicKey()); err != ErrNotProvisioned {
		t.Fatalf("want ErrNotProvisioned, got %v", err)
	}
}

func TestOpenRejectsForgery(t *testing.T) {
	server, peer := keys(t)
	forger, _ := wgtypes.GeneratePrivateKey()
	if _, err := Open(seal(t, sample(server), forger, peer), peer, server.PublicKey()); err == nil {
		t.Fatal("blob from the wrong server key was accepted")
	}
	blob := seal(t, sample(server), server, peer)
	blob[len(blob)-1] ^= 1
	if _, err := Open(blob, peer, server.PublicKey()); err == nil {
		t.Fatal("tampered blob was accepted")
	}
}

func TestOpenRejectsFutureVersion(t *testing.T) {
	server, peer := keys(t)
	cfg := sample(server)
	cfg.Version = Version + 1
	if _, err := Open(seal(t, cfg, server, peer), peer, server.PublicKey()); err == nil {
		t.Fatal("unknown version was accepted")
	}
}
