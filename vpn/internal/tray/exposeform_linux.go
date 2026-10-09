package tray

import (
	_ "embed"
	"errors"
	"log"
	"os/exec"
	"strings"
)

//go:embed exposeform.qml
var exposeFormQML []byte

// showExposeForm shows the form: with Kirigami on Plasma, so it looks like
// the rest of the desktop, and with zenity otherwise. ok is false if it
// was cancelled.
func showExposeForm(f exposeForm) (res exposeForm, ok bool, err error) {
	res, ok, err = qmlExposeForm(f)
	if err == nil {
		return res, ok, nil
	}
	if !errors.Is(err, errNoQML) {
		log.Printf("Kirigami form: %v; falling back to zenity", err) // most likely no Kirigami
	}
	if have("zenity") {
		return zenityExposeForm(f)
	}
	return f, false, errors.New("no dialog tool found (install Kirigami or zenity)")
}

func qmlExposeForm(f exposeForm) (exposeForm, bool, error) {
	var r struct {
		OK     bool   `json:"ok"`
		Target string `json:"target"`
		TCP    bool   `json:"tcp"`
		Name   string `json:"name"`
		Port   string `json:"port"`
	}
	if err := runQML(exposeFormQML, f, &r); err != nil {
		return f, false, err
	}
	f.Target, f.TCP, f.Name, f.Port = r.Target, r.TCP, r.Name, r.Port
	return f, r.OK, nil
}

// zenityExposeForm is the fallback. zenity forms cannot be prefilled, so
// a known target is shown in the text instead of a field.
func zenityExposeForm(f exposeForm) (exposeForm, bool, error) {
	text := f.Message
	if f.Error != "" {
		text = f.Error + "\n\n" + text
	}
	args := []string{"--forms", "--title", f.Title, "--separator", "\x1f"}
	askTarget := f.Target == "" || f.Error != ""
	if askTarget {
		args = append(args, "--add-entry", "Target (port, or host:port)")
	} else {
		text = strings.TrimSpace(text + "\n\nPublish " + f.Target + ":")
	}
	suffix := ""
	if f.Domain != "" {
		suffix = " (<name>." + f.Domain + ")"
	}
	args = append(args, "--text", text,
		"--add-combo", "Publish as", "--combo-values", "HTTPS|TCP",
		"--add-entry", "Name for HTTPS"+suffix+", or public port for TCP (empty: random)")
	out, err := exec.Command("zenity", args...).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return f, false, nil
		}
		return f, false, err
	}
	fields := strings.Split(strings.TrimRight(string(out), "\n"), "\x1f")
	if askTarget && len(fields) == 3 {
		f.Target, fields = fields[0], fields[1:]
	}
	if len(fields) != 2 {
		return f, false, errors.New("unexpected answer from zenity")
	}
	f.TCP = fields[0] == "TCP" || (fields[0] == "" && f.TCP)
	f.Name, f.Port = "", ""
	if f.TCP {
		f.Port = fields[1]
	} else {
		f.Name = fields[1]
	}
	return f, true, nil
}
