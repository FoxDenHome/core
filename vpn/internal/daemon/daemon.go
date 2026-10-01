// Package daemon is the privileged half of FoxDen VPN. It owns the device key,
// fetches the peer's provisioning, decides between LAN (direct) and WAN
// (tunnel), keeps the endpoint fresh and exposes all of it to the tray.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/netip"
	"os"
	"reflect"
	"slices"
	"sync"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
	"github.com/FoxDenHome/core/vpn/internal/provision"
	"github.com/FoxDenHome/core/vpn/internal/tunnel"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

const (
	tickInterval       = 2 * time.Second
	locationInterval   = 30 * time.Second
	resolveInterval    = 60 * time.Second
	provisionInterval  = time.Hour
	unprovisionedRetry = 30 * time.Second
	refreshWait        = 30 * time.Second
	provisionErrRetry  = 5 * time.Minute
	// A session is live while its last handshake is younger than WireGuard's
	// REJECT_AFTER_TIME.
	handshakeFresh = 180 * time.Second
	// Sending without a handshake for this long means the endpoint is dead.
	stuckAfter    = 20 * time.Second
	fullKeepalive = 25 * time.Second
)

type Options struct {
	StateDir     string
	ProvisionURL string
	ServerKey    wgtypes.Key
	Tunnel       tunnel.Options
	// IdleTimeout is how long a split tunnel may sit without traffic before
	// its session is torn down; traffic brings it back on demand.
	IdleTimeout time.Duration
}

type Daemon struct {
	opts Options
	key  wgtypes.Key
	tun  *tunnel.Tunnel
	wake chan struct{}

	mu         sync.Mutex
	settings   Settings
	prov       *provision.Config
	provErr    error
	forceFetch bool
	lastFetch  time.Time
	// refreshWaiters are closed when the forced fetch they asked for is done.
	refreshWaiters []chan struct{}
	nextFetch      time.Time

	location     string
	fp           string
	nextLocation time.Time

	candidates  []netip.AddrPort
	candIdx     int
	nextResolve time.Time

	lastCfg      *tunnel.Config
	lastErr      error
	stats        tunnel.Stats
	lastActivity time.Time
	stuckSince   time.Time
	sessionReset bool
	state        string
}

func New(opts Options) (*Daemon, error) {
	if err := os.MkdirAll(opts.StateDir, 0o700); err != nil {
		return nil, err
	}
	key, created, err := loadOrCreateKey(opts.StateDir)
	if err != nil {
		return nil, fmt.Errorf("loading private key: %w", err)
	}
	if created {
		log.Printf("generated new device key")
	}
	log.Printf("build %s, public key: %s", buildid.Self(), key.PublicKey())

	return &Daemon{
		opts:     opts,
		key:      key,
		tun:      tunnel.New(opts.Tunnel),
		wake:     make(chan struct{}, 1),
		settings: loadSettings(opts.StateDir),
		prov:     loadProvision(opts.StateDir),
		location: api.LocationUnknown,
		state:    api.TunnelDown,
	}, nil
}

func (d *Daemon) PublicKey() wgtypes.Key { return d.key.PublicKey() }

func (d *Daemon) poke() {
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *Daemon) Run(ctx context.Context) error {
	tunnel.CleanupStale(d.opts.Tunnel)
	defer func() {
		if err := d.tun.Close(); err != nil {
			log.Printf("tearing down tunnel: %v", err)
		}
	}()

	t := time.NewTicker(tickInterval)
	defer t.Stop()
	for {
		d.tick(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		case <-d.wake:
		}
	}
}

