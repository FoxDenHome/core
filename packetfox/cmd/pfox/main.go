// pfox is PacketFox: it captures packets on the routers, UniFi APs and
// NixOS hosts at once, follows each packet through the network, and shows
// the result in a Wireshark-like web UI.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/session"
	"github.com/FoxDenHome/core/packetfox/internal/sources"
	"github.com/FoxDenHome/core/packetfox/internal/web"
)

func main() {
	cfgPath := flag.String("config", "/etc/packetfox/config.json", "config file")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		log.Fatal(err)
	}

	agentAuth := sources.SSHAuth{User: "pfox"}
	if cfg.SSHKeyFile != "" {
		if agentAuth.Signer, err = sources.LoadSigner(cfg.SSHKeyFile); err != nil {
			log.Printf("SSH key: %v (host captures will fail)", err)
		}
	}
	apAuth := sources.SSHAuth{User: cfg.UniFiSSHUser, Password: cfg.UniFiSSHPassword}

	inv := session.NewInventory(cfg, agentAuth, apAuth)
	mgr := session.NewManager(cfg, inv)

	// A previous run may have died with mirror rules installed
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	mgr.CleanupRouters(ctx)
	cancel()

	srv := &http.Server{Addr: cfg.Listen, Handler: web.Handler(cfg, mgr), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Print("shutting down")
		mgr.Stop() // removes the routers' mirror rules
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
	log.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
