package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/expose"
)

const exposeUsage = `usage: foxden-vpnd expose [flags] http|tcp [host:]port

Publishes a local port until interrupted:
  http   at https://<random>.tunnel.f0x.es (TLS ends at the edge; the port
         gets plain HTTP, or whatever the client speaks inside TLS)
  tcp    at tcp://tunnel.f0x.es:<random port>, as is

The port is on localhost unless a host is given. The edge is only reached
through the VPN tunnel, so it has to be up. Flags:
`

// runExpose is `foxden-vpnd expose`. It runs as the user: the daemon only
// vouches for the device, and connections to the local port come from here.
func runExpose(socket string, args []string) {
	fs := flag.NewFlagSet("expose", flag.ExitOnError)
	name := fs.String("name", "", "ask for this name instead of a random one (http)")
	port := fs.Int("port", 0, "ask for this public port instead of a random one (tcp)")
	edge := fs.String("edge", "", "control service to connect to (host:port), instead of the provisioned one")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), exposeUsage)
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)
	if fs.NArg() != 2 {
		fs.Usage()
		os.Exit(2)
	}
	kind, target := fs.Arg(0), fs.Arg(1)
	if kind != expose.KindHTTP && kind != expose.KindTCP {
		fs.Usage()
		os.Exit(2)
	}
	if _, err := strconv.Atoi(target); err == nil {
		target = net.JoinHostPort("localhost", target)
	}
	if _, _, err := net.SplitHostPort(target); err != nil {
		log.Fatalf("target: %v", err)
	}
	log.SetFlags(log.Ltime)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	client := api.NewClient(socket)
	c := &expose.Client{
		Target: target,
		Hello:  expose.Hello{Kind: kind, Name: *name, Port: *port},
		Ticket: func(context.Context) (expose.Ticket, error) {
			t, err := client.ExposeTicket()
			if err != nil {
				return expose.Ticket{}, fmt.Errorf("foxden-vpnd: %w", err)
			}
			return expose.Ticket{Ticket: t.Ticket, Edges: t.Edges, ServerName: t.ServerName}, nil
		},
		OnURL: func(url string) { fmt.Printf("Forwarding %s -> %s\n", url, target) },
	}
	if *edge != "" {
		c.Edges = []string{*edge}
	}
	if err := c.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
