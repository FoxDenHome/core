package modules

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gosnmp/gosnmp"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// IF-MIB columns
const (
	ifDescr       = "1.3.6.1.2.1.2.2.1.2"
	ifAdminStatus = "1.3.6.1.2.1.2.2.1.7"
	ifOperStatus  = "1.3.6.1.2.1.2.2.1.8"
	ifInErrors    = "1.3.6.1.2.1.2.2.1.14"
	ifOutErrors   = "1.3.6.1.2.1.2.2.1.20"
	ifName        = "1.3.6.1.2.1.31.1.1.1.1"
	ifHCInOctets  = "1.3.6.1.2.1.31.1.1.1.6"
	ifHCOutOctets = "1.3.6.1.2.1.31.1.1.1.10"
	ifHighSpeed   = "1.3.6.1.2.1.31.1.1.1.15"
	ifAlias       = "1.3.6.1.2.1.31.1.1.1.18"
	sysDescr      = "1.3.6.1.2.1.1.1.0"
	sysUpTime     = "1.3.6.1.2.1.1.3.0"
	ifStatusUp    = 1
)

type portGroupOptions struct {
	Label string `json:"label"`
	// Ports lists interface names (ifName), with brace ranges: "0/{1..24}", "sfp{1..4},wan".
	// Use "#12" to match by ifIndex instead.
	Ports string `json:"ports"`
	Rows  int    `json:"rows"`
	// Labels optionally overrides the printed port labels, same expansion rules.
	Labels string `json:"labels"`
}

type switchOptions struct {
	Groups []portGroupOptions `json:"groups"`
	// UniFi optionally reads PoE from the UniFi controller, since the switches'
	// SNMP agents don't report per-port power. The controller's port N is the
	// Nth port across all groups.
	UniFi *unifiOptions `json:"unifi"`
}

type portInfo struct {
	name, descr, alias       string
	admin, oper              int64
	speed                    int64
	inOctets, outOctets      uint64
	inErrors, outErrors      uint64
	rxRate, txRate           float64
	errorsGrew, haveCounters bool
}

type snmpSwitch struct {
	env   *Env
	dev   *config.Device
	opts  switchOptions
	unifi *unifiClient

	mu   sync.Mutex
	prev map[string]portInfo
	at   time.Time
}

func init() {
	register(Spec{
		Name:        "snmp-switch",
		Description: "Any switch or router with IF-MIB. Options: groups [{label, ports, rows, labels}].",
		Height:      1,
		New:         newSwitch(switchOptions{}),
	})
	register(Spec{
		Name:        "unifi-us-48",
		Description: "UniFi Switch 48 (gen 1): 48 RJ45, 2 SFP, 2 SFP+.",
		Height:      1,
		New: newSwitch(switchOptions{Groups: []portGroupOptions{
			{Label: "RJ45", Ports: "0/{1..48}", Rows: 2, Labels: "{1..48}"},
			{Label: "SFP", Ports: "0/{49..52}", Rows: 2, Labels: "{49..52}"},
		}}),
	})
	register(Spec{
		Name:        "unifi-usw-pro-aggregation",
		Description: "UniFi Switch Pro Aggregation: 28 SFP+, 4 SFP28.",
		Height:      1,
		New: newSwitch(switchOptions{Groups: []portGroupOptions{
			{Label: "SFP+", Ports: "0/{1..28}", Rows: 2, Labels: "{1..28}"},
			{Label: "SFP28", Ports: "0/{29..32}", Rows: 2, Labels: "{29..32}"},
		}}),
	})
	register(Spec{
		Name:        "mikrotik-ccr2004-1g-12s-2xs",
		Description: "MikroTik CCR2004-1G-12S+2XS. Default port names are RouterOS factory names; override groups if renamed.",
		Height:      1,
		New: newSwitch(switchOptions{Groups: []portGroupOptions{
			{Label: "MGMT", Ports: "ether1", Rows: 1, Labels: "MGMT"},
			{Label: "SFP+", Ports: "sfp-sfpplus{1..12}", Rows: 2, Labels: "{1..12}"},
			{Label: "SFP28", Ports: "sfp28-{1..2}", Rows: 2, Labels: "{1..2}"},
		}}),
	})
	register(Spec{
		Name:        "mikrotik-rb5009",
		Description: "MikroTik RB5009UG+S+IN. Default port names are RouterOS factory names; override groups if renamed.",
		Height:      1,
		New: newSwitch(switchOptions{Groups: []portGroupOptions{
			{Label: "RJ45", Ports: "ether{1..8}", Rows: 1, Labels: "{1..8}"},
			{Label: "SFP+", Ports: "sfp-sfpplus1", Rows: 1, Labels: "SFP+"},
		}}),
	})
}

