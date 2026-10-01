package main

import (
	"os/exec"
	"strings"
)

func copyToClipboard(text string) error {
	c := exec.Command("pbcopy")
	c.Stdin = strings.NewReader(text)
	return c.Run()
}

// appleScriptString quotes s as an AppleScript string literal.
func appleScriptString(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

func openURL(u string) error {
	return exec.Command("open", u).Start()
}

// ask shows message with an action button and "Close", and reports whether
// the action was chosen.
func ask(title, message, action string) bool {
	script := "display dialog " + appleScriptString(message) +
		" with title " + appleScriptString(title) +
		" buttons {\"Close\", " + appleScriptString(action) + "} default button " + appleScriptString(action)
	out, err := exec.Command("osascript", "-e", script).Output()
	return err == nil && strings.Contains(string(out), "button returned:"+action)
}

func notify(title, message string) {
	script := "display notification " + appleScriptString(message) + " with title " + appleScriptString(title)
	_ = exec.Command("osascript", "-e", script).Run()
}
