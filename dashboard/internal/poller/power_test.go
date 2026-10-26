package poller

import (
	"strings"
	"testing"

	"github.com/FoxDenHome/core/dashboard/internal/config"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

func pdu(outlets ...rack.Slot) *Device {
	return &Device{ID: "pdu", Name: "pdu", State: rack.State{
		Status:    rack.StatusOK,
		Faceplate: []rack.Group{{ID: "outlets", Kind: rack.KindOutlet, Slots: outlets}},
	}}
}

func TestApplyPower(t *testing.T) {
	src := pdu(
		rack.Slot{ID: "1", Label: "1", Status: rack.StatusOK, Power: rack.Watts(100)},
		rack.Slot{ID: "2", Label: "2", Status: rack.StatusOK, Power: rack.Watts(50.5)},
	)
	srv := &Device{ID: "srv", Name: "srv", State: rack.State{Status: rack.StatusOK, Summary: "load 1.0"}, power: []config.PowerFeed{
		{Device: "pdu", Slot: "1", Label: "PSU 1"},
		{Device: "pdu", Slot: "2", Label: "PSU 2"},
	}}
	applyPower(map[string]*Device{"pdu": src, "srv": srv})

	if srv.State.Summary != "load 1.0 · 150 W" {
		t.Errorf("summary = %q", srv.State.Summary)
	}
	sec := srv.State.Sections[0]
	if sec.Title != "Power" || len(sec.Rows) != 3 || sec.Rows[2].Value != "150.5 W" {
		t.Errorf("power section = %+v", sec)
	}
	if !strings.HasPrefix(sec.Rows[0].Value, "100.0 W") {
		t.Errorf("PSU 1 = %q", sec.Rows[0].Value)
	}
	if got := src.State.FindSlot("1").Sections; len(got) != 1 || got[0].Rows[0].Key != "srv" {
		t.Errorf("outlet not annotated: %+v", got)
	}
}

func TestApplyPowerRedundancyLost(t *testing.T) {
	src := pdu(
		rack.Slot{ID: "1", Label: "1", Status: rack.StatusOK, Power: rack.Watts(100)},
		rack.Slot{ID: "2", Label: "2", Status: rack.StatusOff, Power: rack.Watts(0)},
	)
	srv := &Device{ID: "srv", Name: "srv", State: rack.State{Status: rack.StatusOK}, power: []config.PowerFeed{
		{Device: "pdu", Slot: "1"},
		{Device: "pdu", Slot: "2"},
	}}
	applyPower(map[string]*Device{"pdu": src, "srv": srv})
	if srv.State.Status != rack.StatusWarn {
		t.Errorf("status = %s, want warn", srv.State.Status)
	}
	if r := srv.State.Sections[0].Rows[1]; r.Key != "pdu 2" || r.Status != rack.StatusWarn {
		t.Errorf("off feed row = %+v", r)
	}
}

func TestSnapshotDoesNotLeakPower(t *testing.T) {
	src := pdu(rack.Slot{ID: "1", Label: "1", Status: rack.StatusOK, Power: rack.Watts(5)})
	pi := &Device{ID: "pi", Name: "pi", State: rack.State{Status: rack.StatusOK}, power: []config.PowerFeed{{Device: "pdu", Slot: "1"}}}
	p := &Poller{cfg: &config.Config{}, devices: []*Device{src, pi}}
	for range 3 {
		p.Snapshot()
	}
	if len(pi.State.Sections) != 0 || len(src.State.FindSlot("1").Sections) != 0 {
		t.Errorf("snapshot modified live state")
	}
	snap := p.Snapshot()
	if n := len(snap.Devices[1].State.Sections); n != 1 {
		t.Errorf("snapshot has %d sections, want 1", n)
	}
}
