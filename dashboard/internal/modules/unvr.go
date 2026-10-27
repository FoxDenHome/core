package modules

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
	"github.com/gosnmp/gosnmp"
)

// UCD-SNMP-MIB, which the UNVR's net-snmp agent serves.
const (
	ucdMemTotalReal = "1.3.6.1.4.1.2021.4.5.0"
	ucdMemAvailReal = "1.3.6.1.4.1.2021.4.6.0"
	ucdMemBuffer    = "1.3.6.1.4.1.2021.4.14.0"
	ucdMemCached    = "1.3.6.1.4.1.2021.4.15.0"
	ucdLoad1        = "1.3.6.1.4.1.2021.10.1.3.1"
	ucdLoad5        = "1.3.6.1.4.1.2021.10.1.3.2"
	ucdLoad15       = "1.3.6.1.4.1.2021.10.1.3.3"

	ucdDiskIODevice  = "1.3.6.1.4.1.2021.13.15.1.1.2"
	ucdDiskIOReads   = "1.3.6.1.4.1.2021.13.15.1.1.5"
	ucdDiskIOWrites  = "1.3.6.1.4.1.2021.13.15.1.1.6"
	ucdDiskIONReadX  = "1.3.6.1.4.1.2021.13.15.1.1.12"
	ucdDiskIONWriteX = "1.3.6.1.4.1.2021.13.15.1.1.13"

	lmTempName  = "1.3.6.1.4.1.2021.13.16.2.1.2"
	lmTempValue = "1.3.6.1.4.1.2021.13.16.2.1.3"
	lmFanName   = "1.3.6.1.4.1.2021.13.16.3.1.2"
	lmFanValue  = "1.3.6.1.4.1.2021.13.16.3.1.3"
	lmVoltName  = "1.3.6.1.4.1.2021.13.16.4.1.2"
	lmVoltValue = "1.3.6.1.4.1.2021.13.16.4.1.3"
)

// Only whole disks and RAID arrays; the agent also lists partitions, mtd
// and loop devices.
var unvrIODevice = regexp.MustCompile(`^(sd[a-z]+|md\d+)$`)

type unvrOptions struct {
	// Controller defaults to https://<address>. The UniFi user only needs
	// to see Protect; api_key_env defaults to NVR_API_KEY because an API
	// key is per console.
	unifiOptions
	Bays         int     `json:"bays"`
	DiskTempWarn float64 `json:"disk_temp_warn"`
	DiskTempCrit float64 `json:"disk_temp_crit"`
}

type unvr struct {
	env    *Env
	dev    *config.Device
	opts   unvrOptions
	client *unifiClient

	counters baseline

	mu   sync.Mutex
	prev map[string]diskIO
	at   time.Time
}

type diskIO struct {
	reads, writes, readBytes, writeBytes uint64
}

func init() {
	register(Spec{
		Name:        "unifi-unvr",
		Description: "UniFi UNVR (4 bays). Disks, RAID and cameras from the Protect API, sensors and disk I/O over SNMP. Options: controller, api_key_env or username_env/password_env, insecure, bays, disk_temp_warn/crit.",
		Height:      1,
		New: newUNVR(unvrOptions{
			unifiOptions: unifiOptions{
				APIKeyEnv:   "NVR_API_KEY",
				UsernameEnv: unifiDefaults.UsernameEnv,
				PasswordEnv: unifiDefaults.PasswordEnv,
			},
			Bays: 4,
			// The UNVR runs its disks warmer than a server chassis.
			DiskTempWarn: 55,
			DiskTempCrit: 60,
		}),
	})
}

func newUNVR(defaults unvrOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		if opts.Controller == "" && dev.Address != "" {
			opts.Controller = "https://" + dev.Address
		}
		client, err := newUnifiConsole(env, opts.unifiOptions)
		if err != nil {
			return nil, fmt.Errorf("device %s: %w", dev.ID, err)
		}
		return &unvr{env: env, dev: dev, opts: opts, client: client}, nil
	}
}

func (n *unvr) Skeleton() rack.State {
	bays := rack.Group{ID: "bays", Kind: rack.KindBay, Label: "Drive bays", Rows: 1}
	for i := 1; i <= n.opts.Bays; i++ {
		bays.Slots = append(bays.Slots, rack.Slot{ID: strconv.Itoa(i), Label: fmt.Sprintf("Bay %d", i), Status: rack.StatusUnknown})
	}
	return rack.State{Status: rack.StatusUnknown, Faceplate: []rack.Group{bays}}
}

