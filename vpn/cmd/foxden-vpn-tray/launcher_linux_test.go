package main

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/FoxDenHome/core/vpn/internal/api"
	"github.com/FoxDenHome/core/vpn/internal/provision"
)

type fakeLaunch struct {
	fetches  []string
	code     int
	expiry   time.Time
	started  []*exec.Cmd
	onExit   func(error, string)
	copied   []string
	cleared  chan string
	opened   []string
	notes    fakeNotes
	notified []string
	path     []string // what lookPath finds
}

func newTestLauncher(f *fakeLaunch) *launcher {
	tr := &tray{ui: newUI(), last: &api.Status{Provisioned: true, Launcher: &provision.Launcher{
		JITRadius: "https://radius.example/",
		Hosts: []provision.LaunchHost{
			{Name: "bengalfox", SSH: "bengalfox.example", KVM: &provision.KVM{Host: "kvm.example", Port: 3}},
			{Name: "ups", Web: &provision.WebUI{URL: "https://ups.example/", Radius: true}},
			{Name: "unifi", Web: &provision.WebUI{URL: "https://unifi.example/"}},
		},
	}}}
	tr.krb = &kerberos{dir: "/k", sysConf: "/nonexistent"}
	l := newLauncher(tr)
	l.fetch = func(_ context.Context, env []string, url string) (int, []byte, error) {
		if !slices.Contains(env, "KRB5_CONFIG=/k/krb5.conf") {
			return 0, nil, errors.New("not the tray's krb5.conf")
		}
		f.fetches = append(f.fetches, url)
		return f.code, fmt.Appendf(nil, `{"username":"dori","password":"secret%d","expiry":%q}`,
			len(f.fetches), f.expiry.Format(time.RFC3339Nano)), nil
	}
	l.start = func(cmd *exec.Cmd, onExit func(error, string)) error {
		f.started = append(f.started, cmd)
		f.onExit = onExit
		return nil
	}
	l.copySecret = func(s string) error { f.copied = append(f.copied, s); return nil }
	f.cleared = make(chan string, 10)
	l.clear = func(s string) { f.cleared <- s }
	l.openURL = func(u string) error { f.opened = append(f.opened, u); return nil }
	l.progress = f.notes.progress
	l.notify = func(_, msg string) { f.notified = append(f.notified, msg) }
	l.lookPath = func(file string) (string, error) {
		if slices.Contains(f.path, file) {
			return "/usr/bin/" + file, nil
		}
		return "", exec.ErrNotFound
	}
	l.getenv = func(string) string { return "" }
	return l
}

func TestLauncherCredentials(t *testing.T) {
	f := &fakeLaunch{code: 200, expiry: time.Now().Add(time.Hour)}
	l := newTestLauncher(f)

	c, err := l.credentials(context.Background())
	if err != nil || c.Username != "dori" || c.Password != "secret1" {
		t.Fatalf("got %+v, %v", c, err)
	}
	if !slices.Equal(f.fetches, []string{"https://radius.example/api/credentials"}) {
		t.Fatalf("fetched %v", f.fetches)
	}
	// Good for a while: no new request.
	if c, _ := l.credentials(context.Background()); c.Password != "secret1" || len(f.fetches) != 1 {
		t.Fatalf("not cached: %+v %v", c, f.fetches)
	}
	// About to expire: asked again.
	l.creds.Expiry = time.Now().Add(radiusMargin - time.Second)
	if c, _ := l.credentials(context.Background()); c.Password != "secret2" {
		t.Fatalf("not renewed: %+v", c)
	}

	for code, want := range map[int]string{401: "no Kerberos ticket", 403: "may not log in", 502: "HTTP 502"} {
		f := &fakeLaunch{code: code, expiry: time.Now().Add(time.Hour)}
		if _, err := newTestLauncher(f).credentials(context.Background()); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("HTTP %d: got %v", code, err)
		}
	}
}

func TestLauncherWeb(t *testing.T) {
	f := &fakeLaunch{code: 200, expiry: time.Now().Add(time.Hour)}
	l := newTestLauncher(f)
	ups, _ := l.host("ups")
	l.openWeb(ups)
	if !slices.Equal(f.copied, []string{"secret1"}) || !slices.Equal(f.opened, []string{"https://ups.example/"}) {
		t.Fatalf("copied %v, opened %v", f.copied, f.opened)
	}
	select { // in the background
	case s := <-f.cleared:
		if s != "secret1" {
			t.Fatalf("cleared %q", s)
		}
	case <-time.After(time.Second):
		t.Fatal("not cleared")
	}
	if len(f.notes.log) != 2 || !strings.Contains(f.notes.log[1], "as dori") {
		t.Fatalf("notes %v", f.notes.log)
	}

	// Without RADIUS it only opens the page.
	unifi, _ := l.host("unifi")
	l.openWeb(unifi)
	if len(f.fetches) != 1 || len(f.copied) != 1 || f.opened[1] != "https://unifi.example/" {
		t.Fatalf("plain web UI: fetches %v copied %v opened %v", f.fetches, f.copied, f.opened)
	}
}

func TestLauncherKVM(t *testing.T) {
	f := &fakeLaunch{code: 200, expiry: time.Now().Add(time.Hour)}
	l := newTestLauncher(f)
	h, _ := l.host("bengalfox")

	l.openKVM(h)
	if len(f.started) != 0 || len(f.fetches) != 0 || !strings.Contains(f.notified[0], "netcmdr-view not found") {
		t.Fatalf("without netcmdr-view: started %v, notified %v", f.started, f.notified)
	}

	f.path = []string{"netcmdr-view"}
	l.openKVM(h)
	if len(f.started) != 1 {
		t.Fatalf("started %v", f.started)
	}
	cmd := f.started[0]
	if !slices.Equal(cmd.Args, []string{"netcmdr-view", "--target", "3"}) {
		t.Fatalf("args %v", cmd.Args)
	}
	for _, want := range []string{"NETCMDR_HOST=kvm.example", "NETCMDR_USER=dori", "NETCMDR_PASSWORD=secret1"} {
		if !slices.Contains(cmd.Env, want) {
			t.Errorf("env lacks %s", want)
		}
	}
	f.onExit(errors.New("exit status 1"), "connecting\nError: login refused\n")
	if last := f.notified[len(f.notified)-1]; last != "The console of bengalfox closed: Error: login refused" {
		t.Fatalf("exit note %q", last)
	}
}

func TestLauncherTerminal(t *testing.T) {
	f := &fakeLaunch{}
	l := newTestLauncher(f)
	h, _ := l.host("bengalfox")

	l.openSSH(h)
	if len(f.started) != 0 || !strings.Contains(f.notified[0], "no terminal") {
		t.Fatalf("no terminal: %v %v", f.started, f.notified)
	}
	for _, c := range []struct {
		path []string
		want []string
	}{
		{[]string{"konsole", "xterm"}, []string{"konsole", "-e", "ssh", "bengalfox.example"}},
		{[]string{"gnome-terminal"}, []string{"gnome-terminal", "--", "ssh", "bengalfox.example"}},
		{[]string{"konsole", "xdg-terminal-exec"}, []string{"xdg-terminal-exec", "ssh", "bengalfox.example"}},
	} {
		f.path, f.started = c.path, nil
		l.openSSH(h)
		if len(f.started) != 1 || !slices.Equal(f.started[0].Args, c.want) {
			t.Errorf("with %v: started %v", c.path, f.started)
		}
	}
}