func (d *Daemon) tick(ctx context.Context) {
	now := time.Now()

	d.mu.Lock()
	settings := d.settings
	force := d.forceFetch
	d.forceFetch = false
	waiters := d.refreshWaiters
	d.refreshWaiters = nil
	prov := d.prov
	d.mu.Unlock()
	defer func() {
		for _, w := range waiters {
			close(w)
		}
	}()

	// Provisioning. Slow network calls run without the lock held; only this
	// goroutine writes these fields.
	provChanged := false
	if force || now.After(d.nextFetch) {
		cfg, err := provision.Fetch(ctx, d.opts.ProvisionURL, d.key, d.opts.ServerKey)
		switch {
		case err == nil:
			if !reflect.DeepEqual(cfg, prov) {
				log.Printf("provisioned as %q with %v", cfg.Name, cfg.Addresses)
				provChanged = true
				if err := saveProvision(d.opts.StateDir, cfg); err != nil {
					log.Print(err)
				}
			}
			prov = cfg
			d.nextFetch = now.Add(provisionInterval)
		case errors.Is(err, provision.ErrNotProvisioned):
			if prov != nil {
				log.Printf("peer was removed from the server")
				provChanged = true
				_ = saveProvision(d.opts.StateDir, nil)
			} else if !errors.Is(d.provErr, provision.ErrNotProvisioned) {
				log.Printf("not registered yet, checking every %s", unprovisionedRetry)
			}
			prov = nil
			d.nextFetch = now.Add(unprovisionedRetry)
		default:
			log.Printf("fetching provisioning: %v", err)
			if prov == nil {
				d.nextFetch = now.Add(unprovisionedRetry)
			} else {
				d.nextFetch = now.Add(provisionErrRetry)
			}
		}
		d.mu.Lock()
		d.prov, d.provErr = prov, err
		d.lastFetch = time.Now()
		d.mu.Unlock()
	}

	// Network attachment and location.
	addrs := physicalAddrs(d.tun.Name())
	fp := fingerprint(addrs)
	netChanged := fp != d.fp
	location := d.location
	if netChanged || provChanged || force || now.After(d.nextLocation) {
		location = detectLocation(ctx, prov, addrs)
		d.nextLocation = now.Add(locationInterval)
		if location != d.location {
			log.Printf("location: %s", location)
		}
	}
	if netChanged {
		d.fp = fp
		d.nextResolve = time.Time{}
		if prov == nil {
			d.nextFetch = time.Time{}
		}
	}

	want := settings.Enabled && prov != nil &&
		(location == api.LocationWAN || (location == api.LocationOffline && d.tun.Up()))

	var applyErr error
	if want {
		if force || now.After(d.nextResolve) {
			c := resolveEndpoint(ctx, prov, addrs)
			if len(c) > 0 {
				if !slices.Equal(c, d.candidates) {
					log.Printf("endpoint candidates: %v", c)
					d.candidates, d.candIdx = c, 0
				}
				d.nextResolve = now.Add(resolveInterval)
			} else {
				// Keep the last known endpoint, but retry soon.
				d.nextResolve = now.Add(10 * time.Second)
			}
		}
		cfg, err := d.buildConfig(settings, prov)
		if err == nil && (netChanged || d.lastCfg == nil || !d.tun.Up() || !reflect.DeepEqual(*d.lastCfg, cfg)) {
			err = d.tun.Apply(cfg, netChanged)
			if err == nil {
				d.lastCfg = &cfg
			} else {
				d.lastCfg = nil
			}
		}
		applyErr = err
		if err != nil && (d.lastErr == nil || d.lastErr.Error() != err.Error()) {
			log.Printf("applying tunnel: %v", err) // once per distinct error, not every tick
		}
	} else if d.tun.Up() {
		if err := d.tun.Down(); err != nil {
			log.Printf("tunnel down: %v", err)
		}
		d.lastCfg = nil
	}

	state := d.updateActivity(now, settings, want)

	d.mu.Lock()
	d.location = location
	d.lastErr = applyErr
	d.state = state
	d.mu.Unlock()
}

// updateActivity tracks traffic to detect stuck endpoints, enforce the split
// tunnel idle timeout and derive the state shown to the user.
func (d *Daemon) updateActivity(now time.Time, settings Settings, want bool) string {
	if !want || !d.tun.Up() {
		d.stats = tunnel.Stats{}
		d.stuckSince = time.Time{}
		d.lastActivity = time.Time{} // a new tunnel starts without a session to expire
		d.sessionReset = false
		return api.TunnelDown
	}
	st, err := d.tun.Stats()
	if err != nil {
		return api.TunnelConnecting
	}
	prev := d.stats
	d.stats = st

	txGrew := st.TxBytes > prev.TxBytes
	if st.RxBytes > prev.RxBytes || txGrew {
		d.lastActivity = now
		d.sessionReset = false
	}
	fresh := !st.LastHandshake.IsZero() && now.Sub(st.LastHandshake) < handshakeFresh

	switch {
	case fresh:
		d.stuckSince = time.Time{}
	case txGrew && d.stuckSince.IsZero():
		d.stuckSince = now
	case !txGrew && now.Sub(d.lastActivity) > stuckAfter:
		d.stuckSince = time.Time{}
	}
	if !d.stuckSince.IsZero() && now.Sub(d.stuckSince) > stuckAfter {
		if len(d.candidates) > 1 {
			d.candIdx = (d.candIdx + 1) % len(d.candidates)
			log.Printf("no handshake for %s, trying endpoint %s", stuckAfter, d.candidates[d.candIdx])
		} else {
			log.Printf("no handshake for %s, re-resolving endpoint", stuckAfter)
		}
		d.nextResolve = time.Time{}
		d.stuckSince = now
		d.poke()
	}

	full := settings.Mode == api.ModeFull
	if !full && !d.sessionReset && !d.lastActivity.IsZero() && now.Sub(d.lastActivity) > d.opts.IdleTimeout {
		log.Printf("idle for %s, dropping session until traffic needs it", d.opts.IdleTimeout)
		if err := d.tun.ResetSession(); err != nil {
			log.Printf("resetting session: %v", err)
		}
		d.sessionReset = true
		d.stats = tunnel.Stats{Endpoint: st.Endpoint}
		return api.TunnelIdle
	}

	switch {
	case !d.stuckSince.IsZero():
		return api.TunnelConnecting
	case fresh && !d.sessionReset:
		return api.TunnelConnected
	case full:
		return api.TunnelConnecting
	default:
		return api.TunnelIdle
	}
}