// protectNVR is the part of /proxy/protect/api/nvr shown here.
type protectNVR struct {
	Version         string  `json:"version"`
	FirmwareVersion string  `json:"firmwareVersion"`
	MarketName      string  `json:"marketName"`
	UpSince         int64   `json:"upSince"`
	HardDriveState  string  `json:"hardDriveState"`
	CorruptionState string  `json:"corruptionState"`
	IsRecycling     bool    `json:"isRecycling"`
	CameraUtil      *int    `json:"cameraUtilization"`
	IsRecordingOff  bool    `json:"isRecordingDisabled"`
	HQBytesPerDay   float64 `json:"totalHqBytesPerDay"`
	LQBytesPerDay   float64 `json:"totalLqBytesPerDay"`
	ErrorCode       *string `json:"errorCode"`
	SystemInfo      struct {
		CPU struct {
			AverageLoad float64 `json:"averageLoad"`
			Temperature float64 `json:"temperature"`
		} `json:"cpu"`
		Storage struct {
			Size       float64 `json:"size"`
			Used       float64 `json:"used"`
			Type       string  `json:"type"`
			Capability string  `json:"capability"`
		} `json:"storage"`
		UStorage struct {
			RAID     string `json:"raid"`
			HotSpare bool   `json:"hotspare"`
			Disks    []struct {
				Slot        int      `json:"slot"`
				Type        string   `json:"type"`
				Model       string   `json:"model"`
				Size        float64  `json:"size"`
				Serial      string   `json:"serial"`
				Firmware    string   `json:"firmware"`
				RPM         int      `json:"rpm"`
				SATA        string   `json:"sata"`
				Action      string   `json:"action"`
				Healthy     string   `json:"healthy"`
				State       string   `json:"state"`
				Reason      []string `json:"reason"`
				Temperature *float64 `json:"temperature"`
				PowerOnHrs  *float64 `json:"poweronhrs"`
				BadSector   *float64 `json:"bad_sector"`
				Progress    *float64 `json:"progress"`
			} `json:"disks"`
			Space []struct {
				Device    string   `json:"device"`
				Health    string   `json:"health"`
				Total     float64  `json:"total_bytes"`
				Used      float64  `json:"used_bytes"`
				Action    string   `json:"action"`
				Progress  *float64 `json:"progress"`
				Estimate  *float64 `json:"estimate"`
				SpaceType string   `json:"space_type"`
				Reasons   []string `json:"reasons"`
			} `json:"space"`
		} `json:"ustorage"`
	} `json:"systemInfo"`
}

type protectCamera struct {
	Name  string `json:"name"`
	State string `json:"state"`
	Type  string `json:"type"`
}

func (n *unvr) Poll(ctx context.Context) (rack.State, error) {
	var nvr protectNVR
	var cams []protectCamera
	var apiErr, camErr, snmpErr error
	var v snmp.Values
	var cols map[string]map[string]gosnmp.SnmpPDU
	var wg sync.WaitGroup
	wg.Go(func() { apiErr = n.client.getJSON(ctx, "/proxy/protect/api/nvr", &nvr) })
	wg.Go(func() { camErr = n.client.getJSON(ctx, "/proxy/protect/integration/v1/cameras", &cams) })
	wg.Go(func() { v, cols, snmpErr = n.snmp(ctx) })
	wg.Wait()
	if apiErr != nil && snmpErr != nil {
		return rack.State{}, fmt.Errorf("protect: %v; snmp: %v", apiErr, snmpErr)
	}

	st := n.Skeleton()
	st.Status = rack.StatusOK
	var errs, summary []string
	sys := rack.Section{Title: "System"}

	if apiErr != nil {
		errs = append(errs, "protect: "+apiErr.Error())
		st.Status = rack.StatusWarn
	} else {
		sys.Add("Model", nvr.MarketName)
		sys.Add("UniFi OS", nvr.FirmwareVersion)
		sys.Add("Protect", nvr.Version)
		if nvr.UpSince > 0 {
			sys.Add("Uptime", formatDuration(time.Since(time.UnixMilli(nvr.UpSince))))
		}
		cpu := nvr.SystemInfo.CPU
		sys.Add("CPU load", formatFloat(cpu.AverageLoad, "%"))
		sys.Add("CPU temperature", formatFloat(cpu.Temperature, "°C"))
		if nvr.ErrorCode != nil && *nvr.ErrorCode != "" {
			sys.AddStatus("Error", *nvr.ErrorCode, rack.StatusWarn)
		}
		summary = append(summary, n.storage(&st, &nvr)...)
	}

	// System first, then the storage section from above.
	st.Sections = append([]rack.Section{sys}, st.Sections...)
	if snmpErr != nil {
		errs = append(errs, "snmp: "+snmpErr.Error())
		st.Status = rack.Worst(st.Status, rack.StatusWarn)
	} else {
		summary = append(n.system(&st.Sections[0], v, apiErr == nil), summary...)
		for _, sec := range []rack.Section{n.diskIO(cols), n.sensors(cols)} {
			if len(sec.Rows) > 0 {
				st.Sections = append(st.Sections, sec)
			}
		}
	}

	if camErr != nil {
		errs = append(errs, "cameras: "+camErr.Error())
	} else if len(cams) > 0 {
		sec := rack.Section{Title: "Cameras"}
		sort.Slice(cams, func(i, j int) bool { return cams[i].Name < cams[j].Name })
		up := 0
		for _, c := range cams {
			s := rack.StatusOK
			if c.State == "CONNECTED" {
				up++
			} else {
				s = rack.StatusWarn
			}
			sec.AddStatus(c.Name, strings.TrimPrefix(c.Type, "UVC ")+" · "+strings.ToLower(c.State), s)
		}
		if apiErr == nil && nvr.CameraUtil != nil {
			sec.Add("Capacity used", fmt.Sprintf("%d%%", *nvr.CameraUtil))
		}
		st.Sections = append(st.Sections, sec)
		summary = append(summary, fmt.Sprintf("%d/%d cams", up, len(cams)))
	}

	for _, sec := range st.Sections {
		for _, r := range sec.Rows {
			st.Status = rack.Worst(st.Status, r.Status)
		}
	}
	st.Error = strings.Join(errs, "; ")
	st.Summary = strings.Join(summary, " · ")
	st.Rollup()
	return st, nil
}

