package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/api"
)

// Shares: a toggle per SMB share the device's owner may mount. The first
// toggle asks for a folder; after that it only mounts and unmounts. The
// folders and toggles are this user's, kept in ~/.config/foxden-vpn.

const (
	sharesInterval = time.Minute
	sharesTitle    = "NAS Shares"
)

type shareState struct {
	Path    string `json:"path"`
	Enabled bool   `json:"enabled"`
}

type shares struct {
	t    *tray
	file string
	// pick asks for a folder; replaced in tests.
	pick func(title, start string) (string, error)
	// progress shows what a click is doing, then its result; replaced in
	// tests.
	progress func(title, message string) note
	kick     chan struct{}

	mParent, mPlaceholder, mChange, mChangePlaceholder *systray.MenuItem

	mu      sync.Mutex
	state   map[string]shareState
	mounted map[string]api.Mount // by path
	errs    map[string]string    // last background error per share
	toggles map[string]*systray.MenuItem
	changes map[string]*systray.MenuItem
}

func newShares(t *tray) *shares {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	s := &shares{
		t: t, file: filepath.Join(dir, "foxden-vpn", "mounts.json"), pick: pickFolder, progress: notifyProgress,
		kick: make(chan struct{}, 1), state: map[string]shareState{}, mounted: map[string]api.Mount{},
		errs: map[string]string{}, toggles: map[string]*systray.MenuItem{}, changes: map[string]*systray.MenuItem{},
	}
	s.load()
	return s
}

func (s *shares) load() {
	b, err := os.ReadFile(s.file)
	if err == nil {
		_ = json.Unmarshal(b, &s.state)
	}
}

func (s *shares) save() error {
	b, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.file), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.file, b, 0o600)
}

func (s *shares) menu() {
	s.mParent = systray.AddMenuItem("NAS Shares", "Mount your FoxDen SMB shares")
	// Submenus need a child from the start (see mNetPlaceholder).
	s.mPlaceholder = s.mParent.AddSubMenuItem("Available once registered", "")
	s.mPlaceholder.Disable()
	// "Change Folder" is added below the toggles once shares are known.
}

func (s *shares) poke() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

func (s *shares) run() {
	tk := time.NewTicker(sharesInterval)
	defer tk.Stop()
	for {
		s.reconcile()
		s.render()
		select {
		case <-tk.C:
		case <-s.kick:
		}
	}
}

func homeShort(p string) string {
	if h := os.Getenv("HOME"); h != "" && (p == h || strings.HasPrefix(p, h+"/")) {
		return "~" + strings.TrimPrefix(p, h)
	}
	return p
}

func shareLabel(sh api.Share) string {
	if sh.Home {
		return sh.Name + " (home)"
	}
	return sh.Name
}

// refresh reads which of this user's shares are mounted.
func (s *shares) refresh() {
	list, err := s.t.client.Mounts()
	if err != nil {
		return
	}
	m := map[string]api.Mount{}
	for _, x := range list {
		m[x.Path] = x
	}
	s.mu.Lock()
	s.mounted = m
	s.mu.Unlock()
}

// reconcile mounts enabled shares that are not mounted (at login, after a
// network change, or once a Kerberos ticket is there).
func (s *shares) reconcile() {
	st := s.t.status()
	if st == nil || !st.Provisioned {
		return
	}
	s.refresh()
	for _, sh := range st.Shares {
		s.mu.Lock()
		cur, mounted := s.state[sh.Name], false
		if cur.Path != "" {
			_, mounted = s.mounted[cur.Path]
		}
		s.mu.Unlock()
		if !cur.Enabled || cur.Path == "" || mounted {
			continue
		}
		_, err := s.mount(sh.Name, cur.Path)
		s.mu.Lock()
		if err != nil {
			s.errs[sh.Name] = err.Error()
		} else {
			delete(s.errs, sh.Name)
		}
		s.mu.Unlock()
	}
	s.refresh()
}

func (s *shares) mount(name, path string) (*api.Mount, error) {
	if err := os.MkdirAll(path, 0o755); err != nil {
		return nil, err
	}
	return s.t.client.Mount(name, path)
}

// mountShowing mounts with a notification that stays up while mount.cifs
// runs (it can take a while trying each transport), then shows the result.
func (s *shares) mountShowing(name, path string) {
	n := s.progress(sharesTitle, "Mounting "+name+" at "+homeShort(path)+"…")
	m, err := s.mount(name, path)
	if err != nil {
		n.done("Could not mount " + name + ": " + err.Error())
		return
	}
	msg := name + " is mounted at " + homeShort(path)
	if m.Transport != "" {
		msg += " (" + m.Transport + ")"
	}
	n.done(msg)
}

func (s *shares) unmountShowing(name, path string) error {
	n := s.progress(sharesTitle, "Unmounting "+name+"…")
	if err := s.t.client.Unmount(path); err != nil {
		n.done("Could not unmount " + name + ": " + err.Error())
		return err
	}
	n.done(name + " is unmounted")
	return nil
}