func (d *Daemon) buildConfig(s Settings, prov *provision.Config) (tunnel.Config, error) {
	peer, err := wgtypes.ParseKey(prov.Server.PublicKey)
	if err != nil {
		return tunnel.Config{}, err
	}
	cfg := tunnel.Config{
		PrivateKey: d.key,
		PeerKey:    peer,
		MTU:        prov.MTU,
		Addresses:  prov.Addresses,
		FullTunnel: s.Mode == api.ModeFull,
		DNSServers: prov.DNS.Servers,
		DNSDomains: prov.DNS.Domains,
	}
	if prov.Server.PresharedKey != "" {
		psk, err := wgtypes.ParseKey(prov.Server.PresharedKey)
		if err != nil {
			return tunnel.Config{}, fmt.Errorf("preshared key: %w", err)
		}
		cfg.PresharedKey = &psk
	}
	if len(d.candidates) > 0 {
		cfg.Endpoint = d.candidates[d.candIdx%len(d.candidates)]
	} else if d.lastCfg != nil {
		cfg.Endpoint = d.lastCfg.Endpoint
	}

	if cfg.FullTunnel {
		cfg.Routes = tunnel.FullTunnelRoutes
		cfg.Keepalive = fullKeepalive
	} else {
		routes := slices.Clone(prov.VPNPrefixes)
		for _, n := range prov.Networks {
			if !slices.Contains(s.DisabledNetworks, n.Name) {
				routes = append(routes, n.Prefixes...)
			}
		}
		// Never route the endpoint into its own tunnel.
		ep := cfg.Endpoint.Addr().Unmap()
		routes = slices.DeleteFunc(routes, func(p netip.Prefix) bool {
			if cfg.Endpoint.IsValid() && p.Contains(ep) {
				log.Printf("not routing %s: it contains the endpoint", p)
				return true
			}
			return false
		})
		slices.SortFunc(routes, func(a, b netip.Prefix) int { return a.Addr().Compare(b.Addr()) })
		cfg.Routes = slices.Compact(routes)
	}
	return cfg, nil
}

func (d *Daemon) Status() api.Status {
	d.mu.Lock()
	defer d.mu.Unlock()

	st := api.Status{
		Build:     buildid.Self(),
		PublicKey: d.key.PublicKey().String(),
		Enabled:   d.settings.Enabled,
		Mode:      d.settings.Mode,
		Location:  d.location,
		Tunnel:    d.state,
		Networks:  []api.Network{},
	}
	if d.provErr != nil {
		st.ProvisionError = d.provErr.Error()
	}
	st.LastCheck = d.lastFetch
	if d.lastErr != nil {
		st.Error = d.lastErr.Error()
	}
	if p := d.prov; p != nil {
		st.Provisioned = true
		st.PeerName = p.Name
		for _, a := range p.Addresses {
			st.Addresses = append(st.Addresses, a.Addr().String())
		}
		for _, n := range p.Networks {
			an := api.Network{Name: n.Name, Enabled: !slices.Contains(d.settings.DisabledNetworks, n.Name)}
			for _, pfx := range n.Prefixes {
				an.Prefixes = append(an.Prefixes, pfx.String())
			}
			st.Networks = append(st.Networks, an)
		}
	}
	if d.state != api.TunnelDown {
		st.Interface = d.tun.Name()
		st.Backend = d.tun.Backend()
		st.Endpoint = d.stats.Endpoint
		st.LastHandshake = d.stats.LastHandshake
		st.RxBytes = d.stats.RxBytes
		st.TxBytes = d.stats.TxBytes
	}
	return st
}

func (d *Daemon) Update(u api.SettingsUpdate) (api.Status, error) {
	d.mu.Lock()
	s := d.settings
	s.DisabledNetworks = slices.Clone(s.DisabledNetworks)
	if u.Enabled != nil {
		s.Enabled = *u.Enabled
	}
	if u.Mode != nil {
		if *u.Mode != api.ModeSplit && *u.Mode != api.ModeFull {
			d.mu.Unlock()
			return api.Status{}, fmt.Errorf("invalid mode %q", *u.Mode)
		}
		s.Mode = *u.Mode
	}
	for name, enabled := range u.Network {
		s.DisabledNetworks = slices.DeleteFunc(s.DisabledNetworks, func(n string) bool { return n == name })
		if !enabled {
			s.DisabledNetworks = append(s.DisabledNetworks, name)
		}
	}
	slices.Sort(s.DisabledNetworks)
	err := saveSettings(d.opts.StateDir, s)
	if err == nil {
		d.settings = s
	}
	d.mu.Unlock()
	if err != nil {
		return api.Status{}, err
	}
	d.poke()
	return d.Status(), nil
}

// Refresh fetches provisioning now and returns once that fetch is done (or
// after refreshWait), so the caller sees its outcome.
func (d *Daemon) Refresh(ctx context.Context) api.Status {
	done := make(chan struct{})
	d.mu.Lock()
	d.forceFetch = true
	d.refreshWaiters = append(d.refreshWaiters, done)
	d.mu.Unlock()
	d.poke()
	select {
	case <-done:
	case <-time.After(refreshWait):
	case <-ctx.Done():
	}
	return d.Status()
}
