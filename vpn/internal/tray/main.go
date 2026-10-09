// Package tray is `foxden-vpnd tray`, the unprivileged status-bar applet
// for the daemon: a native NSStatusItem on macOS and a StatusNotifierItem on
// KDE Plasma (and other SNI-capable Linux panels). It is the daemon's own
// binary, so the two always come from the same build.
package tray

import (
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/api"
)

const appName = "FoxDen VPN"

type tray struct {
	client    *api.Client
	portalURL string
	args      []string

	mStatus, mDetail, mAddr       *systray.MenuItem
	mEnabled, mSplit, mFull       *systray.MenuItem
	mNetworks                     *systray.MenuItem
	mNetPlaceholder               *systray.MenuItem
	mRegister, mShowKey, mCopyKey *systray.MenuItem
	mReregister, mRegenerate      *systray.MenuItem
	mDevice, mManage              *systray.MenuItem
	mRefresh                      *systray.MenuItem
	mQuit                         *systray.MenuItem
	nets                          map[string]*systray.MenuItem
	netOrder                      []string
	mServices, mSvcPlaceholder    *systray.MenuItem
	svcs                          map[string]*systray.MenuItem

	ui         *ui
	krb        *kerberos // nil where unsupported
	shares     *shares   // nil where unsupported
	launcher   *launcher // nil where unsupported
	expose     *exposer
	wasProv    atomic.Bool
	renderMu   sync.Mutex
	mu         sync.Mutex
	last       *api.Status
	refreshing atomic.Bool
	poll       chan struct{}
	announce   sync.Once
}

// Options are what the tray was started with.
type Options struct {
	Socket    string // the daemon's control socket
	PortalURL string // device management portal
	// Args start the tray again with the same options, after an update:
	// the command line after the executable's path.
	Args []string
}

// Run runs the tray until it is quit. It must be called from the main
// goroutine.
func Run(o Options) {
	t := &tray{
		client:    api.NewClient(o.Socket),
		portalURL: o.PortalURL,
		args:      o.Args,
		nets:      map[string]*systray.MenuItem{},
		svcs:      map[string]*systray.MenuItem{},
		ui:        newUI(),
		poll:      make(chan struct{}, 1),
	}
	t.krb = newKerberos(t)
	t.shares = newShares(t)
	t.launcher = newLauncher(t)
	t.expose = newExposer(t)
	systray.Run(t.onReady, func() { t.expose.stopAll() })
}

func (t *tray) onReady() {
	t.ui.setIcon(iconOff)
	t.ui.setTooltip(appName)

	t.mStatus = systray.AddMenuItem(appName, "")
	t.mStatus.Disable()
	t.mDetail = systray.AddMenuItem("", "")
	t.mDetail.Disable()
	t.mDetail.Hide()
	t.mAddr = systray.AddMenuItem("", "")
	t.mAddr.Disable()
	t.mAddr.Hide()
	systray.AddSeparator()

	t.mEnabled = systray.AddMenuItemCheckbox("Enabled", "Use the VPN when away from home", false)
	t.mSplit = systray.AddMenuItemCheckbox("Split Tunnel (on demand)", "Only FoxDen networks go through the VPN", false)
	t.mFull = systray.AddMenuItemCheckbox("Full Tunnel", "All traffic goes through the VPN", false)
	t.mNetworks = systray.AddMenuItem("Networks", "Which FoxDen networks to route in split tunnel mode")
	// The submenu must have a child from the start: KDE does not turn an item
	// that was first shown without children into a submenu later.
	t.mNetPlaceholder = t.mNetworks.AddSubMenuItem("Available once registered", "")
	t.mNetPlaceholder.Disable()
	t.mServices = systray.AddMenuItem("Services", "Extra FoxDen services this device runs and keeps up to date")
	t.mSvcPlaceholder = t.mServices.AddSubMenuItem("Loading…", "") // see mNetPlaceholder
	t.mSvcPlaceholder.Disable()
	t.shares.menu() // with the Kerberos ticket in it
	t.launcher.menu()
	t.expose.menu() // with the published ports below it
	systray.AddSeparator()

	// Only until registered; after that it is "Manage Devices…" below.
	t.mRegister = systray.AddMenuItem("Log In and Register…", "Log in to the FoxDen portal and register this device")
	// Rarely needed, so kept out of the way.
	t.mDevice = systray.AddMenuItem("Device", "Registration, key and configuration of this device")
	t.mManage = t.mDevice.AddSubMenuItem("Manage Devices…", "Open the FoxDen portal")
	t.mReregister = t.mDevice.AddSubMenuItem("Register as a Different Device…", "Pick again which device this is")
	t.mRegenerate = t.mDevice.AddSubMenuItem("Regenerate Key…", "Replace this device's key with a new one")
	t.mDevice.AddSeparator()
	t.mShowKey = t.mDevice.AddSubMenuItem("Show Public Key…", "")
	t.mCopyKey = t.mDevice.AddSubMenuItem("Copy Public Key", "")
	t.mRefresh = t.mDevice.AddSubMenuItem("Refresh Configuration", "Re-fetch this device's configuration now")
	systray.AddSeparator()
	t.mQuit = systray.AddMenuItem("Quit", "Quit the applet (the VPN service keeps running)")

	t.onClick(t.mEnabled, func(st *api.Status) api.SettingsUpdate {
		v := !st.Enabled
		return api.SettingsUpdate{Enabled: &v}
	})
	t.onClick(t.mSplit, func(*api.Status) api.SettingsUpdate {
		m := api.ModeSplit
		return api.SettingsUpdate{Mode: &m}
	})
	t.onClick(t.mFull, func(*api.Status) api.SettingsUpdate {
		m := api.ModeFull
		return api.SettingsUpdate{Mode: &m}
	})
	go func() {
		for range t.mRegister.ClickedCh {
			t.enroll(false, "")
		}
	}()
	go func() {
		for range t.mManage.ClickedCh {
			t.openPortal()
		}
	}()
	go func() {
		for range t.mReregister.ClickedCh {
			t.enroll(false, "")
		}
	}()
	go func() {
		for range t.mRegenerate.ClickedCh {
			if st := t.status(); st != nil {
				t.regenerateKey(st)
			}
		}
	}()
	go func() {
		for range t.mShowKey.ClickedCh {
			t.showKey()
		}
	}()
	go func() {
		for range t.mCopyKey.ClickedCh {
			if st := t.status(); st != nil {
				if err := copyToClipboard(st.PublicKey); err != nil {
					notify(appName, err.Error())
				}
			}
		}
	}()
	go func() {
		for range t.mRefresh.ClickedCh {
			t.refresh()
		}
	}()
	go func() {
		<-t.mQuit.ClickedCh
		systray.Quit()
	}()

	go t.pollLoop()
	go t.krb.run()
	go t.shares.run()
	go t.expose.run()
}

