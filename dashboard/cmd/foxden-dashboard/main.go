package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/modules"
	"github.com/FoxDenHome/core/dashboard/internal/poller"
	"github.com/FoxDenHome/core/dashboard/internal/tlscert"
	"github.com/FoxDenHome/core/dashboard/internal/web"
)

func main() {
	configPath := flag.String("config", envOr("CONFIG_FILE", "config.json"), "path to the rack config")
	listModules := flag.Bool("modules", false, "list available modules and exit")
	check := flag.Bool("check", false, "validate the config and exit")
	flag.Parse()

	if *listModules {
		for _, m := range modules.All() {
			fmt.Printf("%-30s %dU  %s\n", m.Name, m.Height, m.Description)
		}
		return
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	env := &modules.Env{
		SNMPCommunity: cfg.SNMP.Community,
		HTTP:          &http.Client{Timeout: cfg.Timeout.Duration},
	}
	p, err := poller.New(cfg, env)
	if err != nil {
		log.Fatal(err)
	}
	if *check {
		fmt.Println("config ok")
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go p.Run(ctx)

	handler := web.Handler(p)
	servers := []*http.Server{{Addr: cfg.Listen, Handler: handler}}
	if t := cfg.TLS; t != nil && t.DNSKey == "" {
		log.Printf("tls: no dns_key, not serving HTTPS for %s", t.Domain)
	} else if t != nil {
		certs, err := tlscert.New(tlscert.Options{
			Domain:    t.Domain,
			Email:     t.Email,
			Directory: t.Directory,
			CacheDir:  t.CacheDir,
			DNSKey:    t.DNSKey,
			HTTP:      &http.Client{Timeout: time.Minute},
		})
		if err != nil {
			log.Fatal(err)
		}
		go certs.Run(ctx)
		servers = append(servers, &http.Server{
			Addr:      t.Listen,
			Handler:   handler,
			TLSConfig: &tls.Config{GetCertificate: certs.GetCertificate},
		})
		if t.HTTPListen != "" {
			servers = append(servers, &http.Server{Addr: t.HTTPListen, Handler: redirectHTTPS(t.Domain)})
		}
	}

	errs := make(chan error, len(servers))
	for _, srv := range servers {
		srv.ReadHeaderTimeout = 10 * time.Second
		go func() {
			log.Printf("listening on %s", srv.Addr)
			var err error
			if srv.TLSConfig != nil {
				err = srv.ListenAndServeTLS("", "")
			} else {
				err = srv.ListenAndServe()
			}
			if err != http.ErrServerClosed {
				errs <- err
			}
		}()
	}
	select {
	case err := <-errs:
		log.Fatal(err)
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, srv := range servers {
		_ = srv.Shutdown(shutdown)
	}
}

// redirectHTTPS sends plain HTTP requests to the same path over HTTPS.
func redirectHTTPS(domain string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://"+domain+r.URL.RequestURI(), http.StatusMovedPermanently)
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
