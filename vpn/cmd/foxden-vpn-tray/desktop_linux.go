package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
)

func have(cmd string) bool {
	_, err := exec.LookPath(cmd)
	return err == nil
}

func copyToClipboard(text string) error {
	if os.Getenv("WAYLAND_DISPLAY") != "" && have("wl-copy") {
		return exec.Command("wl-copy", text).Run()
	}
	for _, q := range []string{"qdbus6", "qdbus"} {
		if have(q) {
			if exec.Command(q, "org.kde.klipper", "/klipper", "setClipboardContents", text).Run() == nil {
				return nil
			}
		}
	}
	for _, args := range [][]string{{"xclip", "-selection", "clipboard"}, {"xsel", "--clipboard", "--input"}} {
		if have(args[0]) {
			c := exec.Command(args[0], args[1:]...)
			c.Stdin = strings.NewReader(text)
			return c.Run()
		}
	}
	return errors.New("no clipboard tool found (install wl-clipboard or xclip)")
}

func openURL(u string) error {
	return exec.Command("xdg-open", u).Start()
}

// ask shows message with an action button and "Close", and reports whether
// the action was chosen.
func ask(title, message, action string) bool {
	switch {
	case have("kdialog"):
		return exec.Command("kdialog", "--title", title, "--yes-label", action, "--no-label", "Close",
			"--yesno", message).Run() == nil
	case have("zenity"):
		return exec.Command("zenity", "--question", "--title", title, "--ok-label", action,
			"--cancel-label", "Close", "--no-wrap", "--text", message).Run() == nil
	default:
		notify(title, message)
		return false
	}
}

func notify(title, message string) {
	if have("notify-send") {
		_ = exec.Command("notify-send", "--app-name=FoxDen VPN", "--icon=network-vpn", title, message).Run()
	}
}

// pickFolder asks for a directory with the desktop's own dialog.
func pickFolder(title, start string) (string, error) {
	var cmd *exec.Cmd
	switch {
	case have("kdialog"):
		cmd = exec.Command("kdialog", "--title", title, "--getexistingdirectory", start)
	case have("zenity"):
		cmd = exec.Command("zenity", "--file-selection", "--directory", "--title", title, "--filename", start+"/")
	default:
		return "", errors.New("no folder picker found (install kdialog or zenity)")
	}
	out, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return "", nil // cancelled
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