// storage fills the bays and the storage meter and adds the storage section.
func (n *unvr) storage(st *rack.State, nvr *protectNVR) []string {
	us := nvr.SystemInfo.UStorage
	bays := &st.Faceplate[0]
	for i := range bays.Slots {
		bays.Slots[i].Status = rack.StatusEmpty
	}
	present := 0
	for _, d := range us.Disks {
		if d.Slot < 1 || d.Slot > len(bays.Slots) {
			continue
		}
		slot := &bays.Slots[d.Slot-1]
		if d.Model == "" && d.Serial == "" {
			continue
		}
		present++
		disk := rack.Section{Title: "Disk"}
		disk.Add("Model", d.Model)
		disk.Add("Serial", d.Serial)
		disk.Add("Firmware", d.Firmware)
		disk.Add("Capacity", formatSize(d.Size))
		kind := d.Type
		if d.RPM > 0 {
			kind += fmt.Sprintf(", %d rpm", d.RPM)
		}
		if d.SATA != "" {
			kind += ", " + d.SATA
		}
		disk.Add("Type", kind)

		health := rack.Section{Title: "Health"}
		worst := rack.StatusOK
		add := func(k, v string, s rack.Status) {
			health.AddStatus(k, v, s)
			worst = rack.Worst(worst, s)
		}
		s := rack.StatusOK
		switch d.Healthy {
		case "good":
		case "warning":
			s = rack.StatusWarn
		default:
			s = rack.StatusCrit
		}
		add("Health", d.Healthy, s)
		s = rack.StatusOK
		if d.State != "normal" {
			s = rack.StatusWarn
		}
		add("State", d.State, s)
		if len(d.Reason) > 0 {
			add("Reason", strings.Join(d.Reason, ", "), rack.StatusWarn)
		}
		if d.Action != "" && d.Action != "none" {
			text := d.Action
			if d.Progress != nil {
				text += fmt.Sprintf(" (%.0f%%)", *d.Progress)
			}
			add("Action", text, rack.StatusWarn)
		}
		if t := d.Temperature; t != nil {
			s := rack.StatusOK
			switch {
			case *t >= n.opts.DiskTempCrit:
				s = rack.StatusCrit
			case *t >= n.opts.DiskTempWarn:
				s = rack.StatusWarn
			}
			add("Temperature", formatFloat(*t, "°C"), s)
			slot.Value = formatFloat(*t, "°")
		}
		if h := d.PowerOnHrs; h != nil {
			add("Power on", fmt.Sprintf("%.0f h (%.1f y)", *h, *h/24/365), rack.StatusOK)
		}
		if b := d.BadSector; b != nil {
			s, text := rack.StatusOK, formatFloat(*b, "")
			if grew := n.counters.growth(d.Serial+"/bad sectors", *b); grew > 0 {
				s = rack.StatusWarn
				text += fmt.Sprintf(" (+%s since dashboard start)", formatFloat(grew, ""))
			}
			add("Bad sectors", text, s)
		}
		slot.Status = worst
		slot.Sections = []rack.Section{health, disk}
	}

	sec := rack.Section{Title: "Storage"}
	raid := strings.ToUpper(us.RAID)
	if us.HotSpare {
		raid += " + hot spare"
	}
	sec.Add("Array", raid)
	for _, sp := range us.Space {
		if sp.SpaceType != "primary" {
			continue
		}
		s := rack.StatusOK
		if sp.Health != "health" {
			s = rack.StatusCrit
		}
		text := sp.Health
		if text == "health" {
			text = "healthy"
		}
		sec.AddStatus("Array health", text+" ("+sp.Device+")", s)
		if sp.Action != "" && sp.Action != "none" {
			text := sp.Action
			if sp.Progress != nil {
				text += fmt.Sprintf(" %.0f%%", *sp.Progress)
			}
			if sp.Estimate != nil && *sp.Estimate > 0 {
				text += ", " + formatDuration(time.Duration(*sp.Estimate)*time.Second) + " left"
			}
			sec.AddStatus("Array action", text, rack.StatusWarn)
		}
		if len(sp.Reasons) > 0 {
			sec.AddStatus("Array reasons", strings.Join(sp.Reasons, ", "), rack.StatusWarn)
		}
	}
	if v := nvr.HardDriveState; v != "" {
		s := rack.StatusOK
		if v != "ok" {
			s = rack.StatusWarn
		}
		sec.AddStatus("Disk state", v, s)
	}
	if v := nvr.CorruptionState; v != "" {
		s := rack.StatusOK
		if v != "healthy" {
			s = rack.StatusWarn
		}
		sec.AddStatus("Recording database", v, s)
	}

	sto := nvr.SystemInfo.Storage
	if sto.Size > 0 {
		// Always nearly full: the NVR overwrites the oldest footage.
		sec.Add("Used", fmt.Sprintf("%s / %s (%.0f%%)", formatSize(sto.Used), formatSize(sto.Size), sto.Used/sto.Size*100))
	}
	if nvr.IsRecycling {
		sec.Add("Recycling", "yes, oldest footage is overwritten")
	}
	if perDay := nvr.HQBytesPerDay + nvr.LQBytesPerDay; perDay > 0 {
		sec.Add("Recording", fmt.Sprintf("%s/day (HQ %s, LQ %s)", formatSize(perDay), formatSize(nvr.HQBytesPerDay), formatSize(nvr.LQBytesPerDay)))
		if sto.Used > 0 {
			sec.Add("Retention (est.)", fmt.Sprintf("%.0f days", sto.Used/perDay))
		}
	}
	if nvr.IsRecordingOff {
		sec.AddStatus("Recording", "disabled", rack.StatusWarn)
	}
	st.Sections = append(st.Sections, sec)
	return []string{fmt.Sprintf("%d/%d bays", present, len(bays.Slots))}
}

