package modules

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/flmon"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// BDT-MIB. The library reuses Dell's storage MIB layout under BDT's
// enterprise number, including Dell's status values.
const bdtGlobalStatus = "1.3.6.1.4.1.20884.10893.2.101.2.1.0"

var bdtStatuses = map[int64]struct {
	text   string
	status rack.Status
}{
	1: {"other", rack.StatusUnknown},
	2: {"unknown", rack.StatusUnknown},
	3: {"ok", rack.StatusOK},
	4: {"non-critical", rack.StatusWarn},
	5: {"critical", rack.StatusCrit},
	6: {"non-recoverable", rack.StatusCrit},
}

// telnetMaxAge is how long telnet data is shown after the monitor stops
// answering. Only one session fits at a time, so every dashboard polling the
// library loses a race now and then.
const telnetMaxAge = 5 * time.Minute

type tapeOptions struct {
	// Telnet is the FLMON monitor's host:port. Defaults to <address>:23, "-"
	// disables it, leaving only the SNMP status.
	Telnet string `json:"telnet"`
	// Drives is how many drives the faceplate shows before the first poll.
	Drives int `json:"drives"`
	// Magazines lists the storage slots of each magazine, left to right.
	Magazines []int `json:"magazines"`
	// CleaningUses is how many cleans a cleaning cartridge is good for.
	CleaningUses int `json:"cleaning_uses"`
}

type tapeLibrary struct {
	env  *Env
	dev  *config.Device
	opts tapeOptions

	counters baseline

	mu   sync.Mutex
	last *tapeData
	// logSeen is the newest error log entry at the first read, so only
	// entries after it count as news.
	logSeen    time.Time
	logSeenSet bool
}

// tapeData is one telnet session's worth of output.
type tapeData struct {
	at       time.Time
	status   flmon.Status
	inv      flmon.Inventory
	fans     map[string]map[int][]string
	retries  map[string]map[int][]string
	adi      map[string]map[int][]string
	activity []flmon.Activity
	log      []flmon.LogEntry
}

func init() {
	register(Spec{
		Name:        "ibm-ts3100",
		Description: "IBM TS3100 / BDT FlexStor II 2U tape library. SNMP status plus inventory, drives and counters from its telnet monitor. Options: telnet, drives, magazines, cleaning_uses.",
		Height:      2,
		New:         newTapeLibrary(tapeOptions{Drives: 2, Magazines: []int{11, 12}}),
	})
}

func newTapeLibrary(defaults tapeOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		if opts.Telnet == "" && dev.Address != "" {
			opts.Telnet = net.JoinHostPort(dev.Address, "23")
		}
		if opts.Telnet == "-" {
			opts.Telnet = ""
		}
		if opts.CleaningUses == 0 {
			opts.CleaningUses = 50
		}
		return &tapeLibrary{env: env, dev: dev, opts: opts}, nil
	}
}

func (t *tapeLibrary) magazineLabel(i int) string {
	switch {
	case len(t.opts.Magazines) == 2 && i == 0:
		return "Left magazine"
	case len(t.opts.Magazines) == 2 && i == 1:
		return "Right magazine"
	}
	return fmt.Sprintf("Magazine %d", i+1)
}

