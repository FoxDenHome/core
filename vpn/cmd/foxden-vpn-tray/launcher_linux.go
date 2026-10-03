package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

// Launcher: the Servers menu opens SSH sessions, web UIs and NetCmdr KVM
// consoles from the list in the device's configuration. Web UIs and the KVM
// log in with JIT RADIUS credentials, which oauth-jit-radius hands out for
// the Kerberos ticket the tray keeps anyway: a web UI gets the password on
// the clipboard, netcmdr-view gets it in its environment.

const (
	launcherTitle = "Servers"
	// radiusMargin is how long credentials must still be good for to be
	// used; a login takes a moment, and the device checks them only then.
	radiusMargin = 2 * time.Minute
	// clipboardClear is how long a password stays on the clipboard.
	clipboardClear = 45 * time.Second
)

type radiusCreds struct {
	Username string    `json:"username"`
	Password string    `json:"password"`
	Expiry   time.Time `json:"expiry"`
}

type launcher struct {
	t *tray
	// These are replaced in tests.
	fetch func(ctx context.Context, env []string, url string) (int, []byte, error)
	// start runs cmd in the background; onExit, if set, gets its error and
	// output when it fails.
	start      func(cmd *exec.Cmd, onExit func(err error, output string)) error
	copySecret func(secret string) error
	clear      func(secret string)
	progress   func(title, message string) note
	notify     func(title, message string)
	lookPath   func(file string) (string, error)
	openURL    func(url string) error
	getenv     func(key string) string

	mParent, mPlaceholder *systray.MenuItem
	ssh, web, kvm         *launchGroup
	mRadius, mCopy        *systray.MenuItem

	mu    sync.Mutex
	creds *radiusCreds
}

// launchGroup is one submenu of the Servers menu, with an item per host.
type launchGroup struct {
	parent, placeholder *systray.MenuItem
	items               map[string]*systray.MenuItem
	order               []string
	open                func(provision.LaunchHost)
}

func newLauncher(t *tray) *launcher {
	return &launcher{
		t: t, fetch: curlNegotiate, start: startDetached, copySecret: copySecretToClipboard,
		clear: clearClipboardAfter, progress: notifyProgress, notify: notify,
		lookPath: exec.LookPath, openURL: openURL, getenv: os.Getenv,
	}
}

func (l *launcher) menu() {
	l.mParent = systray.AddMenuItem(launcherTitle, "SSH, web UIs and KVM consoles of FoxDen servers")
	l.mPlaceholder = l.mParent.AddSubMenuItem("Available once registered", "") // see mNetPlaceholder
	l.mPlaceholder.Disable()
	l.ssh = l.group("SSH", "Open a terminal with an SSH session", l.openSSH)
	l.web = l.group("Web UIs", "Open a management web UI; the password goes on the clipboard", l.openWeb)
	l.kvm = l.group("KVM Consoles", "Open the host's console with netcmdr-view", l.openKVM)
	l.mParent.AddSeparator()
	l.mRadius = l.mParent.AddSubMenuItem("", "JIT RADIUS credentials for web UIs and the KVM")
	l.mRadius.Disable()
	l.mRadius.Hide()
	l.mCopy = l.mParent.AddSubMenuItem("Copy RADIUS Password", "For logging in to network devices by hand")
	go func() {
		for range l.mCopy.ClickedCh {
			l.copyPassword()
		}
	}()
}

func (l *launcher) group(title, tooltip string, open func(provision.LaunchHost)) *launchGroup {
	g := &launchGroup{parent: l.mParent.AddSubMenuItem(title, tooltip), items: map[string]*systray.MenuItem{}, open: open}
	g.placeholder = g.parent.AddSubMenuItem("None", "") // see mNetPlaceholder
	g.placeholder.Disable()
	g.parent.Hide()
	return g
}

func (l *launcher) render(st *api.Status) {
	if l.mParent == nil {
		return
	}
	ui := l.t.ui
	var hosts []provision.LaunchHost
	if st.Launcher != nil {
		hosts = st.Launcher.Hosts
	}
	byGroup := map[*launchGroup][]provision.LaunchHost{}
	for _, h := range hosts {
		if h.SSH != "" {
			byGroup[l.ssh] = append(byGroup[l.ssh], h)
		}
		if h.Web != nil && h.Web.URL != "" {
			byGroup[l.web] = append(byGroup[l.web], h)
		}
		if h.KVM != nil && h.KVM.Host != "" {
			byGroup[l.kvm] = append(byGroup[l.kvm], h)
		}
	}
	for _, g := range []*launchGroup{l.ssh, l.web, l.kvm} {
		l.renderGroup(g, byGroup[g])
	}
	radius := len(byGroup[l.web]) > 0 || len(byGroup[l.kvm]) > 0
	ui.show(l.mPlaceholder, len(hosts) == 0)
	ui.show(l.mCopy, radius || (st.Launcher != nil && st.Launcher.JITRadius != ""))
	l.renderRadius()
}

