package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func testExpose() *provision.Expose {
	return &provision.Expose{
		Addresses:  []netip.Addr{netip.MustParseAddr("10.2.11.43"), netip.MustParseAddr("fd2c:f4cb:63be:2::b2b")},
		Port:       4443,
		ServerName: "tunnel.example",
	}
}

// exposePortal does the expose half of the portal: the challenge, and a
// ticket for the right answer.
func exposePortal(t *testing.T, server wgtypes.Key) *httptest.Server {
	secrets := map[string][]byte{}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/device/challenge", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			PublicKey string `json:"public_key"`
			Purpose   string `json:"purpose"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		pub, err := wgtypes.ParseKey(req.PublicKey)
		if err != nil || req.Purpose != "expose" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		sealed, secret, err := provision.NewChallenge(server, pub)
		if err != nil {
			t.Error(err)
		}
		secrets["tok"] = secret
		_ = json.NewEncoder(w).Encode(map[string]string{"token": "tok", "challenge": base64.RawURLEncoding.EncodeToString(sealed)})
	})
	mux.HandleFunc("POST /api/expose/ticket", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Token, Answer string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		answer, _ := base64.StdEncoding.DecodeString(req.Answer)
		want, ok := secrets[req.Token]
		if !ok || sha256.Sum256(answer) != sha256.Sum256(want) {
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "wrong challenge answer"})
			return
		}
		_ = json.NewEncoder(w).Encode(api.ExposeTicket{Ticket: "ticket", Expires: time.Now().Add(time.Minute)})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestExposeTicket(t *testing.T) {
	server, _ := wgtypes.GeneratePrivateKey()
	portal := exposePortal(t, server)
	d, err := New(Options{
		StateDir: t.TempDir(), PortalURL: portal.URL, ServerKey: server.PublicKey(),
		Tunnel: tunnel.Options{Name: "fvpntest0"}, IdleTimeout: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	refused := func(want string) {
		t.Helper()
		if _, err := d.ExposeTicket(ctx); err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("got %v, want an error about %q", err, want)
		}
	}

	refused("not registered")
	d.prov = testProv(t)
	refused("not offered")
	d.prov.Expose = testExpose()
	d.state = api.TunnelDown
	refused("tunnel is down")

	d.state = api.TunnelIdle // on demand: the first packet brings it up
	got, err := d.ExposeTicket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got.Ticket != "ticket" || got.ServerName != "tunnel.example" ||
		!slices.Equal(got.Edges, []string{"10.2.11.43:4443", "[fd2c:f4cb:63be:2::b2b]:4443"}) {
		t.Fatalf("ticket = %+v", got)
	}
}
