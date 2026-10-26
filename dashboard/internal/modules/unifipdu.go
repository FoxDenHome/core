package modules

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// The UniFi PDU's own SNMP agent has no outlet data, so this goes through the
// UniFi Network controller instead.
type unifiPDUOptions struct {
	unifiOptions
	Outlets int `json:"outlets"`
	Rows    int `json:"rows"`
}

type unifiPDU struct {
	dev    *config.Device
	opts   unifiPDUOptions
	client *unifiClient
}

func init() {
	register(Spec{
		Name:        "unifi-pdu-pro",
		Description: "UniFi USP-PDU-Pro, per-outlet power via the UniFi Network API. Options: controller, site, mac, api_key_env or username_env/password_env, insecure, outlets, rows.",
		Height:      2,
		New: newUnifiPDU(unifiPDUOptions{
			unifiOptions: unifiDefaults,
			Outlets:      20,
			Rows:         2,
		}),
	})
}

func newUnifiPDU(defaults unifiPDUOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		client, err := newUnifiClient(env, opts.unifiOptions)
		if err != nil {
			return nil, fmt.Errorf("device %s: %w", dev.ID, err)
		}
		return &unifiPDU{dev: dev, opts: opts, client: client}, nil
	}
}

func (p *unifiPDU) skeletonOutlets(n int) rack.Group {
	g := rack.Group{ID: "outlets", Kind: rack.KindOutlet, Label: "Outlets", Rows: p.opts.Rows}
	for i := 1; i <= n; i++ {
		g.Slots = append(g.Slots, rack.Slot{ID: strconv.Itoa(i), Label: strconv.Itoa(i), Status: rack.StatusUnknown})
	}
	return g
}

func (p *unifiPDU) Skeleton() rack.State {
	return rack.State{Status: rack.StatusUnknown, Faceplate: []rack.Group{p.skeletonOutlets(p.opts.Outlets)}}
}

type unifiOutlet struct {
	Index       int       `json:"index"`
	Name        string    `json:"name"`
	RelayState  bool      `json:"relay_state"`
	HasMetering *bool     `json:"has_metering"`
	Power       flexFloat `json:"outlet_power"`
	Voltage     flexFloat `json:"outlet_voltage"`
	Current     flexFloat `json:"outlet_current"`
	PowerFactor flexFloat `json:"outlet_power_factor"`
}

type unifiDevice struct {
	Name        string        `json:"name"`
	Model       string        `json:"model"`
	Version     string        `json:"version"`
	State       int           `json:"state"`
	Uptime      flexFloat     `json:"uptime"`
	Outlets     []unifiOutlet `json:"outlet_table"`
	TotalPower  flexFloat     `json:"outlet_ac_power_consumption"`
	PowerBudget flexFloat     `json:"outlet_ac_power_budget"`
}

func (p *unifiPDU) Poll(ctx context.Context) (rack.State, error) {
	var d unifiDevice
	if err := p.client.device(ctx, &d); err != nil {
		return rack.State{}, err
	}

	outlets := d.Outlets
	sort.Slice(outlets, func(i, j int) bool { return outlets[i].Index < outlets[j].Index })
	n := max(len(outlets), p.opts.Outlets)
	group := p.skeletonOutlets(n)
	byIndex := map[int]*rack.Slot{}
	for i := range group.Slots {
		byIndex[i+1] = &group.Slots[i]
	}

	st := rack.State{Status: rack.StatusOK}
	var sum float64
	table := rack.Section{Title: "Outlets"}
	for _, o := range outlets {
		slot := byIndex[o.Index]
		if slot == nil {
			continue
		}
		name := o.Name
		if name == "" {
			name = fmt.Sprintf("Outlet %d", o.Index)
		}
		metered := o.HasMetering == nil || *o.HasMetering
		sec := rack.Section{Title: name}
		sec.Add("Outlet", strconv.Itoa(o.Index))
		if o.RelayState {
			slot.Status = rack.StatusOK
			sec.AddStatus("Relay", "on", rack.StatusOK)
		} else {
			slot.Status = rack.StatusOff
			sec.AddStatus("Relay", "off", rack.StatusOff)
		}
		row := "off"
		if o.RelayState {
			row = "on"
		}
		if metered {
			w := float64(o.Power)
			sum += w
			slot.Value = formatFloat(w, "W")
			slot.Power = rack.Watts(w)
			sec.Add("Power", fmt.Sprintf("%.1f W", w))
			sec.Add("Current", fmt.Sprintf("%.2f A", float64(o.Current)))
			sec.Add("Voltage", fmt.Sprintf("%.1f V", float64(o.Voltage)))
			if o.PowerFactor > 0 {
				sec.Add("Power factor", fmt.Sprintf("%.2f", float64(o.PowerFactor)))
			}
			row = fmt.Sprintf("%s · %.1f W", row, w)
		}
		slot.Label = strconv.Itoa(o.Index)
		slot.Sections = []rack.Section{sec}
		table.AddStatus(fmt.Sprintf("%d %s", o.Index, name), row, slot.Status)
	}

	total := float64(d.TotalPower)
	if total == 0 {
		total = sum
	}
	info := rack.Section{Title: "PDU"}
	val := fmt.Sprintf("%.0f W", total)
	if d.PowerBudget > 0 {
		val += fmt.Sprintf(" / %.0f W", float64(d.PowerBudget))
	}
	info.Add("Total power", val)
	info.Add("Model", d.Model)
	info.Add("Firmware", d.Version)
	if d.Uptime > 0 {
		info.Add("Uptime", formatDuration(time.Duration(d.Uptime)*time.Second))
	}
	if d.State != 1 {
		// 1 is "connected" in the controller's device state enum.
		info.AddStatus("Controller state", strconv.Itoa(d.State), rack.StatusWarn)
		st.Status = rack.StatusWarn
	}

	st.Faceplate = []rack.Group{group}
	st.Sections = []rack.Section{info, table}
	st.Summary = fmt.Sprintf("%.0f W", total)
	st.Rollup()
	return st, nil
}