// The faceplate puts the magazines on the left, the left one on top of the
// mail slot (which takes its bottom) and the right one at full height, then
// the status LEDs centered and the drives on the right (they really sit at the
// back). Magazines show how full they are; the only cartridge drawn on its own
// is the one in the mail slot.
func (t *tapeLibrary) Skeleton() rack.State {
	st := rack.State{Status: rack.StatusUnknown}
	mags := rack.Group{ID: "magazines", Kind: rack.KindBay, Label: "Magazines", Rows: 2, Align: "start"}
	for i := range t.opts.Magazines {
		mags.Slots = append(mags.Slots, rack.Slot{ID: fmt.Sprintf("mag%d", i), Label: t.magazineLabel(i), Status: rack.StatusUnknown})
	}
	if len(mags.Slots) == 2 {
		mags.Slots[1].Span = 2
	}
	mags.Slots = append(mags.Slots, rack.Slot{ID: "mail", Label: "Mail slot", Status: rack.StatusUnknown})
	leds := rack.Group{ID: "leds", Kind: rack.KindLED, Label: "Status", Rows: 2, Slots: []rack.Slot{
		{ID: "ready", Label: "Ready", Status: rack.StatusUnknown},
		{ID: "clean", Label: "Clean", Status: rack.StatusUnknown},
		{ID: "attention", Label: "Attn", Status: rack.StatusUnknown},
		{ID: "error", Label: "Error", Status: rack.StatusUnknown},
	}}
	drives := rack.Group{ID: "drives", Kind: rack.KindBay, Label: "Drives", Rows: 2, Align: "end"}
	for i := range t.opts.Drives {
		drives.Slots = append(drives.Slots, rack.Slot{ID: strconv.Itoa(i), Label: fmt.Sprintf("Drive %d", i), Status: rack.StatusUnknown})
	}
	st.Faceplate = []rack.Group{mags, leds, drives}
	return st
}

func (t *tapeLibrary) Poll(ctx context.Context) (rack.State, error) {
	var snmpVals snmp.Values
	var snmpErr error
	var data *tapeData
	var telnetErr error
	var wg sync.WaitGroup
	wg.Go(func() {
		c, err := snmp.Dial(ctx, t.dev.Address, t.env.SNMPCommunity)
		if err != nil {
			snmpErr = err
			return
		}
		defer c.Close()
		snmpVals, snmpErr = c.Get(sysUpTime, bdtGlobalStatus)
	})
	if t.opts.Telnet != "" {
		wg.Go(func() { data, telnetErr = t.telnet(ctx) })
	}
	wg.Wait()
	if snmpErr != nil && (t.opts.Telnet == "" || telnetErr != nil) {
		return rack.State{}, snmpErr
	}

	st := t.Skeleton()
	st.Status = rack.StatusOK
	lib := rack.Section{Title: "Library"}
	var summary []string

	if snmpErr != nil {
		st.Status = rack.StatusWarn
		st.Error = "SNMP: " + snmpErr.Error()
	} else {
		if v, ok := snmpVals.Int(bdtGlobalStatus); ok {
			s, known := bdtStatuses[v]
			if !known {
				s.text, s.status = strconv.FormatInt(v, 10), rack.StatusUnknown
			}
			lib.AddStatus("Global status", s.text, s.status)
			st.Status = rack.Worst(st.Status, s.status)
		}
		if ticks, ok := snmpVals.Int(sysUpTime); ok {
			lib.Add("Uptime", formatDuration(time.Duration(ticks)*10*time.Millisecond))
		}
	}

	t.mu.Lock()
	if data != nil {
		t.last = data
	} else if t.last != nil && time.Since(t.last.at) < telnetMaxAge {
		data = t.last
	}
	t.mu.Unlock()

	if t.opts.Telnet != "" && data == nil {
		st.Status = rack.Worst(st.Status, rack.StatusWarn)
		st.Error = strings.TrimPrefix(st.Error+"; ", "; ") + "telnet: " + telnetErr.Error()
		st.Sections = []rack.Section{lib}
		return st, nil
	}
	if data == nil {
		st.Sections = []rack.Section{lib}
	} else {
		if telnetErr != nil {
			// Usually the other router's session; the data is still recent.
			lib.Add("Details from", formatDuration(time.Since(data.at))+" ago ("+telnetErr.Error()+")")
		}
		summary = t.fill(&st, &lib, data)
	}
	st.Summary = strings.Join(summary, " · ")
	st.Rollup()
	return st, nil
}

