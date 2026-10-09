package tray

// note is a notification for something that runs; done shows the result.
type note interface {
	done(message string)
}

type plainNote struct{ title string }

func (n plainNote) done(message string) { notify(n.title, message) }

// notifyProgress shows message, then the result once done is called;
// AppleScript notifications cannot be replaced.
func notifyProgress(title, message string) note {
	notify(title, message)
	return plainNote{title}
}
