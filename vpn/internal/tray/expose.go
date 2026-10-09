package tray

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/FoxDenHome/core/vpn/internal/expose"
)

// Exposing ports: what `foxden-vpnd expose` does, from the menu. The
// "Expose Local Port" submenu offers the ports listening on this machine
// and any other target; each published port then gets a top-level item
// with its details, Copy Address and Disconnect. The tunnels run in the
// tray, as the user, like the CLI; a restart into a new version hands them
// over, and the edge's reservation gives them back the same address.

const (
	exposeTitle    = "Expose Local Port"
	maxListeners   = 20
	maxExposed     = 10 // the edge's limit per device
	listenInterval = 5 * time.Second
	// exposeEnv carries the tunnels across a restart into a new version.
	exposeEnv = "FOXDEN_VPN_TRAY_EXPOSED"
)

// listenSocket is a listening TCP socket on this machine.
type listenSocket struct {
	Addr    netip.Addr
	Port    int
	Process string // "" if unknown
}

// listenTarget is one offer in the menu: the sockets of a port that are
// reached through the same target.
type listenTarget struct {
	Target  string
	Process string
}

func (l listenTarget) label() string {
	if l.Process != "" {
		return l.Target + " (" + l.Process + ")"
	}
	return l.Target
}

// listenTargets turns sockets into targets: "localhost:<port>" for those on
// loopback or all addresses, the address itself for others. Ports from
// ephemeral on are left out: they were assigned by the kernel, to helpers
// such as an IDE's, and nobody would type them in either.
func listenTargets(socks []listenSocket, ephemeral int) []listenTarget {
	byTarget := map[string]*listenTarget{}
	var out []*listenTarget
	for _, s := range socks {
		if s.Port >= ephemeral {
			continue
		}
		var host string
		switch {
		case s.Addr.IsUnspecified() || s.Addr == netip.IPv6Loopback() || s.Addr == netip.AddrFrom4([4]byte{127, 0, 0, 1}):
			host = "localhost"
		case s.Addr.IsLinkLocalUnicast() || !s.Addr.IsValid():
			continue // would need a zone
		default:
			host = s.Addr.String()
		}
		target := net.JoinHostPort(host, strconv.Itoa(s.Port))
		if l, ok := byTarget[target]; ok {
			if l.Process == "" {
				l.Process = s.Process
			}
			continue
		}
		l := &listenTarget{Target: target, Process: s.Process}
		byTarget[target] = l
		out = append(out, l)
	}
	res := make([]listenTarget, len(out))
	for i, l := range out {
		res[i] = *l
	}
	slices.SortFunc(res, func(a, b listenTarget) int {
		ah, ap, _ := net.SplitHostPort(a.Target)
		bh, bp, _ := net.SplitHostPort(b.Target)
		an, _ := strconv.Atoi(ap)
		bn, _ := strconv.Atoi(bp)
		// localhost first: that is what is usually wanted.
		return cmp.Or(cmp.Compare(an, bn), cmp.Compare(notLocalhost(ah), notLocalhost(bh)), strings.Compare(ah, bh))
	})
	return res
}

func notLocalhost(host string) int {
	if host == "localhost" {
		return 0
	}
	return 1
}

// normalizeTarget accepts a port or host:port, as the CLI does.
func normalizeTarget(s string) (string, error) {
	s = strings.TrimSpace(s)
	if _, err := strconv.Atoi(s); err == nil {
		s = net.JoinHostPort("localhost", s)
	}
	host, port, err := net.SplitHostPort(s)
	if err != nil {
		return "", err
	}
	if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return "", fmt.Errorf("invalid port %q", port)
	}
	if host == "" {
		host = "localhost"
	}
	return net.JoinHostPort(host, port), nil
}

// savedTunnel is what survives a restart.
type savedTunnel struct {
	Kind    string `json:"kind"`
	Target  string `json:"target"`
	Process string `json:"process,omitempty"`
	Name    string `json:"name,omitempty"`
	Port    int    `json:"port,omitempty"`
	URL     string `json:"url,omitempty"`
}

// tunnel is one published port. Fields after done are guarded by exposer.mu.
type tunnel struct {
	savedTunnel
	cancel context.CancelFunc
	done   chan struct{}

	up          bool
	err         string
	since       time.Time
	open, total int
	lastRemote  string
	lastAt      time.Time
	lastFailed  bool
}

