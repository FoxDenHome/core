package modules

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/promtext"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

type serverOptions struct {
	// NodeExporter is the node_exporter metrics URL. Defaults to http://<address>:9100/metrics.
	NodeExporter string `json:"node_exporter"`
	// SmartExporter is the smartctl_exporter metrics URL. Defaults to
	// http://<address>:9633/metrics, "-" disables it.
	SmartExporter string      `json:"smart_exporter"`
	Bays          *bayOptions `json:"bays"`
	// DiskTempWarn/Crit are drive temperature thresholds in °C.
	DiskTempWarn float64 `json:"disk_temp_warn"`
	DiskTempCrit float64 `json:"disk_temp_crit"`
	// NVMeTempWarn/Crit apply to NVMe drives, which run much hotter. They are
	// lowered to the drive's own reported limits when those are stricter.
	NVMeTempWarn float64 `json:"nvme_temp_warn"`
	NVMeTempCrit float64 `json:"nvme_temp_crit"`
}

// bayOptions describe the drive bays on the front. Slots lists, for each bay
// position row by row from the top left as seen from the front, what disk
// belongs there:
//
//	"phy:4"          disk on SAS expander phy 4 (from the kernel's by-path name)
//	"serial:ZL2ABC"  disk with that serial number
//	"dev:sdc"        kernel device name (unstable across reboots, avoid)
//	""               bay is never populated
//
// To remap after checking identify LEDs, reorder the list.
type bayOptions struct {
	Rows  int      `json:"rows"`
	Cols  int      `json:"cols"`
	Slots []string `json:"slots"`
	// Labels names each bay as printed on the chassis. Defaults to "Bay <n>",
	// counting from 0 in Slots order.
	Labels []string `json:"labels"`
}

type server struct {
	env  *Env
	dev  *config.Device
	opts serverOptions

	// baseline holds the first value seen for counters that only matter when
	// they grow, keyed by disk serial and counter.
	mu       sync.Mutex
	baseline map[string]float64
}

func init() {
	register(Spec{
		Name:        "server",
		Description: "Linux server with node_exporter and optional smartctl_exporter. Options: node_exporter, smart_exporter, bays {rows, cols, slots, labels}, disk_temp_warn/crit, nvme_temp_warn/crit.",
		Height:      1,
		New:         newServer(serverOptions{}),
	})
	register(Spec{
		Name:        "supermicro-cse826",
		Description: "Supermicro CSE-826 2U, 12 x 3.5\" bays behind a SAS3 expander backplane. Bays map to expander phys 0-11 by default.",
		Height:      2,
		New: newServer(serverOptions{
			Bays: &bayOptions{
				Rows:  3,
				Cols:  4,
				Slots: phySlots(12),
			},
		}),
	})
	register(Spec{
		Name:        "mini-pc",
		Description: "Small form factor PC (ThinkCentre Tiny, NUC, ...) with node_exporter and smartctl_exporter. Meant to sit on a shelf.",
		Height:      1,
		New:         newServer(serverOptions{}),
	})
	register(Spec{
		Name:        "raspberry-pi",
		Description: "Raspberry Pi with node_exporter (no SMART on SD cards). Meant to sit on a shelf.",
		Height:      1,
		New:         newServer(serverOptions{SmartExporter: "-"}),
	})
}

func phySlots(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("phy:%d", i)
	}
	return out
}

func newServer(defaults serverOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		if defaults.Bays != nil {
			// Copy so decoding into it doesn't change the preset.
			b := *defaults.Bays
			defaults.Bays = &b
		}
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		if opts.NodeExporter == "" && dev.Address != "" {
			opts.NodeExporter = fmt.Sprintf("http://%s:9100/metrics", dev.Address)
		}
		if opts.SmartExporter == "" && dev.Address != "" {
			opts.SmartExporter = fmt.Sprintf("http://%s:9633/metrics", dev.Address)
		}
		if opts.SmartExporter == "-" {
			opts.SmartExporter = ""
		}
		if opts.DiskTempWarn == 0 {
			opts.DiskTempWarn = 50
		}
		if opts.DiskTempCrit == 0 {
			opts.DiskTempCrit = 60
		}
		if opts.NVMeTempWarn == 0 {
			opts.NVMeTempWarn = 70
		}
		if opts.NVMeTempCrit == 0 {
			opts.NVMeTempCrit = 80
		}
		if b := opts.Bays; b != nil {
			if b.Rows*b.Cols != len(b.Slots) {
				return nil, fmt.Errorf("device %s: bays: %dx%d grid but %d slots", dev.ID, b.Rows, b.Cols, len(b.Slots))
			}
			if b.Labels != nil && len(b.Labels) != len(b.Slots) {
				return nil, fmt.Errorf("device %s: bays: %d labels for %d slots", dev.ID, len(b.Labels), len(b.Slots))
			}
		}
		return &server{env: env, dev: dev, opts: opts}, nil
	}
}

