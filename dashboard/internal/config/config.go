// Package config loads the rack layout: which module sits at which U.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type Duration struct{ time.Duration }

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	d.Duration = v
	return nil
}

type Config struct {
	Listen string `json:"listen"`
	Title  string `json:"title"`
	// Units is the rack height in U.
	Units    int      `json:"units"`
	Interval Duration `json:"interval"`
	Timeout  Duration `json:"timeout"`
	SNMP     SNMP     `json:"snmp"`
	Devices  []Device `json:"devices"`
	// Remote lists sites outside the rack (colo, cloud) whose devices are
	// shown below it. Their devices have no U.
	Remote []Site `json:"remote"`
}

type Site struct {
	Name    string   `json:"name"`
	Devices []Device `json:"devices"`
}

type SNMP struct {
	Community string `json:"community"`
}

type Device struct {
	ID     string `json:"id"`
	Name   string `json:"name,omitempty"`
	Module string `json:"module"`
	// U is the lowest unit the device occupies, counted from the bottom (1-based).
	U int `json:"u,omitempty"`
	// Height in U. Defaults to the module's height.
	Height int `json:"height,omitempty"`
	// Width is the relative width of a device sitting on a shelf. Defaults to 1.
	Width   float64 `json:"width,omitempty"`
	Address string  `json:"address,omitempty"`
	// Options are module specific and override the module's defaults.
	Options json.RawMessage `json:"options,omitempty"`
	// Children sit on this device side by side (only meaningful for shelves).
	Children []Device `json:"children,omitempty"`
}

// Load reads a JSON config. ${VAR} references are expanded from the environment
// so secrets like the SNMP community can stay out of the file.
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{
		Listen:   ":8080",
		Title:    "Rack",
		Units:    42,
		Interval: Duration{15 * time.Second},
		Timeout:  Duration{10 * time.Second},
		SNMP:     SNMP{Community: "public"},
	}
	if err := json.Unmarshal([]byte(os.ExpandEnv(string(raw))), cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	return cfg, nil
}

func (d *Device) DisplayName() string {
	if d.Name != "" {
		return d.Name
	}
	return d.ID
}
