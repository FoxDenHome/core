package modules

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/promtext"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// Time servers export chrony's tracking and sources (chrony_*) and the GNSS
// receiver's state (gpsd_*) through node_exporter's textfile collector. The
// server module adds these sections whenever the metrics are there.

const (
	// clockOffsetWarn/Crit judge chrony's estimate of the system clock offset.
	clockOffsetWarn = 1e-3
	clockOffsetCrit = 100e-3
)

// timing is what a time server adds to the server module's state.
type timing struct {
	sections []rack.Section
	groups   []rack.Group
	summary  []string
	status   rack.Status
}

func (t *timing) add(sec rack.Section) {
	if len(sec.Rows) == 0 {
		return
	}
	t.sections = append(t.sections, sec)
	for _, r := range sec.Rows {
		t.status = rack.Worst(t.status, r.Status)
	}
}

// formatSeconds renders small signed durations with a fitting SI prefix.
func formatSeconds(v float64) string {
	a := math.Abs(v)
	switch {
	case math.IsNaN(v):
		return "—"
	case a == 0:
		return "0 s"
	case a < 1e-6:
		return fmt.Sprintf("%.0f ns", v*1e9)
	case a < 1e-3:
		return fmt.Sprintf("%.1f µs", v*1e6)
	case a < 1:
		return fmt.Sprintf("%.2f ms", v*1e3)
	}
	return fmt.Sprintf("%.3f s", v)
}

func formatPPM(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64) + " ppm"
}

func timingState(node promtext.Metrics) timing {
	t := timing{status: rack.StatusOK}
	led := rack.Group{ID: "timing", Kind: rack.KindLED, Label: "Timing", Rows: 3}

	if sync, ok := chronyTracking(node, &t); ok {
		led.Slots = append(led.Slots, sync)
	}
	if pps, ok := chronySources(node, &t); ok {
		led.Slots = append(led.Slots, pps)
	}
	if gps, sats, ok := gnss(node, &t); ok {
		led.Slots = append([]rack.Slot{gps}, led.Slots...)
		if len(sats.Slots) > 0 {
			t.groups = append(t.groups, sats)
		}
	}
	if len(led.Slots) > 0 {
		t.groups = append([]rack.Group{led}, t.groups...)
	}
	return t
}

func chronyTracking(node promtext.Metrics, t *timing) (rack.Slot, bool) {
	stratum, ok := node.Value("chrony_stratum", nil)
	if !ok {
		return rack.Slot{}, false
	}
	sec := rack.Section{Title: "Time sync"}
	led := rack.Slot{ID: "sync", Label: "Sync", Status: rack.StatusOK}

	leap := ""
	if info := node.Find("chrony_tracking_info", nil); len(info) > 0 {
		sec.Add("Reference", info[0].Labels["refid"])
		leap = info[0].Labels["leap_status"]
	}
	st := rack.StatusOK
	if stratum == 0 || stratum >= 16 {
		st = rack.StatusCrit
	}
	sec.AddStatus("Stratum", formatFloat(stratum, ""), st)

	if off, ok := node.Value("chrony_system_time_offset", nil); ok {
		st := rack.StatusOK
		switch a := math.Abs(off); {
		case a >= clockOffsetCrit:
			st = rack.StatusCrit
		case a >= clockOffsetWarn:
			st = rack.StatusWarn
		}
		sec.AddStatus("System clock offset", formatSeconds(off), st)
		led.Status = rack.Worst(led.Status, st)
	}
	if v, ok := node.Value("chrony_last_offset", nil); ok {
		sec.Add("Last offset", formatSeconds(v))
	}
	if v, ok := node.Value("chrony_rms_offset", nil); ok {
		sec.Add("RMS offset", formatSeconds(v))
		led.Value = "±" + formatSeconds(v)
		t.summary = append(t.summary, fmt.Sprintf("stratum %.0f", stratum), "±"+formatSeconds(v))
	}
	if v, ok := node.Value("chrony_frequency", nil); ok {
		sec.Add("Frequency", formatPPM(v))
	}
	if v, ok := node.Value("chrony_residual_frequency", nil); ok {
		sec.Add("Residual frequency", formatPPM(v))
	}
	if v, ok := node.Value("chrony_skew", nil); ok {
		sec.Add("Skew", formatPPM(v))
	}
	if v, ok := node.Value("chrony_root_delay", nil); ok {
		sec.Add("Root delay", formatSeconds(v))
	}
	if v, ok := node.Value("chrony_root_dispersion", nil); ok {
		sec.Add("Root dispersion", formatSeconds(v))
	}
	if v, ok := node.Value("chrony_update_interval", nil); ok {
		sec.Add("Update interval", formatFloat(v, " s"))
	}
	if ref, ok := node.Value("chrony_ref_time", nil); ok && ref > 0 {
		now, ok := node.Value("node_time_seconds", nil)
		if !ok {
			now = float64(time.Now().Unix())
		}
		sec.Add("Last update", formatDuration(time.Duration(now-ref)*time.Second)+" ago")
	}
	if leap != "" {
		st := rack.StatusOK
		if leap == "Not synchronised" {
			st = rack.StatusCrit
		}
		sec.AddStatus("Leap status", leap, st)
		led.Status = rack.Worst(led.Status, st)
	}
	if st != rack.StatusOK {
		led.Status = rack.Worst(led.Status, st)
	}

	// The kernel's view of the clock discipline.
	if v, ok := node.Value("node_timex_sync_status", nil); ok {
		st, text := rack.StatusOK, "synchronized"
		if v != 1 {
			st, text = rack.StatusWarn, "not synchronized"
		}
		sec.AddStatus("Kernel clock", text, st)
	}
	if v, ok := node.Value("node_timex_maxerror_seconds", nil); ok {
		sec.Add("Kernel max error", formatSeconds(v))
	}
	if v, ok := node.Value("node_timex_tai_offset_seconds", nil); ok {
		sec.Add("TAI offset", formatFloat(v, " s"))
	}
	if v, ok := node.Value("node_timex_pps_frequency_hertz", nil); ok && v != 0 {
		sec.Add("Kernel PPS frequency", formatFloat(v, " Hz"))
	}
	if v, ok := node.Value("node_timex_pps_jitter_seconds", nil); ok && v != 0 {
		sec.Add("Kernel PPS jitter", formatSeconds(v))
	}

	t.add(sec)
	return led, true
}

