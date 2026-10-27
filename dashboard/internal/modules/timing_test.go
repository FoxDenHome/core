package modules

import (
	"os"
	"testing"

	"github.com/FoxDenHome/core/dashboard/internal/promtext"
	"github.com/FoxDenHome/core/dashboard/internal/rack"
)

func rowsOf(t timing, title string) map[string]rack.Row {
	out := map[string]rack.Row{}
	for _, sec := range t.sections {
		if sec.Title == title {
			for _, r := range sec.Rows {
				out[r.Key] = r
			}
		}
	}
	return out
}

func TestTimingState(t *testing.T) {
	f, err := os.Open("testdata/ntpi.prom")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	node, err := promtext.Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	ts := timingState(node)
	if ts.status != rack.StatusOK {
		t.Errorf("status = %s", ts.status)
	}

	sync := rowsOf(ts, "Time sync")
	if r := sync["Reference"]; r.Value != "PPS" {
		t.Errorf("reference = %+v", r)
	}
	if r := sync["RMS offset"]; r.Value != "1.3 µs" {
		t.Errorf("rms offset = %+v", r)
	}

	src := rowsOf(ts, "Time sources")
	if r := src["PPS (refclock)"]; r.Status != rack.StatusOK || r.Value[:8] != "selected" {
		t.Errorf("PPS = %+v", r)
	}
	// GPS is noselect: chrony calls it unreachable, but it's delivering.
	if r := src["GPS (refclock)"]; r.Status != rack.StatusOK || r.Value[:14] != "not selectable" {
		t.Errorf("GPS = %+v", r)
	}

	gnss := rowsOf(ts, "GNSS")
	if r := gnss["Satellites"]; r.Value != "10 used / 19 visible" || r.Status != rack.StatusOK {
		t.Errorf("satellites = %+v", r)
	}
	if r := gnss["Fix"]; r.Value != "3D fix, time only (surveyed)" {
		t.Errorf("fix = %+v", r)
	}
	if r := gnss["GPS"]; r.Value != "6 used / 11 visible" {
		t.Errorf("GPS constellation = %+v", r)
	}

	if len(ts.groups) != 2 || ts.groups[0].ID != "timing" || ts.groups[1].ID != "satellites" {
		t.Fatalf("groups = %+v", ts.groups)
	}
	var labels []string
	for _, s := range ts.groups[0].Slots {
		labels = append(labels, s.Label)
	}
	if len(labels) != 3 || labels[0] != "GPS" || labels[1] != "Sync" || labels[2] != "PPS" {
		t.Errorf("timing LEDs = %v", labels)
	}
	sats := ts.groups[1].Slots
	if len(sats) != 13 || sats[0].Status != rack.StatusOK || sats[len(sats)-1].Status != rack.StatusOff {
		t.Errorf("satellite meters: %d, first %+v, last %+v", len(sats), sats[0], sats[len(sats)-1])
	}
}

func TestFormatSeconds(t *testing.T) {
	for v, want := range map[float64]string{
		-4.3e-8:  "-43 ns",
		1.304e-6: "1.3 µs",
		0.0706:   "70.60 ms",
		2:        "2.000 s",
		0:        "0 s",
	} {
		if got := formatSeconds(v); got != want {
			t.Errorf("formatSeconds(%v) = %q, want %q", v, got, want)
		}
	}
}
