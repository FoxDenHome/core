// Package modules contains one driver per kind of hardware. A module knows how
// to poll its device and what its front looks like; the config only says which
// module sits where and how to reach it.
package modules

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

// Driver is a live instance of a module for one configured device.
type Driver interface {
	// Skeleton is the faceplate before the first poll, all slots unknown.
	Skeleton() rack.State
	Poll(ctx context.Context) (rack.State, error)
}

// Env is shared by all drivers.
type Env struct {
	SNMPCommunity string
	HTTP          *http.Client
}

type Spec struct {
	Name        string
	Description string
	// Height is the default height in U.
	Height int
	New    func(env *Env, dev *config.Device) (Driver, error)
}

var registry = map[string]Spec{}

func register(s Spec) {
	if _, dup := registry[s.Name]; dup {
		panic("duplicate module " + s.Name)
	}
	registry[s.Name] = s
}

func Lookup(name string) (Spec, bool) {
	s, ok := registry[name]
	return s, ok
}

func All() []Spec {
	out := make([]Spec, 0, len(registry))
	for _, s := range registry {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// decodeOptions unmarshals the device's options on top of defaults, so a preset
// only has to set what differs and the config only has to set what it overrides.
func decodeOptions[T any](dev *config.Device, defaults T) (T, error) {
	opts := defaults
	if len(dev.Options) == 0 {
		return opts, nil
	}
	dec := json.NewDecoder(bytes.NewReader(dev.Options))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&opts); err != nil {
		return opts, fmt.Errorf("device %s: options: %w", dev.ID, err)
	}
	return opts, nil
}