var sourceStates = map[string]string{
	"selected":     "selected",
	"combined":     "combined",
	"not_combined": "not combined",
	"unreachable":  "unreachable",
	"falseticker":  "falseticker",
	"too_variable": "too variable",
}

// chronySources lists the sources and returns an LED for the PPS refclock,
// or for whichever source is selected when there's no PPS.
func chronySources(node promtext.Metrics, t *timing) (rack.Slot, bool) {
	infos := node.Find("chrony_source_info", nil)
	if len(infos) == 0 {
		return rack.Slot{}, false
	}
	// Refclocks first, then by name.
	sort.Slice(infos, func(i, j int) bool {
		ri, rj := infos[i].Labels["mode"] == "refclock", infos[j].Labels["mode"] == "refclock"
		if ri != rj {
			return ri
		}
		return infos[i].Labels["source"] < infos[j].Labels["source"]
	})
	sec := rack.Section{Title: "Time sources"}
	led := rack.Slot{ID: "pps", Label: "PPS", Status: rack.StatusUnknown}
	haveLED, selected := false, false
	for _, info := range infos {
		name, mode, state := info.Labels["source"], info.Labels["mode"], info.Labels["state"]
		m := map[string]string{"source": name}
		parts := []string{sourceStates[state]}
		if parts[0] == "" {
			parts[0] = state
		}
		if off, ok := node.Value("chrony_source_offset_seconds", m); ok {
			p := "offset " + formatSeconds(off)
			if e, ok := node.Value("chrony_source_error_seconds", m); ok {
				p += " ±" + formatSeconds(e)
			}
			parts = append(parts, p)
		}
		if sd, ok := node.Value("chrony_source_std_dev_seconds", m); ok {
			parts = append(parts, "σ "+formatSeconds(sd))
		}
		if r, ok := node.Value("chrony_source_reach", m); ok {
			parts = append(parts, "reach "+strconv.FormatInt(int64(r), 8))
		}
		if p, ok := node.Value("chrony_source_poll_interval_seconds", m); ok {
			parts = append(parts, "poll "+formatFloat(p, "s"))
		}
		if mode != "refclock" {
			if s, ok := node.Value("chrony_source_stratum", m); ok {
				parts = append(parts, "stratum "+formatFloat(s, ""))
			}
		}

		// A noselect refclock (GPS time beside PPS) shows as unreachable
		// even while it delivers, so refclocks are judged by reach.
		reach, _ := node.Value("chrony_source_reach", m)
		if state == "unreachable" && reach > 0 {
			parts[0] = "not selectable"
		}
		st := rack.StatusOK
		switch {
		case state == "selected":
			selected = true
		case mode == "refclock" && reach == 0:
			st = rack.StatusWarn
		case mode == "refclock" && state == "unreachable":
		case state == "unreachable":
			st = rack.StatusOff
		case mode == "refclock" && state != "combined" && state != "not_combined":
			st = rack.StatusWarn
		}
		key := name
		if mode == "refclock" {
			key += " (refclock)"
		}
		sec.AddStatus(key, strings.Join(parts, " · "), st)

		if name == "PPS" || (!haveLED && state == "selected") {
			haveLED = true
			led.Label = name
			led.Status = rack.StatusOK
			if state != "selected" {
				led.Status = rack.StatusWarn
			}
			led.Value = sourceStates[state]
		}
	}
	if !selected {
		sec.AddStatus("Selected", "no source selected", rack.StatusCrit)
	}
	t.add(sec)
	return led, haveLED
}

// gnssPrefix is the usual one-letter system prefix for satellite ids.
var gnssPrefix = map[string]string{
	"GPS": "G", "SBAS": "S", "Galileo": "E", "BeiDou": "C", "IMES": "I", "QZSS": "J", "GLONASS": "R", "NavIC": "N",
}