func (s *shares) render() {
	st := s.t.status()
	if s.mParent == nil || st == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ui := s.t.ui
	for _, sh := range st.Shares {
		name := sh.Name
		if _, ok := s.toggles[name]; ok {
			continue
		}
		item := s.mParent.AddSubMenuItemCheckbox(shareLabel(sh), sh.Comment, false)
		s.toggles[name] = item
		go func() {
			for range item.ClickedCh {
				s.toggle(name)
			}
		}()
	}
	if s.mChange == nil && len(st.Shares) > 0 {
		// Gets its first child right away, so KDE sees a submenu (see
		// mNetPlaceholder).
		s.mChange = s.mParent.AddSubMenuItem("Change Folder", "Mount a share somewhere else")
		s.mChangePlaceholder = s.mChange.AddSubMenuItem("No folders chosen yet", "")
		s.mChangePlaceholder.Disable()
	}
	for _, sh := range st.Shares {
		name := sh.Name
		if _, ok := s.changes[name]; ok || s.mChange == nil {
			continue
		}
		change := s.mChange.AddSubMenuItem(shareLabel(sh)+"…", "")
		s.changes[name] = change
		go func() {
			for range change.ClickedCh {
				s.changeFolder(name)
			}
		}()
	}
	for _, sh := range st.Shares {
		name := sh.Name
		item := s.toggles[name]
		cur := s.state[name]
		m, mounted := s.mounted[cur.Path]
		title := shareLabel(sh)
		switch {
		case mounted:
			title += " (" + homeShort(cur.Path) + ", " + m.Transport + ")"
		case cur.Enabled && s.errs[name] != "":
			title += " (error: " + truncate(s.errs[name], 60) + ")"
		case cur.Enabled:
			title += " (mounting…)"
		}
		ui.title(item, title)
		ui.check(item, cur.Enabled)
		ui.show(item, true)
		ui.show(s.changes[name], cur.Path != "")
	}
	ui.show(s.mPlaceholder, len(st.Shares) == 0)
	if s.mChange != nil {
		anyPath := false
		for _, sh := range st.Shares {
			anyPath = anyPath || s.state[sh.Name].Path != ""
		}
		ui.show(s.mChange, anyPath)
		ui.show(s.mChangePlaceholder, !anyPath)
	}
}

// choose asks where to mount name. A folder that is not empty gets a
// subfolder named after the share.
func (s *shares) choose(name, current string) (string, error) {
	start := current
	if start == "" {
		start = os.Getenv("HOME")
	}
	dir, err := s.pick("Folder for the "+name+" share", start)
	if err != nil || dir == "" {
		return "", err
	}
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 && dir != current {
		dir = filepath.Join(dir, name)
	}
	return filepath.Clean(dir), nil
}

func (s *shares) toggle(name string) {
	s.mu.Lock()
	cur := s.state[name]
	s.mu.Unlock()
	if cur.Enabled {
		if cur.Path != "" {
			if err := s.unmountShowing(name, cur.Path); err != nil {
				s.poke()
				return
			}
		}
		cur.Enabled = false
	} else {
		if cur.Path == "" {
			p, err := s.choose(name, "")
			if err != nil {
				notify(appName, err.Error())
				return
			}
			if p == "" {
				return // cancelled
			}
			cur.Path = p
		}
		cur.Enabled = true
		s.mountShowing(name, cur.Path)
	}
	s.mu.Lock()
	s.state[name] = cur
	delete(s.errs, name)
	err := s.save()
	s.mu.Unlock()
	if err != nil {
		notify(appName, err.Error())
	}
	s.refresh()
	s.render()
}

func (s *shares) changeFolder(name string) {
	s.mu.Lock()
	cur := s.state[name]
	_, mounted := s.mounted[cur.Path]
	s.mu.Unlock()
	p, err := s.choose(name, cur.Path)
	if err != nil {
		notify(appName, err.Error())
		return
	}
	if p == "" || p == cur.Path {
		return
	}
	if mounted {
		if err := s.unmountShowing(name, cur.Path); err != nil {
			return
		}
	}
	cur.Path = p
	if cur.Enabled {
		s.mountShowing(name, p)
	}
	s.mu.Lock()
	s.state[name] = cur
	err = s.save()
	s.mu.Unlock()
	if err != nil {
		notify(appName, err.Error())
	}
	s.refresh()
	s.render()
}

// pickFolder asks for a directory with the desktop's own dialog.
func pickFolder(title, start string) (string, error) {
	var cmd *exec.Cmd
	switch {
	case have("kdialog"):
		cmd = exec.Command("kdialog", "--title", title, "--getexistingdirectory", start)
	case have("zenity"):
		cmd = exec.Command("zenity", "--file-selection", "--directory", "--title", title, "--filename", start+"/")
	default:
		return "", errors.New("no folder picker found (install kdialog or zenity)")
	}
	out, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return "", nil // cancelled
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
