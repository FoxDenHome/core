package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
)

// fakeMounts is a daemon that remembers mounts.
type fakeMounts struct {
	mu     sync.Mutex
	mounts map[string]string // path -> share
	log    []string
}

func (f *fakeMounts) client(t *testing.T) *api.Client {
	sock := filepath.Join(t.TempDir(), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(api.Status{Provisioned: true, Shares: []api.Share{{Name: "share"}, {Name: "dori", Home: true}}})
	})
	mux.HandleFunc("GET /v1/mounts", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		out := []api.Mount{}
		for p, s := range f.mounts {
			out = append(out, api.Mount{Source: "//nas/" + s, Path: p, Transport: "SMB Direct"})
		}
		_ = json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /v1/mounts", func(w http.ResponseWriter, r *http.Request) {
		var req api.MountRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		f.mu.Lock()
		f.mounts[req.Path] = req.Share
		f.log = append(f.log, "mount "+req.Share+" "+req.Path)
		f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(api.Mount{Path: req.Path, Transport: "SMB Direct"})
	})
	mux.HandleFunc("POST /v1/mounts/unmount", func(w http.ResponseWriter, r *http.Request) {
		var req api.MountRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		f.mu.Lock()
		delete(f.mounts, req.Path)
		f.log = append(f.log, "unmount "+req.Path)
		f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(struct{}{})
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return api.NewClient(sock)
}

// fakeNotes records progress notifications as "start: …" and "done: …".
type fakeNotes struct{ log []string }

type fakeNote struct{ n *fakeNotes }

func (n fakeNote) done(msg string) { n.n.log = append(n.n.log, "done: "+msg) }

func (f *fakeNotes) progress(_, msg string) note {
	f.log = append(f.log, "start: "+msg)
	return fakeNote{f}
}

func newTestShares(t *testing.T, f *fakeMounts, cfg string, picks *[]string) *shares {
	tr := &tray{client: f.client(t), ui: newUI()}
	tr.last, _ = tr.client.Status()
	s := newShares(tr)
	s.file = cfg
	s.state = map[string]shareState{}
	s.load()
	s.pick = func(string, string) (string, error) {
		if len(*picks) == 0 {
			return "", nil // cancelled
		}
		p := (*picks)[0]
		*picks = (*picks)[1:]
		return p, nil
	}
	return s
}

func TestSharesToggleAndRemount(t *testing.T) {
	home := t.TempDir()
	nonEmpty := filepath.Join(home, "Stuff")
	_ = os.MkdirAll(filepath.Join(nonEmpty, "old"), 0o755)
	cfg := filepath.Join(t.TempDir(), "mounts.json")
	f := &fakeMounts{mounts: map[string]string{}}
	var picks []string
	s := newTestShares(t, f, cfg, &picks)
	notes := &fakeNotes{}
	s.progress = notes.progress

	// Cancelling the picker changes nothing.
	s.toggle("dori")
	if len(f.log) != 0 || s.state["dori"].Enabled {
		t.Fatalf("cancelled pick: %v %+v", f.log, s.state)
	}
	// First toggle asks, and a non-empty folder gets a subfolder.
	picks = []string{nonEmpty}
	s.toggle("share")
	want := filepath.Join(nonEmpty, "share")
	if !slices.Equal(f.log, []string{"mount share " + want}) || !s.state["share"].Enabled {
		t.Fatalf("first toggle: %v %+v", f.log, s.state)
	}
	// It shows a note while mounting, then the result.
	if !slices.Equal(notes.log, []string{
		"start: Mounting share at " + homeShort(want) + "…",
		"done: share is mounted at " + homeShort(want) + " (SMB Direct)",
	}) {
		t.Fatalf("mount notes: %q", notes.log)
	}
	// Off unmounts and keeps the folder for next time.
	s.toggle("share")
	if f.log[len(f.log)-1] != "unmount "+want || s.state["share"].Enabled || s.state["share"].Path != want {
		t.Fatalf("toggle off: %v %+v", f.log, s.state)
	}
	if !slices.Equal(notes.log[2:], []string{"start: Unmounting share…", "done: share is unmounted"}) {
		t.Fatalf("unmount notes: %q", notes.log)
	}
	// Back on: no question, same folder.
	s.toggle("share")
	if len(picks) != 0 || f.log[len(f.log)-1] != "mount share "+want {
		t.Fatalf("toggle on again: %v", f.log)
	}

	// Mounting does not opt into Automount.
	if s.state["share"].AutoMount {
		t.Fatalf("automount turned on by mounting: %+v", s.state)
	}
	s.toggleAuto("share")

	// After a reboot nothing is mounted; Automount brings it back.
	f.mounts = map[string]string{}
	s2 := newTestShares(t, f, cfg, &picks)
	s2.progress = notes.progress
	quiet := len(notes.log)
	s2.reconcile()
	if len(notes.log) != quiet {
		t.Fatalf("background remount notified: %q", notes.log[quiet:])
	}
	if f.log[len(f.log)-1] != "mount share "+want {
		t.Fatalf("remount after restart: %v", f.log)
	}
	n := len(f.log)
	s2.reconcile()
	if len(f.log) != n {
		t.Fatalf("remounted something already mounted: %v", f.log[n:])
	}

	// Changing the folder moves the mount.
	empty := filepath.Join(home, "NAS")
	_ = os.Mkdir(empty, 0o755)
	picks = []string{empty}
	s2.refresh()
	s2.changeFolder("share")
	if !slices.Equal(f.log[n:], []string{"unmount " + want, "mount share " + empty}) || s2.state["share"].Path != empty {
		t.Fatalf("change folder: %v %+v", f.log[n:], s2.state)
	}
	if fi, err := os.Stat(cfg); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("state file: %v %v", fi, err)
	}
}