func (n *unvr) snmp(ctx context.Context) (snmp.Values, map[string]map[string]gosnmp.SnmpPDU, error) {
	c, err := snmp.Dial(ctx, n.dev.Address, n.env.SNMPCommunity)
	if err != nil {
		return nil, nil, err
	}
	defer c.Close()
	v, err := c.Get(sysUpTime, ucdMemTotalReal, ucdMemAvailReal, ucdMemBuffer, ucdMemCached, ucdLoad1, ucdLoad5, ucdLoad15)
	if err != nil {
		return nil, nil, err
	}
	cols := map[string]map[string]gosnmp.SnmpPDU{}
	for _, root := range []string{
		ucdDiskIODevice, ucdDiskIOReads, ucdDiskIOWrites, ucdDiskIONReadX, ucdDiskIONWriteX,
		lmTempName, lmTempValue, lmFanName, lmFanValue, lmVoltName, lmVoltValue,
	} {
		col, err := c.Column(root)
		if err != nil {
			return nil, nil, err
		}
		cols[root] = col
	}
	return v, cols, nil
}

// system adds load and memory, and uptime when Protect didn't give one. It
// returns the summary parts, worded like the server module's.
func (n *unvr) system(sys *rack.Section, v snmp.Values, haveAPI bool) []string {
	var summary []string
	if ticks, ok := v.Int(sysUpTime); ok && !haveAPI {
		sys.Add("Uptime", formatDuration(time.Duration(ticks)*10*time.Millisecond))
	}
	if l1 := v.String(ucdLoad1); l1 != "" {
		sys.Add("Load", fmt.Sprintf("%s / %s / %s", l1, v.String(ucdLoad5), v.String(ucdLoad15)))
		if load, err := strconv.ParseFloat(l1, 64); err == nil {
			summary = append(summary, fmt.Sprintf("load %.1f", load))
		}
	}
	total, okT := v.Int(ucdMemTotalReal)
	avail, okA := v.Int(ucdMemAvailReal)
	if okT && okA && total > 0 {
		buf, _ := v.Int(ucdMemBuffer)
		cached, _ := v.Int(ucdMemCached)
		used := float64(total-avail-buf-cached) * 1024
		pct := used / float64(total*1024) * 100
		sys.Add("Memory", fmt.Sprintf("%s / %s (%.0f%%)", formatBytes(used), formatBytes(float64(total)*1024), pct))
		summary = append(summary, fmt.Sprintf("mem %.0f%%", pct))
	}
	return summary
}

