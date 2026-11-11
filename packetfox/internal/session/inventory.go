package session

import (
	"context"
	"fmt"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/packetfox/internal/config"
	"github.com/FoxDenHome/core/packetfox/internal/model"
	"github.com/FoxDenHome/core/packetfox/internal/sources"
)

// Device is a capture-capable device and the points it offers.
type Device struct {
	Name   string        `json:"name"`
	Kind   model.Kind    `json:"kind"`
	Points []model.Point `json:"points"`
	// Points are discovered over SSH; this is when, and what went wrong.
	Discovered time.Time `json:"discovered,omitzero"`
	Error      string    `json:"error,omitempty"`
}

// Inventory knows the devices pfox can capture on and the hosts it can
// filter for.
type Inventory struct {
	cfg     *config.Config
	agent   sources.SSHAuth
	ap      sources.SSHAuth
	mu      sync.Mutex
	devices map[string]*Device
	// Discovered points by ID, for their labels and kinds
	known map[string]model.Point
}

func NewInventory(cfg *config.Config, agent, ap sources.SSHAuth) *Inventory {
	inv := &Inventory{cfg: cfg, agent: agent, ap: ap, devices: map[string]*Device{}, known: map[string]model.Point{}}
	for _, r := range cfg.Routers {
		d := &Device{Name: r.Name, Kind: model.KindRouter}
		for _, chain := range sources.Chains {
			d.Points = append(d.Points, inv.routerPoint(r, chain))
		}
		inv.devices[r.Name] = d
	}
	for _, a := range cfg.Agents {
		inv.devices[a.Name] = &Device{Name: a.Name, Kind: model.KindAgent}
	}
	for _, a := range cfg.APs {
		inv.devices[a.Name] = &Device{Name: a.Name, Kind: model.KindAP}
	}
	return inv
}

func parseAddrs(list []string) []netip.Addr {
	var out []netip.Addr
	for _, a := range list {
		if p, err := netip.ParsePrefix(a); err == nil {
			out = append(out, p.Addr())
		} else if ip, err := netip.ParseAddr(a); err == nil {
			out = append(out, ip)
		}
	}
	return out
}

func (inv *Inventory) routerPoint(r config.Router, chain string) model.Point {
	dir := "in"
	if chain == "postrouting" {
		dir = "out"
	}
	return model.Point{
		ID: model.RouterPointID(r.Name, chain), Device: r.Name, Kind: model.KindRouter, Chain: chain,
		Label: r.Name + " › " + dir, Clock: "collector", Local: parseAddrs(r.Addresses),
	}
}

// owns returns the addresses that live behind an agent's netns.
func (inv *Inventory) owns(system, netns string) []netip.Addr {
	var out []netip.Addr
	for _, e := range inv.cfg.Endpoints {
		if e.System != system {
			continue
		}
		if (netns == "" && e.Netns == "") || (netns != "" && e.Netns == netns) {
			out = append(out, e.Addrs()...)
		}
	}
	return out
}

func (inv *Inventory) ifacePoint(kind model.Kind, device, netns, nsLabel, iface, ifKind string) model.Point {
	if nsLabel == "" {
		nsLabel = netns
	}
	label := device + " › "
	if netns != "" {
		label += strings.TrimPrefix(nsLabel, "host-") + " › "
	}
	label += iface
	p := model.Point{
		ID: model.IfacePointID(device, netns, iface), Device: device, Kind: kind,
		Netns: netns, Iface: iface, Label: label, Clock: device, NetnsLabel: nsLabel, IfKind: ifKind,
	}
	if kind == model.KindAgent {
		p.Owns = inv.owns(device, netns)
	}
	return p
}

func (inv *Inventory) sshDevice(name string) (config.SSHDevice, model.Kind, sources.SSHAuth, bool) {
	for _, a := range inv.cfg.Agents {
		if a.Name == name {
			return a, model.KindAgent, inv.agent, true
		}
	}
	for _, a := range inv.cfg.APs {
		if a.Name == name {
			return a, model.KindAP, inv.ap, true
		}
	}
	return config.SSHDevice{}, "", sources.SSHAuth{}, false
}

// Discover asks an agent or AP for its interfaces.
func (inv *Inventory) Discover(ctx context.Context, name string) (*Device, error) {
	dev, kind, auth, ok := inv.sshDevice(name)
	if !ok {
		inv.mu.Lock()
		d, ok := inv.devices[name]
		inv.mu.Unlock()
		if !ok {
			return nil, fmt.Errorf("unknown device %q", name)
		}
		return d, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ifaces, err := sources.ListPoints(ctx, kind, dev, auth)

	inv.mu.Lock()
	defer inv.mu.Unlock()
	d := inv.devices[name]
	d.Discovered = time.Now()
	if err != nil {
		d.Error = err.Error()
		return d, nil
	}
	d.Error = ""
	d.Points = nil
	for _, i := range ifaces {
		p := inv.ifacePoint(kind, name, i.Netns, i.Label, i.Iface, i.Kind)
		d.Points = append(d.Points, p)
		inv.known[p.ID] = p
	}
	return d, nil
}

func (inv *Inventory) Devices() []Device {
	inv.mu.Lock()
	defer inv.mu.Unlock()
	var out []Device
	add := func(name string) {
		if d, ok := inv.devices[name]; ok {
			out = append(out, *d)
		}
	}
	for _, r := range inv.cfg.Routers {
		add(r.Name)
	}
	for _, a := range inv.cfg.Agents {
		add(a.Name)
	}
	for _, a := range inv.cfg.APs {
		add(a.Name)
	}
	return out
}

// ResolvePoint turns a point ID from the UI into a point. Interfaces don't
// need to have been discovered: agents check them again themselves.
func (inv *Inventory) ResolvePoint(id string) (model.Point, error) {
	parts := strings.Split(id, "|")
	switch len(parts) {
	case 2:
		for _, r := range inv.cfg.Routers {
			if r.Name == parts[0] {
				for _, c := range sources.Chains {
					if c == parts[1] {
						return inv.routerPoint(r, c), nil
					}
				}
			}
		}
	case 3:
		if _, kind, _, ok := inv.sshDevice(parts[0]); ok && parts[2] != "" {
			if kind == model.KindAP && parts[1] != "" {
				break
			}
			inv.mu.Lock()
			p, ok := inv.known[id]
			inv.mu.Unlock()
			if ok {
				return p, nil
			}
			return inv.ifacePoint(kind, parts[0], parts[1], "", parts[2], ""), nil
		}
	}
	return model.Point{}, fmt.Errorf("unknown capture point %q", id)
}
