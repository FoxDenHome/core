package modules

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// An automatic transfer switch is not a rack device of its own here: it's
// usually mounted out of sight and all it adds is which feed is live. It
// attaches to the device it powers (see upsOptions.ATS).
type atsOptions struct {
	// Model selects the SNMP dialect. Only "cyberpower" for now.
	Model   string `json:"model"`
	Address string `json:"address"`
}

var atsModels = []string{"cyberpower"}

func (a *atsOptions) validate() error {
	if a.Model == "" {
		a.Model = "cyberpower"
	}
	if !slices.Contains(atsModels, a.Model) {
		return fmt.Errorf("unknown model %q (have %s)", a.Model, strings.Join(atsModels, ", "))
	}
	if a.Address == "" {
		return fmt.Errorf("address is required")
	}
	return nil
}

func (a *atsOptions) skeleton() rack.Group {
	return rack.Group{ID: "ats", Kind: rack.KindLED, Label: "Feed", Rows: 2, Slots: []rack.Slot{
		{ID: "1", Label: "A", Status: rack.StatusUnknown},
		{ID: "2", Label: "B", Status: rack.StatusUnknown},
	}}
}

// CyberPower CPS-MIB, ats subtree (1.3.6.1.4.1.3808.1.1.5)
const (
	cpsATSModel           = "1.3.6.1.4.1.3808.1.1.5.1.2.0"
	cpsATSSerial          = "1.3.6.1.4.1.3808.1.1.5.1.5.0"
	cpsATSSelectedSource  = "1.3.6.1.4.1.3808.1.1.5.2.1.2.0"
	cpsATSRedundancy      = "1.3.6.1.4.1.3808.1.1.5.2.1.3.0"
	cpsATSPreferredSource = "1.3.6.1.4.1.3808.1.1.5.3.1.0"
	cpsATSInputName       = "1.3.6.1.4.1.3808.1.1.5.2.2.2.1.2"
	cpsATSInputVoltage    = "1.3.6.1.4.1.3808.1.1.5.2.2.2.1.5"
	cpsATSInputFrequency  = "1.3.6.1.4.1.3808.1.1.5.2.2.2.1.6"
	cpsATSInputVoltState  = "1.3.6.1.4.1.3808.1.1.5.2.2.2.1.7"
	cpsATSInputFreqState  = "1.3.6.1.4.1.3808.1.1.5.2.2.2.1.8"
	cpsATSRedundancyLost  = 1
	cpsATSStateNormal     = 1
	cpsATSTenthsPerUnit   = 10.0
)

func (a *atsOptions) poll(ctx context.Context, env *Env) (rack.Group, rack.Section, string, error) {
	group := a.skeleton()
	sec := rack.Section{Title: "Transfer switch"}

	c, err := snmp.Dial(ctx, a.Address, env.SNMPCommunity)
	if err != nil {
		return group, sec, "", err
	}
	defer c.Close()

	v, err := c.Get(cpsATSModel, cpsATSSerial, cpsATSSelectedSource, cpsATSRedundancy, cpsATSPreferredSource)
	if err != nil {
		return group, sec, "", err
	}
	cols := map[string]map[string]int64{}
	names := map[string]string{}
	for _, col := range []string{cpsATSInputVoltage, cpsATSInputFrequency, cpsATSInputVoltState, cpsATSInputFreqState} {
		rows, err := c.Column(col)
		if err != nil {
			return group, sec, "", err
		}
		cols[col] = map[string]int64{}
		for idx, pdu := range rows {
			cols[col][idx], _ = snmp.Int(pdu)
		}
	}
	if rows, err := c.Column(cpsATSInputName); err == nil {
		for idx, pdu := range rows {
			names[idx] = snmp.String(pdu)
		}
	}

	selected, _ := v.Int(cpsATSSelectedSource)
	preferred, _ := v.Int(cpsATSPreferredSource)
	redundancy, _ := v.Int(cpsATSRedundancy)
	redundant := redundancy != cpsATSRedundancyLost

	activeLabel := "?"
	for i := range group.Slots {
		slot := &group.Slots[i]
		idx := slot.ID
		volts := float64(cols[cpsATSInputVoltage][idx]) / cpsATSTenthsPerUnit
		hz := float64(cols[cpsATSInputFrequency][idx]) / cpsATSTenthsPerUnit
		healthy := cols[cpsATSInputVoltState][idx] == cpsATSStateNormal && cols[cpsATSInputFreqState][idx] == cpsATSStateNormal

		slot.Value = formatFloat(volts, " V")
		active := fmt.Sprint(selected) == idx
		switch {
		case !healthy:
			slot.Status = rack.StatusCrit
		case active:
			slot.Status = rack.StatusOK
			activeLabel = slot.Label
		default:
			// Standby feed that's fine: lit but not active.
			slot.Status = rack.StatusOff
		}
		if active && !healthy {
			activeLabel = slot.Label
		}

		name := names[idx]
		if name == "" {
			name = "Source " + slot.Label
		}
		state := "standby"
		if active {
			state = "active"
		}
		if !healthy {
			state += ", out of range"
		}
		slot.Sections = []rack.Section{{Title: name, Rows: []rack.Row{
			{Key: "State", Value: state, Status: slot.Status},
			{Key: "Voltage", Value: formatFloat(volts, " V")},
			{Key: "Frequency", Value: formatFloat(hz, " Hz")},
		}}}
		sec.AddStatus(name, fmt.Sprintf("%s · %s · %s", state, formatFloat(volts, " V"), formatFloat(hz, " Hz")), slot.Status)
	}

	if !redundant {
		// Only one usable feed: the standby one is what's missing.
		for i := range group.Slots {
			if group.Slots[i].Status == rack.StatusOff {
				group.Slots[i].Status = rack.StatusWarn
			}
		}
		sec.AddStatus("Redundancy", "lost", rack.StatusWarn)
	} else {
		sec.AddStatus("Redundancy", "full", rack.StatusOK)
	}
	if preferred > 0 {
		pref := "?"
		for _, s := range group.Slots {
			if s.ID == fmt.Sprint(preferred) {
				pref = s.Label
			}
		}
		st := rack.StatusOK
		if fmt.Sprint(preferred) != fmt.Sprint(selected) {
			st = rack.StatusWarn
		}
		sec.AddStatus("Preferred feed", pref, st)
	}
	sec.Add("Model", v.String(cpsATSModel))
	sec.Add("Serial", v.String(cpsATSSerial))
	sec.Add("Address", a.Address)

	return group, sec, "feed " + activeLabel, nil
}