func (l *launcher) renderRadius() {
	l.mu.Lock()
	c := l.creds
	l.mu.Unlock()
	if c != nil && time.Until(c.Expiry) > 0 {
		l.t.ui.line(l.mRadius, "RADIUS: "+c.Username+", valid until "+clock(c.Expiry))
	} else {
		l.t.ui.line(l.mRadius, "")
	}
}

// renderGroup adds items for new hosts (items can only be appended) and
// hides those no longer listed.
func (l *launcher) renderGroup(g *launchGroup, hosts []provision.LaunchHost) {
	ui := l.t.ui
	seen := map[string]bool{}
	for _, h := range hosts {
		seen[h.Name] = true
		item, ok := g.items[h.Name]
		if !ok {
			item = g.parent.AddSubMenuItem(h.Name, "")
			g.items[h.Name] = item
			g.order = append(g.order, h.Name)
			name := h.Name
			go func() {
				for range item.ClickedCh {
					if h, ok := l.host(name); ok {
						g.open(h)
					}
				}
			}()
		}
		ui.show(item, true)
	}
	for _, name := range g.order {
		if !seen[name] {
			ui.show(g.items[name], false)
		}
	}
	ui.show(g.placeholder, len(hosts) == 0)
	ui.show(g.parent, len(hosts) > 0)
}

// host looks name up in the current configuration, so a click acts on what
// it says now rather than when the item was added.
func (l *launcher) host(name string) (provision.LaunchHost, bool) {
	if st := l.t.status(); st != nil && st.Launcher != nil {
		for _, h := range st.Launcher.Hosts {
			if h.Name == name {
				return h, true
			}
		}
	}
	return provision.LaunchHost{}, false
}

// credentials returns RADIUS credentials good for at least radiusMargin,
// asking oauth-jit-radius with the Kerberos ticket when needed.
func (l *launcher) credentials(ctx context.Context) (*radiusCreds, error) {
	l.mu.Lock()
	c := l.creds
	l.mu.Unlock()
	if c != nil && time.Until(c.Expiry) > radiusMargin {
		return c, nil
	}
	st := l.t.status()
	if st == nil || st.Launcher == nil || st.Launcher.JITRadius == "" {
		return nil, errors.New("this device's configuration has no JIT RADIUS server")
	}
	var env []string
	if l.t.krb != nil {
		env = l.t.krb.env()
	}
	url := strings.TrimSuffix(st.Launcher.JITRadius, "/") + "/api/credentials"
	code, body, err := l.fetch(ctx, env, url)
	if err != nil {
		return nil, err
	}
	switch code {
	case 200:
	case 401:
		return nil, errors.New("no Kerberos ticket (see NAS Shares)")
	case 403:
		return nil, errors.New("your account may not log in to network devices")
	default:
		return nil, fmt.Errorf("JIT RADIUS: HTTP %d: %s", code, truncate(strings.TrimSpace(string(body)), 70))
	}
	c = &radiusCreds{}
	if err := json.Unmarshal(body, c); err != nil || c.Username == "" || c.Password == "" {
		return nil, errors.New("JIT RADIUS: unexpected answer")
	}
	l.mu.Lock()
	l.creds = c
	l.mu.Unlock()
	if l.mRadius != nil {
		l.renderRadius()
	}
	return c, nil
}

func (l *launcher) openSSH(h provision.LaunchHost) {
	cmd, err := l.terminal("ssh", h.SSH)
	if err == nil {
		err = l.start(cmd, nil)
	}
	if err != nil {
		l.notify(launcherTitle, "Could not open SSH to "+h.Name+": "+err.Error())
	}
}

// terminal builds a command running args in the desktop's terminal.
func (l *launcher) terminal(args ...string) (*exec.Cmd, error) {
	if l.has("xdg-terminal-exec") {
		return exec.Command("xdg-terminal-exec", args...), nil
	}
	if term := l.getenv("TERMINAL"); term != "" && l.has(term) {
		return exec.Command(term, append([]string{"-e"}, args...)...), nil
	}
	for _, t := range []struct {
		name string
		pre  []string
	}{
		{"konsole", []string{"-e"}},
		{"gnome-terminal", []string{"--"}},
		{"kgx", []string{"--"}},
		{"kitty", nil},
		{"alacritty", []string{"-e"}},
		{"foot", nil},
		{"wezterm", []string{"start", "--"}},
		{"xfce4-terminal", []string{"-x"}},
		{"xterm", []string{"-e"}},
	} {
		if l.has(t.name) {
			return exec.Command(t.name, append(append([]string{}, t.pre...), args...)...), nil
		}
	}
	return nil, errors.New("no terminal found (install xdg-terminal-exec)")
}

func (l *launcher) has(file string) bool {
	_, err := l.lookPath(file)
	return err == nil
}

