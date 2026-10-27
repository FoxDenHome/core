package modules

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// genericOptions are reachability checks for devices without a richer module.
// With none set the device is just drawn.
type genericOptions struct {
	// SNMP reads sysDescr/sysUpTime from the device's address.
	SNMP bool `json:"snmp"`
	// TCP is a host:port that must accept connections.
	TCP string `json:"tcp"`
	// HTTP is a URL that must answer (any status below 500).
	HTTP string `json:"http"`
}

type generic struct {
	env  *Env
	dev  *config.Device
	opts genericOptions
}

func init() {
	register(Spec{
		Name:        "generic",
		Description: "Any device. Options: snmp (bool), tcp (host:port), http (URL) reachability checks.",
		Height:      1,
		New:         newGeneric(genericOptions{}),
	})
	register(Spec{
		Name:        "blank",
		Description: "Blanking panel, cable management or anything else with nothing to monitor.",
		Height:      1,
		New:         newGeneric(genericOptions{}),
	})
	register(Spec{
		Name:        "unifi-brush-panel",
		Description: "UniFi 1U brush panel (OCD panel).",
		Height:      1,
		New:         newGeneric(genericOptions{}),
	})
	register(Spec{
		Name:        "shelf",
		Description: "A shelf. Put the devices sitting on it in children.",
		Height:      1,
		New:         newGeneric(genericOptions{}),
	})
}

func newGeneric(defaults genericOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		return &generic{env: env, dev: dev, opts: opts}, nil
	}
}

func (g *generic) Skeleton() rack.State {
	if g.passive() {
		return rack.State{Status: rack.StatusOK, Passive: true}
	}
	return rack.State{Status: rack.StatusUnknown}
}

func (g *generic) passive() bool {
	return !g.opts.SNMP && g.opts.TCP == "" && g.opts.HTTP == ""
}

func (g *generic) Poll(ctx context.Context) (rack.State, error) {
	st := rack.State{Status: rack.StatusOK, Passive: g.passive()}
	info := rack.Section{Title: "Device"}

	if g.opts.SNMP {
		c, err := snmp.Dial(ctx, g.dev.Address, g.env.SNMPCommunity)
		if err != nil {
			return st, err
		}
		defer c.Close()
		v, err := c.Get("1.3.6.1.2.1.1.1.0", "1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.1.5.0")
		if err != nil {
			return st, err
		}
		info.Add("Description", v.String("1.3.6.1.2.1.1.1.0"))
		info.Add("Name", v.String("1.3.6.1.2.1.1.5.0"))
		if ticks, ok := v.Int("1.3.6.1.2.1.1.3.0"); ok {
			up := time.Duration(ticks) * 10 * time.Millisecond
			info.Add("Uptime", formatDuration(up))
			st.Summary = "up " + formatDuration(up)
		}
	}

	if g.opts.TCP != "" {
		d := net.Dialer{}
		conn, err := d.DialContext(ctx, "tcp", g.opts.TCP)
		if err != nil {
			return st, err
		}
		_ = conn.Close()
		info.Add("TCP "+g.opts.TCP, "open")
	}

	if g.opts.HTTP != "" {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.opts.HTTP, nil)
		if err != nil {
			return st, err
		}
		resp, err := g.env.HTTP.Do(req)
		if err != nil {
			return st, err
		}
		_ = resp.Body.Close()
		if resp.StatusCode >= 500 {
			return st, fmt.Errorf("%s: HTTP %d", g.opts.HTTP, resp.StatusCode)
		}
		info.Add("HTTP", resp.Status)
	}

	if len(info.Rows) > 0 {
		st.Sections = []rack.Section{info}
	}
	return st, nil
}
