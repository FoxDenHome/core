// foxden-vpn-tray is the unprivileged status-bar applet for foxden-vpnd: a
// native NSStatusItem on macOS and a StatusNotifierItem on KDE Plasma (and
// other SNI-capable Linux panels).
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/api"
)

const appName = "FoxDen VPN"

type tray struct {
	client    *api.Client
	portalURL string

	mStatus, mDetail, mAddr       *systray.MenuItem
	mEnabled, mSplit, mFull       *systray.MenuItem
	mNetworks                     *systray.MenuItem
	mRegister, mShowKey, mCopyKey *systray.MenuItem
	mRefresh                      *systray.MenuItem
	mQuit                         *systray.MenuItem
	nets                          map[string]*systray.MenuItem
	netOrder                      []string

	mu       sync.Mutex
	last     *api.Status
	poll     chan struct{}
	announce sync.Once
}

func main() {
	socket := flag.String("socket", api.DefaultSocket, "foxden-vpnd control socket")
	portal := flag.String("portal-url", "https://portal.foxden.network/", "device management portal")
	flag.Parse()

	t := &tray{
		client:    api.NewClient(*socket),
		portalURL: *portal,
		nets:      map[string]*systray.MenuItem{},
		poll:      make(chan struct{}, 1),
	}
	systray.Run(t.onReady, func() {})
}

func (t *tray) onReady() {
	setIcon(iconOff)
	systray.SetTooltip(appName)

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
	systray.AddSeparator()

	t.mRegister = systray.AddMenuItem("Register This Device…", "Open the FoxDen VPN portal to add this device")
	t.mShowKey = systray.AddMenuItem("Show Public Key…", "")
	t.mCopyKey = systray.AddMenuItem("Copy Public Key", "")
	t.mRefresh = systray.AddMenuItem("Refresh Configuration", "Re-fetch this device's configuration now")
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
			t.openPortal()
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
			if st, err := t.client.Refresh(); err == nil {
				t.render(st, nil)
			}
			// The daemon fetches asynchronously; look again shortly.
			time.AfterFunc(3*time.Second, t.pollNow)
		}
	}()
	go func() {
		<-t.mQuit.ClickedCh
		systray.Quit()
	}()

	go t.pollLoop()
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
	for {
		st, err := t.client.Status()
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

func setIcon(i iconSet) {
	systray.SetTemplateIcon(i.template, i.regular)
}

func setCheck(item *systray.MenuItem, v bool) {
	if v {
		item.Check()
	} else {
		item.Uncheck()
	}
}

func setLine(item *systray.MenuItem, text string) {
	if text == "" {
		item.Hide()
		return
	}
	item.SetTitle(text)
	item.Show()
}

func (t *tray) render(st *api.Status, err error) {
	t.mu.Lock()
	t.last = st
	t.mu.Unlock()

	if err != nil || st == nil {
		setIcon(iconAttention)
		t.mStatus.SetTitle("VPN service not running")
		setLine(t.mDetail, "")
		setLine(t.mAddr, "")
		for _, m := range []*systray.MenuItem{t.mEnabled, t.mSplit, t.mFull, t.mNetworks, t.mRegister, t.mShowKey, t.mCopyKey, t.mRefresh} {
			m.Disable()
		}
		systray.SetTooltip(appName + ": service not running")
		return
	}
	for _, m := range []*systray.MenuItem{t.mEnabled, t.mSplit, t.mFull, t.mRegister, t.mShowKey, t.mCopyKey, t.mRefresh} {
		m.Enable()
	}
	if st.Provisioned {
		t.mRegister.SetTitle("Manage Devices…")
	} else {
		t.mRegister.SetTitle("Register This Device…")
	}

	full := st.Mode == api.ModeFull
	setCheck(t.mEnabled, st.Enabled)
	setCheck(t.mSplit, !full)
	setCheck(t.mFull, full)
	t.renderNetworks(st, full)

	title, detail, icon := describe(st)
	t.mStatus.SetTitle(title)
	setLine(t.mDetail, detail)
	if len(st.Addresses) > 0 {
		setLine(t.mAddr, strings.Join(st.Addresses, ", "))
	} else {
		setLine(t.mAddr, "")
	}
	setIcon(icon)
	systray.SetTooltip(appName + ": " + title)

	if !st.Provisioned {
		t.announce.Do(func() {
			if !keyAnnounced(st.PublicKey) {
				markKeyAnnounced(st.PublicKey)
				go t.firstRun()
			}
		})
	}
}

func describe(st *api.Status) (title, detail string, icon iconSet) {
	mode := "split tunnel"
	if st.Mode == api.ModeFull {
		mode = "full tunnel"
	}
	switch {
	case !st.Provisioned:
		detail = "Register this device in the VPN portal"
		if st.ProvisionError != "" && !strings.Contains(st.ProvisionError, "not registered") {
			detail = st.ProvisionError
		}
		return "Waiting for approval", detail, iconAttention
	case !st.Enabled:
		return "Disabled", "", iconOff
	case st.Location == api.LocationLAN:
		return "At home (direct)", "", iconLAN
	case st.Location == api.LocationOffline && st.Tunnel == api.TunnelDown:
		return "Offline", "", iconOff
	}
	switch st.Tunnel {
	case api.TunnelConnected:
		detail = st.Endpoint
		if !st.LastHandshake.IsZero() {
			detail += fmt.Sprintf(" · handshake %s ago", time.Since(st.LastHandshake).Round(time.Second))
		}
		return "Connected (" + mode + ")", detail, iconConnected
	case api.TunnelIdle:
		return "Ready (" + mode + ", on demand)", "", iconIdle
	case api.TunnelConnecting:
		return "Connecting…", st.Endpoint, iconIdle
	default:
		return "Not connected", st.Error, iconAttention
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
		item.Show()
		setCheck(item, n.Enabled)
		if full {
			item.Disable()
		} else {
			item.Enable()
		}
	}
	for _, name := range t.netOrder {
		if !seen[name] {
			t.nets[name].Hide()
		}
	}
	if len(st.Networks) == 0 {
		t.mNetworks.Disable()
	} else {
		t.mNetworks.Enable()
	}
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
		"Log in to the VPN portal to add it. It connects by itself once registered."
	if ask(appName, msg, "Open Portal") {
		t.openPortal()
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
	st := t.status()
	if st == nil {
		return
	}
	u, err := url.Parse(t.portalURL)
	if err != nil {
		notify(appName, err.Error())
		return
	}
	if !st.Provisioned {
		u.RawQuery = url.Values{"name": {deviceName()}, "pubkey": {st.PublicKey}}.Encode()
	}
	if err := openURL(u.String()); err != nil {
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
