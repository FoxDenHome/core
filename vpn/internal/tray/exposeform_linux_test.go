package tray

import (
	"bytes"
	"testing"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// TestQMLExposeForm runs the real form offscreen, typing a name and
// submitting it, to check the round trip through the qml tool.
func TestQMLExposeForm(t *testing.T) {
	if qmlTool() == "" {
		t.Skip("no Qt 6 qml tool")
	}
	t.Setenv("QT_QPA_PLATFORM", "offscreen")
	orig := exposeFormQML
	defer func() { exposeFormQML = orig }()
	exposeFormQML = bytes.Replace(orig, []byte("\n    Shortcut {"), []byte(`
    Timer {
        interval: 100
        running: true
        onTriggered: { name.text = "Demo-1"; httpsButton.checked = true; root.submit() }
    }
    Shortcut {`), 1)

	f := newExposeForm("localhost:22", "sshd", &api.Status{Expose: &provision.Expose{
		ServerName: "tunnel.test", TCPPorts: &provision.PortRange{First: 30000, Last: 30199},
	}})
	if f.Domain != "tunnel.test" || f.TCPFirst != 30000 || f.TCPLast != 30199 {
		t.Fatalf("form = %+v", f)
	}
	if !f.TCP {
		t.Fatal("port 22 should default to TCP")
	}
	res, ok, err := qmlExposeForm(f)
	if err != nil {
		if bytes.Contains([]byte(err.Error()), []byte("kirigami")) {
			t.Skip("no Kirigami:", err)
		}
		t.Fatal(err)
	}
	if !ok || res.TCP || res.Name != "Demo-1" || res.Target != "localhost:22" {
		t.Fatalf("got %+v, ok %v", res, ok)
	}
	s, err := res.tunnel()
	if err != nil || s.Kind != "http" || s.Name != "demo-1" || s.Target != "localhost:22" || s.Process != "sshd" {
		t.Fatalf("tunnel %+v, %v", s, err)
	}
}

// TestQMLExposeFormPort types a public port into the picker and submits
// right away, as pressing Publish does, and checks that out-of-range
// input is clamped to the range.
func TestQMLExposeFormPort(t *testing.T) {
	if qmlTool() == "" {
		t.Skip("no Qt 6 qml tool")
	}
	t.Setenv("QT_QPA_PLATFORM", "offscreen")
	orig := exposeFormQML
	defer func() { exposeFormQML = orig }()
	st := &api.Status{Expose: &provision.Expose{TCPPorts: &provision.PortRange{First: 30000, Last: 30199}}}
	for typed, want := range map[string]string{"30042": "30042", "40000": "30199", "": "", "Random": ""} {
		exposeFormQML = bytes.Replace(orig, []byte("\n    Shortcut {"), []byte(`
    Timer {
        interval: 100
        running: true
        onTriggered: { port.contentItem.text = "`+typed+`"; root.submit() }
    }
    Shortcut {`), 1)
		res, ok, err := qmlExposeForm(newExposeForm("localhost:22", "", st))
		if err != nil {
			t.Fatal(err)
		}
		if !ok || !res.TCP || res.Port != want {
			t.Errorf("typed %q: got %+v, ok %v; want port %q", typed, res, ok, want)
		}
	}
}
