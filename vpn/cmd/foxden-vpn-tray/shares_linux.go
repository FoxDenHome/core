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

// Shares: a submenu per SMB share the device's owner may mount, with a
// "Mounted" toggle, the folder and its state, Open Folder and Change Folder.
// The first mount asks for a folder; after that the toggle only mounts and
// unmounts. Folders and toggles are this user's, kept in ~/.config/foxden-vpn.

const (
	sharesInterval = time.Minute
	sharesTitle    = "NAS Shares"
)

type shareState struct {
	Path string `json:"path"`
	// AutoMount mounts the share when the tray starts (at login); opt-in.
	AutoMount bool `json:"automount"`
	// Enabled keeps the share mounted for this session, remounting it after
	// network changes or a new ticket. At start it is AutoMount, or whether
	// the share is still mounted (the tray restarted after an update).
	Enabled bool `json:"-"`
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

	mParent, mPlaceholder *systray.MenuItem

	mu      sync.Mutex
	state   map[string]shareState
	mounted map[string]api.Mount // by path
	errs    map[string]string    // last background error per share
	items   map[string]*shareItem
	started bool // Enabled has been set from AutoMount and the mounts
}

func newShares(t *tray) *shares {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	s := &shares{
		t: t, file: filepath.Join(dir, "foxden-vpn", "mounts.json"), pick: pickFolder, progress: notifyProgress,
		kick: make(chan struct{}, 1), state: map[string]shareState{}, mounted: map[string]api.Mount{},
		errs: map[string]string{}, items: map[string]*shareItem{},
	}
	s.load()
	return s
}

func (s *shares) load() {
	b, err := os.ReadFile(s.file)
	if err != nil {
		return
	}
	_ = json.Unmarshal(b, &s.state)
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
	// The ticket comes first: items can only be appended, and the shares
	// arrive with the configuration. This also gives the submenu a child
	// from the start (see mNetPlaceholder).
	s.t.krb.menu(s.mParent)
	s.mParent.AddSeparator()
	s.mPlaceholder = s.mParent.AddSubMenuItem("Available once registered", "")
	s.mPlaceholder.Disable()
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
	s.mu.Lock()
	if !s.started {
		s.started = true
		for name, cur := range s.state {
			_, mounted := s.mounted[cur.Path]
			cur.Enabled = cur.AutoMount || (cur.Path != "" && mounted)
			s.state[name] = cur
		}
	}
	s.mu.Unlock()
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
		if _, ok := s.items[sh.Name]; !ok {
			s.items[sh.Name] = s.addItem(sh)
		}
	}
	for _, sh := range st.Shares {
		it := s.items[sh.Name]
		cur := s.state[sh.Name]
		m, mounted := s.mounted[cur.Path]
		title, info := shareLabel(sh), ""
		switch {
		case mounted:
			title += " (" + m.Transport + ")"
			info = homeShort(cur.Path)
		case cur.Enabled && s.errs[sh.Name] != "":
			title += " (error)"
			info = "Error: " + truncate(s.errs[sh.Name], 70)
		case cur.Enabled:
			title += " (mounting…)"
			info = "Mounting at " + homeShort(cur.Path) + "…"
		case cur.Path != "":
			info = homeShort(cur.Path) + " (not mounted)"
		}
		ui.title(it.parent, title)
		ui.show(it.parent, true)
		ui.check(it.mount, s.checked(sh.Name))
		ui.check(it.auto, cur.AutoMount)
		ui.line(it.info, info)
		ui.show(it.open, mounted)
		if cur.Path == "" {
			ui.title(it.change, "Choose Folder…")
		} else {
			ui.title(it.change, "Change Folder…")
		}
	}
	ui.show(s.mPlaceholder, len(st.Shares) == 0)
}

// shareItem is one share's submenu.
type shareItem struct {
	parent, mount, auto, info, open, change *systray.MenuItem
}

// addItem adds a share's submenu, all children at once so KDE sees a
// submenu (see mNetPlaceholder).
func (s *shares) addItem(sh api.Share) *shareItem {
	name := sh.Name
	it := &shareItem{parent: s.mParent.AddSubMenuItem(shareLabel(sh), sh.Comment)}
	it.mount = it.parent.AddSubMenuItemCheckbox("Mounted", "Mount this share now", false)
	it.auto = it.parent.AddSubMenuItemCheckbox("Automount", "Mount this share at every login", false)
	it.info = it.parent.AddSubMenuItem("", "")
	it.info.Disable()
	it.info.Hide()
	it.open = it.parent.AddSubMenuItem("Open Folder", "")
	it.change = it.parent.AddSubMenuItem("Change Folder…", "Mount this share somewhere else")
	on := func(m *systray.MenuItem, f func()) {
		go func() {
			for range m.ClickedCh {
				f()
			}
		}()
	}
	on(it.mount, func() { s.toggle(name) })
	on(it.auto, func() { s.toggleAuto(name) })
	on(it.change, func() { s.changeFolder(name) })
	on(it.open, func() {
		s.mu.Lock()
		p := s.state[name].Path
		s.mu.Unlock()
		if err := openURL(p); err != nil {
			notify(sharesTitle, err.Error())
		}
	})
	return it
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

// checked is what the Mounted box shows: mounted, or about to be. A share
// whose mount failed shows unchecked, so a click retries. Needs s.mu.
func (s *shares) checked(name string) bool {
	cur := s.state[name]
	_, mounted := s.mounted[cur.Path]
	return (cur.Path != "" && mounted) || (cur.Enabled && s.errs[name] == "")
}

func (s *shares) toggle(name string) {
	s.mu.Lock()
	cur, on := s.state[name], s.checked(name)
	s.mu.Unlock()
	if on {
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

// toggleAuto changes whether the share is mounted at login. It does not
// mount or unmount now; a share without a folder gets one first.
func (s *shares) toggleAuto(name string) {
	s.mu.Lock()
	cur := s.state[name]
	s.mu.Unlock()
	if !cur.AutoMount && cur.Path == "" {
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
	s.mu.Lock()
	latest := s.state[name] // keep a mount state that changed meanwhile
	latest.Path, latest.AutoMount = cur.Path, !cur.AutoMount
	s.state[name] = latest
	err := s.save()
	s.mu.Unlock()
	if err != nil {
		notify(appName, err.Error())
	}
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
