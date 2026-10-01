// foxden-vpn-portal lets users register and manage their own VPN devices.
//
// It is management only: the routers' wg-vpn peer table is the database and
// the CDN serves provisioning, so neither this portal nor Kanidm being down
// affects existing devices. Only changes need them.
package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/fastly"
	"github.com/FoxDenHome/core/vpn/internal/registry"
	"github.com/FoxDenHome/core/vpn/internal/routeros"
)

type Config struct {
	Listen    string `json:"listen"`
	PublicURL string `json:"public_url"`
	OIDC      struct {
		Issuer   string `json:"issuer"`
		ClientID string `json:"client_id"`
	} `json:"oidc"`
	// Routers[0] is the source of truth; the rest mirror it.
	Routers []routeros.Router `json:"routers"`
	Fastly  struct {
		ServiceID  string `json:"service_id"`
		Dictionary string `json:"dictionary"`
		KeyPrefix  string `json:"key_prefix"`
	} `json:"fastly"`
	VPN               registry.Settings `json:"vpn"`
	ReconcileInterval string            `json:"reconcile_interval"`
}

func defaultConfig() Config {
	var c Config
	c.Listen = "127.0.0.1:1446"
	c.Fastly.Dictionary = "vpn_peers"
	c.Fastly.KeyPrefix = "/vpn/peers/"
	c.ReconcileInterval = "5m"
	c.VPN = registry.Settings{
		Interface:        "wg-vpn",
		Pool:             netip.MustParsePrefix("10.100.10.0/24"),
		IPv6Base:         netip.MustParseAddr("fd2c:f4cb:63be::"),
		Host:             "vpn.foxden.network",
		DNSDomains:       []string{"foxden.network", "10.in-addr.arpa", "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa"},
		InternalPrefixes: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("fd2c:f4cb:63be::/48")},
		Networks:         []string{"mgmt", "lan", "dmz", "labnet", "security", "hypervisor", "retro"},
	}
	return c
}

func main() {
	configPath := flag.String("config", "/etc/foxden-vpn-portal/config.json", "config file")
	flag.Parse()

	cfg := defaultConfig()
	b, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		log.Fatalf("%s: %v", *configPath, err)
	}
	if len(cfg.Routers) == 0 {
		log.Fatal("no routers configured")
	}
	// Secrets come from the environment (a sops EnvironmentFile).
	password := os.Getenv("ROUTEROS_PASSWORD")
	for i := range cfg.Routers {
		cfg.Routers[i].Password = password
	}
	interval, err := time.ParseDuration(cfg.ReconcileInterval)
	if err != nil {
		log.Fatalf("reconcile_interval: %v", err)
	}

	sessionKey := []byte(os.Getenv("SESSION_SECRET"))
	if len(sessionKey) == 0 {
		// Sessions then just don't survive restarts.
		sessionKey = make([]byte, 32)
		_, _ = rand.Read(sessionKey)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	p := &portal{
		cfg:     cfg,
		dial:    dialRouter,
		cookies: &signer{key: sessionKey, secure: strings.HasPrefix(cfg.PublicURL, "https://")},
	}
	if token := os.Getenv("FASTLY_API_TOKEN"); token != "" {
		p.dict = &fastly.Dictionary{Token: token, ServiceID: cfg.Fastly.ServiceID, Name: cfg.Fastly.Dictionary}
	} else {
		log.Print("FASTLY_API_TOKEN not set: provisioning will not be published")
	}
	if err := p.setupOIDC(ctx); err != nil {
		// Kanidm being down must not stop the reconcile loop.
		log.Printf("OIDC setup failed, will retry on login: %v", err)
	}

	go p.reconcileLoop(ctx, interval)

	srv := &http.Server{Addr: cfg.Listen, Handler: p.routes(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	log.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
