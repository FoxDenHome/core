package tray

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/godbus/dbus/v5"
)

const (
	portalName      = "org.freedesktop.portal.Desktop"
	portalPath      = "/org/freedesktop/portal/desktop"
	portalRequest   = "org.freedesktop.portal.Request"
	portalCancelled = 1
)

// portalPickFolder asks for a directory with the FileChooser portal. ""
// means cancelled.
func portalPickFolder(title, start string) (string, error) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return "", err
	}
	defer conn.Close()

	// The answer comes as a signal on a request object whose path follows
	// from our name and a token we choose; listen before asking, so it
	// cannot be missed.
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	token := "foxden_" + hex.EncodeToString(b)
	sender := strings.NewReplacer(":", "", ".", "_").Replace(conn.Names()[0])
	handle := dbus.ObjectPath(portalPath + "/request/" + sender + "/" + token)
	if err := conn.AddMatchSignal(dbus.WithMatchObjectPath(handle), dbus.WithMatchInterface(portalRequest),
		dbus.WithMatchMember("Response")); err != nil {
		return "", err
	}
	signals := make(chan *dbus.Signal, 4)
	conn.Signal(signals)

	opts := map[string]dbus.Variant{
		"handle_token": dbus.MakeVariant(token),
		"directory":    dbus.MakeVariant(true),
		"modal":        dbus.MakeVariant(true),
		"accept_label": dbus.MakeVariant("Choose"),
	}
	if start != "" {
		opts["current_folder"] = dbus.MakeVariant(append([]byte(start), 0))
	}
	var got dbus.ObjectPath
	err = conn.Object(portalName, portalPath).
		Call("org.freedesktop.portal.FileChooser.OpenFile", 0, "", title, opts).Store(&got)
	if err != nil {
		return "", err
	}
	if got != handle { // portals before 0.9 pick the path themselves
		handle = got
		_ = conn.AddMatchSignal(dbus.WithMatchObjectPath(handle), dbus.WithMatchInterface(portalRequest),
			dbus.WithMatchMember("Response"))
	}
	for sig := range signals {
		if sig.Path != handle || sig.Name != portalRequest+".Response" || len(sig.Body) < 2 {
			continue
		}
		return portalFolder(sig.Body[0], sig.Body[1])
	}
	return "", errors.New("lost the session bus")
}

// portalFolder reads the folder from a Response signal's body.
func portalFolder(code, results any) (string, error) {
	switch c, _ := code.(uint32); c {
	case 0:
	case portalCancelled:
		return "", nil
	default:
		return "", fmt.Errorf("the file chooser failed (%d)", c)
	}
	res, _ := results.(map[string]dbus.Variant)
	uris, _ := res["uris"].Value().([]string)
	if len(uris) == 0 {
		return "", errors.New("the file chooser returned no folder")
	}
	u, err := url.Parse(uris[0])
	if err != nil || u.Scheme != "file" {
		return "", fmt.Errorf("the file chooser returned %q, not a local folder", uris[0])
	}
	return u.Path, nil
}
