package tray

import (
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
)

func TestListenTargets(t *testing.T) {
	a := netip.MustParseAddr
	got := listenTargets([]listenSocket{
		{Addr: a("::"), Port: 8080},
		{Addr: a("0.0.0.0"), Port: 8080, Process: "nginx"},
		{Addr: a("127.0.0.1"), Port: 3000, Process: "node"},
		{Addr: a("::1"), Port: 3000},
		{Addr: a("127.0.0.53"), Port: 53},
		{Addr: a("192.168.1.5"), Port: 22},
		{Addr: a("0.0.0.0"), Port: 22, Process: "sshd"},
		{Addr: a("fe80::1"), Port: 9000},
		{Addr: a("127.0.0.1"), Port: 41315, Process: "code"},
	}, 32768)
	var labels []string
	for _, l := range got {
		labels = append(labels, l.label())
	}
	want := "localhost:22 (sshd)|192.168.1.5:22|127.0.0.53:53|localhost:3000 (node)|localhost:8080 (nginx)"
	if strings.Join(labels, "|") != want {
		t.Fatalf("got  %s\nwant %s", strings.Join(labels, "|"), want)
	}
}

func TestNormalizeTarget(t *testing.T) {
	for in, want := range map[string]string{
		"3000":            "localhost:3000",
		" 192.168.1.5:22": "192.168.1.5:22",
		":80":             "localhost:80",
		"[::1]:5432":      "[::1]:5432",
		"nas:445":         "nas:445",
		"nas":             "",
		"70000":           "",
		"host:http":       "",
	} {
		got, err := normalizeTarget(in)
		if (err != nil) != (want == "") || got != want {
			t.Errorf("normalizeTarget(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
}

func TestTunnelLines(t *testing.T) {
	at := time.Date(2026, 1, 1, 15, 4, 0, 0, time.Local)
	tun := &tunnel{savedTunnel: savedTunnel{Kind: "http", Target: "localhost:3000", Process: "node"}}
	title, to, state, conns, last := tunnelLines(tun)
	if title != "Publishing localhost:3000…" || to != "To localhost:3000 (node)" || state != "Connecting…" ||
		conns != "No connections yet" || last != "" {
		t.Fatalf("connecting: %q %q %q %q %q", title, to, state, conns, last)
	}
	tun.URL, tun.up, tun.since = "https://abc.tunnel.f0x.es", true, at
	tun.total, tun.open, tun.lastRemote, tun.lastAt = 3, 1, "203.0.113.7", at
	title, _, state, conns, last = tunnelLines(tun)
	if title != "https://abc.tunnel.f0x.es → localhost:3000" || state != "Connected since 15:04" ||
		conns != "3 connections, 1 open" || last != "Last from 203.0.113.7 at 15:04" {
		t.Fatalf("up: %q %q %q %q", title, state, conns, last)
	}
	tun.up, tun.err, tun.open, tun.lastFailed = false, "timeout", 0, true
	title, _, state, conns, last = tunnelLines(tun)
	if title != "https://abc.tunnel.f0x.es → localhost:3000 (reconnecting)" || state != "Reconnecting: timeout" ||
		conns != "3 connections, none open" || last != "Last from 203.0.113.7 at 15:04 (localhost:3000 not reachable)" {
		t.Fatalf("down: %q %q %q %q", title, state, conns, last)
	}
}

func TestExposeHandoff(t *testing.T) {
	t.Setenv(exposeEnv, "")
	e := newExposer(&tray{})
	if undo := e.handoff(); os.Getenv(exposeEnv) != "" || undo == nil {
		t.Fatal("handoff without tunnels set the environment")
	}

	// A tunnel that is running (its goroutine ends when cancelled).
	done := make(chan struct{})
	tun := &tunnel{savedTunnel: savedTunnel{Kind: "tcp", Target: "localhost:22", Port: 30042, URL: "tcp://tunnel.f0x.es:30042"},
		done: done, cancel: func() { close(done) }}
	e.tunnels = []*tunnel{tun}
	e.handoff()
	want := `[{"kind":"tcp","target":"localhost:22","port":30042,"url":"tcp://tunnel.f0x.es:30042"}]`
	if got := os.Getenv(exposeEnv); got != want {
		t.Fatalf("handed over %s, want %s", got, want)
	}
}

func TestExposeFormTunnel(t *testing.T) {
	for _, c := range []struct {
		f    exposeForm
		want savedTunnel
		err  bool
	}{
		{f: exposeForm{Target: "3000"}, want: savedTunnel{Kind: "http", Target: "localhost:3000"}},
		{f: exposeForm{Target: "3000", Name: " Demo "}, want: savedTunnel{Kind: "http", Target: "localhost:3000", Name: "demo"}},
		{f: exposeForm{Target: "nas:22", TCP: true, Name: "ignored", Port: "30022"}, want: savedTunnel{Kind: "tcp", Target: "nas:22", Port: 30022}},
		{f: exposeForm{Target: "3000", Name: "-bad"}, err: true},
		{f: exposeForm{Target: "3000", TCP: true, Port: "x"}, err: true},
		{f: exposeForm{Target: "nope"}, err: true},
		{f: exposeForm{Target: "22", TCP: true, Port: "30199", TCPFirst: 30000, TCPLast: 30199}, want: savedTunnel{Kind: "tcp", Target: "localhost:22", Port: 30199}},
		{f: exposeForm{Target: "22", TCP: true, Port: "30200", TCPFirst: 30000, TCPLast: 30199}, err: true},
		{f: exposeForm{Target: "22", TCP: true, Port: "2222"}, want: savedTunnel{Kind: "tcp", Target: "localhost:22", Port: 2222}}, // range unknown
		{f: newExposeForm("localhost:8080", "nginx", nil), want: savedTunnel{Kind: "http", Target: "localhost:8080", Process: "nginx"}},
	} {
		got, err := c.f.tunnel()
		if (err != nil) != c.err || (!c.err && got != c.want) {
			t.Errorf("%+v: got %+v, %v; want %+v", c.f, got, err, c.want)
		}
	}
	// A different target than the one offered loses the process name.
	f := newExposeForm("localhost:8080", "nginx", nil)
	f.Target = "8081"
	if got, _ := f.tunnel(); got.Process != "" {
		t.Errorf("process kept for another target: %+v", got)
	}
}