func (s *server) bayLabel(i int) string {
	if b := s.opts.Bays; b.Labels != nil {
		return b.Labels[i]
	}
	return fmt.Sprintf("Bay %d", i)
}

func (s *server) Skeleton() rack.State {
	st := rack.State{Status: rack.StatusUnknown}
	if b := s.opts.Bays; b != nil {
		g := rack.Group{ID: "bays", Kind: rack.KindBay, Label: "Drive bays", Rows: b.Rows}
		for i, key := range b.Slots {
			status := rack.StatusUnknown
			if key == "" {
				status = rack.StatusEmpty
			}
			g.Slots = append(g.Slots, rack.Slot{ID: strconv.Itoa(i), Label: s.bayLabel(i), Status: status})
		}
		st.Faceplate = []rack.Group{g}
	}
	return st
}

type disk struct {
	dev, model, serial, path, wwn string
	rotational                    bool
	phy                           int
}

var phyRe = regexp.MustCompile(`-phy(\d+)-`)

func (d *disk) matches(key string) bool {
	kind, val, _ := strings.Cut(key, ":")
	switch kind {
	case "phy":
		return d.phy >= 0 && strconv.Itoa(d.phy) == val
	case "serial":
		return strings.EqualFold(d.serial, val)
	case "dev":
		return d.dev == val
	case "wwn":
		return strings.EqualFold(d.wwn, val)
	}
	return false
}

func (s *server) Poll(ctx context.Context) (rack.State, error) {
	var node, smart promtext.Metrics
	var nodeErr, smartErr error
	var wg sync.WaitGroup
	if s.opts.NodeExporter != "" {
		wg.Go(func() { node, nodeErr = promtext.Fetch(ctx, s.env.HTTP, s.opts.NodeExporter) })
	}
	if s.opts.SmartExporter != "" {
		wg.Go(func() { smart, smartErr = promtext.Fetch(ctx, s.env.HTTP, s.opts.SmartExporter) })
	}
	wg.Wait()
	if nodeErr != nil {
		return rack.State{}, fmt.Errorf("node_exporter: %w", nodeErr)
	}

	st := s.Skeleton()
	st.Status = rack.StatusOK
	var summary []string

	sys := rack.Section{Title: "System"}
	if node != nil {
		if u := node.Find("node_uname_info", nil); len(u) > 0 {
			sys.Add("Hostname", u[0].Labels["nodename"])
			sys.Add("Kernel", u[0].Labels["release"])
		}
		if boot, ok := node.Value("node_boot_time_seconds", nil); ok {
			now, ok := node.Value("node_time_seconds", nil)
			if !ok {
				now = float64(time.Now().Unix())
			}
			sys.Add("Uptime", formatDuration(time.Duration(now-boot)*time.Second))
		}
		cores := len(node.Find("node_cpu_seconds_total", map[string]string{"mode": "idle"}))
		if load, ok := node.Value("node_load1", nil); ok {
			v := fmt.Sprintf("%.2f", load)
			if cores > 0 {
				v += fmt.Sprintf(" / %d cores", cores)
			}
			sys.Add("Load (1m)", v)
			summary = append(summary, fmt.Sprintf("load %.1f", load))
		}
		total, okT := node.Value("node_memory_MemTotal_bytes", nil)
		avail, okA := node.Value("node_memory_MemAvailable_bytes", nil)
		if okT && okA && total > 0 {
			used := (total - avail) / total * 100
			status := rack.StatusOK
			if used > 95 {
				status = rack.StatusWarn
			}
			sys.AddStatus("Memory", fmt.Sprintf("%s / %s (%.0f%%)", formatBytes(total-avail), formatBytes(total), used), status)
			summary = append(summary, fmt.Sprintf("mem %.0f%%", used))
		}
		if t := node.Max("node_hwmon_temp_celsius", nil); !math.IsNaN(t) {
			sys.Add("Hottest sensor", formatFloat(t, "°C"))
		}
		if failed := node.Find("node_systemd_unit_state", map[string]string{"state": "failed"}); len(failed) > 0 {
			var names []string
			for _, f := range failed {
				if f.Value == 1 {
					names = append(names, f.Labels["name"])
				}
			}
			if len(names) > 0 {
				sort.Strings(names)
				sys.AddStatus("Failed units", strings.Join(names, ", "), rack.StatusWarn)
				st.Status = rack.StatusWarn
			} else {
				sys.Add("Failed units", "none")
			}
		}
	}
	st.Sections = append(st.Sections, sys)

	if pools := s.zfsPools(node); len(pools.Rows) > 0 {
		st.Sections = append(st.Sections, pools)
		for _, r := range pools.Rows {
			st.Status = rack.Worst(st.Status, r.Status)
		}
	}

	disks := s.disks(node)
	if s.opts.Bays != nil || len(disks) > 0 {
		if smartErr != nil {
			st.Status = rack.Worst(st.Status, rack.StatusWarn)
			st.Error = "smartctl_exporter: " + smartErr.Error()
		}
		used := map[string]bool{}
		if b := s.opts.Bays; b != nil {
			bays := &st.Faceplate[0]
			for i, key := range b.Slots {
				slot := &bays.Slots[i]
				if key == "" {
					continue
				}
				var d *disk
				for j := range disks {
					if disks[j].matches(key) {
						d = &disks[j]
						break
					}
				}
				if d == nil {
					slot.Status = rack.StatusEmpty
					slot.Sections = []rack.Section{{Title: slot.Label, Rows: []rack.Row{{Key: "Mapped to", Value: key}, {Key: "Disk", Value: "none"}}}}
					continue
				}
				used[d.dev] = true
				s.fillDisk(slot, d, smart, key)
			}
			populated := 0
			for _, sl := range bays.Slots {
				if sl.Status != rack.StatusEmpty {
					populated++
				}
			}
			summary = append(summary, fmt.Sprintf("%d/%d bays", populated, len(bays.Slots)))
		}

		// Disks not behind a front bay (NVMe, boot drives, servers without bays).
		internal := rack.Group{ID: "internal", Kind: rack.KindBay, Label: "Internal disks", Rows: 1, Internal: true}
		for i := range disks {
			d := &disks[i]
			if used[d.dev] {
				continue
			}
			slot := rack.Slot{ID: d.dev, Label: d.dev}
			s.fillDisk(&slot, d, smart, "")
			internal.Slots = append(internal.Slots, slot)
		}
		if len(internal.Slots) > 0 {
			st.Faceplate = append(st.Faceplate, internal)
		}
	}

	st.Summary = strings.Join(summary, " · ")
	st.Rollup()
	return st, nil
}

