package main

import (
	"context"
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

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           web.Handler(p),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
