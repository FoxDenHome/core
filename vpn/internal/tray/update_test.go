package tray

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/buildid"
)

func TestUpdater(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "foxden-vpnd")
	_ = os.WriteFile(bin, []byte("v1"), 0o755)
	v1 := buildid.File(bin)
	var execs []string
	u := &updater{ownBuild: v1, args: []string{"tray"}, exec: func(path string, args []string) error {
		if !slices.Equal(args, []string{"tray"}) {
			t.Errorf("args = %q", args)
		}
		execs = append(execs, path)
		return nil
	}}

	u.check(&api.Status{Build: v1, Executable: bin})
	u.check(&api.Status{}) // a daemon from before lock step
	if len(execs) != 0 {
		t.Fatal("restarted while in step")
	}

	// An install is under way: the daemon restarted before its file was
	// written, or the file is newer than the running daemon.
	_ = os.WriteFile(bin, []byte("v2"), 0o755)
	v2 := buildid.File(bin)
	u.check(&api.Status{Build: "other", Executable: bin})
	if len(execs) != 0 {
		t.Fatal("restarted into a file that is not the daemon's build")
	}

	// The daemon runs what is on disk: follow it. A restart that fails is
	// undone and not tried again for that build.
	var undone int
	u.handoff = func() func() { return func() { undone++ } }
	u.exec = func(path string, _ []string) error { execs = append(execs, path); return os.ErrPermission }
	u.check(&api.Status{Build: v2, Executable: bin})
	u.check(&api.Status{Build: v2, Executable: bin})
	if len(execs) != 1 || execs[0] != bin || undone != 1 {
		t.Fatalf("execs = %q, undone %d; want one attempt, undone", execs, undone)
	}

	// A tray-only change: the daemon restarts with a build that differs
	// from ours only because of tray code.
	_ = os.WriteFile(bin, []byte("v3"), 0o755)
	u.exec = func(path string, _ []string) error { execs = append(execs, path); return nil }
	u.check(&api.Status{Build: buildid.File(bin), Executable: bin})
	if len(execs) != 2 {
		t.Fatal("did not follow a daemon whose build differs from ours")
	}
}