// telnet reads everything from the monitor in one session, retrying once if
// another session holds it.
func (t *tapeLibrary) telnet(ctx context.Context) (*tapeData, error) {
	s, err := flmon.Dial(ctx, t.opts.Telnet)
	if errors.Is(err, flmon.ErrBusy) {
		select {
		case <-time.After(time.Duration(500+rand.IntN(1500)) * time.Millisecond):
		case <-ctx.Done():
			return nil, err
		}
		s, err = flmon.Dial(ctx, t.opts.Telnet)
	}
	if err != nil {
		return nil, err
	}
	defer s.Close()

	d := &tapeData{at: time.Now()}
	run := func(cmd string) string {
		if err != nil {
			return ""
		}
		var out string
		out, err = s.Run(cmd)
		return out
	}
	d.status = flmon.ParseStatus(run("stat"))
	d.inv = flmon.ParseInventory(run("inv"))
	d.fans = flmon.Table(run("fst"))
	d.retries = flmon.Table(run("rets"))
	d.adi = flmon.Table(run("adir"))
	for i := range d.status.Drives {
		d.activity = append(d.activity, flmon.ParseActivity(run(fmt.Sprintf("dra %d", i))))
	}
	d.log = flmon.ParseLog(run("edp"))
	if err != nil {
		return nil, err
	}
	return d, nil
}

