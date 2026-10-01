package daemon

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func TestRefreshWaitsForFetch(t *testing.T) {
	server, _ := wgtypes.GeneratePrivateKey()
	var blob atomic.Value // []byte; empty means 404
	blob.Store([]byte(nil))
	var fetches atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetches.Add(1)
		time.Sleep(200 * time.Millisecond) // a slow CDN must not make Refresh return early
		b := blob.Load().([]byte)
		if len(b) == 0 {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(b)
	}))
	defer srv.Close()

	d, err := New(Options{
		StateDir:     t.TempDir(),
		ProvisionURL: srv.URL,
		ServerKey:    server.PublicKey(),
		Tunnel:       tunnel.Options{Name: "fvpntest0"},
		IdleTimeout:  time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	d.settings.Enabled = false // keep the tunnel out of this test
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = d.Run(ctx) }()

	st := d.Refresh(ctx)
	if st.Provisioned || !strings.Contains(st.ProvisionError, "not registered") || st.LastCheck.IsZero() {
		t.Fatalf("before registration: %+v", st)
	}

	cfg := testProv(t)
	cfg.Server.PublicKey = server.PublicKey().String()
	sealed, err := provision.Seal(cfg, server, d.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	blob.Store(sealed)

	before := fetches.Load()
	st = d.Refresh(ctx)
	if !st.Provisioned || st.ProvisionError != "" {
		t.Fatalf("after registration: %+v", st)
	}
	if fetches.Load() == before {
		t.Fatal("Refresh returned without fetching")
	}
}
