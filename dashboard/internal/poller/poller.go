// Package poller runs every device's driver on an interval and keeps the
// latest state for the web UI.
package poller

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/modules"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// Device is a configured device as the UI sees it.
type Device struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	Module   string     `json:"module"`
	U        int        `json:"u,omitempty"`
	Height   int        `json:"height"`
	Width    float64    `json:"width"`
	Address  string     `json:"address,omitempty"`
	State    rack.State `json:"state"`
	Children []*Device  `json:"children,omitempty"`

	power []config.PowerFeed
}

type Snapshot struct {
	Title   string    `json:"title"`
	Units   int       `json:"units"`
	Devices []*Device `json:"devices"`
	Remote  []Site    `json:"remote,omitempty"`
}

type Site struct {
	Name    string    `json:"name"`
	Devices []*Device `json:"devices"`
}

type entry struct {
	dev    *Device
	driver modules.Driver
}

type Poller struct {
	cfg     *config.Config
	mu      sync.RWMutex
	devices []*Device
	remote  []Site
	entries []entry
}

func New(cfg *config.Config, env *modules.Env) (*Poller, error) {
	p := &Poller{cfg: cfg}
	seen := map[string]bool{}
	occupied := map[int]string{}
	var build func(c *config.Device, top bool) (*Device, error)
	build = func(c *config.Device, top bool) (*Device, error) {
		if c.ID == "" {
			return nil, fmt.Errorf("device without id (module %q)", c.Module)
		}
		if seen[c.ID] {
			return nil, fmt.Errorf("duplicate device id %q", c.ID)
		}
		seen[c.ID] = true
		spec, ok := modules.Lookup(c.Module)
		if !ok {
			return nil, fmt.Errorf("device %s: unknown module %q", c.ID, c.Module)
		}
		drv, err := spec.New(env, c)
		if err != nil {
			return nil, err
		}
		d := &Device{
			ID:      c.ID,
			Name:    c.DisplayName(),
			Module:  c.Module,
			U:       c.U,
			Height:  c.Height,
			Width:   c.Width,
			Address: c.Address,
			State:   drv.Skeleton(),
			power:   c.Power,
		}
		if d.Height == 0 {
			d.Height = spec.Height
		}
		if d.Width == 0 {
			d.Width = 1
		}
		if top {
			if c.U < 1 || c.U+d.Height-1 > cfg.Units {
				return nil, fmt.Errorf("device %s: U%d-%d is outside the %dU rack", c.ID, c.U, c.U+d.Height-1, cfg.Units)
			}
			for u := c.U; u < c.U+d.Height; u++ {
				if other, taken := occupied[u]; taken {
					return nil, fmt.Errorf("device %s: U%d is already taken by %s", c.ID, u, other)
				}
				occupied[u] = c.ID
			}
		}
		p.entries = append(p.entries, entry{dev: d, driver: drv})
		for i := range c.Children {
			child, err := build(&c.Children[i], false)
			if err != nil {
				return nil, err
			}
			d.Children = append(d.Children, child)
		}
		return d, nil
	}
	for i := range cfg.Devices {
		d, err := build(&cfg.Devices[i], true)
		if err != nil {
			return nil, err
		}
		p.devices = append(p.devices, d)
	}
	for _, site := range cfg.Remote {
		s := Site{Name: site.Name}
		for i := range site.Devices {
			d, err := build(&site.Devices[i], false)
			if err != nil {
				return nil, err
			}
			s.Devices = append(s.Devices, d)
		}
		p.remote = append(p.remote, s)
	}
	if err := p.checkPower(); err != nil {
		return nil, err
	}
	return p, nil
}

// Run polls every device until ctx is done.
func (p *Poller) Run(ctx context.Context) {
	var wg sync.WaitGroup
	for _, e := range p.entries {
		wg.Go(func() { p.loop(ctx, e) })
	}
	wg.Wait()
}

func (p *Poller) loop(ctx context.Context, e entry) {
	t := time.NewTicker(p.cfg.Interval.Duration)
	defer t.Stop()
	for {
		p.pollOnce(ctx, e)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (p *Poller) pollOnce(ctx context.Context, e entry) {
	pctx, cancel := context.WithTimeout(ctx, p.cfg.Timeout.Duration)
	defer cancel()
	st, err := e.driver.Poll(pctx)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		log.Printf("%s: %v", e.dev.ID, err)
		st = e.driver.Skeleton()
		st.Status = rack.StatusCrit
		st.Error = err.Error()
	}
	st.Updated = time.Now()
	p.mu.Lock()
	e.dev.State = st
	p.mu.Unlock()
}

// Snapshot returns a deep enough copy of the current state to serialize.
func (p *Poller) Snapshot() Snapshot {
	p.mu.RLock()
	defer p.mu.RUnlock()
	byID := map[string]*Device{}
	var clone func(d *Device) *Device
	clone = func(d *Device) *Device {
		c := *d
		c.State = d.State.Clone()
		byID[c.ID] = &c
		c.Children = nil
		for _, ch := range d.Children {
			c.Children = append(c.Children, clone(ch))
		}
		return &c
	}
	out := Snapshot{Title: p.cfg.Title, Units: p.cfg.Units}
	for _, d := range p.devices {
		out.Devices = append(out.Devices, clone(d))
	}
	for _, site := range p.remote {
		s := Site{Name: site.Name}
		for _, d := range site.Devices {
			s.Devices = append(s.Devices, clone(d))
		}
		out.Remote = append(out.Remote, s)
	}
	applyPower(byID)
	return out
}