// fill draws the faceplate and sections from telnet data and returns the
// summary parts.
func (t *tapeLibrary) fill(st *rack.State, lib *rack.Section, d *tapeData) []string {
	l := d.status.Library
	add := func(sec *rack.Section, key, field string) {
		if v := l[field]; v != "" {
			sec.Add(key, v)
		}
	}
	lib.Add("Model", strings.TrimSpace(l["Vendor ID"]+" "+l["Product ID"]))
	add(lib, "Serial", "Serial Number")
	if fw := l["Firmware Revision"]; fw != "" {
		if built := l["Firmware Build date"]; built != "" {
			fw += " (" + built + ")"
		}
		lib.Add("Firmware", fw)
	}
	add(lib, "Robotics firmware", "Robotic FW Revision")
	add(lib, "Bootcode", "Bootcode Revision")
	add(lib, "Power-ups", "Number of Powerups")
	if mins, err := strconv.ParseFloat(strings.Fields(l["Minutes of Operation"] + " x")[0], 64); err == nil {
		lib.Add("Operating time", fmt.Sprintf("%s (%.1f y)", formatDuration(time.Duration(mins)*time.Minute), mins/60/24/365))
	}
	if v := d.inv.Settings["Lib 0 Loader mode"]; v != "" {
		lib.Add("Loader mode", v)
	}
	if v := d.inv.Settings["Autoclean"]; v != "" {
		lib.Add("Autoclean", v)
	}
	if v := l["Inventory valid"]; v != "" {
		s := rack.StatusOK
		if v != "Yes" {
			s = rack.StatusWarn
		}
		lib.AddStatus("Inventory valid", v, s)
	}
	add(lib, "Barcode reader", "Barcode Reader")

	// Front panel LEDs.
	leds := &st.Faceplate[1]
	for i := range leds.Slots {
		s := &leds.Slots[i]
		on := l[map[string]string{"ready": "Ready", "clean": "Clean", "attention": "Attention", "error": "Error"}[s.ID]]
		switch {
		case on == "":
			s.Status = rack.StatusUnknown
		case on != "On" && s.ID == "ready":
			s.Status = rack.StatusWarn
		case on != "On":
			s.Status = rack.StatusOff
		case s.ID == "ready":
			s.Status = rack.StatusOK
		case s.ID == "error":
			s.Status = rack.StatusCrit
		default:
			s.Status = rack.StatusWarn
		}
		s.Value = strings.ToLower(on)
	}

	// Storage slots, in magazine order.
	var slots, drives []flmon.Element
	var mail *flmon.Element
	for _, e := range d.inv.Elements {
		switch e.Kind {
		case "Slot":
			slots = append(slots, e)
		case "Drive":
			drives = append(drives, e)
		case "Mailslot":
			mail = &e
		}
	}
	sort.Slice(slots, func(i, j int) bool { return slots[i].Number < slots[j].Number })
	full, data, cleaning := 0, 0, 0
	rest := slots
	for i, size := range t.opts.Magazines {
		var in []flmon.Element
		if i == len(t.opts.Magazines)-1 {
			size = len(rest)
		}
		in, rest = rest[:min(size, len(rest))], rest[min(size, len(rest)):]
		f, dc, cc := t.fillMagazine(st.FindSlot(fmt.Sprintf("mag%d", i)), in, d)
		full, data, cleaning = full+f, data+dc, cleaning+cc
	}
	if m := st.FindSlot("mail"); mail != nil {
		t.fillSlot(m, *mail, d)
	} else {
		m.Status = rack.StatusEmpty
	}

	inv := rack.Section{Title: "Inventory"}
	inv.Add("Slots used", fmt.Sprintf("%d / %d", full, len(slots)))
	inv.Add("Data cartridges", strconv.Itoa(data))
	inv.Add("Cleaning cartridges", strconv.Itoa(cleaning))

	dg := &st.Faceplate[2]
	for i := range dg.Slots {
		// Bays the library doesn't report a drive for.
		dg.Slots[i].Status = rack.StatusEmpty
	}
	loaded := 0
	for i, f := range d.status.Drives {
		if i >= len(dg.Slots) {
			dg.Slots = append(dg.Slots, rack.Slot{ID: strconv.Itoa(i), Label: fmt.Sprintf("Drive %d", i)})
		}
		slot := &dg.Slots[i]
		var e flmon.Element
		for _, x := range drives {
			if x.Number == i {
				e = x
			}
		}
		if e.Full() {
			loaded++
		}
		t.fillDrive(slot, i, f, e, d)
	}
	inv.Add("Drives loaded", fmt.Sprintf("%d / %d", loaded, len(d.status.Drives)))

	robot := rack.Section{Title: "Robotics"}
	add(&robot, "Move count", "Move count")
	if v := l["Robotics Temperature"]; v != "" {
		robot.Add("Temperature", v+"°C")
	}
	add(&robot, "Connection speed", "Robotic Conn. Speed")
	sumRetries := func(section string) (usage, retries float64) {
		for _, row := range d.retries[section] {
			if len(row) >= 2 {
				u, _ := strconv.ParseFloat(row[0], 64)
				r, _ := strconv.ParseFloat(row[1], 64)
				usage += u
				retries += r
			}
		}
		return
	}
	for _, c := range []struct{ section, label string }{{"Slot", "Slot"}, {"Drive", "Drive"}, {"Transp.", "Transport"}, {"Motor", "Motor"}} {
		if _, ok := d.retries[c.section]; !ok {
			continue
		}
		usage, retries := sumRetries(c.section)
		s := rack.StatusOK
		text := fmt.Sprintf("%s moves, %s retries", formatFloat(usage, ""), formatFloat(retries, ""))
		if grew := t.counters.growth("retries/"+c.section, retries); grew > 0 {
			s = rack.StatusWarn
			text += fmt.Sprintf(" (+%s since dashboard start)", formatFloat(grew, ""))
		}
		robot.AddStatus(c.label+" moves", text, s)
	}

	st.Sections = []rack.Section{*lib, inv, robot}
	if errs := t.errorLog(d.log); len(errs.Rows) > 0 {
		st.Sections = append(st.Sections, errs)
	}
	for _, sec := range st.Sections {
		for _, r := range sec.Rows {
			st.Status = rack.Worst(st.Status, r.Status)
		}
	}

	return []string{fmt.Sprintf("%d/%d drives loaded", loaded, len(d.status.Drives)), fmt.Sprintf("%d/%d slots", full, len(slots))}
}

func mediumName(m string) string {
	kind, gen, _ := strings.Cut(m, " ")
	switch kind {
	case "Data":
		return "LTO-" + gen + " data"
	case "Clean":
		return "cleaning"
	}
	return m
}

// volser is the cartridge's volume serial: the barcode without its media suffix.
func volser(barcode string) string {
	if len(barcode) == 8 {
		return barcode[:6]
	}
	return barcode
}