func (t *tray) status() *api.Status {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.last
}

func (t *tray) pollNow() {
	select {
	case t.poll <- struct{}{}:
	default:
	}
}

func (t *tray) pollLoop() {
	tk := time.NewTicker(2 * time.Second)
	defer tk.Stop()
	upd := newUpdater(t.args)
	upd.handoff = t.expose.handoff
	for {
		st, err := t.client.Status()
		if err == nil {
			upd.check(st)
		}
		t.render(st, err)
		select {
		case <-tk.C:
		case <-t.poll:
		}
	}
}

// onClick sends the update built from the current status whenever item is clicked.
func (t *tray) onClick(item *systray.MenuItem, build func(*api.Status) api.SettingsUpdate) {
	go func() {
		for range item.ClickedCh {
			st := t.status()
			if st == nil {
				continue
			}
			nst, err := t.client.Update(build(st))
			if err != nil {
				notify(appName, err.Error())
				t.pollNow()
				continue
			}
			t.render(nst, nil)
		}
	}()
}

func (t *tray) render(st *api.Status, err error) {
	t.renderMu.Lock()
	defer t.renderMu.Unlock()
	t.mu.Lock()
	t.last = st
	t.mu.Unlock()
	t.expose.render() // enabled only while registered
	if st != nil && !t.wasProv.Swap(st.Provisioned) && st.Provisioned {
		t.krb.poke() // just registered, or the first status after start
		t.shares.poke()
	}

	if err != nil || st == nil {
		t.ui.setIcon(iconAttention)
		t.ui.title(t.mStatus, "VPN service not running")
		t.ui.line(t.mDetail, "")
		t.ui.line(t.mAddr, "")
		for _, m := range []*systray.MenuItem{t.mEnabled, t.mSplit, t.mFull, t.mNetworks, t.mServices, t.mRegister, t.mDevice} {
			t.ui.enable(m, false)
		}
		t.ui.setTooltip(appName + ": service not running")
		return
	}
	for _, m := range []*systray.MenuItem{t.mEnabled, t.mSplit, t.mFull, t.mServices, t.mRegister, t.mDevice} {
		t.ui.enable(m, true)
	}
	if t.refreshing.Load() {
		t.ui.title(t.mRefresh, "Refreshing…")
		t.ui.enable(t.mRefresh, false)
	} else {
		t.ui.title(t.mRefresh, "Refresh Configuration")
		t.ui.enable(t.mRefresh, true)
	}
	t.ui.show(t.mRegister, !st.Provisioned)
	t.ui.show(t.mManage, st.Provisioned)
	t.ui.show(t.mReregister, st.Provisioned)
	t.ui.show(t.mRegenerate, st.Provisioned)

	full := st.Mode == api.ModeFull
	t.ui.check(t.mEnabled, st.Enabled)
	t.ui.check(t.mSplit, !full)
	t.ui.check(t.mFull, full)
	t.renderNetworks(st, full && st.Location != api.LocationLAN) // always split at home
	t.renderServices(st)
	t.launcher.render(st)

	title, detail, icon := describe(st, t.refreshing.Load())
	t.ui.title(t.mStatus, title)
	t.ui.line(t.mDetail, detail)
	if len(st.Addresses) > 0 {
		t.ui.line(t.mAddr, strings.Join(st.Addresses, ", "))
	} else {
		t.ui.line(t.mAddr, "")
	}
	t.ui.setIcon(icon)
	t.ui.setTooltip(appName + ": " + title)

	if !st.Provisioned {
		t.announce.Do(func() {
			if !keyAnnounced(st.PublicKey) {
				markKeyAnnounced(st.PublicKey)
				go t.firstRun()
			}
		})
	}
}