// lmRows pairs an lmSensors name column with its value column.
func lmRows(cols map[string]map[string]gosnmp.SnmpPDU, nameCol, valueCol string) [][2]any {
	idx := make([]int, 0, len(cols[nameCol]))
	for k := range cols[nameCol] {
		i, _ := strconv.Atoi(k)
		idx = append(idx, i)
	}
	sort.Ints(idx)
	var out [][2]any
	for _, i := range idx {
		k := strconv.Itoa(i)
		val, ok := snmp.Int(cols[valueCol][k])
		if !ok {
			continue
		}
		out = append(out, [2]any{snmp.String(cols[nameCol][k]), val})
	}
	return out
}

func (n *unvr) sensors(cols map[string]map[string]gosnmp.SnmpPDU) rack.Section {
	sec := rack.Section{Title: "Sensors"}
	for _, r := range lmRows(cols, lmTempName, lmTempValue) {
		sec.Add(r[0].(string), formatFloat(float64(r[1].(int64))/1000, "°C"))
	}
	for _, r := range lmRows(cols, lmFanName, lmFanValue) {
		sec.Add(r[0].(string), fmt.Sprintf("%d rpm", r[1].(int64)))
	}
	for _, r := range lmRows(cols, lmVoltName, lmVoltValue) {
		sec.Add(r[0].(string), fmt.Sprintf("%.2f V", float64(r[1].(int64))/1000))
	}
	return sec
}

// diskIO reports per-disk throughput since the last poll.
func (n *unvr) diskIO(cols map[string]map[string]gosnmp.SnmpPDU) rack.Section {
	now := time.Now()
	cur := map[string]diskIO{}
	for idx, pdu := range cols[ucdDiskIODevice] {
		name := snmp.String(pdu)
		if !unvrIODevice.MatchString(name) {
			continue
		}
		var d diskIO
		d.reads, _ = snmp.Uint(cols[ucdDiskIOReads][idx])
		d.writes, _ = snmp.Uint(cols[ucdDiskIOWrites][idx])
		d.readBytes, _ = snmp.Uint(cols[ucdDiskIONReadX][idx])
		d.writeBytes, _ = snmp.Uint(cols[ucdDiskIONWriteX][idx])
		cur[name] = d
	}
	n.mu.Lock()
	prev, dt := n.prev, now.Sub(n.at).Seconds()
	n.prev, n.at = cur, now
	n.mu.Unlock()

	names := make([]string, 0, len(cur))
	for name := range cur {
		names = append(names, name)
	}
	// Disks first, then arrays.
	sort.Slice(names, func(i, j int) bool {
		if (names[i][0] == 'm') != (names[j][0] == 'm') {
			return names[j][0] == 'm'
		}
		return names[i] < names[j]
	})
	sec := rack.Section{Title: "Disk I/O"}
	for _, name := range names {
		d := cur[name]
		old, ok := prev[name]
		if !ok || dt <= 0 || d.readBytes < old.readBytes || d.writeBytes < old.writeBytes {
			sec.Add(name, fmt.Sprintf("read %s, written %s total", formatBytes(float64(d.readBytes)), formatBytes(float64(d.writeBytes))))
			continue
		}
		rate := func(a, b uint64) float64 { return float64(a-b) / dt }
		text := fmt.Sprintf("read %s/s, write %s/s", formatBytes(rate(d.readBytes, old.readBytes)), formatBytes(rate(d.writeBytes, old.writeBytes)))
		// The op counts are 32-bit and wrap.
		if d.reads >= old.reads && d.writes >= old.writes {
			text += fmt.Sprintf(" · %.0f / %.0f IOPS", rate(d.reads, old.reads), rate(d.writes, old.writes))
		}
		sec.Add(name, text)
	}
	return sec
}