// fillMagazine sums up a magazine and lists its cartridges. It returns the
// slots in use and how many hold data and cleaning cartridges.
func (t *tapeLibrary) fillMagazine(s *rack.Slot, slots []flmon.Element, d *tapeData) (full, data, cleaning int) {
	carts := rack.Section{Title: "Cartridges"}
	status := rack.StatusOK
	loads := 0
	for _, e := range slots {
		var c rack.Slot
		t.fillSlot(&c, e, d)
		text := "empty"
		if e.Full() {
			full++
			if e.Cleaning() {
				cleaning++
			} else {
				data++
			}
			text = e.Barcode + " · " + mediumName(e.Medium)
			if e.Loads >= 0 {
				loads += e.Loads
				if e.Cleaning() {
					text += fmt.Sprintf(" · %d/%d uses", e.Loads, t.opts.CleaningUses)
				} else {
					text += fmt.Sprintf(" · %d loads", e.Loads)
				}
			}
		}
		if e.Exceptions != "" {
			text += " · " + e.Exceptions
		}
		st := c.Status
		if st == rack.StatusEmpty {
			st = rack.StatusOff
		}
		carts.AddStatus(fmt.Sprintf("Slot %d", e.Number), text, st)
		status = rack.Worst(status, c.Status)
	}
	sum := rack.Section{Title: "Magazine"}
	sum.Add("Slots used", fmt.Sprintf("%d / %d", full, len(slots)))
	sum.Add("Data cartridges", strconv.Itoa(data))
	sum.Add("Cleaning cartridges", strconv.Itoa(cleaning))
	sum.Add("Cartridge loads", strconv.Itoa(loads))
	if len(slots) > 0 {
		sum.Add("Slots", fmt.Sprintf("%d–%d", slots[0].Number, slots[len(slots)-1].Number))
	}
	s.Status = status
	s.Value = fmt.Sprintf("%d/%d", full, len(slots))
	if len(slots) == 0 {
		s.Status = rack.StatusEmpty
	}
	s.Sections = []rack.Section{sum, carts}
	return
}

func (t *tapeLibrary) fillSlot(s *rack.Slot, e flmon.Element, d *tapeData) {
	sec := rack.Section{Title: "Cartridge"}
	sec.Add("Element", strconv.Itoa(e.Address))
	if !e.Full() {
		s.Status = rack.StatusEmpty
		sec.Add("Cartridge", "none")
	} else {
		s.Status = rack.StatusOK
		s.Value = volser(e.Barcode)
		sec.Add("Barcode", e.Barcode)
		sec.Add("Type", mediumName(e.Medium))
		if e.Loads >= 0 {
			if e.Cleaning() {
				st := rack.StatusOK
				if e.Loads >= t.opts.CleaningUses {
					st = rack.StatusWarn
				}
				sec.AddStatus("Uses", fmt.Sprintf("%d / %d", e.Loads, t.opts.CleaningUses), st)
				s.Status = rack.Worst(s.Status, st)
			} else {
				sec.Add("Loads", strconv.Itoa(e.Loads))
			}
		}
	}
	if !e.Access {
		sec.AddStatus("Accessible", "no", rack.StatusWarn)
		s.Status = rack.Worst(s.Status, rack.StatusWarn)
	}
	if e.Exceptions != "" {
		sec.AddStatus("Exceptions", e.Exceptions, rack.StatusWarn)
		s.Status = rack.StatusWarn
	}
	if row := d.retries["Slot"][e.Number]; len(row) >= 2 {
		sec.Add("Robot visits", row[0])
		r, _ := strconv.ParseFloat(row[1], 64)
		st := rack.StatusOK
		text := row[1]
		if grew := t.counters.growth(fmt.Sprintf("slot/%d", e.Number), r); grew > 0 {
			st = rack.StatusWarn
			text += fmt.Sprintf(" (+%s since dashboard start)", formatFloat(grew, ""))
		}
		sec.AddStatus("Move retries", text, st)
		if st != rack.StatusOK {
			// Worst would also turn an empty slot ok.
			s.Status = rack.Worst(s.Status, st)
		}
	}
	s.Sections = []rack.Section{sec}
}