func describe(st *api.Status, refreshing bool) (title, detail string, icon iconSet) {
	mode := "split tunnel"
	switch {
	case st.Location == api.LocationLAN:
		mode = "at home" // always split at home
	case st.Mode == api.ModeFull:
		mode = "full tunnel"
	}
	switch {
	case !st.Provisioned && refreshing:
		return "Checking registration…", "", iconAttention
	case !st.Provisioned:
		detail = "Log in to register this device"
		if st.ProvisionError != "" && !strings.Contains(st.ProvisionError, "not registered") {
			detail = st.ProvisionError
		}
		if !st.LastCheck.IsZero() {
			detail += " · checked at " + clock(st.LastCheck)
		}
		return "Waiting for approval", detail, iconAttention
	case !st.Enabled:
		return "Disabled", "", iconOff
	case st.Location == api.LocationOffline && st.Tunnel == api.TunnelDown:
		return "Offline", "", iconOff
	}
	switch st.Tunnel {
	case api.TunnelConnected:
		detail = st.Endpoint
		if !st.LastHandshake.IsZero() {
			detail += " · handshake at " + clock(st.LastHandshake)
		}
		return "Connected (" + mode + ")", detail, iconConnected
	case api.TunnelIdle:
		if st.Location == api.LocationLAN {
			return "Ready (at home, on demand)", "", iconLAN
		}
		return "Ready (" + mode + ", on demand)", "", iconIdle
	case api.TunnelConnecting:
		return "Connecting…", st.Endpoint, iconIdle
	default:
		return "Not connected", st.Error, iconAttention
	}
}

// clock renders a time for menu text. Absolute times keep the text stable
// between polls; "12s ago" would change, and so rebuild the menu, every time.
func clock(at time.Time) string {
	return at.Local().Format("15:04")
}

// refresh asks the daemon to fetch its configuration now, shows that it is
// working, and reports the outcome.
func (t *tray) refresh() {
	if !t.refreshing.CompareAndSwap(false, true) {
		return
	}
	before := t.status()
	t.render(before, nil)

	st, err := t.client.Refresh()
	t.refreshing.Store(false)
	if err != nil {
		t.render(t.status(), nil)
		notify(appName, "Refresh failed: "+err.Error())
		return
	}
	t.render(st, nil)

	switch {
	case st.Provisioned && (before == nil || !before.Provisioned):
		notify(appName, "Registered as \""+st.PeerName+"\". Configuration loaded.")
	case st.Provisioned && st.ProvisionError != "":
		notify(appName, "Could not refresh, using the saved configuration: "+st.ProvisionError)
	case st.Provisioned:
		notify(appName, "Configuration is up to date.")
	case st.ProvisionError != "" && !strings.Contains(st.ProvisionError, "not registered"):
		notify(appName, "Could not check registration: "+st.ProvisionError)
	default:
		notify(appName, "This device is not registered yet. If you just added it in the portal, "+
			"it can take a minute to show up. It keeps checking every 30 seconds.")
	}
}

