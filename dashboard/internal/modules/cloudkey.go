package modules

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// The Cloud Key has no SNMP agent, so everything comes from the console's
// own /api/system plus the Network app's sysinfo. Its HDD bay and battery
// are deliberately ignored: ours has neither.
type cloudKeyOptions struct {
	// Controller defaults to https://<address>.
	unifiOptions
	CPUTempWarn float64 `json:"cpu_temp_warn"`
	CPUTempCrit float64 `json:"cpu_temp_crit"`
	MemWarn     float64 `json:"mem_warn"`
	StorageWarn float64 `json:"storage_warn"`
}

type cloudKey struct {
	opts   cloudKeyOptions
	client *unifiClient
}

func init() {
	register(Spec{
		Name:        "unifi-cloud-key-gen2-plus",
		Description: "UniFi Cloud Key Gen2 Plus (UCK-G2-PLUS), via the UniFi OS and Network APIs; HDD and battery are not reported. Options: controller, api_key_env or username_env/password_env, insecure, cpu_temp_warn/crit, mem_warn, storage_warn (percent).",
		Height:      1,
		New: newCloudKey(cloudKeyOptions{
			unifiOptions: unifiDefaults,
			CPUTempWarn:  70,
			CPUTempCrit:  80,
			MemWarn:      90,
			StorageWarn:  90,
		}),
	})
}

func newCloudKey(defaults cloudKeyOptions) func(*Env, *config.Device) (Driver, error) {
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
		return &cloudKey{opts: opts, client: client}, nil
	}
}

func (k *cloudKey) Skeleton() rack.State {
	return rack.State{
		Status: rack.StatusUnknown,
		Faceplate: []rack.Group{{ID: "leds", Kind: rack.KindLED, Label: "Status", Rows: 1, Slots: []rack.Slot{
			{ID: "console", Label: "Console", Status: rack.StatusUnknown},
			{ID: "network", Label: "Network", Status: rack.StatusUnknown},
			{ID: "internet", Label: "Internet", Status: rack.StatusUnknown},
		}}},
	}
}

// uosSystem is the part of UniFi OS /api/system shown here.
type uosSystem struct {
	Name     string `json:"name"`
	Hardware struct {
		Name     string `json:"name"`
		Firmware string `json:"firmwareVersion"`
		Serial   string `json:"serialno"`
	} `json:"hardware"`
	UcoreVersion string    `json:"ucore_version"`
	Uptime       flexFloat `json:"uptime"`
	DeviceState  string    `json:"deviceState"`
	DeviceError  *string   `json:"deviceErrorCode"`
	HasInternet  *bool     `json:"hasInternet"`
	CPU          struct {
		// CurrentLoad is a 0..1 fraction.
		CurrentLoad *float64 `json:"currentload"`
		Temperature *float64 `json:"temperature"`
	} `json:"cpu"`
	// Memory is in KiB.
	Memory struct {
		Total     float64 `json:"total"`
		Available float64 `json:"available"`
	} `json:"memory"`
	// Storage is the internal eMMC only; the HDD bay lives in ustorage.
	Storage []struct {
		Type       string  `json:"type"`
		MountPoint string  `json:"mountPoint"`
		Size       float64 `json:"size"`
		Used       float64 `json:"used"`
	} `json:"storage"`
	Wans []struct {
		Interface string `json:"interface"`
		Plugged   bool   `json:"plugged"`
		SpeedType string `json:"speedType"`
	} `json:"wans"`
	Devices struct {
		UnifiOS []struct {
			MAC            string `json:"mac"`
			IsConsole      bool   `json:"isConsole"`
			FirmwareStatus string `json:"firmwareStatus"`
		} `json:"unifiOS"`
	} `json:"devices"`
	Apps struct {
		Controllers []uosApp `json:"controllers"`
		Apps        []uosApp `json:"apps"`
	} `json:"apps"`
	MAC string `json:"mac"`
}

type uosApp struct {
	Name            string `json:"name"`
	Version         string `json:"version"`
	IsInstalled     bool   `json:"isInstalled"`
	IsRunning       bool   `json:"isRunning"`
	Status          string `json:"status"`
	ControllerState string `json:"controllerStatus"`
	UpdateAvailable *struct {
		Version string `json:"version"`
	} `json:"updateAvailable"`
}

type networkSysinfo struct {
	Data []struct {
		Version         string `json:"version"`
		UpdateAvailable bool   `json:"update_available"`
	} `json:"data"`
}

