package modules

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
	"github.com/FoxDenHome/core/dashboard/internal/snmp"
)

// UPS-MIB (RFC 1628)
const (
	upsIdentManufacturer   = "1.3.6.1.2.1.33.1.1.1.0"
	upsIdentModel          = "1.3.6.1.2.1.33.1.1.2.0"
	upsIdentFirmware       = "1.3.6.1.2.1.33.1.1.3.0"
	upsIdentAgentFirmware  = "1.3.6.1.2.1.33.1.1.4.0"
	upsIdentSerial         = "1.3.6.1.2.1.33.1.1.5.0"
	upsBatteryStatus       = "1.3.6.1.2.1.33.1.2.1.0"
	upsSecondsOnBattery    = "1.3.6.1.2.1.33.1.2.2.0"
	upsMinutesRemaining    = "1.3.6.1.2.1.33.1.2.3.0"
	upsChargeRemaining     = "1.3.6.1.2.1.33.1.2.4.0"
	upsBatteryVoltage      = "1.3.6.1.2.1.33.1.2.5.0"
	upsBatteryTemperature  = "1.3.6.1.2.1.33.1.2.7.0"
	upsInputFrequency      = "1.3.6.1.2.1.33.1.3.3.1.2.1"
	upsInputVoltage        = "1.3.6.1.2.1.33.1.3.3.1.3.1"
	upsOutputSource        = "1.3.6.1.2.1.33.1.4.1.0"
	upsOutputFrequency     = "1.3.6.1.2.1.33.1.4.2.0"
	upsOutputVoltage       = "1.3.6.1.2.1.33.1.4.4.1.2.1"
	upsOutputCurrent       = "1.3.6.1.2.1.33.1.4.4.1.3.1"
	upsOutputPower         = "1.3.6.1.2.1.33.1.4.4.1.4.1"
	upsOutputPercentLoad   = "1.3.6.1.2.1.33.1.4.4.1.5.1"
	upsAlarmsPresent       = "1.3.6.1.2.1.33.1.6.1.0"
	upsConfigOutputVA      = "1.3.6.1.2.1.33.1.9.5.0"
	upsConfigOutputPowerW  = "1.3.6.1.2.1.33.1.9.6.0"
	upsCurrentScaleTenths  = 10.0
	upsVoltageScaleTenths  = 10.0
	upsFrequencyScaleTenth = 10.0
)

type upsOptions struct {
	// LoadWarn is the output load percentage that turns the UPS yellow.
	LoadWarn float64 `json:"load_warn"`
	// ChargeWarn is the battery charge percentage below which the UPS turns yellow.
	ChargeWarn float64 `json:"charge_warn"`
	// ATS is an optional transfer switch feeding this UPS. Its source is shown
	// on the UPS since it has no slot of its own.
	ATS *atsOptions `json:"ats"`
}

type ups struct {
	env  *Env
	dev  *config.Device
	opts upsOptions
}

func init() {
	register(Spec{
		Name:        "ups-rfc1628",
		Description: "Any UPS speaking the standard UPS-MIB (RFC 1628) over SNMP. Options: load_warn, charge_warn, ats {model, address}.",
		Height:      2,
		New:         newUPS(upsOptions{}),
	})
	register(Spec{
		Name:        "eaton-5px-2u",
		Description: "Eaton 5PX G2 2U with Network-M2/M3 card (UPS-MIB). Options as ups-rfc1628.",
		Height:      2,
		New:         newUPS(upsOptions{}),
	})
}

func newUPS(defaults upsOptions) func(*Env, *config.Device) (Driver, error) {
	return func(env *Env, dev *config.Device) (Driver, error) {
		opts, err := decodeOptions(dev, defaults)
		if err != nil {
			return nil, err
		}
		if opts.LoadWarn == 0 {
			opts.LoadWarn = 80
		}
		if opts.ChargeWarn == 0 {
			opts.ChargeWarn = 90
		}
		if opts.ATS != nil {
			if err := opts.ATS.validate(); err != nil {
				return nil, fmt.Errorf("device %s: ats: %w", dev.ID, err)
			}
		}
		return &ups{env: env, dev: dev, opts: opts}, nil
	}
}

