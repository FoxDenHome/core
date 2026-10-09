package tray

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
)

// Dialogs on Plasma are small Kirigami windows run with Qt 6's qml tool,
// so they look like the rest of the desktop. The last command line
// argument is the dialog's input as JSON; the answer is logged as
// "FOXDEN-RESULT <json>".

// qmlTool finds Qt 6's qml tool; plain "qml" is often Qt 5's.
func qmlTool() string {
	for _, c := range []string{"qml6", "/usr/lib/qt6/bin/qml", "/usr/lib64/qt6/bin/qml"} {
		if p, err := exec.LookPath(c); err == nil {
			return p
		}
	}
	return ""
}

const qmlResultPrefix = "FOXDEN-RESULT "

var errNoQML = errors.New("no Qt 6 qml tool")

// runQML shows the dialog in source with input and decodes its answer
// into out. An error means it could not be shown (most likely Kirigami
// is missing), not that it was cancelled.
func runQML(source []byte, input, out any) error {
	tool := qmlTool()
	if tool == "" {
		return errNoQML
	}
	file, err := os.CreateTemp("", "foxden-vpn-*.qml")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(source)
	if cerr := file.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	arg, err := json.Marshal(input)
	if err != nil {
		return err
	}
	// -a widget: the desktop style draws with QStyle, which needs a
	// QApplication. Logging goes to stderr, not the journal, so the
	// answer can be read from it.
	cmd := exec.Command(tool, "-a", "widget", file.Name(), "--", string(arg))
	cmd.Env = append(os.Environ(), "QT_FORCE_STDERR_LOGGING=1", "QT_MESSAGE_PATTERN=%{message}")
	output, err := cmd.CombinedOutput()
	for _, line := range strings.Split(string(output), "\n") {
		if v, found := strings.CutPrefix(strings.TrimSpace(line), qmlResultPrefix); found {
			return json.Unmarshal([]byte(v), out)
		}
	}
	if err == nil {
		err = errors.New("no answer")
	}
	return errors.New(err.Error() + ": " + strings.TrimSpace(truncate(string(output), 300)))
}