func newSwitch(defaults switchOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		for i, g := range opts.Groups {
			ports := expand(g.Ports)
			if len(ports) == 0 {
				return nil, fmt.Errorf("device %s: group %d has no ports", dev.ID, i)
			}
			if g.Labels != "" && len(expand(g.Labels)) != len(ports) {
				return nil, fmt.Errorf("device %s: group %d has %d ports but %d labels", dev.ID, i, len(ports), len(expand(g.Labels)))
			}
			if opts.Groups[i].Rows <= 0 {
				opts.Groups[i].Rows = 1
			}
		}
		sw := &snmpSwitch{env: env, dev: dev, opts: opts}
		if opts.UniFi != nil {
			sw.unifi, err = newUnifiClient(env, opts.UniFi.withDefaults())
			if err != nil {
				return nil, fmt.Errorf("device %s: unifi: %w", dev.ID, err)
			}
		}
		return sw, nil
	}
}

func (s *snmpSwitch) Skeleton() rack.State {
	st := rack.State{Status: rack.StatusUnknown}
	for gi, g := range s.opts.Groups {
		ports := expand(g.Ports)
		labels := ports
		if g.Labels != "" {
			labels = expand(g.Labels)
		}
		group := rack.Group{ID: strconv.Itoa(gi), Kind: rack.KindPort, Label: g.Label, Rows: g.Rows}
		for i, p := range ports {
			group.Slots = append(group.Slots, rack.Slot{ID: p, Label: labels[i], Status: rack.StatusUnknown})
		}
		st.Faceplate = append(st.Faceplate, group)
	}
	return st
}

func (s *snmpSwitch) Poll(ctx context.Context) (rack.State, error) {
	c, err := snmp.Dial(ctx, s.dev.Address, s.env.SNMPCommunity)
	if err != nil {
		return rack.State{}, err
	}
	defer c.Close()

	sys, err := c.Get(sysDescr, sysUpTime)
	if err != nil {
		return rack.State{}, err
	}

	cols := map[string]map[string]gosnmp.SnmpPDU{}
	for _, col := range []string{ifName, ifDescr, ifAlias, ifAdminStatus, ifOperStatus, ifHighSpeed, ifHCInOctets, ifHCOutOctets, ifInErrors, ifOutErrors} {
		rows, err := c.Column(col)
		if err != nil {
			return rack.State{}, fmt.Errorf("walking %s: %w", col, err)
		}
		cols[col] = rows
	}

	now := time.Now()
	ports := map[string]portInfo{}
	byIndex := map[string]string{}
	for idx, pdu := range cols[ifName] {
		p := portInfo{name: snmp.String(pdu)}
		if d, ok := cols[ifDescr][idx]; ok {
			p.descr = snmp.String(d)
		}
		if a, ok := cols[ifAlias][idx]; ok {
			p.alias = snmp.String(a)
		}
		p.admin, _ = snmp.Int(cols[ifAdminStatus][idx])
		p.oper, _ = snmp.Int(cols[ifOperStatus][idx])
		p.speed, _ = snmp.Int(cols[ifHighSpeed][idx])
		var okIn, okOut bool
		p.inOctets, okIn = snmp.Uint(cols[ifHCInOctets][idx])
		p.outOctets, okOut = snmp.Uint(cols[ifHCOutOctets][idx])
		p.haveCounters = okIn && okOut
		p.inErrors, _ = snmp.Uint(cols[ifInErrors][idx])
		p.outErrors, _ = snmp.Uint(cols[ifOutErrors][idx])
		ports[p.name] = p
		byIndex["#"+idx] = p.name
	}

	s.mu.Lock()
	if s.prev != nil {
		dt := now.Sub(s.at).Seconds()
		for name, p := range ports {
			old, ok := s.prev[name]
			if !ok || !p.haveCounters || !old.haveCounters || dt <= 0 {
				continue
			}
			if p.inOctets >= old.inOctets {
				p.rxRate = float64(p.inOctets-old.inOctets) * 8 / dt
			}
			if p.outOctets >= old.outOctets {
				p.txRate = float64(p.outOctets-old.outOctets) * 8 / dt
			}
			p.errorsGrew = p.inErrors > old.inErrors || p.outErrors > old.outErrors
			ports[name] = p
		}
	}
	s.prev, s.at = ports, now
	s.mu.Unlock()

	var poe map[int]unifiPort
	var poeErr error
	if s.unifi != nil {
		poe, poeErr = s.poe(ctx)
	}

	st := s.Skeleton()
	st.Status = rack.StatusOK
	up, total := 0, 0
	var poeTotal float64
	for gi := range st.Faceplate {
		for si := range st.Faceplate[gi].Slots {
			slot := &st.Faceplate[gi].Slots[si]
			key := slot.ID
			if strings.HasPrefix(key, "#") {
				key = byIndex[key]
			}
			p, ok := ports[key]
			total++
			if !ok {
				slot.Status = rack.StatusEmpty
				slot.Sections = []rack.Section{{Title: slot.ID, Rows: []rack.Row{{Key: "Interface", Value: "not found"}}}}
				continue
			}
			s.fillPort(slot, p)
			if pp, ok := poe[total]; ok {
				poeTotal += fillPoE(slot, pp)
			}
			if p.oper == ifStatusUp {
				up++
			}
		}
	}

	sec := rack.Section{Title: "Device"}
	sec.Add("Description", sys.String(sysDescr))
	if ticks, ok := sys.Int(sysUpTime); ok {
		sec.Add("Uptime", formatDuration(time.Duration(ticks)*10*time.Millisecond))
	}
	sec.Add("Ports up", fmt.Sprintf("%d / %d", up, total))
	st.Summary = fmt.Sprintf("%d/%d up", up, total)
	if poeErr != nil {
		st.Status = rack.StatusWarn
		st.Error = "unifi: " + poeErr.Error()
	} else if poe != nil {
		sec.Add("PoE draw", fmt.Sprintf("%.1f W", poeTotal))
		st.Summary += fmt.Sprintf(" · PoE %.0f W", poeTotal)
	}
	st.Sections = []rack.Section{sec}
	st.Rollup()
	return st, nil
}