func (u *ups) Skeleton() rack.State {
	st := rack.State{
		Status: rack.StatusUnknown,
		Faceplate: []rack.Group{
			{ID: "meters", Kind: rack.KindMeter, Rows: 2, Slots: []rack.Slot{
				{ID: "battery", Label: "Battery", Status: rack.StatusUnknown},
				{ID: "load", Label: "Load", Status: rack.StatusUnknown},
			}},
			{ID: "output", Kind: rack.KindLED, Label: "Output", Rows: 3, Slots: []rack.Slot{
				{ID: "line", Label: "Line", Status: rack.StatusUnknown},
				{ID: "battery", Label: "Battery", Status: rack.StatusUnknown},
				{ID: "bypass", Label: "Bypass", Status: rack.StatusUnknown},
			}},
		},
	}
	if u.opts.ATS != nil {
		st.Faceplate = append(st.Faceplate, u.opts.ATS.skeleton())
	}
	return st
}

var upsOutputSources = map[int64]string{
	1: "other", 2: "none", 3: "normal", 4: "bypass", 5: "battery", 6: "booster", 7: "reducer",
}

var upsBatteryStatuses = map[int64]string{1: "unknown", 2: "normal", 3: "low", 4: "depleted"}

func (u *ups) Poll(ctx context.Context) (rack.State, error) {
	c, err := snmp.Dial(ctx, u.dev.Address, u.env.SNMPCommunity)
	if err != nil {
		return rack.State{}, err
	}
	defer c.Close()
	v, err := c.Get(
		upsIdentManufacturer, upsIdentModel, upsIdentFirmware, upsIdentAgentFirmware, upsIdentSerial,
		upsBatteryStatus, upsSecondsOnBattery, upsMinutesRemaining, upsChargeRemaining, upsBatteryVoltage, upsBatteryTemperature,
		upsInputFrequency, upsInputVoltage,
		upsOutputSource, upsOutputFrequency, upsOutputVoltage, upsOutputCurrent, upsOutputPower, upsOutputPercentLoad,
		upsAlarmsPresent, upsConfigOutputVA, upsConfigOutputPowerW,
	)
	if err != nil {
		return rack.State{}, err
	}

	st := u.Skeleton()
	st.Status = rack.StatusOK
	meters, leds := &st.Faceplate[0], &st.Faceplate[1]

	battery := rack.Section{Title: "Battery"}
	output := rack.Section{Title: "Output"}
	input := rack.Section{Title: "Input"}
	ident := rack.Section{Title: "Identity"}
	var summary []string

	bs, _ := v.Int(upsBatteryStatus)
	bStatus := rack.StatusOK
	switch bs {
	case 3:
		bStatus = rack.StatusWarn
	case 4:
		bStatus = rack.StatusCrit
	case 1:
		bStatus = rack.StatusUnknown
	}
	battery.AddStatus("Status", upsBatteryStatuses[bs], bStatus)

	if charge, ok := v.Int(upsChargeRemaining); ok {
		cs := rack.Worst(bStatus)
		if float64(charge) < u.opts.ChargeWarn {
			cs = rack.Worst(cs, rack.StatusWarn)
		}
		meters.Slots[0] = rack.Slot{ID: "battery", Label: "Battery", Status: cs, Value: fmt.Sprintf("%d%%", charge), Percent: rack.Percent(float64(charge))}
		battery.AddStatus("Charge", fmt.Sprintf("%d%%", charge), cs)
	}
	if mins, ok := v.Int(upsMinutesRemaining); ok {
		battery.Add("Runtime", formatDuration(time.Duration(mins)*time.Minute))
		summary = append(summary, formatDuration(time.Duration(mins)*time.Minute))
	}
	if volts, ok := v.Int(upsBatteryVoltage); ok {
		battery.Add("Voltage", formatFloat(float64(volts)/upsVoltageScaleTenths, " V"))
	}
	if temp, ok := v.Int(upsBatteryTemperature); ok {
		battery.Add("Temperature", fmt.Sprintf("%d°C", temp))
	}
	onBatt, _ := v.Int(upsSecondsOnBattery)
	if onBatt > 0 {
		battery.AddStatus("On battery for", formatDuration(time.Duration(onBatt)*time.Second), rack.StatusWarn)
	}

	src, _ := v.Int(upsOutputSource)
	output.Add("Source", upsOutputSources[src])
	srcStatus := map[string]rack.Status{"line": rack.StatusOff, "battery": rack.StatusOff, "bypass": rack.StatusOff}
	switch src {
	case 3, 6, 7:
		srcStatus["line"] = rack.StatusOK
	case 5:
		srcStatus["battery"] = rack.StatusWarn
		st.Status = rack.StatusWarn
	case 4:
		srcStatus["bypass"] = rack.StatusWarn
		st.Status = rack.StatusWarn
	case 2:
		st.Status = rack.StatusCrit
	}
	for i := range leds.Slots {
		leds.Slots[i].Status = srcStatus[leds.Slots[i].ID]
	}

	if load, ok := v.Int(upsOutputPercentLoad); ok {
		ls := rack.StatusOK
		if float64(load) >= u.opts.LoadWarn {
			ls = rack.StatusWarn
		}
		meters.Slots[1] = rack.Slot{ID: "load", Label: "Load", Status: ls, Value: fmt.Sprintf("%d%%", load), Percent: rack.Percent(float64(load))}
		output.AddStatus("Load", fmt.Sprintf("%d%%", load), ls)
	}
	if w, ok := v.Int(upsOutputPower); ok {
		rated, _ := v.Int(upsConfigOutputPowerW)
		val := fmt.Sprintf("%d W", w)
		if rated > 0 {
			val += fmt.Sprintf(" / %d W", rated)
		}
		output.Add("Power", val)
		summary = append([]string{fmt.Sprintf("%d W", w)}, summary...)
	}
	if volts, ok := v.Int(upsOutputVoltage); ok {
		output.Add("Voltage", fmt.Sprintf("%d V", volts))
	}
	if amps, ok := v.Int(upsOutputCurrent); ok {
		output.Add("Current", formatFloat(float64(amps)/upsCurrentScaleTenths, " A"))
	}
	if hz, ok := v.Int(upsOutputFrequency); ok {
		output.Add("Frequency", formatFloat(float64(hz)/upsFrequencyScaleTenth, " Hz"))
	}
	if volts, ok := v.Int(upsInputVoltage); ok {
		input.Add("Voltage", fmt.Sprintf("%d V", volts))
	}
	if hz, ok := v.Int(upsInputFrequency); ok {
		input.Add("Frequency", formatFloat(float64(hz)/upsFrequencyScaleTenth, " Hz"))
	}
	if alarms, ok := v.Int(upsAlarmsPresent); ok {
		as := rack.StatusOK
		if alarms > 0 {
			as = rack.StatusWarn
		}
		output.AddStatus("Active alarms", fmt.Sprint(alarms), as)
	}

	ident.Add("Manufacturer", v.String(upsIdentManufacturer))
	ident.Add("Model", v.String(upsIdentModel))
	ident.Add("Serial", v.String(upsIdentSerial))
	ident.Add("Firmware", v.String(upsIdentFirmware))
	ident.Add("Agent firmware", v.String(upsIdentAgentFirmware))
	if va, ok := v.Int(upsConfigOutputVA); ok {
		ident.Add("Rating", fmt.Sprintf("%d VA", va))
	}

	st.Sections = []rack.Section{output, battery, input}

	if u.opts.ATS != nil {
		group, sec, atsSummary, err := u.opts.ATS.poll(ctx, u.env)
		st.Faceplate[2] = group
		if err != nil {
			st.Status = rack.Worst(st.Status, rack.StatusWarn)
			st.Error = "ATS: " + err.Error()
		} else {
			st.Sections = append(st.Sections, sec)
			summary = append(summary, atsSummary)
		}
	}

	st.Sections = append(st.Sections, ident)
	st.Summary = strings.Join(summary, " · ")
	st.Rollup()
	return st, nil
}
