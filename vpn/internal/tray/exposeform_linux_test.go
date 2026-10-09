package tray

import (
	"bytes"
	"testing"
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

	f := newExposeForm("localhost:22", "sshd", "tunnel.test")
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
