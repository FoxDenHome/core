package poller

import (
	"fmt"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// checkPower makes sure every power feed names a slot that exists.
func (p *Poller) checkPower() error {
	byID := map[string]*Device{}
	for _, e := range p.entries {
		byID[e.dev.ID] = e.dev
	}
	for _, e := range p.entries {
		for _, f := range e.dev.power {
			src, ok := byID[f.Device]
			if !ok {
				return fmt.Errorf("device %s: power: unknown device %q", e.dev.ID, f.Device)
			}
			if src.State.FindSlot(f.Slot) == nil {
				return fmt.Errorf("device %s: power: %s has no slot %q", e.dev.ID, f.Device, f.Slot)
			}
		}
	}
	return nil
}

func feedLabel(f config.PowerFeed, src *Device, slot *rack.Slot) string {
	if f.Label != "" {
		return f.Label
	}
	return src.Name + " " + slot.Label
}

// applyPower gives every device with power feeds a Power section read from the
// slots feeding it, and notes on each of those slots what it powers. It works
// on a snapshot, so readings are always the feeding device's latest.
func applyPower(byID map[string]*Device) {
	for _, d := range byID {
		if len(d.power) == 0 {
			continue
		}
		sec := rack.Section{Title: "Power"}
		var total float64
		metered, off := 0, 0
		for _, f := range d.power {
			src := byID[f.Device]
			slot := src.State.FindSlot(f.Slot)
			label := feedLabel(f, src, slot)
			via := ""
			if f.Label != "" {
				via = fmt.Sprintf(" · %s %s", src.Name, slot.Label)
			}
			switch {
			case slot.Status == rack.StatusOff:
				off++
				sec.AddStatus(label, "off"+via, rack.StatusOff)
			case slot.Power == nil || slot.Status == rack.StatusUnknown:
				sec.AddStatus(label, "no data"+via, rack.StatusUnknown)
			default:
				metered++
				total += *slot.Power
				sec.Add(label, fmt.Sprintf("%.1f W%s", *slot.Power, via))
			}

			powers := rack.Section{Title: "Powers"}
			powers.Add(d.Name, label)
			slot.Sections = append(slot.Sections, powers)
		}
		// With redundant feeds, one going dark leaves the device running
		// without its spare, which nothing else would flag.
		if off > 0 && off < len(d.power) {
			for i := range sec.Rows {
				if sec.Rows[i].Status == rack.StatusOff {
					sec.Rows[i].Status = rack.StatusWarn
				}
			}
			d.State.Status = rack.Worst(d.State.Status, rack.StatusWarn)
		}
		if metered > 0 {
			if len(d.power) > 1 {
				sec.Add("Total", fmt.Sprintf("%.1f W", total))
			}
			w := fmt.Sprintf("%.0f W", total)
			if d.State.Summary == "" {
				d.State.Summary = w
			} else {
				d.State.Summary += " · " + w
			}
		}
		d.State.Sections = append([]rack.Section{sec}, d.State.Sections...)
	}
}
