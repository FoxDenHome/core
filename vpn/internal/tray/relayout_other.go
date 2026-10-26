//go:build !linux

package tray

import "fyne.io/systray"

// relayout is only needed for dbusmenu hosts.
func relayout(*systray.MenuItem) {}