func (t *tray) renderNetworks(st *api.Status, full bool) {
	seen := map[string]bool{}
	for _, n := range st.Networks {
		seen[n.Name] = true
		item, ok := t.nets[n.Name]
		if !ok {
			name := n.Name
			item = t.mNetworks.AddSubMenuItemCheckbox(name, strings.Join(n.Prefixes, "\n"), n.Enabled)
			t.nets[name] = item
			t.netOrder = append(t.netOrder, name)
			t.onClick(item, func(st *api.Status) api.SettingsUpdate {
				enabled := true
				for _, x := range st.Networks {
					if x.Name == name {
						enabled = !x.Enabled
					}
				}
				return api.SettingsUpdate{Network: map[string]bool{name: enabled}}
			})
		}
		here := slices.Contains(st.HomeNetworks, n.Name)
		if here {
			t.ui.title(item, n.Name+" (you are here: direct)")
		} else {
			t.ui.title(item, n.Name)
		}
		t.ui.show(item, true)
		t.ui.check(item, n.Enabled)
		t.ui.enable(item, !full && !here)
	}
	for _, name := range t.netOrder {
		if !seen[name] {
			t.ui.show(t.nets[name], false)
		}
	}
	if len(st.Networks) == 0 {
		t.ui.show(t.mNetPlaceholder, true)
	} else {
		t.ui.show(t.mNetPlaceholder, false)
	}
	t.ui.enable(t.mNetworks, true)
	if full {
		t.ui.title(t.mNetworks, "Networks (split tunnel only)")
	} else {
		t.ui.title(t.mNetworks, "Networks")
	}
}

// serviceTitle puts a service's state into its menu title.
func serviceTitle(s api.Service) string {
	var state string
	switch s.State {
	case api.ServiceRunning:
		state = s.Detail
	case api.ServiceNotInstalled:
		state = "off"
	case api.ServiceUnmanaged:
		state = "installed manually, tick to manage"
	case api.ServiceUnsupported:
		state = s.Detail
	case api.ServiceError:
		state = "error: " + s.Detail
		if len(state) > 70 {
			state = state[:69] + "…"
		}
	default:
		state = "checking…"
	}
	return s.Name + " (" + state + ")"
}

func (t *tray) renderServices(st *api.Status) {
	for _, s := range st.Services {
		item, ok := t.svcs[s.Name]
		if !ok {
			name := s.Name
			item = t.mServices.AddSubMenuItemCheckbox(name, s.Description, false)
			t.svcs[name] = item
			go func() {
				for range item.ClickedCh {
					t.toggleService(name)
				}
			}()
		}
		t.ui.title(item, serviceTitle(s))
		t.ui.check(item, s.Wanted != nil && *s.Wanted)
		t.ui.enable(item, s.State != api.ServiceUnsupported)
		t.ui.show(item, true)
	}
	t.ui.show(t.mSvcPlaceholder, len(st.Services) == 0)
}

func (t *tray) toggleService(name string) {
	st := t.status()
	if st == nil {
		return
	}
	var svc *api.Service
	for i := range st.Services {
		if st.Services[i].Name == name {
			svc = &st.Services[i]
		}
	}
	if svc == nil {
		return
	}
	enable := svc.Wanted == nil || !*svc.Wanted
	if !enable && !ask(appName, "Remove "+name+" from this device?\n\n"+svc.Description, "Remove") {
		return
	}
	nst, err := t.client.Update(api.SettingsUpdate{Services: map[string]bool{name: enable}})
	if err != nil {
		notify(appName, err.Error())
		return
	}
	t.render(nst, nil)
}

func (t *tray) showKey() {
	st := t.status()
	if st == nil {
		return
	}
	msg := "This device's FoxDen VPN public key is:\n\n" + st.PublicKey
	if st.Provisioned {
		msg += "\n\nIt is registered as \"" + st.PeerName + "\"."
	}
	if ask(appName, msg, "Copy") {
		if err := copyToClipboard(st.PublicKey); err != nil {
			notify(appName, err.Error())
		}
	}
}

func (t *tray) firstRun() {
	msg := "This device is not registered with FoxDen VPN yet.\n\n" +
		"Log in to register it. It connects by itself once registered."
	if ask(appName, msg, "Log In") {
		t.enroll(false, "")
	}
}

var nonHostChars = regexp.MustCompile(`[^a-z0-9-]+`)

// deviceName suggests a portal device name from the hostname.
func deviceName() string {
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(strings.ToLower(h), ".")
	h = strings.Trim(nonHostChars.ReplaceAllString(h, "-"), "-")
	if len(h) > 31 {
		h = strings.Trim(h[:31], "-")
	}
	return h
}

func (t *tray) openPortal() {
	if err := openURL(t.portal()); err != nil {
		notify(appName, err.Error())
	}
}

func announcedPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "foxden-vpn", "announced-key"), nil
}

// keyAnnounced reports whether the first-run key dialog was already shown for key.
func keyAnnounced(key string) bool {
	p, err := announcedPath()
	if err != nil {
		return false
	}
	b, err := os.ReadFile(p)
	return err == nil && strings.TrimSpace(string(b)) == key
}

func markKeyAnnounced(key string) {
	p, err := announcedPath()
	if err == nil {
		err = os.MkdirAll(filepath.Dir(p), 0o700)
	}
	if err == nil {
		err = os.WriteFile(p, []byte(key+"\n"), 0o600)
	}
	if err != nil && !errors.Is(err, os.ErrExist) {
		log.Printf("remembering announced key: %v", err)
	}
}