func (s *server) zfsPools(node promtext.Metrics) rack.Section {
	sec := rack.Section{Title: "ZFS pools"}
	states := map[string]string{}
	for _, smp := range node.Find("node_zfs_zpool_state", nil) {
		if smp.Value == 1 {
			states[smp.Labels["zpool"]] = smp.Labels["state"]
		}
	}
	names := make([]string, 0, len(states))
	for n := range states {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		state := states[n]
		status := rack.StatusOK
		switch state {
		case "online":
		case "degraded":
			status = rack.StatusWarn
		default:
			status = rack.StatusCrit
		}
		sec.AddStatus(n, state, status)
	}
	return sec
}

// disks lists the physical disks node_exporter knows, skipping virtual devices.
func (s *server) disks(node promtext.Metrics) []disk {
	var out []disk
	for _, smp := range node.Find("node_disk_info", nil) {
		l := smp.Labels
		dev := l["device"]
		if strings.HasPrefix(dev, "dm-") || strings.HasPrefix(dev, "md") || strings.HasPrefix(dev, "sr") ||
			strings.HasPrefix(dev, "zd") || strings.HasPrefix(dev, "loop") || l["serial"] == "" {
			continue
		}
		d := disk{dev: dev, model: l["model"], serial: l["serial"], path: l["path"], wwn: l["wwn"], rotational: l["rotational"] == "1", phy: -1}
		if m := phyRe.FindStringSubmatch(d.path); m != nil {
			d.phy, _ = strconv.Atoi(m[1])
		}
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].dev < out[j].dev })
	return out
}

// tempLimits picks the warn/crit temperatures for a drive.
func (s *server) tempLimits(dev string, smart promtext.Metrics) (warn, crit float64) {
	info := smart.Find("smartctl_device", map[string]string{"device": dev})
	if len(info) == 0 || info[0].Labels["protocol"] != "NVMe" {
		return s.opts.DiskTempWarn, s.opts.DiskTempCrit
	}
	warn, crit = s.opts.NVMeTempWarn, s.opts.NVMeTempCrit
	limit := func(kind string) float64 {
		v, ok := smart.Value("smartctl_device_temperature", map[string]string{"device": dev, "temperature_type": kind})
		if !ok || v <= 0 {
			return math.Inf(1)
		}
		return v
	}
	return math.Min(warn, limit("op_limit_max")), math.Min(crit, limit("critical_limit_max"))
}