var gpsdFixStatus = map[float64]string{
	0: "unknown", 1: "GPS", 2: "DGPS", 3: "RTK fixed", 4: "RTK float", 5: "dead reckoning", 6: "GNSS + dead reckoning", 7: "time only (surveyed)", 8: "simulated",
}

func gnss(node promtext.Metrics, t *timing) (rack.Slot, rack.Group, bool) {
	up, ok := node.Value("gpsd_up", nil)
	if !ok {
		return rack.Slot{}, rack.Group{}, false
	}
	sec := rack.Section{Title: "GNSS"}
	led := rack.Slot{ID: "gps", Label: "GPS", Status: rack.StatusOK}
	sats := rack.Group{ID: "satellites", Kind: rack.KindMeter, Label: "Satellite signal", Internal: true}
	if up != 1 {
		sec.AddStatus("gpsd", "no reports", rack.StatusCrit)
		led.Status = rack.StatusCrit
		t.add(sec)
		return led, sats, true
	}

	mode, _ := node.Value("gpsd_fix_mode", nil)
	fix, st := "no fix", rack.StatusCrit
	switch mode {
	case 2:
		fix, st = "2D fix", rack.StatusOK
	case 3:
		fix, st = "3D fix", rack.StatusOK
	}
	if s, ok := node.Value("gpsd_fix_status", nil); ok && mode >= 2 {
		if name, ok := gpsdFixStatus[s]; ok {
			fix += ", " + name
		}
	}
	sec.AddStatus("Fix", fix, st)
	led.Status = st

	visible, okV := node.Value("gpsd_satellites_visible", nil)
	used, okU := node.Value("gpsd_satellites_used", nil)
	if okV && okU {
		st := rack.StatusOK
		switch {
		case used == 0:
			st = rack.StatusCrit
		case used < 3:
			st = rack.StatusWarn
		}
		sec.AddStatus("Satellites", fmt.Sprintf("%.0f used / %.0f visible", used, visible), st)
		led.Status = rack.Worst(led.Status, st)
		led.Value = fmt.Sprintf("%.0f sats", used)
		t.summary = append(t.summary, fmt.Sprintf("%.0f/%.0f sats", used, visible))
	}

	// Per constellation, in a stable order.
	type count struct{ used, visible float64 }
	byGNSS := map[string]*count{}
	for _, smp := range node.Find("gpsd_satellites", nil) {
		g := smp.Labels["gnss"]
		if byGNSS[g] == nil {
			byGNSS[g] = &count{}
		}
		byGNSS[g].visible += smp.Value
		if smp.Labels["used"] == "true" {
			byGNSS[g].used += smp.Value
		}
	}
	names := make([]string, 0, len(byGNSS))
	for g := range byGNSS {
		names = append(names, g)
	}
	sort.Strings(names)
	for _, g := range names {
		c := byGNSS[g]
		sec.Add(g, fmt.Sprintf("%.0f used / %.0f visible", c.used, c.visible))
	}

	for _, d := range []string{"h", "v", "p", "t", "g"} {
		if v, ok := node.Value("gpsd_dop", map[string]string{"type": d}); ok {
			sec.Add(strings.ToUpper(d)+"DOP", strconv.FormatFloat(v, 'f', 2, 64))
		}
	}
	if v, ok := node.Value("gpsd_time_error_seconds", nil); ok {
		sec.Add("Time error estimate", formatSeconds(v))
	}
	if v, ok := node.Value("gpsd_leap_seconds", nil); ok {
		sec.Add("GPS leap seconds", formatFloat(v, " s"))
	}

	// One meter per satellite: used ones first, strongest first.
	snrs := node.Find("gpsd_satellite_snr_dbhz", nil)
	sort.Slice(snrs, func(i, j int) bool {
		ui, uj := snrs[i].Labels["used"] == "true", snrs[j].Labels["used"] == "true"
		if ui != uj {
			return ui
		}
		if snrs[i].Value != snrs[j].Value {
			return snrs[i].Value > snrs[j].Value
		}
		return snrs[i].Labels["svid"] < snrs[j].Labels["svid"]
	})
	var sum float64
	var n int
	for _, smp := range snrs {
		if smp.Value <= 0 {
			// In view but not tracked: counted above, nothing to draw.
			continue
		}
		g, svid := smp.Labels["gnss"], smp.Labels["svid"]
		prefix := gnssPrefix[g]
		if prefix == "" {
			prefix = g
		}
		slot := rack.Slot{
			ID:      g + "-" + svid,
			Label:   prefix + svid,
			Value:   formatFloat(smp.Value, " dB-Hz"),
			Percent: rack.Percent(math.Min(100, smp.Value/50*100)),
			Status:  rack.StatusOff,
		}
		if smp.Labels["used"] == "true" {
			slot.Status = rack.StatusOK
			sum += smp.Value
			n++
		}
		sats.Slots = append(sats.Slots, slot)
	}
	if n > 0 {
		sec.Add("Mean signal (used)", fmt.Sprintf("%.1f dB-Hz", sum/float64(n)))
	}
	sats.Rows = (len(sats.Slots) + 1) / 2

	t.add(sec)
	return led, sats, true
}
