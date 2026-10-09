package tray

import (
	"sync"

	"github.com/godbus/dbus/v5"
)

// note is a notification that stays up while something runs; done replaces
// it with the result, which expires.
type note interface {
	done(message string)
}

const noteResultTimeout = 6000 // ms

var (
	notifyBusOnce sync.Once
	notifyBus     *dbus.Conn
)

func notifications() dbus.BusObject {
	notifyBusOnce.Do(func() {
		if c, err := dbus.ConnectSessionBus(); err == nil {
			notifyBus = c
		}
	})
	if notifyBus == nil {
		return nil
	}
	return notifyBus.Object("org.freedesktop.Notifications", "/org/freedesktop/Notifications")
}

type busNote struct {
	obj   dbus.BusObject
	title string
	id    uint32
}

// send shows or, with a previous id, replaces the notification. A timeout
// of 0 keeps it up until replaced or closed.
func (n *busNote) send(message string, timeout int32) error {
	return n.obj.Call("org.freedesktop.Notifications.Notify", 0,
		appName, n.id, "network-vpn", n.title, message, []string{},
		map[string]dbus.Variant{}, timeout).Store(&n.id)
}

func (n *busNote) done(message string) {
	if n.send(message, noteResultTimeout) != nil {
		notify(n.title, message)
	}
}

type plainNote struct{ title string }

func (n plainNote) done(message string) { notify(n.title, message) }

// notifyProgress shows message until done is called. Without a
// notification service on the bus, only the result is shown.
func notifyProgress(title, message string) note {
	if obj := notifications(); obj != nil {
		n := &busNote{obj: obj, title: title}
		if n.send(message, 0) == nil {
			return n
		}
	}
	return plainNote{title}
}