// growth returns how much a counter rose since it was first seen. The baseline
// is in memory, so a restart accepts whatever the counter is at then.
func (s *server) growth(key string, v float64) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.baseline == nil {
		s.baseline = map[string]float64{}
	}
	base, ok := s.baseline[key]
	if !ok || v < base {
		s.baseline[key] = v
		return 0
	}
	return v - base
}

// smartDevice finds the smartctl_exporter device label for a disk. The names
// usually match, but smartctl addresses NVMe drives by controller (nvme0) where
// the kernel names the namespace (nvme0n1), so fall back to the serial.
func smartDevice(d *disk, smart promtext.Metrics) string {
	if len(smart.Find("smartctl_device", map[string]string{"device": d.dev})) > 0 {
		return d.dev
	}
	for _, smp := range smart.Find("smartctl_device", nil) {
		if d.serial != "" && strings.EqualFold(smp.Labels["serial_number"], d.serial) {
			return smp.Labels["device"]
		}
	}
	return ""
}

func (s *server) fillDisk(slot *rack.Slot, d *disk, smart promtext.Metrics, key string) {
	ident := rack.Section{Title: "Disk"}
	ident.Add("Device", "/dev/"+d.dev)
	ident.Add("Model", d.model)
	ident.Add("Serial", d.serial)
	if d.wwn != "" {
		ident.Add("WWN", d.wwn)
	}
	if d.phy >= 0 {
		ident.Add("Expander phy", strconv.Itoa(d.phy))
	}
	if key != "" {
		ident.Add("Mapped by", key)
	}
	if d.rotational {
		ident.Add("Type", "HDD")
	} else {
		ident.Add("Type", "SSD")
	}

	slot.Status = rack.StatusOK
	if smart == nil {
		// Without a SMART source there's nothing to judge; only flag it when
		// one is configured but didn't answer.
		if s.opts.SmartExporter != "" {
			slot.Status = rack.StatusUnknown
		}
		slot.Sections = []rack.Section{ident}
		return
	}

	dev := smartDevice(d, smart)
	m := map[string]string{"device": dev}
	if dev == "" {
		slot.Status = rack.StatusUnknown
		ident.AddStatus("SMART", "no data", rack.StatusUnknown)
		slot.Sections = []rack.Section{ident}
		return
	}
	if info := smart.Find("smartctl_device", m); len(info) > 0 {
		l := info[0].Labels
		if l["firmware_version"] != "" {
			ident.Add("Firmware", l["firmware_version"])
		}
		if l["protocol"] != "" {
			ident.Add("Protocol", l["protocol"])
		}
	}
	if cap, ok := smart.Value("smartctl_device_capacity_bytes", m); ok && cap > 0 {
		ident.Add("Capacity", formatSize(cap))
	}

	health := rack.Section{Title: "SMART"}
	worst := rack.StatusOK
	add := func(k, v string, st rack.Status) {
		health.AddStatus(k, v, st)
		worst = rack.Worst(worst, st)
	}

	if ok, found := smart.Value("smartctl_device_smart_status", m); found {
		if ok == 1 {
			add("Overall", "PASSED", rack.StatusOK)
		} else {
			add("Overall", "FAILED", rack.StatusCrit)
		}
	}
	tm := map[string]string{"device": dev, "temperature_type": "current"}
	if t, ok := smart.Value("smartctl_device_temperature", tm); ok {
		warn, crit := s.tempLimits(dev, smart)
		st := rack.StatusOK
		switch {
		case t >= crit:
			st = rack.StatusCrit
		case t >= warn:
			st = rack.StatusWarn
		}
		add("Temperature", formatFloat(t, "°C"), st)
		slot.Value = formatFloat(t, "°")
	}
	if secs, ok := smart.Value("smartctl_device_power_on_seconds", m); ok {
		add("Power on", fmt.Sprintf("%.0f h (%.1f y)", secs/3600, secs/3600/24/365), rack.StatusOK)
	}
	if v, ok := smart.Value("smartctl_device_power_cycle_count", m); ok {
		add("Power cycles", formatFloat(v, ""), rack.StatusOK)
	}

	// Counters where anything above zero is worth a look.
	// Counters where anything above zero is worth a look, except the
	// growthOnly ones: those are lifetime counts where an old non-zero value
	// is normal and only an increase means something is happening.
	counters := []struct {
		metric, label string
		match         map[string]string
		status        rack.Status
		growthOnly    bool
	}{
		{"smartctl_scsi_grown_defect_list", "Grown defects", nil, rack.StatusWarn, true},
		{"smartctl_read_total_uncorrected_errors", "Uncorrected reads", nil, rack.StatusWarn, false},
		{"smartctl_write_total_uncorrected_errors", "Uncorrected writes", nil, rack.StatusWarn, false},
		{"smartctl_verify_total_uncorrected_errors", "Uncorrected verifies", nil, rack.StatusWarn, false},
		{"smartctl_device_media_errors", "Media errors", nil, rack.StatusWarn, true},
		{"smartctl_device_critical_warning", "Critical warning", nil, rack.StatusCrit, false},
		{"smartctl_device_attribute", "Reallocated sectors", map[string]string{"attribute_name": "Reallocated_Sector_Ct", "attribute_value_type": "raw"}, rack.StatusWarn, true},
		{"smartctl_device_attribute", "Pending sectors", map[string]string{"attribute_name": "Current_Pending_Sector", "attribute_value_type": "raw"}, rack.StatusWarn, false},
		{"smartctl_device_attribute", "Offline uncorrectable", map[string]string{"attribute_name": "Offline_Uncorrectable", "attribute_value_type": "raw"}, rack.StatusWarn, false},
		{"smartctl_device_attribute", "Reported uncorrectable", map[string]string{"attribute_name": "Reported_Uncorrect", "attribute_value_type": "raw"}, rack.StatusWarn, false},
		{"smartctl_device_attribute", "CRC errors", map[string]string{"attribute_name": "UDMA_CRC_Error_Count", "attribute_value_type": "raw"}, rack.StatusWarn, true},
	}
	for _, c := range counters {
		match := map[string]string{"device": dev}
		for k, v := range c.match {
			match[k] = v
		}
		v, ok := smart.Value(c.metric, match)
		if !ok {
			continue
		}
		st := rack.StatusOK
		text := formatFloat(v, "")
		if c.growthOnly {
			if grew := s.growth(d.serial+"/"+c.label, v); grew > 0 {
				st = c.status
				text += fmt.Sprintf(" (+%s since dashboard start)", formatFloat(grew, ""))
			}
		} else if v > 0 {
			st = c.status
		}
		add(c.label, text, st)
	}
	for _, metric := range []string{"smartctl_device_percentage_used", "smartctl_scsi_percentage_used_endurance_indicator"} {
		if v, ok := smart.Value(metric, m); ok {
			st := rack.StatusOK
			if v >= 90 {
				st = rack.StatusWarn
			}
			add("Endurance used", formatFloat(v, "%"), st)
		}
	}
	if v, ok := smart.Value("smartctl_device_self_test_log_error_count", m); ok {
		st := rack.StatusOK
		if v > 0 {
			st = rack.StatusWarn
		}
		add("Self-test errors", formatFloat(v, ""), st)
	}

	// Full ATA attribute table, normalized value against threshold.
	attrs := rack.Section{Title: "ATA attributes"}
	type attr struct {
		id                     int
		name                   string
		value, thresh, raw     float64
		hasValue, hasThreshold bool
	}
	byID := map[string]*attr{}
	for _, smp := range smart.Find("smartctl_device_attribute", m) {
		id := smp.Labels["attribute_id"]
		a := byID[id]
		if a == nil {
			n, _ := strconv.Atoi(id)
			a = &attr{id: n, name: smp.Labels["attribute_name"]}
			byID[id] = a
		}
		switch smp.Labels["attribute_value_type"] {
		case "value":
			a.value, a.hasValue = smp.Value, true
		case "thresh":
			a.thresh, a.hasThreshold = smp.Value, true
		case "raw":
			a.raw = smp.Value
		}
	}
	list := make([]*attr, 0, len(byID))
	for _, a := range byID {
		list = append(list, a)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].id < list[j].id })
	for _, a := range list {
		st := rack.StatusOK
		if a.hasValue && a.hasThreshold && a.thresh > 0 && a.value <= a.thresh {
			st = rack.StatusCrit
			worst = rack.Worst(worst, st)
		}
		attrs.AddStatus(fmt.Sprintf("%d %s", a.id, a.name), fmt.Sprintf("%.0f (thr %.0f) raw %.0f", a.value, a.thresh, a.raw), st)
	}

	slot.Status = worst
	slot.Sections = []rack.Section{health, ident}
	if len(attrs.Rows) > 0 {
		slot.Sections = append(slot.Sections, attrs)
	}
}