func (t *tapeLibrary) fillDrive(s *rack.Slot, i int, f flmon.Fields, e flmon.Element, d *tapeData) {
	s.Status = rack.StatusOK
	drive := rack.Section{Title: "Drive"}
	drive.Add("Model", strings.TrimSpace(f["Vendor ID"]+" "+f["Product ID"]))
	drive.Add("Serial", f["Serial number"])
	drive.Add("Firmware", f["Firmware Revision"])
	if v := f["Interface type"]; v != "" {
		drive.Add("Interface", v)
	}
	if i < len(d.activity) {
		a := d.activity[i]
		drive.Add("Activity", a.Activity)
		if len(a.Flags) > 0 {
			drive.Add("Flags", strings.Join(a.Flags, ", "))
		}
		for _, flag := range a.Flags {
			if flag == "ATT" {
				drive.AddStatus("Attention", "drive needs attention", rack.StatusWarn)
				s.Status = rack.StatusWarn
			}
		}
	}
	if e.Full() {
		drive.Add("Loaded", e.Barcode)
	} else {
		drive.Add("Loaded", "none")
	}

	temp := f["Drive Temperature"]
	if row := d.fans["Drive"][i]; len(row) >= 6 {
		if temp == "" {
			temp = row[5]
		}
		drive.Add("Fan", fmt.Sprintf("speed %s, cooling %s (%s), monitoring %s", row[0], strings.ToLower(row[1]), row[2], row[3]))
	}
	if v, err := strconv.ParseFloat(temp, 64); err == nil {
		drive.Add("Temperature", formatFloat(v, "°C"))
		s.Value = formatFloat(v, "°")
	}

	usage := rack.Section{Title: "Usage"}
	for _, k := range []string{"Media loads", "Cleaning operations", "Power on hours", "Media motion hours"} {
		if v := f[k]; v != "" {
			usage.Add(k, v)
		}
	}
	if m, err := strconv.ParseFloat(f["Tape meters"], 64); err == nil {
		usage.Add("Tape moved", fmt.Sprintf("%.0f km", m/1000))
	}
	if row := d.retries["Drive"][i]; len(row) >= 2 {
		usage.Add("Robot loads", row[0])
		r, _ := strconv.ParseFloat(row[1], 64)
		st := rack.StatusOK
		if t.counters.growth(fmt.Sprintf("drive/%d", i), r) > 0 {
			st = rack.StatusWarn
			s.Status = rack.StatusWarn
		}
		usage.AddStatus("Load retries", row[1], st)
	}

	ports := rack.Section{Title: "Host ports"}
	for _, p := range []string{"A", "B"} {
		pre := "Port " + p + " "
		if f[pre+"Identifier"] == "" {
			continue
		}
		text := f[pre+"Link"]
		if v := f[pre+"Speed"]; v != "" && v != "-" {
			text += ", " + v
		}
		st := rack.StatusOK
		if f[pre+"Link"] != "Connected" {
			st = rack.StatusOff
		}
		ports.AddStatus("Port "+p, text, st)
		ports.Add("Port "+p+" WWN", f[pre+"Identifier"])
	}
	if row := d.adi["Drive"][i]; len(row) >= 4 {
		ports.Add("ADI retries", fmt.Sprintf("rx %s, tx %s, logouts %s, logins %s", row[0], row[1], row[2], row[3]))
	}

	s.Sections = []rack.Section{drive, usage}
	if len(ports.Rows) > 0 {
		s.Sections = append(s.Sections, ports)
	}
}

// errorLog lists the newest entries. Entries newer than the newest one seen at
// the first read are flagged.
func (t *tapeLibrary) errorLog(log []flmon.LogEntry) rack.Section {
	sec := rack.Section{Title: "Error log"}
	t.mu.Lock()
	if !t.logSeenSet {
		t.logSeenSet = true
		if len(log) > 0 {
			t.logSeen = log[0].Time
		}
	}
	seen := t.logSeen
	t.mu.Unlock()
	for i, e := range log {
		if i == 5 {
			sec.Add("…", fmt.Sprintf("%d older entries", len(log)-i))
			break
		}
		st := rack.StatusOK
		if e.Time.After(seen) {
			st = rack.StatusWarn
		}
		sec.AddStatus(e.Time.Format("2006-01-02 15:04"), e.Message, st)
	}
	return sec
}
