package tray

import (
	"log"
	"reflect"

	"fyne.io/systray"
	"github.com/godbus/dbus/v5"
)

// fyne.io/systray's dbusmenu export, on the shared session bus connection.
const menuPath = "/StatusNotifierItem/menu"

// relayout makes the tray host re-read submenu m after items were added to
// it. fyne.io/systray only announces layout changes on the root, and its
// AboutToShow never asks for an update, so KDE keeps showing a submenu it
// has already filled as it first saw it.
func relayout(m *systray.MenuItem) {
	conn, err := dbus.SessionBus()
	if err != nil || len(conn.Names()) == 0 {
		return
	}
	var rev uint32
	v, err := conn.Object(conn.Names()[0], menuPath).GetProperty("com.canonical.dbusmenu.Version")
	if err == nil {
		_ = v.Store(&rev)
	}
	// MenuItem has no accessor for its id.
	id := int32(reflect.ValueOf(m).Elem().FieldByName("id").Uint())
	if err := conn.Emit(menuPath, "com.canonical.dbusmenu.LayoutUpdated", rev, id); err != nil {
		log.Printf("tray: relayout of %v: %v", m, err)
	}
}
