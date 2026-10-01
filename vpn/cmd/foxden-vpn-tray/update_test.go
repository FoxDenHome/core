package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
)

func TestUpdater(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "foxden-vpn-tray")
	_ = os.WriteFile(bin, []byte("v1"), 0o755)
	var execs int
	u := &updater{ownBuild: buildid.File(bin), path: bin, exec: func(string) error { execs++; return nil }}

	u.check(&api.Status{Build: "d1"})
	u.check(&api.Status{Build: "d1"})
	if execs != 0 {
		t.Fatal("restarted without an update")
	}
	u.check(&api.Status{Build: "d2"}) // daemon updated, tray binary unchanged
	if execs != 0 {
		t.Fatal("restarted although the tray binary did not change")
	}
	_ = os.WriteFile(bin, []byte("v2"), 0o755)
	u.check(&api.Status{Build: "d2"}) // same daemon build: not a new signal
	if execs != 0 {
		t.Fatal("restarted without a daemon change")
	}
	u.check(&api.Status{Build: "d3"})
	if execs != 1 {
		t.Fatalf("execs = %d, want 1", execs)
	}
	u.check(&api.Status{}) // old daemon without build IDs
	if execs != 1 {
		t.Fatal("restarted on a status without build ID")
	}
}