func TestSharesAutoMount(t *testing.T) {
	home := t.TempDir()
	cfg := filepath.Join(t.TempDir(), "mounts.json")
	shareDir, doriDir := filepath.Join(home, "share"), filepath.Join(home, "dori")
	// A file from before Automount: "enabled" is not opting in.
	old := `{"share": {"path": "` + shareDir + `", "enabled": true, "automount": true}, "dori": {"path": "` + doriDir + `", "enabled": true}}`
	if err := os.WriteFile(cfg, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	f := &fakeMounts{mounts: map[string]string{}}
	var picks []string
	s := newTestShares(t, f, cfg, &picks)
	s.progress = (&fakeNotes{}).progress
	if !s.state["share"].AutoMount || s.state["dori"].AutoMount {
		t.Fatalf("loaded state: %+v", s.state)
	}
	s.reconcile()
	if !slices.Equal(f.log, []string{"mount share " + shareDir}) {
		t.Fatalf("login mounts: %v", f.log)
	}

	// Automount only changes the setting; it does not mount now.
	s.toggleAuto("dori")
	if !s.state["dori"].AutoMount || len(f.log) != 1 {
		t.Fatalf("automount on: %v %+v", f.log, s.state)
	}
	// Unticking Automount keeps the current mount.
	s.toggleAuto("share")
	if s.state["share"].AutoMount || !s.state["share"].Enabled || len(f.log) != 1 {
		t.Fatalf("automount off: %v %+v", f.log, s.state)
	}

	// The tray restarts (an update) while share is still mounted: it stays
	// enabled and is remounted if it drops, though Automount is off.
	s2 := newTestShares(t, f, cfg, &picks)
	s2.progress = s.progress
	s2.reconcile()
	if !s2.state["share"].Enabled {
		t.Fatalf("still-mounted share after restart: %+v", s2.state)
	}
	if f.log[len(f.log)-1] != "mount dori "+doriDir {
		t.Fatalf("automount share after restart: %v", f.log)
	}

	// After a reboot nothing is mounted: only Automount shares come back.
	f.mounts = map[string]string{}
	n := len(f.log)
	s3 := newTestShares(t, f, cfg, &picks)
	s3.reconcile()
	if !slices.Equal(f.log[n:], []string{"mount dori " + doriDir}) {
		t.Fatalf("after reboot: %v", f.log[n:])
	}
	var saved map[string]map[string]any
	b, _ := os.ReadFile(cfg)
	if json.Unmarshal(b, &saved) != nil || saved["share"]["automount"] != false || saved["share"]["enabled"] != nil {
		t.Fatalf("saved: %s", b)
	}
}
