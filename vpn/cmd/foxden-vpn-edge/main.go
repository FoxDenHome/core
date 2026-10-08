// foxden-vpn-edge publishes local ports of VPN devices, like ngrok: HTTP(S)
// under random names below its domain (it terminates TLS with a wildcard
// certificate) and raw TCP on random ports from a range the router forwards.
// Devices connect out to its control service with `foxden-vpnd expose`,
// which is only reachable from inside (the VPN or the LAN); see
// internal/expose.
//
// It keeps no state besides the open sessions and only asks the portal who a
// device is, so it needs no secrets but its certificate.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/expose"
	"github.com/quic-go/quic-go"
)

type Config struct {
	// Domain is the edge's own name; tunnels get names directly below it.
	Domain string `json:"domain"`
	// TCPHost is the public name raw TCP tunnels are reached at.
	TCPHost string `json:"tcp_host"`
	Listen  struct {
		HTTP  string `json:"http"`
		HTTPS string `json:"https"`
		// The proxy listeners expect a PROXY v2 header (from foxIngress).
		HTTPProxy  string `json:"http_proxy"`
		HTTPSProxy string `json:"https_proxy"`
		// Control is the control service (QUIC, so UDP). It must not be
		// reachable from the internet: nothing forwards it.
		Control string `json:"control"`
	} `json:"listen"`

	// TrustedProxies (addresses or prefixes) may send PROXY headers; empty
	// trusts everyone.
	TrustedProxies []string `json:"trusted_proxies"`
	Cert           string   `json:"cert"`
	Key            string   `json:"key"`
	PortalURL      string   `json:"portal_url"`
	TCPPorts       struct {
		First int `json:"first"`
		Last  int `json:"last"`
	} `json:"tcp_ports"`
	MaxPerDevice int `json:"max_per_device"`
	// Reserve is how long a closed tunnel's name or port stays with its
	// device, so reconnecting gets it back.
	Reserve string `json:"reserve"`
	// Recheck is how often open tunnels' devices are checked with the portal.
	Recheck string `json:"recheck"`
}

func defaultConfig() Config {
	var c Config
	c.Domain = "tunnel.f0x.es"
	c.Listen.HTTP = ":80"
	c.Listen.HTTPS = ":443"
	c.Listen.HTTPProxy = ":81"
	c.Listen.HTTPSProxy = ":444"
	c.Listen.Control = ":4443"
	c.PortalURL = "https://portal.foxden.network"
	c.TCPPorts.First, c.TCPPorts.Last = 30000, 30199
	c.MaxPerDevice = 10
	c.Reserve = "10m"
	c.Recheck = "5m"
	return c
}

func main() {
	configPath := flag.String("config", "/etc/foxden-vpn-edge/config.json", "config file")
	flag.Parse()

	cfg := defaultConfig()
	b, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		log.Fatalf("%s: %v", *configPath, err)
	}
	cfg.Domain = strings.ToLower(cfg.Domain)
	if cfg.TCPHost == "" {
		cfg.TCPHost = cfg.Domain
	}
	if cfg.TCPPorts.First <= 0 || cfg.TCPPorts.Last < cfg.TCPPorts.First || cfg.TCPPorts.Last > 65535 {
		log.Fatal("tcp_ports: invalid range")
	}

	proxies, err := parsePrefixes(cfg.TrustedProxies)
	if err != nil {
		log.Fatalf("trusted_proxies: %v", err)
	}

	certs := &certFile{cert: cfg.Cert, key: cfg.Key}
	if _, err := certs.get(nil); err != nil {
		log.Printf("no certificate yet, TLS fails until there is one: %v", err)
	}
	e, err := newEdge(cfg, &portalVerifier{url: strings.TrimSuffix(cfg.PortalURL, "/"), client: &http.Client{Timeout: 20 * time.Second}}, certs.get)
	if err != nil {
		log.Fatal(err)
	}
	e.proxies = proxies

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	serve := func(addr string, handle func(net.Conn, bool), proxied bool) {
		if addr == "" {
			return
		}
		l, err := net.Listen("tcp", addr)
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("listening on %s (proxied: %v)", addr, proxied)
		go func() {
			<-ctx.Done()
			_ = l.Close()
		}()
		go func() {
			for {
				c, err := l.Accept()
				if err != nil {
					if !errors.Is(err, net.ErrClosed) {
						log.Printf("accept %s: %v", addr, err)
					}
					return
				}
				go handle(c, proxied)
			}
		}()
	}
	serve(cfg.Listen.HTTP, e.servePlain, false)
	serve(cfg.Listen.HTTPProxy, e.servePlain, true)
	serve(cfg.Listen.HTTPS, e.serveTLS, false)
	serve(cfg.Listen.HTTPSProxy, e.serveTLS, true)
	if cfg.Listen.Control != "" {
		ql, err := quic.ListenAddr(cfg.Listen.Control, e.control, expose.QUICConfig(true))
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("listening on %s (QUIC)", cfg.Listen.Control)
		go func() {
			<-ctx.Done()
			_ = ql.Close()
		}()
		go e.serveQUIC(ctx, ql)
	}
	<-ctx.Done()
}

func parsePrefixes(in []string) ([]netip.Prefix, error) {
	out := make([]netip.Prefix, 0, len(in))
	for _, s := range in {
		if a, err := netip.ParseAddr(s); err == nil {
			out = append(out, netip.PrefixFrom(a, a.BitLen()))
			continue
		}
		p, err := netip.ParsePrefix(s)
		if err != nil {
			return nil, err
		}
		out = append(out, p.Masked())
	}
	return out, nil
}

// portalVerifier asks the portal's /api/expose/check.
type portalVerifier struct {
	url    string
	client *http.Client
}

func (p *portalVerifier) check(ctx context.Context, body map[string]string) (int, []byte, error) {
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.url+"/api/expose/check", bytes.NewReader(b))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("contacting the portal: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode, data, err
}

func (p *portalVerifier) Ticket(ctx context.Context, ticket string) (identity, error) {
	code, data, err := p.check(ctx, map[string]string{"ticket": ticket})
	if err != nil {
		return identity{}, err
	}
	if code != http.StatusOK {
		var e struct{ Error string }
		if json.Unmarshal(data, &e) == nil && e.Error != "" {
			return identity{}, errors.New(e.Error)
		}
		return identity{}, fmt.Errorf("portal: HTTP %d", code)
	}
	var id identity
	if err := json.Unmarshal(data, &id); err != nil {
		return identity{}, err
	}
	if id.PublicKey == "" || id.Owner == "" {
		return identity{}, errors.New("portal returned no device")
	}
	return id, nil
}

func (p *portalVerifier) Active(ctx context.Context, publicKey string) (bool, error) {
	code, _, err := p.check(ctx, map[string]string{"public_key": publicKey})
	switch {
	case err != nil:
		return false, err
	case code == http.StatusOK:
		return true, nil
	case code == http.StatusForbidden:
		return false, nil
	default:
		return false, fmt.Errorf("portal: HTTP %d", code)
	}
}