func (s *snmpSwitch) fillPort(slot *rack.Slot, p portInfo) {
	sec := rack.Section{Title: p.name}
	if p.alias != "" {
		sec.Add("Description", p.alias)
	}
	if p.descr != "" && p.descr != p.name {
		sec.Add("Interface", p.descr)
	}
	switch {
	case p.admin != ifStatusUp:
		slot.Status = rack.StatusOff
		sec.AddStatus("State", "disabled", rack.StatusOff)
	case p.oper == ifStatusUp:
		slot.Status = rack.StatusOK
		slot.Value = formatSpeed(p.speed)
		sec.AddStatus("State", "up", rack.StatusOK)
		sec.Add("Speed", formatSpeed(p.speed))
	default:
		slot.Status = rack.StatusOff
		sec.AddStatus("State", "down", rack.StatusOff)
	}
	if p.haveCounters && p.oper == ifStatusUp {
		sec.Add("RX", formatBits(p.rxRate))
		sec.Add("TX", formatBits(p.txRate))
	}
	es := rack.StatusOK
	if p.errorsGrew {
		es = rack.StatusWarn
		slot.Status = rack.Worst(slot.Status, rack.StatusWarn)
	}
	sec.AddStatus("Errors in/out", fmt.Sprintf("%d / %d", p.inErrors, p.outErrors), es)
	slot.Sections = []rack.Section{sec}
}

type unifiPort struct {
	Index      int       `json:"port_idx"`
	PoECapable bool      `json:"port_poe"`
	PoEEnable  bool      `json:"poe_enable"`
	PoEGood    bool      `json:"poe_good"`
	PoEMode    string    `json:"poe_mode"`
	PoEClass   string    `json:"poe_class"`
	PoEPower   flexFloat `json:"poe_power"`
	PoEVoltage flexFloat `json:"poe_voltage"`
	// PoECurrent is in mA.
	PoECurrent flexFloat `json:"poe_current"`
}

// poe returns the controller's PoE-capable ports by port number.
func (s *snmpSwitch) poe(ctx context.Context) (map[int]unifiPort, error) {
	var d struct {
		Ports []unifiPort `json:"port_table"`
	}
	if err := s.unifi.device(ctx, &d); err != nil {
		return nil, err
	}
	out := map[int]unifiPort{}
	for _, p := range d.Ports {
		if p.PoECapable {
			out[p.Index] = p
		}
	}
	return out, nil
}

// fillPoE adds a port's PoE state and returns the watts it delivers.
func fillPoE(slot *rack.Slot, p unifiPort) float64 {
	sec := &slot.Sections[0]
	if !p.PoEEnable {
		sec.AddStatus("PoE", "off", rack.StatusOff)
		return 0
	}
	w := float64(p.PoEPower)
	slot.Power = rack.Watts(w)
	if !p.PoEGood {
		sec.Add("PoE", fmt.Sprintf("%s, no device", p.PoEMode))
		return w
	}
	v := fmt.Sprintf("%.1f W", w)
	if p.PoEClass != "" {
		v += " · " + p.PoEClass
	}
	sec.Add("PoE", v)
	sec.Add("PoE voltage", fmt.Sprintf("%.1f V", float64(p.PoEVoltage)))
	sec.Add("PoE current", fmt.Sprintf("%.0f mA", float64(p.PoECurrent)))
	return w
}
