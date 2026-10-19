package tray

import (
	_ "embed"
	"errors"
	"log"
	"os/exec"
	"strings"
)

//go:embed sshkeys.qml
var sshKeysQML []byte

// showSSHKeysForm shows the dialog: with Kirigami on Plasma, and otherwise
// as zenity's text editor for the file. ok is false if it was cancelled.
func showSSHKeysForm(f sshKeysForm) (sshKeysAnswer, bool, error) {
	var a sshKeysAnswer
	err := runQML(sshKeysQML, f, &a)
	if err == nil {
		a.Text = nil // the Kirigami dialog edits by key
		return a, a.OK, nil
	}
	if !errors.Is(err, errNoQML) {
		log.Printf("Kirigami dialog: %v; falling back to zenity", err) // most likely no Kirigami
	}
	if have("zenity") {
		return zenitySSHKeysForm(f)
	}
	return a, false, errors.New("no dialog tool found (install Kirigami or zenity)")
}

// zenitySSHKeysForm is the fallback: the reference keys first, for copying,
// then the file to edit.
func zenitySSHKeysForm(f sshKeysForm) (sshKeysAnswer, bool, error) {
	var a sshKeysAnswer
	text := "Your Kanidm keys, for reference (they are changed in Kanidm):"
	if f.Error != "" {
		text = f.Error + "\n\n" + text
	}
	cmd := exec.Command("zenity", "--text-info", "--title", f.Title+": reference", "--width", "800", "--height", "300",
		"--ok-label", "Edit authorized_keys…", "--cancel-label", "Cancel")
	cmd.Stdin = strings.NewReader("# " + text + "\n" + f.reference())
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return a, false, nil
		}
		return a, false, err
	}
	if f.ReadOnly != "" {
		return a, false, errors.New(f.Path + ": " + f.ReadOnly)
	}
	cmd = exec.Command("zenity", "--text-info", "--editable", "--title", f.Title+": "+f.Path,
		"--width", "800", "--height", "500", "--ok-label", "Save", "--cancel-label", "Cancel")
	cmd.Stdin = strings.NewReader(f.Text)
	out, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return a, false, nil
		}
		return a, false, err
	}
	s := string(out)
	a.OK, a.Text = true, &s
	return a, true, nil
}