type tunnelSlot struct {
	parent, to, state, conns, last, copy, browse, disconnect *systray.MenuItem
}

type exposer struct {
	t         *tray
	scan      func() ([]listenSocket, error)
	show      func(exposeForm) (exposeForm, bool, error)
	ephemeral int
	kick      chan struct{}
	dialog    sync.Mutex // held while the form is up

	mParent, mHeader, mNone, mMore, mOther *systray.MenuItem
	lslots                                 []*systray.MenuItem
	tslots                                 []*tunnelSlot

	mu        sync.Mutex
	listening []listenTarget
	tunnels   []*tunnel
	domain    string
}

func newExposer(t *tray) *exposer {
	return &exposer{t: t, scan: listenSockets, show: showExposeForm, ephemeral: ephemeralPorts(), kick: make(chan struct{}, 1)}
}

func (e *exposer) poke() {
	select {
	case e.kick <- struct{}{}:
	default:
	}
}

// menu adds the submenu and, at the top level right below it, a hidden
// item per possible tunnel: items can only be appended, and KDE needs a
// submenu's children from the start (see mNetPlaceholder).
func (e *exposer) menu() {
	e.mParent = systray.AddMenuItem(exposeTitle, "Publish a port of this machine on the internet")
	e.mHeader = e.mParent.AddSubMenuItem("Listening on this machine:", "")
	e.mHeader.Disable()
	for range maxListeners {
		m := e.mParent.AddSubMenuItem("", "Publish this port over HTTPS or TCP")
		m.Hide()
		e.lslots = append(e.lslots, m)
	}
	e.mNone = e.mParent.AddSubMenuItem("None found", "")
	e.mNone.Disable()
	e.mMore = e.mParent.AddSubMenuItem("More not shown, use Other Target…", "")
	e.mMore.Disable()
	e.mMore.Hide()
	e.mParent.AddSeparator()
	e.mOther = e.mParent.AddSubMenuItem("Other Target…", "Publish any port this machine can reach")

	for range maxExposed {
		s := &tunnelSlot{parent: systray.AddMenuItem("", "")}
		s.to = s.parent.AddSubMenuItem("", "")
		s.state = s.parent.AddSubMenuItem("", "")
		s.conns = s.parent.AddSubMenuItem("", "")
		s.last = s.parent.AddSubMenuItem("", "")
		for _, m := range []*systray.MenuItem{s.to, s.state, s.conns, s.last} {
			m.Disable()
		}
		s.last.Hide()
		s.parent.AddSeparator()
		s.copy = s.parent.AddSubMenuItem("Copy Address", "")
		s.browse = s.parent.AddSubMenuItem("Open in Browser", "")
		s.parent.AddSeparator()
		s.disconnect = s.parent.AddSubMenuItem("Disconnect", "Stop publishing this port")
		s.parent.Hide()
		e.tslots = append(e.tslots, s)
	}

	on := func(m *systray.MenuItem, f func()) {
		go func() {
			for range m.ClickedCh {
				f()
			}
		}()
	}
	for i, m := range e.lslots {
		on(m, func() { e.publishListener(i) })
	}
	on(e.mOther, func() { e.publish(newExposeForm("", "", e.domainName())) })
	for i, s := range e.tslots {
		on(s.copy, func() {
			if url, _ := e.slotTunnel(i); url != "" {
				if err := copyToClipboard(url); err != nil {
					notify(exposeTitle, err.Error())
				}
			}
		})
		on(s.browse, func() {
			if url, _ := e.slotTunnel(i); url != "" {
				if err := openURL(url); err != nil {
					notify(exposeTitle, err.Error())
				}
			}
		})
		on(s.disconnect, func() {
			if _, cancel := e.slotTunnel(i); cancel != nil {
				cancel()
			}
		})
	}
}

func (e *exposer) run() {
	e.restore()
	tk := time.NewTicker(listenInterval)
	defer tk.Stop()
	for {
		if socks, err := e.scan(); err == nil {
			l := listenTargets(socks, e.ephemeral)
			e.mu.Lock()
			e.listening = l
			e.mu.Unlock()
		} else {
			log.Printf("listing listening ports: %v", err)
		}
		e.render()
		select {
		case <-tk.C:
		case <-e.kick:
		}
	}
}

// slotTunnel returns the address and cancel function of the tunnel shown
// in slot i.
func (e *exposer) slotTunnel(i int) (string, context.CancelFunc) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if i < len(e.tunnels) {
		return e.tunnels[i].URL, e.tunnels[i].cancel
	}
	return "", nil
}

