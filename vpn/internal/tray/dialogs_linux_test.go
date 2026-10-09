package tray

import (
	"bytes"
	"testing"

	"github.com/godbus/dbus/v5"
)

// TestQMLAsk runs the real dialog offscreen and presses its action.
func TestQMLAsk(t *testing.T) {
	if qmlTool() == "" {
		t.Skip("no Qt 6 qml tool")
	}
	t.Setenv("QT_QPA_PLATFORM", "offscreen")
	orig := askDialogQML
	defer func() { askDialogQML = orig }()
	askDialogQML = bytes.Replace(orig, []byte("\n    Shortcut {"), []byte(`
    Timer {
        interval: 100
        running: true
        onTriggered: root.answer(root.form.action === "Remove")
    }
    Shortcut {`), 1)
	if !ask("t", "Remove it?", "Remove") {
		t.Error("action not reported")
	}
	if ask("t", "Copy it?", "Copy") {
		t.Error("Close reported as the action")
	}
}

func TestPortalFolder(t *testing.T) {
	uris := func(u ...string) map[string]dbus.Variant {
		return map[string]dbus.Variant{"uris": dbus.MakeVariant(u)}
	}
	for _, c := range []struct {
		code    uint32
		results map[string]dbus.Variant
		want    string
		err     bool
	}{
		{0, uris("file:///home/fox/My%20Shares"), "/home/fox/My Shares", false},
		{1, nil, "", false}, // cancelled
		{2, nil, "", true},
		{0, uris(), "", true},
		{0, uris("smb://nas/share"), "", true},
	} {
		got, err := portalFolder(c.code, c.results)
		if got != c.want || (err != nil) != c.err {
			t.Errorf("%d %v: got %q, %v", c.code, c.results, got, err)
		}
	}
}
