package main

import (
	"bytes"
	"sync"
	"time"

	"fyne.io/systray"
)

// ui forwards only real changes to the tray. fyne.io/systray re-sends the
// whole menu layout on every property update, and KDE then rebuilds an open
// menu: it flickers and open submenus stop responding until clicked again.
//
// The icon and tooltip are the exception, they are re-sent anyway for a
// while after start and then every minute: fyne.io/systray calls onReady
// before it has exported them on D-Bus, and drops anything set in between.
// Re-sending them does not touch the menu, so it causes no flicker.
type ui struct {
	mu       sync.Mutex
	items    map[*systray.MenuItem]*itemState
	icon     []byte
	tooltip  *string
	started  time.Time
	lastSync time.Time
}

const (
	startupResend = 10 * time.Second
	periodicSync  = time.Minute
)

type itemState struct {
	title                     *string
	checked, enabled, visible *bool
}

func newUI() *ui { return &ui{items: map[*systray.MenuItem]*itemState{}, started: time.Now()} }

// resync reports whether icon and tooltip must be re-sent even if unchanged.
func (u *ui) resync() bool {
	now := time.Now()
	if now.Sub(u.started) < startupResend || now.Sub(u.lastSync) >= periodicSync {
		u.lastSync = now
		return true
	}
	return false
}

func (u *ui) state(m *systray.MenuItem) *itemState {
	s, ok := u.items[m]
	if !ok {
		s = &itemState{}
		u.items[m] = s
	}
	return s
}

// changed records v in *slot and reports whether it differs from before.
func changed[T comparable](slot **T, v T) bool {
	if *slot != nil && **slot == v {
		return false
	}
	*slot = &v
	return true
}

func (u *ui) title(m *systray.MenuItem, title string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if changed(&u.state(m).title, title) {
		m.SetTitle(title)
	}
}

func (u *ui) check(m *systray.MenuItem, v bool) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if changed(&u.state(m).checked, v) {
		if v {
			m.Check()
		} else {
			m.Uncheck()
		}
	}
}

func (u *ui) enable(m *systray.MenuItem, v bool) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if changed(&u.state(m).enabled, v) {
		if v {
			m.Enable()
		} else {
			m.Disable()
		}
	}
}

func (u *ui) show(m *systray.MenuItem, v bool) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if changed(&u.state(m).visible, v) {
		if v {
			m.Show()
		} else {
			m.Hide()
		}
	}
}

// line shows text on an informational item, hiding it when empty.
func (u *ui) line(m *systray.MenuItem, text string) {
	if text != "" {
		u.title(m, text)
	}
	u.show(m, text != "")
}

// setIcon and setTooltip are called on every render; resync is checked
// once per render, in setIcon.
func (u *ui) setIcon(i iconSet) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.resync() {
		u.icon, u.tooltip = nil, nil
	}
	if !bytes.Equal(u.icon, i.regular) {
		u.icon = i.regular
		systray.SetTemplateIcon(i.template, i.regular)
	}
}

func (u *ui) setTooltip(s string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if changed(&u.tooltip, s) {
		systray.SetTooltip(s)
	}
}