func (e *exposer) publishListener(i int) {
	e.mu.Lock()
	if i >= len(e.listening) {
		e.mu.Unlock()
		return
	}
	l := e.listening[i]
	e.mu.Unlock()
	f := newExposeForm(l.Target, l.Process, e.domainName())
	e.publish(f)
}

// publish shows the form until what was entered is valid, then publishes it.
func (e *exposer) publish(f exposeForm) {
	if !e.dialog.TryLock() {
		return // one form at a time
	}
	defer e.dialog.Unlock()
	for {
		res, ok, err := e.show(f)
		if err != nil {
			notify(exposeTitle, err.Error())
			return
		}
		if !ok {
			return
		}
		s, err := res.tunnel()
		if err == nil {
			e.start(s, false)
			return
		}
		f, f.Error = res, err.Error()
	}
}

// domainName is the edge's domain, for the form, as the last ticket said.
// Before the first one, it asks for one; the form makes do without.
func (e *exposer) domainName() string {
	e.mu.Lock()
	d := e.domain
	e.mu.Unlock()
	if d == "" {
		if t, err := e.t.client.ExposeTicket(); err == nil {
			e.mu.Lock()
			e.domain, d = t.ServerName, t.ServerName
			e.mu.Unlock()
		}
	}
	return d
}

func (e *exposer) update(f func()) {
	e.mu.Lock()
	f()
	e.mu.Unlock()
	e.render()
}

// start publishes a target. A restored tunnel keeps trying to get its
// address back even if the first attempts fail.
func (e *exposer) start(s savedTunnel, restored bool) {
	ctx, cancel := context.WithCancel(context.Background())
	tun := &tunnel{savedTunnel: s, cancel: cancel, done: make(chan struct{})}
	e.mu.Lock()
	if len(e.tunnels) >= maxExposed {
		e.mu.Unlock()
		cancel()
		notify(exposeTitle, fmt.Sprintf("At most %d ports can be published at once.", maxExposed))
		return
	}
	e.tunnels = append(e.tunnels, tun)
	e.mu.Unlock()
	e.render()

	c := &expose.Client{
		Target: s.Target,
		Hello:  expose.Hello{Kind: s.Kind, Name: s.Name, Port: s.Port},
		Ticket: func(context.Context) (expose.Ticket, error) {
			t, err := e.t.client.ExposeTicket()
			if err != nil {
				return expose.Ticket{}, fmt.Errorf("foxden-vpnd: %w", err)
			}
			e.mu.Lock()
			e.domain = t.ServerName
			e.mu.Unlock()
			return expose.Ticket{Ticket: t.Ticket, Edges: t.Edges, ServerName: t.ServerName}, nil
		},
		Retry: restored,
		OnUp: func(w expose.Welcome) {
			var prev string
			e.update(func() {
				prev = tun.URL
				tun.URL, tun.Name, tun.Port = w.URL, w.Name, w.Port
				tun.up, tun.err, tun.since = true, "", time.Now()
			})
			switch {
			case prev == w.URL:
			case prev == "":
				msg := s.Target + " is published at " + w.URL
				if copyToClipboard(w.URL) == nil {
					msg += " (address copied)"
				}
				notify(exposeTitle, msg)
			default:
				notify(exposeTitle, s.Target+" is now published at "+w.URL+" instead of "+prev)
			}
		},
		OnDown: func(err error) {
			e.update(func() {
				tun.up = false
				if err != nil {
					tun.err = err.Error()
				}
			})
		},
		OnConn: func(remote string, err error) func() {
			if host, _, herr := net.SplitHostPort(remote); herr == nil {
				remote = host
			}
			e.update(func() {
				tun.total++
				tun.lastRemote, tun.lastAt, tun.lastFailed = remote, time.Now(), err != nil
				if err == nil {
					tun.open++
				}
			})
			return func() { e.update(func() { tun.open-- }) }
		},
		Logf: func(format string, args ...any) {
			log.Printf("expose %s: "+format, append([]any{s.Target}, args...)...)
		},
	}
	go func() {
		defer close(tun.done)
		err := c.Run(ctx)
		e.update(func() {
			e.tunnels = slices.DeleteFunc(e.tunnels, func(x *tunnel) bool { return x == tun })
		})
		if err != nil && ctx.Err() == nil {
			notify(exposeTitle, "Could not publish "+s.Target+": "+err.Error())
		}
	}()
}