func (k *cloudKey) Poll(ctx context.Context) (rack.State, error) {
	var sys uosSystem
	var info networkSysinfo
	var sysErr, infoErr error
	var wg sync.WaitGroup
	wg.Go(func() { sysErr = k.client.getJSON(ctx, "/api/system", &sys) })
	wg.Go(func() {
		infoErr = k.client.getJSON(ctx, "/proxy/network/api/s/"+k.opts.Site+"/stat/sysinfo", &info)
	})
	wg.Wait()
	if sysErr != nil {
		return rack.State{}, sysErr
	}

	st := k.Skeleton()
	leds := st.Faceplate[0].Slots
	var summary []string

	sec := rack.Section{Title: "System"}
	sec.Add("Model", sys.Hardware.Name)
	sec.Add("Name", sys.Name)
	sec.Add("Serial", strings.ToUpper(sys.Hardware.Serial))
	fw := sys.Hardware.Firmware
	for _, d := range sys.Devices.UnifiOS {
		if d.IsConsole && strings.EqualFold(d.MAC, sys.MAC) && d.FirmwareStatus != "" && d.FirmwareStatus != "upToDate" {
			fw += " (" + d.FirmwareStatus + ")"
		}
	}
	sec.Add("UniFi OS", fw)
	sec.Add("Core", sys.UcoreVersion)
	if sys.Uptime > 0 {
		sec.Add("Uptime", formatDuration(time.Duration(float64(sys.Uptime)*float64(time.Second))))
	}
	console := rack.StatusOK
	if sys.DeviceState != "" && sys.DeviceState != "setup" {
		console = rack.StatusWarn
		sec.AddStatus("State", sys.DeviceState, console)
	}
	if sys.DeviceError != nil && *sys.DeviceError != "" {
		console = rack.StatusCrit
		sec.AddStatus("Error", *sys.DeviceError, console)
	}
	if l := sys.CPU.CurrentLoad; l != nil {
		sec.Add("CPU load", formatFloat(*l*100, "%"))
		summary = append(summary, fmt.Sprintf("cpu %.0f%%", *l*100))
	}
	if t := sys.CPU.Temperature; t != nil {
		s := rack.StatusOK
		switch {
		case *t >= k.opts.CPUTempCrit:
			s = rack.StatusCrit
		case *t >= k.opts.CPUTempWarn:
			s = rack.StatusWarn
		}
		sec.AddStatus("CPU temperature", formatFloat(*t, "°C"), s)
		console = rack.Worst(console, s)
	}
	if m := sys.Memory; m.Total > 0 {
		used := (m.Total - m.Available) * 1024
		pct := used / (m.Total * 1024) * 100
		s := rack.StatusOK
		if pct >= k.opts.MemWarn {
			s = rack.StatusWarn
		}
		sec.AddStatus("Memory", fmt.Sprintf("%s / %s (%.0f%%)", formatBytes(used), formatBytes(m.Total*1024), pct), s)
		console = rack.Worst(console, s)
		summary = append(summary, fmt.Sprintf("mem %.0f%%", pct))
	}
	for _, d := range sys.Storage {
		if d.Size <= 0 {
			continue
		}
		pct := d.Used / d.Size * 100
		s := rack.StatusOK
		if pct >= k.opts.StorageWarn {
			s = rack.StatusWarn
		}
		label := "Storage"
		if d.Type != "" {
			label += " (" + d.Type + ")"
		}
		sec.AddStatus(label, fmt.Sprintf("%s / %s (%.0f%%)", formatSize(d.Used), formatSize(d.Size), pct), s)
		console = rack.Worst(console, s)
	}
	for _, w := range sys.Wans {
		s, text := rack.StatusOK, w.SpeedType
		if !w.Plugged {
			s, text = rack.StatusCrit, "unplugged"
		}
		sec.AddStatus("Link "+w.Interface, text, s)
		console = rack.Worst(console, s)
	}
	leds[0].Status = console

	// Not reported: leave the LED dark rather than unknown.
	inet := rack.StatusOff
	if sys.HasInternet != nil {
		inet = rack.StatusOK
		text := "yes"
		if !*sys.HasInternet {
			inet, text = rack.StatusWarn, "no"
		}
		sec.AddStatus("Internet", text, inet)
	}
	leds[2].Status = inet

	apps := rack.Section{Title: "Applications"}
	network := rack.StatusUnknown
	for _, a := range append(sys.Apps.Controllers, sys.Apps.Apps...) {
		if !a.IsInstalled {
			continue
		}
		s := rack.StatusOK
		text := a.Version
		if !a.IsRunning {
			s, text = rack.StatusCrit, text+" · stopped"
		} else if a.Status != "" && a.Status != "ok" {
			s, text = rack.StatusWarn, text+" · "+a.Status
		}
		if a.UpdateAvailable != nil && a.UpdateAvailable.Version != "" {
			text += " (update: " + a.UpdateAvailable.Version + ")"
		}
		apps.AddStatus(titleCase(a.Name), text, s)
		if a.Name == "network" {
			network = s
		}
	}
	if infoErr != nil {
		network = rack.Worst(network, rack.StatusWarn)
		apps.AddStatus("Network API", infoErr.Error(), rack.StatusWarn)
	} else if len(info.Data) > 0 && info.Data[0].UpdateAvailable {
		apps.Add("Network update", "available")
	}
	leds[1].Status = network

	st.Sections = []rack.Section{sec}
	if len(apps.Rows) > 0 {
		st.Sections = append(st.Sections, apps)
	}
	st.Status = rack.StatusOK
	for _, s := range st.Sections {
		for _, r := range s.Rows {
			st.Status = rack.Worst(st.Status, r.Status)
		}
	}
	st.Summary = strings.Join(summary, " · ")
	st.Rollup()
	return st, nil
}

func titleCase(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