func (l *launcher) openWeb(h provision.LaunchHost) {
	if !h.Web.Radius {
		if err := l.openURL(h.Web.URL); err != nil {
			l.notify(launcherTitle, err.Error())
		}
		return
	}
	n := l.progress(launcherTitle, "Getting RADIUS credentials for "+h.Name+"…")
	c, err := l.credentials(context.Background())
	if err == nil {
		err = l.copySecret(c.Password)
	}
	if err != nil {
		n.done("Could not log in to " + h.Name + ": " + err.Error())
		return
	}
	go l.clear(c.Password)
	n.done("Log in to " + h.Name + " as " + c.Username + ", the password is on the clipboard for " +
		strconv.Itoa(int(clipboardClear.Seconds())) + "s")
	if err := l.openURL(h.Web.URL); err != nil {
		l.notify(launcherTitle, err.Error())
	}
}

func (l *launcher) openKVM(h provision.LaunchHost) {
	if !l.has("netcmdr-view") {
		l.notify(launcherTitle, "netcmdr-view not found, install NetCmdr")
		return
	}
	n := l.progress(launcherTitle, "Opening the console of "+h.Name+"…")
	c, err := l.credentials(context.Background())
	if err != nil {
		n.done("Could not open the console of " + h.Name + ": " + err.Error())
		return
	}
	cmd := exec.Command("netcmdr-view", "--target", strconv.Itoa(h.KVM.Port))
	// The password stays out of argv, where every user could read it.
	cmd.Env = append(os.Environ(), "NETCMDR_HOST="+h.KVM.Host, "NETCMDR_USER="+c.Username, "NETCMDR_PASSWORD="+c.Password)
	err = l.start(cmd, func(err error, output string) {
		l.notify(launcherTitle, "The console of "+h.Name+" closed: "+lastLine(output, err))
	})
	if err != nil {
		n.done("Could not open the console of " + h.Name + ": " + err.Error())
		return
	}
	n.done("Connecting to the console of " + h.Name + " (" + h.KVM.Host + " port " + strconv.Itoa(h.KVM.Port) + ")")
}

// lastLine is the last line a command printed, which is where netcmdr-view
// puts its error.
func lastLine(out string, err error) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if s := strings.TrimSpace(lines[len(lines)-1]); s != "" {
		return truncate(s, 120)
	}
	return err.Error()
}

func (l *launcher) copyPassword() {
	c, err := l.credentials(context.Background())
	if err == nil {
		err = l.copySecret(c.Password)
	}
	if err != nil {
		l.notify(launcherTitle, "Could not get RADIUS credentials: "+err.Error())
		return
	}
	go l.clear(c.Password)
	l.notify(launcherTitle, "Password for "+c.Username+" copied, valid until "+clock(c.Expiry)+
		"; it leaves the clipboard in "+strconv.Itoa(int(clipboardClear.Seconds()))+"s")
}

// curlNegotiate GETs url with the session's Kerberos ticket. curl does
// SPNEGO with the system's GSSAPI, which reads every kind of credential
// cache (KEYRING, KCM); gokrb5 would only read files.
func curlNegotiate(ctx context.Context, env []string, url string) (int, []byte, error) {
	if !have("curl") {
		return 0, nil, errors.New("curl not found")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "curl", "-sS", "--negotiate", "-u", ":", "-H", "Accept: application/json",
		"-w", "\n%{http_code}", url)
	cmd.Env = env
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return 0, nil, errors.New(strings.TrimPrefix(msg, "curl: "))
	}
	i := bytes.LastIndexByte(out, '\n')
	code, err := strconv.Atoi(string(out[i+1:]))
	if i < 0 || err != nil {
		return 0, nil, errors.New("unexpected answer from curl")
	}
	return code, out[:i], nil
}

func startDetached(cmd *exec.Cmd, onExit func(err error, output string)) error {
	var out bytes.Buffer
	if onExit != nil {
		cmd.Stdout, cmd.Stderr = &out, &out
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() {
		if err := cmd.Wait(); err != nil && onExit != nil {
			onExit(err, out.String())
		}
	}()
	return nil
}

// copySecretToClipboard copies a password, keeping it out of the
// clipboard history where the tool allows that.
func copySecretToClipboard(secret string) error {
	if os.Getenv("WAYLAND_DISPLAY") != "" && have("wl-copy") {
		if exec.Command("wl-copy", "--sensitive", secret).Run() == nil {
			return nil
		}
		return exec.Command("wl-copy", secret).Run() // before wl-clipboard 2.2
	}
	return copyToClipboard(secret)
}

// clearClipboardAfter empties the clipboard after clipboardClear, unless
// something else was copied meanwhile.
func clearClipboardAfter(secret string) {
	time.Sleep(clipboardClear)
	var paste, clear *exec.Cmd
	switch {
	case os.Getenv("WAYLAND_DISPLAY") != "" && have("wl-paste"):
		paste, clear = exec.Command("wl-paste", "--no-newline"), exec.Command("wl-copy", "--clear")
	case have("xclip"):
		paste = exec.Command("xclip", "-selection", "clipboard", "-o")
		clear = exec.Command("xclip", "-selection", "clipboard", "-i", "/dev/null")
	default:
		return
	}
	if out, err := paste.Output(); err == nil && string(out) == secret {
		_ = clear.Run()
	}
}