// stopAll closes every tunnel, giving the edge a moment to hear about it so
// it can hand the addresses back right away.
func (e *exposer) stopAll() []savedTunnel {
	e.mu.Lock()
	tuns := slices.Clone(e.tunnels)
	var saved []savedTunnel
	for _, tun := range tuns {
		saved = append(saved, tun.savedTunnel)
	}
	e.mu.Unlock()
	for _, tun := range tuns {
		tun.cancel()
	}
	deadline := time.After(2 * time.Second)
	for _, tun := range tuns {
		select {
		case <-tun.done:
		case <-deadline:
			return saved
		}
	}
	return saved
}

// handoff stops the tunnels before a restart into a new version and leaves
// them in the environment for it. undo restarts them if the restart fails.
func (e *exposer) handoff() (undo func()) {
	e.mu.Lock()
	n := len(e.tunnels)
	e.mu.Unlock()
	if n == 0 {
		return func() {}
	}
	saved := e.stopAll()
	b, err := json.Marshal(saved)
	if err == nil {
		err = os.Setenv(exposeEnv, string(b))
	}
	if err != nil {
		log.Printf("handing over published ports: %v", err)
	}
	return e.restore
}

// restore restarts the tunnels handed over by the version before.
func (e *exposer) restore() {
	v := os.Getenv(exposeEnv)
	_ = os.Unsetenv(exposeEnv)
	if v == "" {
		return
	}
	var saved []savedTunnel
	if err := json.Unmarshal([]byte(v), &saved); err != nil {
		log.Printf("restoring published ports: %v", err)
		return
	}
	for _, s := range saved {
		e.start(s, true)
	}
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// tunnelLines describes a tunnel for its item and submenu. Needs e.mu.
func tunnelLines(tun *tunnel) (title, to, state, conns, last string) {
	to = "To " + tun.Target
	if tun.Process != "" {
		to += " (" + tun.Process + ")"
	}
	switch {
	case tun.URL == "":
		title = "Publishing " + tun.Target + "…"
		state = "Connecting…"
		if tun.err != "" {
			state = "Retrying: " + truncate(tun.err, 70)
		}
	case tun.up:
		title = tun.URL + " → " + tun.Target
		state = "Connected since " + clock(tun.since)
	default:
		title = tun.URL + " → " + tun.Target + " (reconnecting)"
		state = "Reconnecting: " + truncate(tun.err, 70)
	}
	switch {
	case tun.total == 0:
		conns = "No connections yet"
	case tun.open == 0:
		conns = plural(tun.total, "connection", "connections") + ", none open"
	default:
		conns = plural(tun.total, "connection", "connections") + ", " + strconv.Itoa(tun.open) + " open"
	}
	if tun.lastRemote != "" {
		last = "Last from " + tun.lastRemote + " at " + clock(tun.lastAt)
		if tun.lastFailed {
			last += " (" + tun.Target + " not reachable)"
		}
	}
	return
}

func (e *exposer) render() {
	if e.mParent == nil {
		return
	}
	st := e.t.status()
	ui := e.t.ui
	e.mu.Lock()
	defer e.mu.Unlock()

	ui.enable(e.mParent, st != nil && st.Provisioned)
	published := map[string]bool{}
	for _, tun := range e.tunnels {
		published[tun.Target] = true
	}
	for i, m := range e.lslots {
		if i >= len(e.listening) {
			ui.show(m, false)
			continue
		}
		l := e.listening[i]
		title := l.label() + "…"
		if published[l.Target] {
			title = l.label() + " (published)…"
		}
		ui.title(m, title)
		ui.show(m, true)
	}
	ui.show(e.mNone, len(e.listening) == 0)
	ui.show(e.mMore, len(e.listening) > maxListeners)

	for i, s := range e.tslots {
		if i >= len(e.tunnels) {
			ui.show(s.parent, false)
			continue
		}
		tun := e.tunnels[i]
		title, to, state, conns, last := tunnelLines(tun)
		ui.title(s.parent, title)
		ui.title(s.to, to)
		ui.title(s.state, state)
		ui.title(s.conns, conns)
		ui.line(s.last, last)
		ui.enable(s.copy, tun.URL != "")
		ui.show(s.browse, tun.Kind == expose.KindHTTP)
		ui.enable(s.browse, tun.URL != "")
		ui.show(s.parent, true)
	}
}
